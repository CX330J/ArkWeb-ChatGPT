import { webview } from '@kit.ArkWeb';
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { MihomoCore, CoreOpResult } from './MihomoCore';
import { ParsedNode } from './SubscriptionLoader';
import { buildMihomoConfig, ConfigBuildInput, DEFAULT_MIXED_PORT } from './ConfigBuilder';
import { Subscriptions, SubscriptionData } from './Subscriptions';
import { strategyName, withAppStrategies } from './ProxyStrategies';
import { PROXY_TEST_URL, PROXY_TEST_TIMEOUT_MS } from './ProxyConstants';
import { AutoSelect, AutoSelectResult } from './AutoSelect';
import { ProxySettingsStore, ProxySettings } from './ProxySettings';

export enum ProxyState { IDLE = 0, STARTING = 1, RUNNING = 2, STOPPING = 3, ERROR = 4 }
export interface OpResult { ok: boolean; error?: string; nodeCount?: number; version?: string; }
export interface PingResult { ok: boolean; latencyMs: number; error?: string; }
export interface ProxySnapshot { now?: string; type?: string; all?: string[]; }
/** 内核累计流量与活动连接数（用于面板展示）。 */
export interface TrafficStats {
  uploadTotal: number;
  downloadTotal: number;
  activeConnections: number;
}
interface ConnectionsBody {
  downloadTotal: number;
  uploadTotal: number;
  connections: Object[];
}
interface DelayResponse { delay: number; }
interface SelectionBody { name: string; }
interface ControlResult { ok: boolean; body: string; error?: string; }
export type ProxyListener = (state: ProxyState, routeChanged: boolean) => void;

/** 内核和 ArkWeb 代理的唯一入口；保存的开关意愿与实际运行状态分别管理。 */
export class ProxyManager {
  private static state: ProxyState = ProxyState.IDLE;
  private static lastError: string = '';
  private static busy: boolean = false;
  private static listeners: Set<ProxyListener> = new Set();
  private static secret: string = util.generateRandomUUID(true) + util.generateRandomUUID(true);
  private static routeName: string = '';
  private static restoreTask: Promise<void> | null = null;
  /** 本次启动是否需要在 busy 释放后补一次自动选路。 */
  private static pendingAutoSelect: boolean = false;
  private static lifecycleGeneration: number = 0;
  /**
   * 用户最后一次手动选节点的时间。
   *
   * 自动换路必须尊重手动选择：用户刚点了某个节点，紧接着一次探测抖动就把它换掉，
   * 会让人以为"我点了没用"。界面在冷却期内跳过自动换路。
   */
  private static lastManualSelectAt: number = 0;

  static getState(): ProxyState { return ProxyManager.state; }
  static getLastManualSelectAt(): number { return ProxyManager.lastManualSelectAt; }
  static getLastError(): string { return ProxyManager.lastError; }
  static getPort(): number { return DEFAULT_MIXED_PORT; }
  static isBusy(): boolean { return ProxyManager.busy; }
  /**
   * 当前配置里"应用出口"策略组的名字。
   *
   * 由 startCore 在生成配置时写入，是唯一权威值：自动选路必须用它去问内核，
   * 不能在别处再算一次 —— 命名带重名避让（订阅已有同名组时追加 " ·"），
   * 两处独立计算迟早会算出不同的名字。
   */
  static getRouteName(): string { return ProxyManager.routeName; }
  static subscribe(listener: ProxyListener): void { ProxyManager.listeners.add(listener); }
  static unsubscribe(listener: ProxyListener): void { ProxyManager.listeners.delete(listener); }

  private static publish(state: ProxyState, changed: boolean = false): void {
    ProxyManager.state = state;
    // 逐个隔离：监听器里抛异常不能中断调用方的 try/finally，
    // 否则 busy 会永远停在被这次 publish 卡住的那一刻（之后所有操作都提示"正在切换"）。
    ProxyManager.listeners.forEach((listener: ProxyListener) => {
      try {
        listener(state, changed);
      } catch (err) {
        console.error('MihomoProxy: 状态监听器异常 ' + JSON.stringify(err));
      }
    });
  }

  /** 冷启动只读本地缓存；失败保留用户的开启意愿，下次启动仍可重试。 */
  static async restore(ctx: common.UIAbilityContext): Promise<void> {
    if (ProxyManager.restoreTask === null) {
      ProxyManager.restoreTask = ProxyManager.restoreSaved(ctx).catch((err: Object) => {
        // 失败的 Promise 不能被缓存：否则本进程内后续每次 restore 都会立刻拿到
        // 同一个拒绝，代理在本进程内再也不会自动启动。清掉缓存，下次还能重试。
        ProxyManager.restoreTask = null;
        console.error('MihomoProxy: 恢复代理失败 ' + JSON.stringify(err));
      });
    }
    await ProxyManager.restoreTask;
  }

  private static async restoreSaved(ctx: common.UIAbilityContext): Promise<void> {
    await Subscriptions.init(ctx);
    if (Subscriptions.isEnabled()) { await ProxyManager.enable(ctx, false, false); }
  }

  static async enable(ctx: common.UIAbilityContext, forceFetch: boolean = false,
    allowNetwork: boolean = true): Promise<OpResult> {
    if (ProxyManager.busy) { return { ok: false, error: '正在切换连接，请稍候' }; }
    if (ProxyManager.state === ProxyState.RUNNING) { return { ok: true }; }
    ProxyManager.busy = true;
    ProxyManager.lastError = '';
    ProxyManager.publish(ProxyState.STARTING);
    let result: OpResult;
    try {
      await Subscriptions.init(ctx);
      await Subscriptions.setEnabled(true);
      // 自动选路要在内核起来之后立刻跑，不能让用户再点一次。
      // 开关是否打开由 runPendingAutoSelect 统一判断，这里只登记"需要选路"。
      result = await ProxyManager.startCore(ctx, forceFetch, allowNetwork, true);
    } catch (err) {
      try { await ProxyManager.removeWebProxy(); } catch (cleanupError) {
        // 移除代理失败也必须停内核：内核活着但状态是 ERROR 的话，
        // 下一次 enable 会在已运行的内核上再次 start，必然失败，用户要连点两次。
        MihomoCore.stop();
        ProxyManager.busy = false;
        return ProxyManager.fail('移除代理失败，请重试关闭代理');
      }
      MihomoCore.stop();
      ProxyManager.busy = false;
      return ProxyManager.fail(ProxyManager.errText(err));
    }
    // busy 必须在选路之前释放：pingNode 需要它，否则会互相等待。
    ProxyManager.busy = false;
    // 不等待选路结果：全量测速按节点数可能要几秒到十几秒，
    // 而冷启动的首屏导航就在等 enable() 返回 —— 等它会把"代理已就绪"推迟到测速之后。
    ProxyManager.runPendingAutoSelect(ctx).catch(() => {});
    return result;
  }

  private static async startCore(ctx: common.UIAbilityContext, forceFetch: boolean,
    allowNetwork: boolean, autoSelect: boolean = false): Promise<OpResult> {
    const generation: number = ProxyManager.lifecycleGeneration;
    const active = Subscriptions.getActive();
    if (active === null) { return ProxyManager.fail('请先添加订阅'); }
    let data: SubscriptionData | null = null;
    if (forceFetch) {
      const fetched = await Subscriptions.fetch(ctx, active.id, true);
      if (fetched.ok) {
        data = { nodes: fetched.nodes, groups: fetched.groups, rules: fetched.rules,
          ruleProviders: fetched.ruleProviders };
      }
    } else { data = await Subscriptions.getActiveDataForStart(ctx, allowNetwork); }
    if (data === null || data.nodes.length === 0) {
      return ProxyManager.fail('没有可用的本地节点，请更新订阅后重试');
    }
    if (generation !== ProxyManager.lifecycleGeneration) {
      return { ok: false, error: '代理启动已取消' };
    }
    const load = MihomoCore.load(ctx.bundleCodeDir, ctx.filesDir);
    if (!load.ok) { return ProxyManager.fail('内核加载失败：' + (load.error ?? '未知错误')); }
    const input: ConfigBuildInput = {
      nodes: data.nodes, groups: data.groups, rules: data.rules, ruleProviders: data.ruleProviders,
      rulesDir: ctx.filesDir + '/rules', selectedNode: Subscriptions.getActiveNode(),
      selectedGroup: Subscriptions.getActiveGroup(), mixedPort: DEFAULT_MIXED_PORT,
      controllerSecret: ProxyManager.secret, groupSelections: Subscriptions.getGroupSelections()
    };
    const rulesDir: string = ctx.filesDir + '/rules';
    if (!fileIo.accessSync(rulesDir)) { fileIo.mkdirSync(rulesDir); }
    const path: string = ctx.filesDir + '/mihomo_active.yaml';
    const f = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
    try { fileIo.writeSync(f.fd, buildMihomoConfig(input)); } finally { fileIo.closeSync(f); }
    ProxyManager.routeName = strategyName(withAppStrategies(data.nodes, data.groups), '出口');
    const started: CoreOpResult = await MihomoCore.start(path);
    if (generation !== ProxyManager.lifecycleGeneration) {
      return { ok: false, error: '代理启动已取消' };
    }
    if (!started.ok) {
      MihomoCore.stop();
      return ProxyManager.fail('内核启动失败：' + (started.lastError ?? started.error ?? '未知错误'));
    }
    // 就绪等待：这是冷启动首屏导航的关键路径，必须有明确上界。
    // 每次用短超时（probe=true，read 2s），再加"次数 + 总时长"双限；
    // 只按次数不限时长的话，内核"能连上但不回应"时能拖好几分钟白屏。
    let ready: boolean = false;
    const readyDeadline: number = Date.now() + 12000;
    for (let i = 0; i < 20; i++) {
      if (Date.now() >= readyDeadline) { break; }
      const result = await ProxyManager.control('/version', http.RequestMethod.GET, '', true);
      if (generation !== ProxyManager.lifecycleGeneration) {
        return { ok: false, error: '代理启动已取消' };
      }
      if (result.ok) { ready = true; break; }
      await new Promise<void>((resolve) => { setTimeout(resolve, 150); });
    }
    if (!ready) { MihomoCore.stop(); return ProxyManager.fail('代理控制器未就绪，请重试'); }
    await ProxyManager.applyWebProxy();
    if (generation !== ProxyManager.lifecycleGeneration) {
      await ProxyManager.removeWebProxy();
      return { ok: false, error: '代理启动已取消' };
    }
    ProxyManager.publish(ProxyState.RUNNING, true);
    // 自动选路不能放在 busy 持有期间：pingNode 需要 busy=false 才能测速，
    // 而选路又在等 busy 释放 —— 两边互等会死锁。所以这里只登记一个"待选路"标记，
    // 由 enable() 在 finally 释放 busy 之后再执行（见 enable 的调用处）。
    if (autoSelect) {
      ProxyManager.pendingAutoSelect = true;
    }
    return { ok: true, nodeCount: data.nodes.length, version: load.version };
  }

  /**
   * 在 busy 释放之后执行的自动选路。
   * 由 enable/restartIfRunning 在 finally 之后调用，调用方不需要关心时机。
   */
  static async runPendingAutoSelect(ctx: common.UIAbilityContext): Promise<void> {
    if (!ProxyManager.pendingAutoSelect) {
      return;
    }
    // 开关在这里统一生效：enable / restartIfRunning / recover 三条路径都会经过这里，
    // 各自再读一遍设置既重复又容易漏（restartIfRunning 曾经就没读）。
    //
    // 注意清理标记的时机：只有"确实不需要选路"（开关关闭）或"这一轮跑完"
    // 才清标记。如果因为别的原因提前返回，标记必须留着，让下一轮还能补上。
    try {
      await ProxySettingsStore.init(ctx);
      const settings: ProxySettings = await ProxySettingsStore.load();
      if (!settings.autoSelectOnStart) {
        ProxyManager.pendingAutoSelect = false;
        return;
      }
    } catch (settingsError) { /* 读设置失败时按默认值继续 */ }
    ProxyManager.pendingAutoSelect = false;
    try {
      // 正在跑的那一轮可能属于"上一个内核/上一份订阅"：等它结束后再跑一轮自己的，
      // 而不是复用它的结果（复用会拿旧节点表的延迟去改新配置的出口）。
      // 等待设上限：一轮测速正常 9s 内结束，等过头说明对端异常，直接放弃本轮，
      // 由下一次健康探测或用户手动触发补上，绝不无限等待。
      const deadline: number = Date.now() + 30000;
      while (AutoSelect.isRunning() && Date.now() < deadline) {
        await new Promise<void>((resolve) => { setTimeout(resolve, 200); });
        // 等待期间用户可能关掉代理。
        if (ProxyManager.state !== ProxyState.RUNNING) {
          return;
        }
      }
      if (ProxyManager.state !== ProxyState.RUNNING) {
        return;
      }
      // 用户选了负载均衡出口时不做应用层选路：节点切换交给内核的健康检查，
      // 应用层改出口会把均衡组换成单节点，并触发一次网页刷新（用户明确不要）。
      if (await ProxyManager.routeUsesBalance()) {
        console.info('MihomoProxy: 自动选路跳过（当前出口为负载均衡组）');
        return;
      }
      // 排队期间如果又被登记了一次（例如刚切完订阅），标记可能已重新置位；
      // 无论如何这里只跑一轮，跑完统一清掉，避免"标记遗留导致下一轮再测一遍"。
      const picked: AutoSelectResult = await AutoSelect.run(ctx);
      ProxyManager.pendingAutoSelect = false;
      if (picked.ok) {
        console.info('MihomoProxy: 自动选路 -> ' + picked.node +
          ' (' + picked.latencyMs.toString() + 'ms, tested=' + picked.tested.toString() + ')');
      } else {
        console.warn('MihomoProxy: 自动选路跳过 ' + (picked.error ?? '未知原因'));
      }
    } catch (err) {
      console.warn('MihomoProxy: 自动选路异常 ' + JSON.stringify(err));
    }
  }

  static async disable(): Promise<OpResult> {
    if (ProxyManager.busy) { return { ok: false, error: '正在切换连接，请稍候' }; }
    ProxyManager.busy = true;
    ProxyManager.publish(ProxyState.STOPPING);
    try {
      await Subscriptions.setEnabled(false);
      await ProxyManager.removeWebProxy();
      const stopped = MihomoCore.stop();
      if (!stopped.ok) {
        // 关闭失败时把"开启意愿"改回去：内核可能还在跑，
        // 否则下次启动不会恢复代理，而用户看到的却是"已开启过"。
        await Subscriptions.setEnabled(true);
        return ProxyManager.fail('内核关闭失败');
      }
      ProxyManager.publish(ProxyState.IDLE, true);
      return { ok: true };
    } catch (err) {
      // 关闭流程中途抛异常时内核也可能还活着：停一次再报错，保证"已关闭"是可信状态。
      MihomoCore.stop();
      return ProxyManager.fail('关闭代理失败：' + ProxyManager.errText(err));
    }
    finally { ProxyManager.busy = false; }
  }

  /**
   * Ability 销毁时的静默清理：停内核、摘掉应用代理、把运行状态复位。
   *
   * 和 disable() 的区别：**不改写"开启意愿"**。
   * disable() 会 Subscriptions.setEnabled(false)，而用户只是退出应用、并没有关代理，
   * 下次启动仍应自动恢复。
   *
   * 必须复位 state：UIAbility 可能在同一进程里重建（例如窗口被回收后重新拉起），
   * 静态 state 若还停在 RUNNING，restore() → enable() 会直接返回成功，
   * 内核其实已经停了，表现为"界面显示已连接但网页没网"。
   *
   * 同步执行：onDestroy 不能 await。removeWebProxy 是异步回调，
   * 退出路径上尽力而为即可 —— 窗口都要销毁了，残留的代理覆盖不影响进程回收。
   */
  static shutdown(): void {
    ProxyManager.lifecycleGeneration++;
    ProxyManager.restoreTask = null;
    ProxyManager.pendingAutoSelect = false;
    ProxyManager.removeWebProxy().catch(() => {});
    MihomoCore.stop();
    ProxyManager.busy = false;
    ProxyManager.publish(ProxyState.IDLE);
  }

  /** 切换订阅才重载配置，全程持有同一把锁，不改写开启意愿。 */
  static async restartIfRunning(ctx: common.UIAbilityContext): Promise<OpResult> {
    if (ProxyManager.busy) { return { ok: false, error: '正在切换连接，请稍候' }; }
    if (ProxyManager.state !== ProxyState.RUNNING) { return { ok: true }; }
    ProxyManager.busy = true;
    ProxyManager.publish(ProxyState.STARTING);
    let result: OpResult;
    try {
      await ProxyManager.removeWebProxy();
      const stopped = MihomoCore.stop();
      if (!stopped.ok) {
        ProxyManager.busy = false;
        return ProxyManager.fail('无法停止旧连接');
      }
      // 切订阅后节点集合变了，重新测速才有意义。
      result = await ProxyManager.startCore(ctx, false, false, true);
    } catch (err) {
      MihomoCore.stop();
      ProxyManager.busy = false;
      return ProxyManager.fail(ProxyManager.errText(err));
    }
    ProxyManager.busy = false;
    // 同样不阻塞：restartIfRunning 的调用方（切订阅）在等返回结果更新界面，
    // 没必要为测速再等十几秒；选路完成后会自行 publish 触发刷新。
    ProxyManager.runPendingAutoSelect(ctx).catch(() => {});
    return result;
  }

  /**
   * 后台被系统回收后的自愈。
   *
   * 现象：切后台一段时间再回来，网页还在但完全不通 —— ArkWeb 的代理设置仍指向
   * 127.0.0.1:7890，而那个端口背后的内核已经被系统杀掉（或监听被回收）。
   * 状态字段还是 RUNNING，因为进程内的静态变量不会因为内核进程死掉而改变。
   *
   * 判定方式：直接问内核控制端口。它不通就重建内核 + 重新应用代理设置。
   *
   * @param reapplyProxy 内核正常时是否也重新下发一次应用级代理设置。
   *   仅"从后台回来"时传 true：那时系统可能已经把代理设置清掉（换网络、Web 进程回收）。
   *   运行中诊断链路时传 false —— 重复下发会重置 ArkWeb 的网络栈，
   *   可能把页面上正在用的长连接一起断掉。
   *
   * 【锁的归属】探测（最长 10s）期间必须持锁：否则用户在这段时间里关掉代理，
   * 探测晚到的结果会把代理设置重新装回去，指向一个已经停掉的内核。
   * 所以先在入口拿 busy，拿到之后所有 return 都经过 finally 释放；
   * 这也意味着探测期间其它操作会收到"正在切换连接"，这是可接受的代价。
   */
  static async recover(ctx: common.UIAbilityContext, reapplyProxy: boolean = false): Promise<OpResult> {
    if (ProxyManager.state !== ProxyState.RUNNING) { return { ok: true }; }
    if (ProxyManager.busy) { return { ok: false, error: '正在切换连接，请稍候' }; }
    ProxyManager.busy = true;
    try {
      // 用短超时探测：这里是"回前台/断网诊断"的热路径，内核假死时不该让
      // 用户握着锁等 10 秒才知道要重建。
      const probe = await ProxyManager.control('/version', http.RequestMethod.GET, '', true);
      if (probe.ok) {
        if (reapplyProxy) {
          // applyProxyOverride 幂等，代价只有一次 IPC；失败保持现状即可。
          try { await ProxyManager.applyWebProxy(); } catch (applyError) { /* 保持现状 */ }
        }
        return { ok: true };
      }
      // 探测期间用户可能已经关掉了代理：此时重建毫无意义，直接放弃。
      if (ProxyManager.state !== ProxyState.RUNNING) { return { ok: true }; }
      console.warn('MihomoProxy: 内核无响应，开始重建');
      ProxyManager.publish(ProxyState.STARTING);
      // 代理设置可能还残留着，先移除；失败不阻断重建。
      try { await ProxyManager.removeWebProxy(); } catch (removeError) { /* 忽略 */ }
      // 内核可能已经死了，stop 失败属于预期，不影响后续重建。
      MihomoCore.stop();
      const result: OpResult = await ProxyManager.startCore(ctx, false, false, true);
      ProxyManager.busy = false;
      ProxyManager.runPendingAutoSelect(ctx).catch(() => {});
      return result;
    } catch (err) {
      // 走到这里说明 startCore 内部抛了（正常失败都会返回 OpResult）。
      // 内核可能已经起来了但后续步骤失败：必须停掉，否则下一次 enable 会双启动。
      MihomoCore.stop();
      return ProxyManager.fail(ProxyManager.errText(err));
    } finally {
      ProxyManager.busy = false;
    }
  }

  /** Clash 原生 select 策略切换，不重启内核。manual=false 表示这是自动选路发起的。 */
  static async select(group: string, node: string, withinGroup: string = '',
    manual: boolean = true): Promise<OpResult> {
    if (ProxyManager.busy) { return { ok: false, error: '正在切换连接，请稍候' }; }
    ProxyManager.busy = true;
    try {
      const target: string = group.length > 0 ? group : node;
      if (ProxyManager.state === ProxyState.RUNNING) {
        if (withinGroup.length > 0) {
          const member = await ProxyManager.putSelection(withinGroup, node);
          if (!member.ok) { return member; }
        }
        const result = await ProxyManager.putSelection(ProxyManager.routeName, target);
        if (!result.ok) { return result; }
      }
      if (withinGroup.length > 0) { await Subscriptions.setGroupSelection(withinGroup, node); }
      await Subscriptions.setSelection(group, group.length > 0 ? '' : node);
      if (manual && node.length > 0) { ProxyManager.lastManualSelectAt = Date.now(); }
      if (ProxyManager.state === ProxyState.RUNNING) {
        // 【切到/切自负载均衡组时不清连接、不发 routeChanged】
        // 用户明确要求：负载均衡的节点切换不要刷新网页和界面。
        // 这里切换的是"总入口选哪个国家组"或"均衡组本身"，内核会自己按健康检查轮转成员，
        // 网页上的连接完全不需要重来 —— 清了反而把正在进行的流式回复打断。
        // 其它情况保持原行为：出口从 A 节点换到 B 节点，长连接确实还挂在旧出口上，必须重建。
        const balanced: boolean = await ProxyManager.routeUsesBalance();
        if (!balanced) {
          await ProxyManager.control('/connections', http.RequestMethod.DELETE);
          ProxyManager.publish(ProxyState.RUNNING, true);
        } else {
          ProxyManager.publish(ProxyState.RUNNING, false);
        }
      }
      return { ok: true };
    } finally { ProxyManager.busy = false; }
  }

  private static async putSelection(group: string, name: string): Promise<OpResult> {
    const body: SelectionBody = { name: name };
    const result = await ProxyManager.control('/proxies/' + encodeURIComponent(group),
      http.RequestMethod.PUT, JSON.stringify(body));
    return { ok: result.ok, error: result.error };
  }

  static async snapshot(name: string): Promise<ProxySnapshot | null> {
    if (ProxyManager.state !== ProxyState.RUNNING) { return null; }
    const result = await ProxyManager.control('/proxies/' + encodeURIComponent(name));
    if (!result.ok) { return null; }
    try { const parsed: ProxySnapshot = JSON.parse(result.body); return parsed; } catch (err) { return null; }
  }

  /**
   * 当前出口链路是否经过 load-balance 组。
   *
   * 【为什么需要它】负载均衡组由**内核自己**做健康检查和成员切换：
   * 某个节点挂了，内核把它踢出轮转，下一次连接自动落到别的节点，全程不通知应用层。
   * 应用层的自动选路如果同时插手，会做两件有害的事：
   *   ① 把出口从"组"改成"单个节点"（`select` 覆盖），均衡能力直接失效；
   *   ② `select` 会 DELETE /connections 并发布 routeChanged，导致网页刷新、界面跳动。
   * 用户明确要求：负载均衡的节点切换不要刷新网页和界面。
   *
   * 判断方式问内核（`/proxies/<name>` 的 `type` 字段），不自己猜：
   * 应用侧生成的策略组不在 `Subscriptions.getActiveGroups()` 里，靠本地数据判断不了。
   */
  static async routeUsesBalance(): Promise<boolean> {
    if (ProxyManager.state !== ProxyState.RUNNING) { return false; }
    let name: string = ProxyManager.routeName;
    const visited: Set<string> = new Set();
    for (let depth = 0; depth < 12 && name.length > 0 && !visited.has(name); depth++) {
      visited.add(name);
      const snap: ProxySnapshot | null = await ProxyManager.snapshot(name);
      if (snap === null) { return false; }
      if (snap.type !== undefined && /loadbalance/i.test(snap.type)) { return true; }
      if (snap.now === undefined || snap.now === name) { return false; }
      name = snap.now;
    }
    return false;
  }

  /**
   * 读取内核累计上/下行字节数与活动连接数（源数据：mihomo `/connections`）。
   *
   * 只做汇总、不计算速率：速率需要两次采样和一个时间窗，面板每 5 秒刷新一次，
   * 直接展示累计值更稳定，也不会因为漏采样而跳变。内核未运行时返回 null。
   */
  static async traffic(): Promise<TrafficStats | null> {
    if (ProxyManager.state !== ProxyState.RUNNING) { return null; }
    const result: ControlResult = await ProxyManager.control('/connections', http.RequestMethod.GET, '', true);
    if (!result.ok || result.body.length === 0) { return null; }
    try {
      const body: ConnectionsBody = JSON.parse(result.body) as ConnectionsBody;
      const connections: Object[] = body.connections !== undefined && Array.isArray(body.connections)
        ? body.connections : [];
      const stats: TrafficStats = {
        uploadTotal: typeof body.uploadTotal === 'number' ? body.uploadTotal : 0,
        downloadTotal: typeof body.downloadTotal === 'number' ? body.downloadTotal : 0,
        activeConnections: connections.length
      };
      return stats;
    } catch (err) {
      return null;
    }
  }

  /** 经节点协议、TLS 和目标 HTTP 请求测试延迟，使用 mihomo URLTest。 */
  static async pingNode(node: ParsedNode): Promise<PingResult> {
    // 启用流程内部也会调用测速，此时 busy 仍为 true（直到 enable 返回）。
    // 直接拒绝会让"启动时自动选路"永远测不到任何节点，所以这里等一小段时间
    // 让出给正在进行的切换，而不是立刻失败。
    const waited: boolean = await ProxyManager.waitIdle(3000);
    if (ProxyManager.state !== ProxyState.RUNNING) {
      return { ok: false, latencyMs: -1, error: '请先开启代理再测速' };
    }
    if (!waited) {
      return { ok: false, latencyMs: -1, error: '代理正忙，跳过本轮测速' };
    }
    const result = await ProxyManager.control('/proxies/' + encodeURIComponent(node.name) +
      '/delay?timeout=' + PROXY_TEST_TIMEOUT_MS.toString() + '&url=' + encodeURIComponent(PROXY_TEST_URL));
    if (!result.ok) { return { ok: false, latencyMs: -1, error: result.error }; }
    try {
      const parsed: DelayResponse = JSON.parse(result.body);
      if (typeof parsed.delay === 'number' && parsed.delay > 0) { return { ok: true, latencyMs: parsed.delay }; }
    } catch (err) { /* 非法响应按测速失败处理 */ }
    return { ok: false, latencyMs: -1, error: '节点未返回有效延迟' };
  }

  /**
   * 等待 busy 标志释放，最多 timeoutMs。
   * 返回 true 表示已空闲，false 表示超时仍忙。
   */
  private static async waitIdle(timeoutMs: number): Promise<boolean> {
    if (!ProxyManager.busy) {
      return true;
    }
    const deadline: number = Date.now() + timeoutMs;
    while (ProxyManager.busy && Date.now() < deadline) {
      await new Promise<void>((resolve) => { setTimeout(resolve, 50); });
    }
    return !ProxyManager.busy;
  }

  /**
   * 请求本地控制器。
   *
   * readTimeout 默认 10s 是按"测速请求"估的（内核要等远端节点回应）；
   * 但控制面自己的小请求（/version、/proxies、选路 PUT）只需要毫秒级，
   * 用 10s 会让一次内核卡死最多拖住调用方 10 秒。这里按用途分开：
   * probe=true 用短超时，只有测速才用长超时。
   */
  private static async control(path: string, method: http.RequestMethod = http.RequestMethod.GET,
    body: string = '', probe: boolean = false): Promise<ControlResult> {
    const request = http.createHttp();
    try {
      const response = await request.request('http://127.0.0.1:9090' + path, {
        method: method, header: { 'Authorization': 'Bearer ' + ProxyManager.secret, 'Content-Type': 'application/json' },
        extraData: body, connectTimeout: 700, readTimeout: probe ? 2000 : 10000,
        expectDataType: http.HttpDataType.STRING, usingCache: false, usingProxy: false
      });
      const text: string = typeof response.result === 'string' ? response.result : '';
      return { ok: response.responseCode >= 200 && response.responseCode < 300, body: text,
        error: response.responseCode >= 300 ? '内核请求失败（' + response.responseCode.toString() + '）' : undefined };
    } catch (err) { return { ok: false, body: '', error: '无法连接代理控制器' }; }
    finally { request.destroy(); }
  }

  private static applyWebProxy(): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      const timer: number = setTimeout(() => reject(new Error('应用代理设置超时')), 8000);
      try {
        const cfg = new webview.ProxyConfig();
        cfg.clearImplicitRules();
        cfg.insertProxyRule('http://127.0.0.1:' + DEFAULT_MIXED_PORT);
        cfg.insertProxyRule('socks://127.0.0.1:' + DEFAULT_MIXED_PORT);
        webview.ProxyController.applyProxyOverride(cfg, () => { clearTimeout(timer); resolve(); });
      } catch (err) { clearTimeout(timer); reject(new Error(ProxyManager.errText(err))); }
    });
  }

  private static removeWebProxy(): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      const timer: number = setTimeout(() => reject(new Error('移除应用代理超时')), 8000);
      try { webview.ProxyController.removeProxyOverride(() => { clearTimeout(timer); resolve(); }); }
      catch (err) { clearTimeout(timer); reject(new Error(ProxyManager.errText(err))); }
    });
  }

  private static fail(message: string): OpResult {
    ProxyManager.lastError = message;
    ProxyManager.publish(ProxyState.ERROR);
    console.error('MihomoProxy: ' + message);
    return { ok: false, error: message };
  }
  private static errText(err: Object | null | undefined): string {
    return err instanceof Error ? err.message : JSON.stringify(err);
  }
}
