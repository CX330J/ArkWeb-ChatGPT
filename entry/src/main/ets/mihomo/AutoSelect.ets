/**
 * 自动选路与链路健康监测。
 *
 * 目标：
 *   1) 启动时自动测速，挑一条当前能通、延迟最低的节点，而不是沿用上次的选择；
 *   2) 运行中周期性探测，链路劣化就自动换一个更好的；
 *   3) 换完节点后由调用方决定是否刷新网页，让已建立的长连接重新走新出口。
 *
 * 为什么不直接依赖内核的 url-test 组：
 *   内核自带的 url-test 只比较"节点 → 测试 URL"的延迟，不关心节点是否真的能出网，
 *   也不会在整条链路（内核 → 节点 → 目标）失效时主动上报。这里做应用级判定：
 *   先测节点延迟，再由调用方结合真实目标连通性决定是否切换。
 *
 * 并发约束：
 *   ProxyManager.pingNode 在 busy 时直接拒绝，所以自动选路必须给用户的手动操作让路。
 *   run() 内部用同一个 Promise 复用，避免启动、定时器、前台恢复三处入口叠加。
 */

import { common } from '@kit.AbilityKit';
import { ParsedNode, ParsedGroup } from './SubscriptionLoader';
import { ProxyManager, PingResult, ProxyState, ProxySnapshot, OpResult } from './ProxyManager';
import { Subscriptions, SubscriptionData } from './Subscriptions';
import { PROXY_TEST_CONCURRENCY } from './ProxyConstants';
import { ProxyRegion, RegionInfo, RegionTier } from './ProxyRegion';

/** 自动选路结果。 */
export interface AutoSelectResult {
  ok: boolean;
  /** 选中的节点名；ok=false 时为空串 */
  node: string;
  /** 该节点延迟（毫秒）；未测到为 -1 */
  latencyMs: number;
  /** 参与测速的节点数 */
  tested: number;
  /** 本次是否真的切换了出口 */
  switched: boolean;
  /** 选中节点的地区（日本 / 新加坡 / 美国 …） */
  region?: string;
  /** 是否因为"出口真的换了"而需要重载页面（仅 switched 且出口名确实变化时为 true） */
  routeChanged?: boolean;
  error?: string;
}

export interface AutoSelectOptions {
  /** 只在候选节点里挑，空表示当前订阅全部节点 */
  candidates?: ParsedNode[];
  /** 当前延迟比最优慢多少毫秒以内就不切换（默认 40） */
  tolerance?: number;
  /** 整轮测速的时间上限（毫秒，默认 9000） */
  maxDurationMs?: number;
}

/** 健康探测结果。 */
export interface HealthResult {
  ok: boolean;
  latencyMs: number;
  error?: string;
}

/** 切换出口的结果。 */
export interface ApplyResult {
  ok: boolean;
  error?: string;
}

const DEFAULT_TOLERANCE: number = 40;
/**
 * 整轮测速的时间上限。
 *
 * 节点多的订阅动辄上百个，8 并发、单个超时 4s，最坏情况要测好几分钟 —— 用户等不起，
 * 而且这时候他多半已经在用网页了。到点就用手上已有的结果做决定：
 * 已经测通的节点足够选出"当前最优"，没轮到的下一轮再说。
 */
const DEFAULT_MAX_DURATION_MS: number = 9000;

export class AutoSelect {
  /** 正在进行的一轮；结束后自行清空。 */
  private static running: Promise<AutoSelectResult> | null = null;

  /**
   * 串行化入口：同一时刻只跑一个自动选路，并发调用复用同一轮。
   *
   * 为什么是复用它而不是排队再跑一轮：
   *   · 同一份节点表、同一个内核上重复测速没有任何新信息，只会把网络和内核一起拖慢；
   *   · 真正的"结果过期"场景（切了订阅、重建了内核）由 runPendingAutoSelect 处理 ——
   *     它会等当前这轮结束，再为新的配置跑一轮，不会复用旧结果。
   * 代价是后到的调用拿到的是同一轮结果，而不是它自己的参数结果；
   * 目前三个调用点（启动选路、健康自愈、面板手动测速）都不需要区分，可以接受。
   */
  static run(ctx: common.UIAbilityContext, opts?: AutoSelectOptions): Promise<AutoSelectResult> {
    if (AutoSelect.running !== null) {
      return AutoSelect.running;
    }
    const task: Promise<AutoSelectResult> = AutoSelect.runInner(ctx, opts);
    AutoSelect.running = task;
    task.then(() => {
      if (AutoSelect.running === task) { AutoSelect.running = null; }
    }).catch(() => {
      if (AutoSelect.running === task) { AutoSelect.running = null; }
    });
    return task;
  }

  static isRunning(): boolean {
    return AutoSelect.running !== null;
  }

  private static async runInner(ctx: common.UIAbilityContext,
    opts?: AutoSelectOptions): Promise<AutoSelectResult> {
    if (ProxyManager.getState() !== ProxyState.RUNNING) {
      return AutoSelect.miss('代理未运行', 0);
    }
    await Subscriptions.init(ctx);
    const data: SubscriptionData | null = await Subscriptions.getActiveData(ctx);
    if (data === null || data.nodes.length === 0) {
      return AutoSelect.miss('没有可用节点', 0);
    }

    const candidates: ParsedNode[] = (opts !== undefined && opts.candidates !== undefined &&
      opts.candidates.length > 0) ? opts.candidates : data.nodes;
    if (candidates.length === 0) {
      return AutoSelect.miss('候选节点为空', 0);
    }

    // 先按地区优先级排序再测速（日本 → 新加坡 → 美国 → 其它可用地区 → 未知 → 不可用）。
    //
    // 顺序既是"选择偏好"，也是"预算分配"：测速有 9 秒总预算，而订阅里常有上百个节点，
    // 排在后面的根本轮不到。香港节点距离最近、延迟最低，若按订阅原序测速，
    // 预算全花在香港/台湾上，日本节点永远测不到 —— 真机上就出现过选中「V香港 07」。
    const regions: Map<string, RegionInfo> = ProxyRegion.classifyAll(candidates);
    const ordered: ParsedNode[] = ProxyRegion.order(candidates, regions);

    // 当前出口名先取出来，延迟直接复用整轮测速的结果。
    // 早先的写法是"先单独 ping 当前节点，再全量测速"，等于把当前节点测了两遍：
    // 启动路径上平白多出最多一个超时周期（4s）的关键路径。
    const current: string = await AutoSelect.currentExit();

    const budget: number = opts !== undefined && opts.maxDurationMs !== undefined
      ? opts.maxDurationMs : DEFAULT_MAX_DURATION_MS;
    const probes: Map<string, number> = await AutoSelect.probeAll(ordered, budget);
    const currentLatency: number = current.length > 0 ? (probes.get(current) ?? -1) : -1;
    const usable: ParsedNode[] = ordered.filter((n: ParsedNode) => {
      const d: number | undefined = probes.get(n.name);
      return d !== undefined && d > 0;
    });
    if (usable.length === 0) {
      return AutoSelect.miss('所有节点均测速失败', candidates.length);
    }

    // 先比地区优先级，再比延迟：同一地区里挑延迟最低的那个。
    // 不能只按延迟排 —— 香港节点通常比日本快 100~200ms，单看延迟必然选香港，
    // 而香港是 ChatGPT 不可用地区，选出来等于把网页打不开。
    let best: ParsedNode = usable[0];
    let bestTier: number = AutoSelect.tierOf(regions, best.name);
    let bestLatency: number = probes.get(best.name) ?? -1;
    for (let i = 1; i < usable.length; i++) {
      const node: ParsedNode = usable[i];
      const tier: number = AutoSelect.tierOf(regions, node.name);
      const latency: number = probes.get(node.name) ?? -1;
      if (tier < bestTier || (tier === bestTier && latency < bestLatency)) {
        best = node;
        bestTier = tier;
        bestLatency = latency;
      }
    }
    const tolerance: number = opts !== undefined && opts.tolerance !== undefined
      ? opts.tolerance : DEFAULT_TOLERANCE;

    // 当前出口还在用，且"比最优没有更差的地区、延迟也在容差内" -> 不动，避免在相近节点间来回抖。
    //
    // 地区优先级必须参与判断：当前是香港（不可用地区）时，哪怕它 80ms、日本节点 200ms，
    // 也要切 —— 否则网页永远停在打不开的那条链路上，直到它自己劣化。
    if (currentLatency > 0) {
      const currentTier: number = AutoSelect.tierOf(regions, current);
      if (currentTier < bestTier) {
        return { ok: true, node: current, latencyMs: currentLatency, tested: candidates.length,
          switched: false, region: ProxyRegion.label(regions.get(current)) };
      }
      if (currentTier === bestTier && currentLatency <= bestLatency + tolerance) {
        return { ok: true, node: current, latencyMs: currentLatency, tested: candidates.length,
          switched: false, region: ProxyRegion.label(regions.get(current)) };
      }
    }

    const applied = await AutoSelect.applyNode(best);
    if (!applied.ok) {
      return AutoSelect.miss(applied.error ?? '切换出口失败', candidates.length);
    }
    return { ok: true, node: best.name, latencyMs: bestLatency,
      tested: candidates.length, switched: true, region: ProxyRegion.label(regions.get(best.name)),
      // 出口名没变（例如当初就是从枚举里挑的同一个节点）就不需要调用方再刷新一次页面。
      routeChanged: current.length === 0 || current !== best.name };
  }

  /** 取节点地区优先级；不在候选表里（例如当前出口属于其它分组）时就地识别一次。 */
  private static tierOf(regions: Map<string, RegionInfo>, name: string): number {
    const info: RegionInfo | undefined = regions.get(name);
    if (info !== undefined) {
      return info.tier;
    }
    return ProxyRegion.classify(name).tier;
  }

  private static miss(error: string, tested: number): AutoSelectResult {
    return { ok: false, node: '', latencyMs: -1, tested: tested, switched: false, error: error };
  }

  /**
   * 并发测速；失败的节点不进表，调用方按"不可用"处理。
   *
   * 带总时长预算：到点就不再领新节点，已经在测的那几个让它测完（内核侧的 delay 请求
   * 不会因为这里放弃而被取消）。这样"节点很多"时依然能在可控时间内给出结论。
   */
  private static async probeAll(nodes: ParsedNode[], maxDurationMs: number): Promise<Map<string, number>> {
    const result: Map<string, number> = new Map<string, number>();
    const deadline: number = Date.now() + maxDurationMs;
    let cursor: number = 0;
    const work = async (): Promise<void> => {
      while (true) {
        if (Date.now() >= deadline) {
          return;
        }
        const index: number = cursor++;
        if (index >= nodes.length) {
          return;
        }
        const node: ParsedNode = nodes[index];
        const ping: PingResult = await ProxyManager.pingNode(node);
        if (ping.ok && ping.latencyMs > 0) {
          result.set(node.name, ping.latencyMs);
        }
      }
    };
    const workers: Promise<void>[] = [];
    const width: number = Math.min(PROXY_TEST_CONCURRENCY, nodes.length);
    for (let i = 0; i < width; i++) {
      workers.push(work());
    }
    await Promise.all(workers);
    return result;
  }

  /** 把出口切到指定节点；withinGroup 用于同时更新子组的选择。 */
  static async applyNode(node: ParsedNode, withinGroup: string = ''): Promise<ApplyResult> {
    if (ProxyManager.getState() !== ProxyState.RUNNING) {
      const miss: ApplyResult = { ok: false, error: '代理未运行' };
      return miss;
    }
    // manual=false：这是自动选路发起的切换，不应刷新"用户手动选择"的冷却时间。
    const result: OpResult = await ProxyManager.select('', node.name, withinGroup, false);
    const applied: ApplyResult = { ok: result.ok, error: result.error };
    return applied;
  }

  /**
   * 解析当前真实出口（叶子节点名）。
   *
   * 策略组可以嵌套：应用出口组 → 用户订阅的分组 → 具体节点。
   * 逐层跟随内核返回的 now 指针，直到落到一个真实节点或到达深度上限。
   */
  static async currentExit(): Promise<string> {
    const nodes: ParsedNode[] = Subscriptions.getActiveNodes();
    const groups: ParsedGroup[] = Subscriptions.getActiveGroups();
    let name: string = ProxyManager.getRouteName();
    if (name.length === 0) {
      name = Subscriptions.getActiveNode();
    }
    const visited: Set<string> = new Set<string>();
    for (let depth = 0; depth < 12 && name.length > 0; depth++) {
      if (visited.has(name)) {
        break;
      }
      visited.add(name);
      if (nodes.some((n: ParsedNode) => n.name === name)) {
        return name;
      }
      if (!groups.some((g: ParsedGroup) => g.name === name)) {
        break;
      }
      const snap: ProxySnapshot | null = await ProxyManager.snapshot(name);
      if (snap === null || snap.now === undefined || snap.now === name) {
        break;
      }
      name = snap.now;
    }
    return name;
  }

}

/**
 * 链路健康监测。
 *
 * 只回答"现在这条链路还通不通"，不做节点挑选 —— 挑选交给 AutoSelect。
 * 连续失败达到阈值才判定不健康，避免一次抖动就触发换路。
 */
export class ProxyHealth {
  private static timer: number = 0;
  private static failures: number = 0;
  private static lastOk: boolean = true;
  private static onChange: (healthy: boolean) => void = () => {};
  private static threshold: number = 2;

  /**
   * 上次启动时用的参数。重复 start 只刷新回调、不重置失败计数 ——
   * 否则"回到前台时调用一次 start"会把"已经连续失败一次"的计数清零，
   * 链路明明已经坏了却永远攒不够阈值，自动换路永远不触发。
   */
  private static intervalMs: number = 0;

  /** 启动周期探测；intervalMs 为 0 表示停止。 */
  static start(intervalMs: number, threshold: number, onChange: (healthy: boolean) => void): void {
    ProxyHealth.onChange = onChange;
    ProxyHealth.threshold = threshold;
    if (intervalMs <= 0) {
      ProxyHealth.stop();
      return;
    }
    if (ProxyHealth.timer !== 0 && ProxyHealth.intervalMs === intervalMs) {
      return;
    }
    ProxyHealth.stop();
    ProxyHealth.intervalMs = intervalMs;
    ProxyHealth.failures = 0;
    ProxyHealth.lastOk = true;
    ProxyHealth.timer = setInterval(() => {
      ProxyHealth.check().catch(() => {});
    }, intervalMs);
  }

  /**
   * 停止周期探测。
   *
   * 只停计时器，**不清回调**：start() 在重建计时器时会先调用它，
   * 如果这里把 onChange 清掉，start() 刚装上的回调立刻就被抹掉，
   * 周期探测从此永远触发不到页面 —— 链路劣化自动切换会静默失效。
   * 页面销毁时的回调清理走 dispose()。
   */
  static stop(): void {
    if (ProxyHealth.timer !== 0) {
      clearInterval(ProxyHealth.timer);
      ProxyHealth.timer = 0;
    }
    ProxyHealth.intervalMs = 0;
  }

  /**
   * 页面销毁时调用：停表并清掉回调，避免已销毁的页面实例被静态字段一直持有；
   * 还在飞行中的 check() 回来后也就不会再调用到旧页面。
   */
  static dispose(): void {
    ProxyHealth.stop();
    ProxyHealth.onChange = () => {};
  }

  static isRunning(): boolean {
    return ProxyHealth.timer !== 0;
  }

  /**
   * 立即探测一次。
   *
   * ctx 用于在节点缓存尚未加载时补一次本地解析 —— 否则 currentExit 拿不到节点表，
   * 会把"还没加载"误判成"链路坏了"，进而触发一次毫无意义的自动换路。
   */
  static async check(ctx?: common.UIAbilityContext): Promise<HealthResult> {
    if (ProxyManager.getState() !== ProxyState.RUNNING) {
      return { ok: false, latencyMs: -1, error: '代理未运行' };
    }
    if (ProxyManager.isBusy()) {
      return { ok: ProxyHealth.lastOk, latencyMs: -1 };
    }
    let nodes: ParsedNode[] = Subscriptions.getActiveNodes();
    if (nodes.length === 0 && ctx !== undefined) {
      const data: SubscriptionData | null = await Subscriptions.getActiveData(ctx);
      if (data !== null) { nodes = data.nodes; }
    }
    const exit: string = await AutoSelect.currentExit();
    const node: ParsedNode | undefined = nodes.find((n: ParsedNode) => n.name === exit);
    if (node === undefined) {
      // 解析不出出口（订阅未加载、出口是 DIRECT 等）不代表链路故障：
      // 返回"中性"结果，不推进失败计数，避免误触发换路。
      return { ok: ProxyHealth.lastOk, latencyMs: -1, error: '无法解析当前出口' };
    }
    const r: PingResult = await ProxyManager.pingNode(node);
    return ProxyHealth.record(r.ok, r.ok ? r.latencyMs : -1, r.error);
  }

  private static record(ok: boolean, latencyMs: number, error?: string): HealthResult {
    if (ok) {
      const wasUnhealthy: boolean = !ProxyHealth.lastOk;
      ProxyHealth.failures = 0;
      ProxyHealth.lastOk = true;
      if (wasUnhealthy) {
        ProxyHealth.onChange(true);
      }
    } else {
      ProxyHealth.failures++;
      if (ProxyHealth.failures >= ProxyHealth.threshold && ProxyHealth.lastOk) {
        ProxyHealth.lastOk = false;
        ProxyHealth.onChange(false);
      }
    }
    return { ok: ok, latencyMs: latencyMs, error: error };
  }

  static reset(): void {
    ProxyHealth.failures = 0;
    ProxyHealth.lastOk = true;
  }

  /**
   * 连续失败是否已达到阈值（即链路判定为不健康）。
   *
   * 调用方不能用 check() 返回的 ok 直接决定换路：那是"这一次探测"的结果，
   * 单次丢包/超时很常见，判决要按连续失败计数来。
   */
  static isUnhealthy(): boolean {
    return !ProxyHealth.lastOk;
  }
}
