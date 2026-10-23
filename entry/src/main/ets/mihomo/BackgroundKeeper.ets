/**
 * 后台常驻。
 *
 * 要解决的问题：
 *   应用切到后台后，系统会冻结进程、回收渲染进程、断开本地代理的内核监听。
 *   回到前台时表现出来就是"网络无法连接"——网页还在，但出口没了。
 *
 * 做法：
 *   申请一个 DATA_TRANSFER 类型的长时任务。这是系统允许的"持续运行"通道，
 *   应用在后台仍持有 CPU 配额，本地 127.0.0.1 的监听不会被回收。
 *
 * 为什么是 DATA_TRANSFER 而不是别的类型：
 *   · AUDIO_PLAYBACK / AUDIO_RECORDING / LOCATION 都要求真实对应的行为，
 *     没有音频却申请音频类型会被系统判定滥用并撤销任务；
 *   · DATA_TRANSFER 对应"持续的网络数据传输"，本应用后台维持代理链路正好吻合。
 *
 * 必要的工程配置（缺一不可）：
 *   · module.json5 声明 ohos.permission.KEEP_BACKGROUND_RUNNING
 *   · abilities 里声明 backgroundModes: ["dataTransfer"]
 *   两者缺任意一个，startBackgroundRunning 都会失败。
 *
 * 【DATA_TRANSFER 的进度约束】系统要求数据传任务"持续更新进度"，超过 10 分钟不更新
 * 会被判定为滥用并撤销（SDK 原文见 BackgroundMode.DATA_TRANSFER 的 Note）。
 * 本应用在后台并没有真实的上传/下载进度可言，所以这里用 updateBackgroundRunning
 * 做一次"心跳式更新"：只要进程还活着就周期性续期，进程被回收时心跳自然停止。
 * 这不是伪造进度，只是告诉系统"任务仍在运行"；不更新就会被系统直接杀掉，反而更差。
 *
 * 失败时的行为：
 *   一律当成"没有后台保活"继续跑，不影响前台功能。长时任务本身也可能被系统
 *   在低电量等场景撤销，所以每次进后台都要重新申请，不要长期缓存"已启动"状态。
 */

import { common, wantAgent, WantAgent, Want } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';

export interface KeepResult {
  ok: boolean;
  error?: string;
}

const REQUEST_CODE: number = 0x2001;
/** 续期间隔：系统在 10 分钟不更新时撤销，取 4 分钟留足余量。 */
const RENEW_INTERVAL_MS: number = 4 * 60 * 1000;

export class BackgroundKeeper {
  private static active: boolean = false;
  private static cachedAgent: WantAgent | null = null;
  private static renewTimer: number = 0;
  /** 串行化 acquire/release：两者都会 await 系统调用，交错执行会重复申请或漏续期。 */
  private static pending: Promise<void> = Promise.resolve();

  static isActive(): boolean {
    return BackgroundKeeper.active;
  }

  /** 申请后台常驻；已持有时直接返回成功。 */
  static acquire(ctx: common.UIAbilityContext): Promise<KeepResult> {
    return BackgroundKeeper.serialize(() => BackgroundKeeper.acquireInner(ctx));
  }

  /** 释放后台常驻；未启用时直接返回成功。 */
  static release(ctx: common.UIAbilityContext): Promise<KeepResult> {
    return BackgroundKeeper.serialize(() => BackgroundKeeper.releaseInner(ctx));
  }

  /**
   * 把 acquire/release 排成一条队。
   *
   * 不排队的具体后果：进后台的 acquire 还在等系统返回时用户又切回前台，
   * release 看到的 active 仍是 false 直接返回，随后 acquire 成功 ——
   * 长时任务就留在了前台，通知栏一条"正在运行"直到下次切后台。
   */
  private static serialize(task: () => Promise<KeepResult>): Promise<KeepResult> {
    const run: Promise<KeepResult> = BackgroundKeeper.pending.then(task, task);
    // 队尾只关心"上一个完成"，不关心它成功与否，否则一次失败会卡住整条队列。
    BackgroundKeeper.pending = run.then(() => {}, () => {});
    return run;
  }

  private static async acquireInner(ctx: common.UIAbilityContext): Promise<KeepResult> {
    if (BackgroundKeeper.active) {
      // 已持有但续期计时器可能因一次释放失败被停掉，补启动一次（幂等）。
      BackgroundKeeper.startRenew(ctx);
      return { ok: true };
    }
    try {
      const agent: WantAgent = await BackgroundKeeper.agent(ctx);
      await backgroundTaskManager.startBackgroundRunning(ctx,
        backgroundTaskManager.BackgroundMode.DATA_TRANSFER, agent);
      BackgroundKeeper.active = true;
      BackgroundKeeper.startRenew(ctx);
      console.info('BackgroundKeeper: 后台常驻已启用');
      return { ok: true };
    } catch (err) {
      // 权限未声明、backgroundModes 缺失、或被系统策略拒绝都会走到这里。
      // 不抛给调用方：没有后台保活只是体验降级，不应影响应用可用性。
      const text: string = err instanceof Error ? err.message : JSON.stringify(err);
      // 失败原因里有一种是"任务已存在"：系统侧还挂着上一条（本进程曾被回收、
      // 或上次续期失败时清掉了 active 但任务没真正撤销）。目标状态本来就是"有任务"，
      // 这种情况按已启用处理；否则会卡在 active=false，下次进后台又失败一次。
      // 不靠错误码字符串猜：直接问系统当前有没有连续任务，这才是权威答案。
      if (await BackgroundKeeper.hasSystemTask(ctx)) {
        BackgroundKeeper.active = true;
        BackgroundKeeper.startRenew(ctx);
        console.info('BackgroundKeeper: 系统侧已有连续任务，按已启用处理');
        return { ok: true };
      }
      console.warn('BackgroundKeeper: 启用失败 ' + text);
      return { ok: false, error: text };
    }
  }

  /**
   * 查询本应用当前是否持有连续任务。
   * API 不可用或查询失败时返回 false（按"没有"处理，调用方会正常报告失败）。
   */
  private static async hasSystemTask(ctx: common.UIAbilityContext): Promise<boolean> {
    try {
      const tasks: backgroundTaskManager.ContinuousTaskInfo[] =
        await backgroundTaskManager.getAllContinuousTasks(ctx);
      return tasks !== undefined && tasks.length > 0;
    } catch (err) {
      return false;
    }
  }

  private static async releaseInner(ctx: common.UIAbilityContext): Promise<KeepResult> {
    if (!BackgroundKeeper.active) {
      BackgroundKeeper.stopRenew();
      return { ok: true };
    }
    try {
      await backgroundTaskManager.stopBackgroundRunning(ctx);
      BackgroundKeeper.active = false;
      // 释放成功才停续期：系统调用失败时任务可能还在，计时器要留着继续续期。
      BackgroundKeeper.stopRenew();
      console.info('BackgroundKeeper: 后台常驻已释放');
      return { ok: true };
    } catch (err) {
      const text: string = err instanceof Error ? err.message : JSON.stringify(err);
      console.warn('BackgroundKeeper: 释放失败 ' + text);
      return { ok: false, error: text };
    }
  }

  /**
   * 周期续期，避免 DATA_TRANSFER 因"长时间无进度"被系统撤销。
   *
   * 失败处理：update 失败有两种可能 —— 任务真被系统撤销了，或只是一次偶发的服务调用失败。
   * 不靠错误文案猜，直接问系统当前还有没有任务：
   *   · 没有 -> 清掉 active，等下次进后台重新申请；
   *   · 有   -> 保持 active 继续续期，避免"任务还在、我们却以为没了"，
   *            那样下次 acquire 会重复申请，下次 release 又会跳过（通知栏留下一条删不掉的）。
   */
  private static startRenew(ctx: common.UIAbilityContext): void {
    BackgroundKeeper.stopRenew();
    BackgroundKeeper.renewTimer = setInterval(() => {
      if (!BackgroundKeeper.active) {
        BackgroundKeeper.stopRenew();
        return;
      }
      // 这里要的是 module.json5 里 backgroundModes 的字符串名，不是枚举值。
      backgroundTaskManager.updateBackgroundRunning(ctx,
        ['dataTransfer']).catch((err: Object) => {
          const text: string = err instanceof Error ? err.message : JSON.stringify(err);
          console.warn('BackgroundKeeper: 续期失败 ' + text);
          BackgroundKeeper.hasSystemTask(ctx).then((exists: boolean) => {
            if (!exists) {
              BackgroundKeeper.active = false;
              BackgroundKeeper.stopRenew();
              console.info('BackgroundKeeper: 系统侧任务已不存在，等待下次进后台重新申请');
            }
          }).catch(() => {});
        });
    }, RENEW_INTERVAL_MS);
  }

  private static stopRenew(): void {
    if (BackgroundKeeper.renewTimer !== 0) {
      clearInterval(BackgroundKeeper.renewTimer);
      BackgroundKeeper.renewTimer = 0;
    }
  }

  /**
   * 构造点击通知回到应用的 WantAgent。
   * 复用同一个实例，避免每次前后台切换都新建（会在通知栏堆条目）。
   */
  private static async agent(ctx: common.UIAbilityContext): Promise<WantAgent> {
    if (BackgroundKeeper.cachedAgent !== null) {
      return BackgroundKeeper.cachedAgent;
    }
    const want: Want = {
      bundleName: ctx.abilityInfo.bundleName,
      abilityName: ctx.abilityInfo.name
    };
    const info: wantAgent.WantAgentInfo = {
      wants: [want],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: REQUEST_CODE,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    const agent: WantAgent = await wantAgent.getWantAgent(info);
    BackgroundKeeper.cachedAgent = agent;
    return agent;
  }
}
