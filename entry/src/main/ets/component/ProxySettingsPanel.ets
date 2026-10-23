import { common } from '@kit.AbilityKit';
import { ProxyManager, ProxyState, ProxySnapshot, OpResult, PingResult, TrafficStats } from '../mihomo/ProxyManager';
import { Subscriptions, Subscription, SubscriptionData } from '../mihomo/Subscriptions';
import { ParsedNode, ParsedGroup } from '../mihomo/SubscriptionLoader';
import { withAppStrategies, groupNodes, GroupSelection } from '../mihomo/ProxyStrategies';
import { PROXY_TEST_CONCURRENCY } from '../mihomo/ProxyConstants';
import { AutoSelect, AutoSelectResult } from '../mihomo/AutoSelect';
import { ProxySettingsStore, ProxySettings } from '../mihomo/ProxySettings';

/** 缓存的测速结果最多展示 10 分钟：再旧就不可信了（节点延迟变化很快）。 */
const LATENCY_CACHE_TTL_MS: number = 10 * 60 * 1000;

interface LatencyEntry {
  name: string;
  delay: number;
}

interface LatencyCacheFile {
  at: number;
  entries: LatencyEntry[];
}

@Component
export struct ProxySettingsPanel {
  @Prop isDark: boolean = false;
  onClose: () => void = () => {};
  onStateChanged: (state: ProxyState) => void = () => {};
  @State private state: ProxyState = ProxyManager.getState();
  @State private busy: boolean = false;
  @State private loading: boolean = true;
  @State private subs: Subscription[] = [];
  @State private activeId: string = '';
  @State private nodes: ParsedNode[] = [];
  @State private groups: ParsedGroup[] = [];
  @State private selectedGroup: string = '';
  @State private selectedNode: string = '';
  @State private current: string = '';
  /** 内核累计流量：由 refreshCurrent 每 5 秒带回来一次，没有独立定时器。 */
  @State private traffic: TrafficStats | null = null;
  @State private groupNow: Map<string, string> = new Map();
  @State private expanded: Set<string> = new Set();
  @State private pingMap: Map<string, number> = new Map();
  @State private pinging: Set<string> = new Set();
  @State private tab: number = 0;
  @State private visibleCount: number = 24;
  @State private query: string = '';
  @State private sortByDelay: boolean = false;
  @State private showSubscriptions: boolean = false;
  @State private newUrl: string = '';
  @State private errorText: string = '';
  @State private statusText: string = '';
  @State private batchLabel: string = '';
  @State private completed: number = 0;
  @State private total: number = 0;
  // 智能选路
  @State private autoSelectOnStart: boolean = true;
  @State private autoSwitchOnDegrade: boolean = true;
  @State private refreshAfterSwitch: boolean = true;
  @State private keepAliveInBackground: boolean = true;
  @State private healthIntervalMs: number = 60000;
  @State private autoTesting: boolean = false;
  @State private autoResult: string = '';
  /** 智能选路卡片是否展开（默认展开，用过一次后可收起，把屏幕让给策略组列表）。 */
  @State private showSmart: boolean = true;
  /** 策略组卡片首屏渲染数量：26 个组一次性布局会明显拖慢面板首帧。 */
  @State private visibleGroups: number = 10;
  /** bootstrap 读到的测速缓存原文，等节点列表就绪后再解析（见 applyLatencyCache）。 */
  private cachedLatency: string = '';
  private ctx: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
  private disposed: boolean = false;
  private generation: number = 0;
  private batchGeneration: number = 0;
  private timer: number = 0;
  private readonly listener = (state: ProxyState): void => {
    if (this.disposed) { return; }
    this.state = state;
    this.onStateChanged(state);
    if (state === ProxyState.ERROR) { this.errorText = ProxyManager.getLastError(); }
    if (state !== ProxyState.RUNNING) { this.cancelBatch(); }
  };

  private pageBg(): string { return this.isDark ? '#101615' : '#F1F5F3'; }
  private cardBg(): string { return this.isDark ? '#1B2421' : '#FFFFFF'; }
  private inputBg(): string { return this.isDark ? '#27332E' : '#EAF0EC'; }
  private primary(): string { return this.isDark ? '#F1F7F3' : '#182D24'; }
  private secondary(): string { return this.isDark ? '#A5B7AD' : '#61776A'; }
  private accent(): string { return this.isDark ? '#62D9AB' : '#087F5B'; }
  private errorColor(): string { return this.isDark ? '#FF9D91' : '#BE3B31'; }
  private working(): boolean {
    return this.busy || this.loading || this.state === ProxyState.STARTING || this.state === ProxyState.STOPPING;
  }

  aboutToAppear(): void {
    const t0: number = Date.now();
    console.info('PERF panel | aboutToAppear');
    this.disposed = false;
    ProxyManager.subscribe(this.listener);
    this.bootstrap();
    // 定时刷新是"尽力而为"：失败不该冒泡成未处理的 Promise 拒绝。
    this.timer = setInterval(() => { this.refreshCurrent().catch(() => {}); }, 5000);
  }
  aboutToDisappear(): void {
    this.disposed = true;
    this.generation++;
    this.cancelBatch();
    ProxyManager.unsubscribe(this.listener);
    clearInterval(this.timer);
  }
  /** 一行"标题 + 开关"的通用设置项。副标题说明会挤占空间，已按用户要求全部去掉。 */
  @Builder
  private settingRow(title: string, value: boolean, onChange: (on: boolean) => void) {
    Row({ space: 10 }) {
      Text(title).fontSize(13).fontColor(this.primary()).layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: value })
        .selectedColor('#087F5B').enabled(!this.working())
        .onChange((on: boolean) => onChange(on))
    }.width('100%')
  }

  /**
   * 「智能选路」卡片标题行：点标题展开/收起，右侧显示当前动作。
   *
   * 【为什么不接受 open 参数】ArkUI 的 @Builder 值参数不参与状态刷新：
   * 父组件重渲染时 builder 仍用上次捕获的旧值，实测收起后标签还停在"收起"。
   * 这里直接读 this.showSmart，状态变化才会带着文案一起更新。
   */
  @Builder
  private smartHeader() {
    Row({ space: 8 }) {
      Text('智能选路').fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.primary()).layoutWeight(1)
      Text(this.showSmart ? '收起' : '展开').fontSize(11).fontColor(this.secondary())
    }.width('100%').padding({ top: 2, bottom: 2 })
    .onClick(() => {
      this.showSmart = !this.showSmart;
      this.saveSetting('smartPanelExpanded', this.showSmart);
    })
  }

  @Builder
  private intervalButton(label: string, ms: number) {
    Button(label, { type: ButtonType.Normal })
      .height(32).fontSize(11)
      .fontColor(this.healthIntervalMs === ms ? '#FFFFFF' : this.secondary())
      .backgroundColor(this.healthIntervalMs === ms ? '#087F5B' : this.inputBg())
      .borderRadius(8).layoutWeight(1)
      .enabled(!this.working())
      .onClick(() => {
        this.healthIntervalMs = ms;
        this.saveSetting('healthCheckIntervalMs', ms);
      })
  }

  private get healthLabel(): string {
    if (this.healthIntervalMs <= 0) { return '已关闭'; }
    if (this.healthIntervalMs < 60000) { return (this.healthIntervalMs / 1000).toString() + ' 秒'; }
    return (this.healthIntervalMs / 60000).toString() + ' 分钟';
  }

  /**
   * 单个设置项落盘。
   *
   * 【并发写法】连续快速拨两个开关时，如果每次都"读-改-写"，两次读到的会是同一份旧快照，
   * 后写的那次把前一次改的键覆盖回去。这里把操作串成一条队列：
   * 每次读到的都是上一次写完之后的存储，不会丢更新。
   * 顺手检查 save() 的返回值 —— 存储初始化失败时它返回 false，
   * 不提示的话用户以为存上了，其实下次打开又变回默认值。
   */
  private saveSetting(key: string, value: boolean | number | string): Promise<void> {
    const task: Promise<void> = this.saveChain.then(async () => {
      await ProxySettingsStore.init(this.ctx);
      const s: ProxySettings = await ProxySettingsStore.load();
      if (key === 'autoSelectOnStart') { s.autoSelectOnStart = value as boolean; }
      else if (key === 'autoSwitchOnDegrade') { s.autoSwitchOnDegrade = value as boolean; }
      else if (key === 'refreshAfterSwitch') { s.refreshAfterSwitch = value as boolean; }
      else if (key === 'keepAliveInBackground') { s.keepAliveInBackground = value as boolean; }
      else if (key === 'healthCheckIntervalMs') { s.healthCheckIntervalMs = value as number; }
      else if (key === 'smartPanelExpanded') { s.smartPanelExpanded = value as boolean; }
      else if (key === 'latencyCache') { s.latencyCache = value as string; }
      const saved: boolean = await ProxySettingsStore.save(s);
      if (!saved && !this.disposed) {
        this.errorText = '设置未能保存，请重启应用后重试';
      }
    }).catch((err: Object) => {
      if (!this.disposed) { this.errorText = '保存设置失败：' + JSON.stringify(err); }
    });
    this.saveChain = task;
    return task;
  }
  /** 设置写入队列的队尾：保证多次快速修改按顺序落盘。 */
  private saveChain: Promise<void> = Promise.resolve();

  /** 手动触发一次自动选路，结果直接展示在面板里。 */
  private async runAutoTest(): Promise<void> {
    if (this.autoTesting || this.working()) { return; }
    // 已经有一轮在跑（启动选路 / 劣化换路）时不排队：排队会让用户再等一整轮，
    // 而那一轮的结果对他同样有效。直接告知"正在进行"。
    if (AutoSelect.isRunning()) {
      this.autoResult = '已在测速中，请稍候…';
      return;
    }
    this.autoTesting = true;
    this.autoResult = '';
    try {
      const result: AutoSelectResult = await AutoSelect.run(this.ctx);
      if (this.disposed) { return; }
      if (result.ok) {
        this.autoResult = '已选择 ' + result.node + '（' + result.latencyMs.toString() + 'ms，共测 ' +
          result.tested.toString() + ' 个）' + (result.switched ? ' · 已切换' : ' · 保持当前');
      } else {
        this.autoResult = '选路失败：' + (result.error ?? '未知原因');
      }
      await this.refreshCurrent();
    } catch (err) {
      // AutoSelect.run 正常不会 reject（内部已兜住），这里兜底避免未处理的 Promise 拒绝。
      if (!this.disposed) { this.autoResult = '选路异常：' + JSON.stringify(err); }
    } finally {
      if (!this.disposed) { this.autoTesting = false; }
    }
  }

  private async bootstrap(): Promise<void> {
    const t0: number = Date.now();
    try {
      await Subscriptions.init(this.ctx);
      // 面板可能在 init/读盘期间就被关闭（用户点开又立刻关掉）：
      // 每个 await 之后都要重新确认存活，否则会把 @State 写进已销毁的组件。
      if (this.disposed) { return; }
      await ProxySettingsStore.init(this.ctx);
      const settings: ProxySettings = await ProxySettingsStore.load();
      if (this.disposed) { return; }
      this.autoSelectOnStart = settings.autoSelectOnStart;
      this.autoSwitchOnDegrade = settings.autoSwitchOnDegrade;
      this.refreshAfterSwitch = settings.refreshAfterSwitch;
      this.keepAliveInBackground = settings.keepAliveInBackground;
      this.healthIntervalMs = settings.healthCheckIntervalMs;
      this.showSmart = settings.smartPanelExpanded;
      this.cachedLatency = settings.latencyCache;
      await this.loadLocal();
      if (this.disposed) { return; }
      this.showSubscriptions = this.subs.length === 0;
      this.errorText = ProxyManager.getLastError();
      // 面板打开耗时分段：init=读偏好，settings=读开关，local=读盘解析订阅。
      // 用户反馈"点侧栏按钮要两三秒"，先量清楚再优化，避免盲猜。
      console.info('PERF panel | ready ' + (Date.now() - t0).toString() + 'ms');
    } finally {
      if (!this.disposed) { this.loading = false; }
    }
  }
  private refreshMeta(): void {
    // 独立对象让 ArkUI 感知订阅元信息的更新。
    this.subs = Subscriptions.list().map((s: Subscription): Subscription => {
      return { id: s.id, name: s.name, url: s.url, lastFetchAt: s.lastFetchAt,
        nodeCount: s.nodeCount, groupCount: s.groupCount,
        updateIntervalHours: s.updateIntervalHours };
    });
    this.activeId = Subscriptions.getActiveId();
    this.selectedGroup = Subscriptions.getActiveGroup();
    this.selectedNode = Subscriptions.getActiveNode();
  }
  private async loadLocal(): Promise<void> {
    this.generation++;
    this.cancelBatch();
    this.pingMap = new Map();
    this.pinging = new Set();
    this.groupNow = new Map();
    this.expanded = new Set();
    this.refreshMeta();
    const data: SubscriptionData | null = await Subscriptions.getActiveData(this.ctx);
    // 读订阅可能涉及磁盘解析，面板关掉后不该继续写 @State。
    if (this.disposed) { return; }
    this.nodes = data === null ? [] : data.nodes;
    this.groups = data === null || data.nodes.length === 0 ? [] : withAppStrategies(data.nodes, data.groups);
    // 节点列表就绪后再套用缓存：缓存里可能有已删除节点的旧记录，需要按当前节点过滤。
    this.applyLatencyCache();
    if (this.selectedGroup.length === 0 && this.selectedNode.length === 0 && this.nodes.length > 0) {
      this.selectedNode = this.nodes[0].name;
    }
    const now: Map<string, string> = new Map();
    Subscriptions.getGroupSelections().forEach((s: GroupSelection) => now.set(s.group, s.node));
    this.groupNow = now;
    await this.refreshCurrent();
  }
  /**
   * 把持久化的测速结果套回 pingMap。
   *
   * 为什么值得做：104 个节点全量测速要十几秒，而面板每次打开 pingMap 都是空的，
   * 用户看到的全是"测速"按钮。缓存 10 分钟内的结果，打开即有数据可比较。
   * 过期或解析失败一律静默忽略 —— 缓存只是锦上添花，不能因为它让面板打不开。
   */
  private applyLatencyCache(): void {
    if (this.cachedLatency.length === 0) { return; }
    let file: LatencyCacheFile | null = null;
    try {
      file = JSON.parse(this.cachedLatency) as LatencyCacheFile;
    } catch (err) {
      return;
    }
    if (file === null || file.at === undefined || Date.now() - file.at > LATENCY_CACHE_TTL_MS) { return; }
    const map: Map<string, number> = new Map();
    for (let i = 0; i < file.entries.length; i++) {
      const entry: LatencyEntry = file.entries[i];
      // 只接受当前订阅里仍存在的节点，避免节点删了还显示旧延迟。
      if (this.nodes.some((n: ParsedNode) => n.name === entry.name)) {
        map.set(entry.name, entry.delay);
      }
    }
    this.pingMap = map;
  }

  /** 把当前 pingMap 写回设置（fire-and-forget：写失败不影响测速本身）。 */
  private persistLatency(): void {
    const entries: LatencyEntry[] = [];
    this.pingMap.forEach((delay: number, name: string) => { entries.push({ name: name, delay: delay }); });
    if (entries.length === 0) { return; }
    const file: LatencyCacheFile = { at: Date.now(), entries: entries };
    this.cachedLatency = JSON.stringify(file);
    this.saveSetting('latencyCache', this.cachedLatency);
  }

  private async refreshCurrent(): Promise<void> {
    if (this.disposed || this.state !== ProxyState.RUNNING || ProxyManager.isBusy()) { return; }
    const generation: number = this.generation;
    let name: string = this.selectedGroup.length > 0 ? this.selectedGroup : this.selectedNode;
    const visited: Set<string> = new Set();
    const now: Map<string, string> = new Map(this.groupNow);
    for (let depth = 0; depth < 12 && name.length > 0 && !visited.has(name); depth++) {
      visited.add(name);
      const snapshot: ProxySnapshot | null = await ProxyManager.snapshot(name);
      if (this.disposed || generation !== this.generation) { return; }
      if (snapshot === null || snapshot.now === undefined || snapshot.now === name) { break; }
      now.set(name, snapshot.now);
      name = snapshot.now;
    }
    this.groupNow = now;
    this.current = name;
    // 流量统计搭这趟已有的 5 秒轮询，不额外开定时器（面板里已经有一个 5s interval）。
    // 先赋值再判存活：上面每轮 snapshot 已经查过 disposed，这里多一次 await，
    // 若中途面板被关掉，写 @State 也只是最后一次无害赋值。
    this.traffic = await ProxyManager.traffic();
  }

  /** 字节数转成人读的短单位；0 显示 0 B。 */
  private bytesText(bytes: number): string {
    if (bytes <= 0) { return '0 B'; }
    if (bytes < 1024) { return bytes.toString() + ' B'; }
    if (bytes < 1024 * 1024) { return (bytes / 1024).toFixed(1) + ' KB'; }
    if (bytes < 1024 * 1024 * 1024) { return (bytes / 1048576).toFixed(1) + ' MB'; }
    return (bytes / 1073741824).toFixed(2) + ' GB';
  }
  private async toggle(on: boolean): Promise<void> {
    if (this.working() || on === (this.state === ProxyState.RUNNING)) { return; }
    this.busy = true;
    this.errorText = '';
    try {
      const result: OpResult = on ? await ProxyManager.enable(this.ctx) : await ProxyManager.disable();
      if (this.disposed) { return; }
      if (!result.ok) { this.errorText = result.error ?? '连接操作失败'; }
      this.state = ProxyManager.getState();
      await this.refreshCurrent();
    } finally { if (!this.disposed) { this.busy = false; } }
  }
  private async choose(group: string, node: string = '', within: string = ''): Promise<void> {
    if (this.working()) { return; }
    this.busy = true;
    this.errorText = '';
    try {
      const result: OpResult = await ProxyManager.select(group, node, within);
      if (this.disposed) { return; }
      if (!result.ok) { this.errorText = result.error ?? '切换失败'; return; }
      this.refreshMeta();
      if (within.length > 0) {
        const now: Map<string, string> = new Map(this.groupNow);
        now.set(within, node);
        this.groupNow = now;
      }
      this.statusText = '已选择出口';
    } finally { if (!this.disposed) { this.busy = false; } }
    await this.refreshCurrent();
  }
  private toggleExpanded(group: ParsedGroup): void {
    const next: Set<string> = new Set(this.expanded);
    if (next.has(group.name)) { next.delete(group.name); } else {
      next.add(group.name);
      this.readGroup(group.name).catch(() => {});
    }
    this.expanded = next;
  }
  private async readGroup(name: string): Promise<void> {
    const generation: number = this.generation;
    const value = await ProxyManager.snapshot(name);
    if (!this.disposed && generation === this.generation && value !== null && value.now !== undefined) {
      const now: Map<string, string> = new Map(this.groupNow);
      now.set(name, value.now);
      this.groupNow = now;
    }
  }
  private cancelBatch(): void {
    this.batchGeneration++;
    this.batchLabel = '';
  }
  private async pingOne(node: ParsedNode): Promise<void> {
    if (this.pinging.has(node.name) || this.state !== ProxyState.RUNNING) { return; }
    const generation: number = this.generation;
    const active: Set<string> = new Set(this.pinging);
    active.add(node.name);
    this.pinging = active;
    try {
      const result: PingResult = await ProxyManager.pingNode(node);
      if (this.disposed || generation !== this.generation) { return; }
      const map: Map<string, number> = new Map(this.pingMap);
      map.set(node.name, result.ok ? result.latencyMs : -1);
      this.pingMap = map;
      // 批量测速时不逐节点落盘：104 个节点会触发 104 次 preferences 读改写，
      // 测速期间明显卡顿。批次结束由 testNodes 统一写一次。
      if (this.batchLabel.length === 0) { this.persistLatency(); }
    } finally {
      if (!this.disposed && generation === this.generation) {
        const next: Set<string> = new Set(this.pinging);
        next.delete(node.name);
        this.pinging = next;
      }
    }
  }
  private async testNodes(nodes: ParsedNode[], label: string): Promise<void> {
    if (this.batchLabel.length > 0 || this.state !== ProxyState.RUNNING || this.working()) { return; }
    const batch: number = ++this.batchGeneration;
    const generation: number = this.generation;
    this.batchLabel = label;
    this.total = nodes.length;
    this.completed = 0;
    let cursor: number = 0;
    const workers: Promise<void>[] = [];
    const work = async (): Promise<void> => {
      while (cursor < nodes.length && !this.disposed && batch === this.batchGeneration && generation === this.generation) {
        const node: ParsedNode = nodes[cursor++];
        await this.pingOne(node);
        if (this.disposed || batch !== this.batchGeneration || generation !== this.generation) { return; }
        this.completed++;
      }
    };
    for (let i = 0; i < Math.min(PROXY_TEST_CONCURRENCY, nodes.length); i++) { workers.push(work()); }
    await Promise.all(workers);
    if (this.disposed || batch !== this.batchGeneration || generation !== this.generation) { return; }
    this.batchLabel = '';
    this.statusText = label + '完成 · ' + this.completed.toString() + ' 个节点';
    this.persistLatency();
    await this.refreshCurrent();
  }
  private async testGroup(group: ParsedGroup): Promise<void> {
    const next: Set<string> = new Set(this.expanded);
    next.add(group.name);
    this.expanded = next;
    await this.testNodes(groupNodes(group, this.groups, this.nodes), '分组测速');
    await this.readGroup(group.name);
  }
  private filteredNodes(): ParsedNode[] {
    const q: string = this.query.trim().toLowerCase();
    const nodes: ParsedNode[] = this.nodes.filter((n: ParsedNode) => n.name.toLowerCase().includes(q));
    if (this.sortByDelay) {
      nodes.sort((a: ParsedNode, b: ParsedNode) => this.delayOrder(a.name) - this.delayOrder(b.name));
    }
    return nodes;
  }
  private filteredGroups(): ParsedGroup[] {
    const q: string = this.query.trim().toLowerCase();
    const list: ParsedGroup[] = this.groups.filter((g: ParsedGroup) => g.name.toLowerCase().includes(q) ||
      g.proxies.some((name: string) => name.toLowerCase().includes(q)));
    // 展示层排序：把「应用 · 负载均衡」总入口提到最前。
    // YAML 里它必须排在各组之后（内核按文件顺序建组，先引用后定义会报 not found），
    // 但面板里用户先看到它、"选国家"入口才符合直觉 —— 只调整渲染顺序，不动配置顺序。
    const root: number = list.findIndex((g: ParsedGroup) => g.name === '应用 · 负载均衡');
    if (root > 0) {
      const head: ParsedGroup = list[root];
      list.splice(root, 1);
      list.unshift(head);
    }
    return list;
  }
  private members(group: ParsedGroup): string[] {
    const q: string = this.query.trim().toLowerCase();
    const members: string[] = group.proxies.filter((name: string) => q.length === 0 ||
      group.name.toLowerCase().includes(q) || name.toLowerCase().includes(q));
    if (this.sortByDelay) { members.sort((a: string, b: string) => this.delayOrder(a) - this.delayOrder(b)); }
    return members;
  }
  private delayOrder(name: string): number {
    const delay: number | undefined = this.pingMap.get(name);
    return delay === undefined ? 1000000 : delay < 0 ? 2000000 : delay;
  }
  private nodeFor(name: string): ParsedNode | undefined { return this.nodes.find((n: ParsedNode) => n.name === name); }
  private testName(name: string): void {
    const node = this.nodeFor(name);
    if (node !== undefined) { this.pingOne(node); }
  }
  private typeLabel(type: string, name: string = ''): string {
    if (type === 'url-test') { return '自动选择'; }
    if (type === 'fallback') { return '故障转移'; }
    if (type === 'load-balance') { return '负载均衡'; }
    // 负载均衡总入口是 select，但它的成员是"各国均衡组"，叫"手动选择"会看不懂。
    if (type === 'select' && name === '应用 · 负载均衡') { return '选国家'; }
    if (type === 'select') { return '手动选择'; }
    return type;
  }
  private latencyText(name: string): string {
    if (this.pinging.has(name)) { return '测试中'; }
    const delay: number | undefined = this.pingMap.get(name);
    return delay === undefined ? '测速' : delay < 0 ? '不可用' : delay.toString() + ' ms';
  }
  private latencyColor(name: string): string {
    const delay: number | undefined = this.pingMap.get(name);
    return delay === undefined ? this.secondary() : delay < 0 ? this.errorColor() :
      delay < 300 ? this.accent() : this.isDark ? '#EBC780' : '#956115';
  }
  private stateLabel(): string {
    if (this.state === ProxyState.STARTING) { return '正在连接'; }
    if (this.state === ProxyState.STOPPING) { return '正在断开'; }
    if (this.state === ProxyState.RUNNING) { return '代理已连接'; }
    if (this.state === ProxyState.ERROR) { return '连接需要重试'; }
    return '代理未开启';
  }
  private activeName(): string {
    return this.subs.find((s: Subscription) => s.id === this.activeId)?.name ?? '未选择订阅';
  }
  private updatedAt(s: Subscription): string {
    if (s.lastFetchAt === 0) { return '尚未更新'; }
    const d: Date = new Date(s.lastFetchAt);
    return '更新于 ' + (d.getMonth() + 1).toString() + '/' + d.getDate().toString() + ' ' +
      d.getHours().toString().padStart(2, '0') + ':' + d.getMinutes().toString().padStart(2, '0');
  }
  private async syncRuntime(): Promise<void> {
    if (ProxyManager.getState() === ProxyState.RUNNING) {
      const result = await ProxyManager.restartIfRunning(this.ctx);
      // 重启内核可能要几秒，期间面板可能已被关闭：之后不再写 @State。
      if (this.disposed) { return; }
      if (!result.ok) { this.errorText = result.error ?? '应用订阅失败'; }
    }
    if (this.disposed) { return; }
    this.state = ProxyManager.getState();
    await this.loadLocal();
  }
  private async addSubscription(): Promise<void> {
    if (this.working()) { return; }
    const url: string = this.newUrl.trim();
    if (!/^https?:\/\/[^\s]+$/i.test(url)) { this.errorText = '请输入有效的 HTTP 或 HTTPS 订阅链接'; return; }
    this.busy = true;
    this.errorText = '';
    try {
      const sub: Subscription | null = await Subscriptions.add(url);
      if (this.disposed) { return; }
      if (sub === null) { this.errorText = '订阅添加失败'; return; }
      const result = await Subscriptions.fetch(this.ctx, sub.id, false);
      if (this.disposed) { return; }
      if (!result.ok) { this.errorText = result.error ?? '下载失败，请重试更新'; this.refreshMeta(); return; }
      await Subscriptions.setActive(sub.id);
      if (this.disposed) { return; }
      this.newUrl = '';
      await this.syncRuntime();
      if (this.disposed) { return; }
      this.statusText = '订阅已保存到本地';
    } catch (err) {
      if (!this.disposed) { this.errorText = err instanceof Error ? err.message : '订阅添加失败'; }
    } finally { if (!this.disposed) { this.busy = false; } }
  }
  private async switchSubscription(id: string): Promise<void> {
    if (this.working() || id === this.activeId) { return; }
    this.busy = true;
    this.errorText = '';
    try {
      const data = await Subscriptions.loadCached(this.ctx, id);
      if (this.disposed) { return; }
      if (data === null || data.nodes.length === 0) { this.errorText = '该订阅没有本地节点，请先更新'; return; }
      await Subscriptions.setActive(id);
      if (this.disposed) { return; }
      await this.syncRuntime();
    } finally { if (!this.disposed) { this.busy = false; } }
  }
  private async refreshSubscription(id: string): Promise<void> {
    if (this.working()) { return; }
    this.busy = true;
    this.errorText = '';
    try {
      const result = await Subscriptions.fetch(this.ctx, id, false);
      if (this.disposed) { return; }
      if (!result.ok) { this.errorText = result.error ?? '订阅更新失败，已保留本地节点'; return; }
      if (id === this.activeId) { await this.syncRuntime(); } else { this.refreshMeta(); }
      if (this.disposed) { return; }
      this.statusText = '订阅已更新';
    } finally { if (!this.disposed) { this.busy = false; } }
  }
  private confirmRemove(s: Subscription): void {
    this.getUIContext().showAlertDialog({ title: '删除订阅', message: '删除“' + s.name + '”？',
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: { value: '删除', action: () => { this.removeSubscription(s.id); } } });
  }
  private async removeSubscription(id: string): Promise<void> {
    if (this.working()) { return; }
    this.busy = true;
    try {
      const active: boolean = id === this.activeId;
      if (active && ProxyManager.getState() === ProxyState.RUNNING) {
        const stopped = await ProxyManager.disable();
        if (this.disposed) { return; }
        if (!stopped.ok) { this.errorText = stopped.error ?? '关闭代理失败'; return; }
      }
      await Subscriptions.remove(id);
      if (this.disposed) { return; }
      await this.loadLocal();
      if (this.disposed) { return; }
      if (active) { this.statusText = '订阅已删除，请确认新订阅后开启代理'; }
    } finally { if (!this.disposed) { this.busy = false; } }
  }

  @Builder
  delayButton(name: string) {
    Button(this.latencyText(name), { type: ButtonType.Normal })
      .fontSize(12).fontColor(this.latencyColor(name)).backgroundColor(this.inputBg())
      .borderRadius(10).height(36).constraintSize({ minWidth: 70 })
      .enabled(this.state === ProxyState.RUNNING && !this.working() && !this.pinging.has(name))
      .onClick(() => this.testName(name))
  }
  @Builder
  groupCard(group: ParsedGroup) {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        Column({ space: 4 }) {
          Text((this.expanded.has(group.name) ? '▾  ' : '▸  ') + group.name)
            .fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.primary()).maxLines(2)
          Text(this.typeLabel(group.type, group.name) + ' · ' + group.proxies.length.toString() + ' 项')
            .fontSize(12).fontColor(this.secondary())
        }.alignItems(HorizontalAlign.Start).layoutWeight(1).onClick(() => this.toggleExpanded(group))
        Button(this.selectedGroup === group.name ? '使用中' : '使用', { type: ButtonType.Normal })
          .height(36).fontSize(12).fontColor(this.selectedGroup === group.name ? Color.White : this.accent())
          .backgroundColor(this.selectedGroup === group.name ? '#087F5B' : this.inputBg()).borderRadius(10)
          .enabled(!this.working() && this.selectedGroup !== group.name)
          .onClick(() => this.choose(group.name))
      }.width('100%')
      if (this.expanded.has(group.name)) {
        Row() {
          Text('当前：' + (this.groupNow.get(group.name) ?? (group.proxies[0] ?? '等待选择')))
            .fontSize(12).fontColor(this.accent()).layoutWeight(1).maxLines(2)
          Button('整组测速', { type: ButtonType.Normal }).fontSize(12).height(36)
            .backgroundColor(this.inputBg()).fontColor(this.primary()).borderRadius(10)
            .enabled(!this.working() && this.state === ProxyState.RUNNING && this.batchLabel.length === 0)
            .onClick(() => this.testGroup(group))
        }.width('100%')
        ForEach(this.members(group), (name: string) => {
          Row({ space: 8 }) {
            Text((this.groupNow.get(group.name) === name ? '●  ' : '') + name)
              .fontSize(13).fontColor(this.groupNow.get(group.name) === name ? this.accent() : this.primary())
              .layoutWeight(1).maxLines(2).padding({ top: 10, bottom: 10 })
              .onClick(() => {
                if (group.type === 'select') { this.choose(group.name, name, group.name); }
              })
            if (this.nodeFor(name) !== undefined) { this.delayButton(name) }
            else {
              Text(this.groups.some((g: ParsedGroup) => g.name === name) ? '子策略' : name)
                .fontSize(11).fontColor(this.secondary())
            }
          }.width('100%')
        }, (name: string) => name)
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding(16).backgroundColor(this.cardBg())
    .borderRadius(18).border({ width: this.selectedGroup === group.name ? 1.5 : 0, color: this.accent() })
  }

  build() {
    Column() {
      Row() {
        Column({ space: 3 }) {
          Text('连接与代理').fontSize(23).fontWeight(FontWeight.Bold).fontColor(this.primary())
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Button('✕', { type: ButtonType.Circle }).width(40).height(40)
          .fontColor(this.secondary()).backgroundColor(this.inputBg()).onClick(() => this.onClose())
      }.width('100%').padding({ left: 20, right: 20, top: 8, bottom: 16 })
      Scroll() {
        Column({ space: 14 }) {
          Column({ space: 14 }) {
            Row({ space: 10 }) {
              Circle().width(10).height(10).fill(this.state === ProxyState.RUNNING ? this.accent() : this.secondary())
              Text(this.stateLabel()).fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.primary()).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.state === ProxyState.RUNNING })
                .selectedColor('#087F5B').enabled(!this.working() && this.nodes.length > 0)
                .onChange((on: boolean) => this.toggle(on))
            }.width('100%')
            Text(this.state === ProxyState.RUNNING ? '当前出口  ' + (this.current || this.selectedNode || this.selectedGroup) :
              (this.selectedNode || this.selectedGroup || '未选择出口'))
              .fontSize(13).fontColor(this.secondary()).maxLines(2).width('100%')
            // 流量统计：内核累计值 + 当前活动连接数。只在运行时显示，
            // 未运行时旧数据没有意义（内核每次启动都从 0 开始计）。
            if (this.state === ProxyState.RUNNING && this.traffic !== null) {
              Text('↑ ' + this.bytesText(this.traffic.uploadTotal) + '   ↓ ' +
                this.bytesText(this.traffic.downloadTotal) + '   ·   ' +
                this.traffic.activeConnections.toString() + ' 个连接')
                .fontSize(12).fontColor(this.secondary()).width('100%').maxLines(1)
            }
          }.width('100%').padding(18).backgroundColor(this.cardBg()).borderRadius(20)

          if (this.errorText.length > 0) {
            Text(this.errorText).fontSize(13).fontColor(this.errorColor()).width('100%')
              .padding(14).backgroundColor(this.cardBg()).borderRadius(12)
          }
          if (this.statusText.length > 0) { Text(this.statusText).fontSize(12).fontColor(this.accent()).width('100%') }

          // ---------- 智能选路 ----------
          // 可收起：这一段是四个开关 + 一排间隔按钮，展开时占掉近一屏，
          // 用户要往下翻策略组时得滑很久，收起后一个标题行就能让出空间。
          Column({ space: 12 }) {
            this.smartHeader()
            if (this.showSmart) {
              this.settingRow('启动自动选路', this.autoSelectOnStart,
                (on: boolean) => { this.autoSelectOnStart = on; this.saveSetting('autoSelectOnStart', on); })
              this.settingRow('链路劣化自动切换', this.autoSwitchOnDegrade,
                (on: boolean) => { this.autoSwitchOnDegrade = on; this.saveSetting('autoSwitchOnDegrade', on); })
              this.settingRow('换节点后刷新网页', this.refreshAfterSwitch,
                (on: boolean) => { this.refreshAfterSwitch = on; this.saveSetting('refreshAfterSwitch', on); })
              this.settingRow('后台保持连接', this.keepAliveInBackground,
                (on: boolean) => { this.keepAliveInBackground = on; this.saveSetting('keepAliveInBackground', on); })
              Row({ space: 8 }) {
                Text('健康探测间隔').fontSize(13).fontColor(this.primary()).layoutWeight(1)
                Text(this.healthLabel).fontSize(12).fontColor(this.secondary())
              }.width('100%')
              Row({ space: 6 }) {
                this.intervalButton('30 秒', 30000)
                this.intervalButton('1 分钟', 60000)
                this.intervalButton('5 分钟', 300000)
                this.intervalButton('关闭', 0)
              }.width('100%')
              Button(this.autoTesting ? '正在测速…' : '立即测速并选最优', { type: ButtonType.Normal })
                .width('100%').height(42).fontSize(13)
                .fontColor(this.accent()).backgroundColor(this.inputBg()).borderRadius(12)
                .enabled(!this.working() && !this.autoTesting && this.state === ProxyState.RUNNING)
                .onClick(() => this.runAutoTest())
              if (this.autoResult.length > 0) {
                Text(this.autoResult).fontSize(12).fontColor(this.secondary()).width('100%').maxLines(3)
              }
            }
          }.width('100%').padding(16).backgroundColor(this.cardBg()).borderRadius(18)

          Column({ space: 12 }) {
            Row() {
              Column({ space: 4 }) {
                Text('订阅管理').fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.primary())
                Text(this.activeName()).fontSize(12).fontColor(this.secondary()).maxLines(1)
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              Button(this.showSubscriptions ? '收起' : '管理', { type: ButtonType.Normal })
                .fontSize(12).height(36).backgroundColor(this.inputBg()).fontColor(this.primary()).borderRadius(10)
                .onClick(() => { this.showSubscriptions = !this.showSubscriptions; })
            }.width('100%')
            if (this.showSubscriptions) {
              ForEach(this.subs, (s: Subscription) => {
                Column({ space: 6 }) {
                  Row() {
                    Text((s.id === this.activeId ? '●  ' : '') + s.name).fontSize(14)
                      .fontColor(s.id === this.activeId ? this.accent() : this.primary()).layoutWeight(1).maxLines(1)
                      .onClick(() => this.switchSubscription(s.id))
                    Button(s.id === this.activeId ? '使用中' : '使用', { type: ButtonType.Normal })
                      .fontSize(12).height(36).fontColor(this.accent()).backgroundColor(this.inputBg()).borderRadius(10)
                      .stateEffect(false).enabled(!this.working() && s.id !== this.activeId)
                      .onClick(() => this.switchSubscription(s.id))
                    Button('更新', { type: ButtonType.Normal }).fontSize(12).height(36)
                      .backgroundColor(this.inputBg()).fontColor(this.primary()).borderRadius(10).enabled(!this.working())
                      .onClick(() => this.refreshSubscription(s.id))
                    Button('删除', { type: ButtonType.Normal }).fontSize(12).height(36)
                      .backgroundColor(Color.Transparent).fontColor(this.errorColor()).enabled(!this.working())
                      .onClick(() => this.confirmRemove(s))
                  }.width('100%')
                  Text(s.nodeCount.toString() + ' 节点 · ' + s.groupCount.toString() + ' 分组 · ' + this.updatedAt(s))
                    .fontSize(11).fontColor(this.secondary()).width('100%')
                }.width('100%')
              }, (s: Subscription) => s.id)
              TextInput({ text: this.newUrl, placeholder: '粘贴订阅链接' }).fontSize(13)
                .height(44).backgroundColor(this.inputBg()).fontColor(this.primary()).borderRadius(12)
                .onChange((value: string) => { this.newUrl = value; })
              Button(this.busy ? '正在处理…' : '添加并下载').width('100%').height(42).fontSize(13)
                .backgroundColor('#087F5B').fontColor(Color.White).enabled(!this.working())
                .onClick(() => this.addSubscription())
            }
          }.width('100%').padding(16).backgroundColor(this.cardBg()).borderRadius(18)

          if (this.nodes.length > 0) {
            Row({ space: 6 }) {
              this.tabButton('策略分组', 0, this.groups.length)
              this.tabButton('全部节点', 1, this.nodes.length)
            }.width('100%').padding(4).backgroundColor(this.inputBg()).borderRadius(14)
            TextInput({ text: this.query, placeholder: '搜索分组或节点' }).fontSize(13).height(42)
              .backgroundColor(this.cardBg()).fontColor(this.primary()).borderRadius(12)
                .onChange((value: string) => { this.query = value; this.visibleCount = 24; this.visibleGroups = 10; })
            Row({ space: 8 }) {
              Button(this.sortByDelay ? '延迟排序 ↑' : '订阅顺序', { type: ButtonType.Normal })
                .height(36).fontSize(12).fontColor(this.primary()).backgroundColor(this.cardBg()).borderRadius(10)
                .onClick(() => { this.sortByDelay = !this.sortByDelay; })
              Blank()
              Button(this.batchLabel.length > 0 ? '取消测速' : '全部测速', { type: ButtonType.Normal })
                .height(36).fontSize(12).fontColor(this.accent()).backgroundColor(this.cardBg()).borderRadius(10)
                .enabled(!this.working() && this.state === ProxyState.RUNNING)
                .onClick(() => {
                  if (this.batchLabel.length > 0) { this.cancelBatch(); }
                  else { this.testNodes(this.filteredNodes(), '全部测速'); }
                })
            }.width('100%')
            if (this.batchLabel.length > 0) {
              Text(this.batchLabel + '  ' + this.completed.toString() + ' / ' + this.total.toString())
                .fontSize(12).fontColor(this.accent()).width('100%')
              Progress({ value: this.completed, total: Math.max(1, this.total), type: ProgressType.Linear }).color(this.accent()).width('100%')
            }
            if (this.tab === 0) {
              // 分批渲染：26 个分组卡片（每张还有嵌套行）一次性布局，首帧会明显卡顿。
              // 先出 10 个，剩下的用户滑到底再补 —— 和“全部节点”页签的处理方式一致。
              ForEach(this.filteredGroups().slice(0, this.visibleGroups),
                (group: ParsedGroup) => { this.groupCard(group) }, (g: ParsedGroup) => g.name)
              if (this.filteredGroups().length > this.visibleGroups) {
                Button('显示更多分组', { type: ButtonType.Normal }).height(40).fontSize(13)
                  .backgroundColor(this.cardBg()).fontColor(this.accent()).stateEffect(false)
                  .onClick(() => { this.visibleGroups += 10; })
              }
              if (this.filteredGroups().length === 0) { Text('没有匹配的分组').fontColor(this.secondary()).padding(20) }
            } else {
              ForEach(this.filteredNodes().slice(0, this.visibleCount), (node: ParsedNode) => {
                Row({ space: 10 }) {
                  Column({ space: 5 }) {
                    Text((this.selectedNode === node.name ? '●  ' : '') + node.name).fontSize(14)
                      .fontColor(this.selectedNode === node.name ? this.accent() : this.primary()).maxLines(2)
                    Text(node.type.toUpperCase()).fontSize(10).fontColor(this.secondary())
                  }.alignItems(HorizontalAlign.Start).layoutWeight(1).onClick(() => this.choose('', node.name))
                  this.delayButton(node.name)
                }.width('100%').padding(16).backgroundColor(this.cardBg()).borderRadius(16)
              }, (node: ParsedNode) => node.name)
              if (this.filteredNodes().length > this.visibleCount) {
                Button('显示更多', { type: ButtonType.Normal }).height(40).fontSize(13)
                  .backgroundColor(this.cardBg()).fontColor(this.accent()).stateEffect(false)
                  .onClick(() => { this.visibleCount += 24; })
              }
              if (this.filteredNodes().length === 0) { Text('没有匹配的节点').fontColor(this.secondary()).padding(20) }
            }
          } else {
            Text(this.loading ? '正在读取本地订阅…' : '添加订阅后即可选择策略与节点')
              .fontSize(14).fontColor(this.secondary()).padding(24)
          }
          Blank().height(28)
        }.width('100%').padding({ left: 16, right: 16 })
      }.layoutWeight(1).scrollBar(BarState.Off)
    }.width('100%').height('100%').backgroundColor(this.pageBg())
  }
  @Builder
  tabButton(label: string, index: number, count: number) {
    Button(label + ' ' + count.toString(), { type: ButtonType.Normal }).layoutWeight(1).height(38).fontSize(13)
      .stateEffect(false)
      .fontWeight(this.tab === index ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.tab === index ? this.accent() : this.secondary())
      .backgroundColor(this.tab === index ? this.cardBg() : Color.Transparent).borderRadius(11)
      .onClick(() => { if (this.tab !== index) { this.visibleCount = 24; this.visibleGroups = 10; this.tab = index; } })
  }
}
