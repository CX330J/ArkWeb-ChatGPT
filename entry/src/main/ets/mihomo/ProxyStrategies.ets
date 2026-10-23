import { ParsedGroup, ParsedNode } from './SubscriptionLoader';
import { PROXY_TEST_URL } from './ProxyConstants';
import { ProxyRegion, RegionInfo, RegionTier, CountryPool } from './ProxyRegion';

export interface GroupSelection {
  subscriptionId: string;
  group: string;
  node: string;
}

export function strategyName(groups: ParsedGroup[], label: string): string {
  let name: string = '应用 · ' + label;
  while (groups.some((g: ParsedGroup) => g.name === name)) {
    name += ' ·';
  }
  return name;
}

/** url-test 组：组内自动挑延迟最低的节点。 */
function urlTestGroup(name: string, proxies: string[]): ParsedGroup {
  const g: ParsedGroup = {
    name: name, type: 'url-test', proxies: proxies,
    lines: ['- name: ' + name, '  type: url-test',
      '  url: ' + PROXY_TEST_URL, '  interval: 30', '  tolerance: 50', '  lazy: false']
  };
  return g;
}

/** fallback 组：按顺序取第一个可用的成员 —— 用来表达"日本优先，其次新加坡，再次美国"。 */
function fallbackGroup(name: string, proxies: string[]): ParsedGroup {
  const g: ParsedGroup = {
    name: name, type: 'fallback', proxies: proxies,
    lines: ['- name: ' + name, '  type: fallback',
      '  url: ' + PROXY_TEST_URL, '  interval: 30', '  lazy: false']
  };
  return g;
}

/** 取指定优先级的节点名。 */
function namesOfTier(nodes: ParsedNode[], regions: Map<string, RegionInfo>, tier: number): string[] {
  const out: string[] = [];
  for (let i = 0; i < nodes.length; i++) {
    const info: RegionInfo | undefined = regions.get(nodes[i].name);
    if (info !== undefined && info.tier === tier) {
      out.push(nodes[i].name);
    }
  }
  return out;
}

/**
 * 无分组订阅同样提供自动选择和故障转移；原订阅策略完整保留。
 *
 * 这里额外生成"按地区分层"的策略组，解决一个真机复现过的问题：
 *   ChatGPT 只在部分国家可用，而香港节点物理距离最近、延迟最低。
 *   只按延迟自动选，必然选到香港 —— 代理是通的，网页却打不开。
 *
 * 分层结构：
 *   应用 · 日本线路 / 新加坡线路 / 美国线路   -> 各组内 url-test，各自挑最快
 *   应用 · 其他可用线路                       -> 其余 ChatGPT 可用地区（同一层内比延迟）
 *   应用 · 智能线路                           -> fallback：日本 → 新加坡 → 美国 → 其他
 *   应用 · 自动选择                           -> 只在"可用地区"里比延迟（含台湾等，但不含香港）
 *   应用 · 负载均衡                           -> 多节点分摊，默认按目标域名哈希（会话粘性更好）
 *
 * 为什么智能线路用 fallback 而不是 url-test：
 *   url-test 只认延迟，香港/台湾永远比日本快，分层就失效了；
 *   fallback 按成员顺序取"第一个活着"的，正好表达地区优先级，每层内部再各自比延迟。
 */
export function withAppStrategies(nodes: ParsedNode[], groups: ParsedGroup[]): ParsedGroup[] {
  const regions: Map<string, RegionInfo> = ProxyRegion.classifyAll(nodes);
  const jp: string[] = namesOfTier(nodes, regions, RegionTier.JAPAN);
  const sg: string[] = namesOfTier(nodes, regions, RegionTier.SINGAPORE);
  const us: string[] = namesOfTier(nodes, regions, RegionTier.UNITED_STATES);
  // "其他可用"= 明确可用地区 + 识别不出的节点；明确不可用（香港/大陆/俄罗斯…）一律不进。
  const other: string[] = [];
  const usable: string[] = [];
  for (let i = 0; i < nodes.length; i++) {
    const info: RegionInfo | undefined = regions.get(nodes[i].name);
    const tier: number = info !== undefined ? info.tier : RegionTier.UNKNOWN;
    if (tier === RegionTier.BLOCKED) {
      continue;
    }
    usable.push(nodes[i].name);
    if (tier === RegionTier.SUPPORTED || tier === RegionTier.UNKNOWN) {
      other.push(nodes[i].name);
    }
  }
  // 兜底：订阅里恰好全是"不可用地区"时不要把组成员清空（空组会让内核拒绝整份配置），
  // 退回全量节点，至少代理还能用。
  const usableNames: string[] = usable.length > 0 ? usable : nodes.map((n: ParsedNode) => n.name);

  const result: ParsedGroup[] = [];
  // ---------- 负载均衡：每个国家一个组 ----------
  //
  // 【为什么按国家拆开，而不是一个大池子】
  // 不同国家的出口 IP 完全不同，ChatGPT 这类带登录态的服务会把会话和出口地区绑定，
  // 请求被随机分到另一个国家，轻则触发风控、重则直接掉登录。
  // 所以均衡必须**限制在同一个国家内**（用户的原话：一般负载均衡是选择某一个国家进行均衡）。
  //
  // 【为什么每个国家都生成，而不是只生成首选国家】
  // 早先只生成一个"应用 · 负载均衡"，国家写死按日本→新加坡→美国挑第一个。
  // 用户的实际诉求是"能自己选国家"：他想在日本节点之间均衡、也可能想在新加坡之间均衡。
  // 现在每个有节点的国家各生成一个组（`应用 · 负载均衡 · 日本`……），
  // 再额外生成一个总入口 `应用 · 负载均衡`（type: select，成员是所有国家组），
  // 在面板里点开总入口就能在各国之间切，点开某个国家组能看到该国全部节点。
  //
  // 【成员范围】均衡组收录该国的**全部**节点（不再像旧版那样只取首选国家）。
  //
  // 【为什么单节点国家不单独成组】
  // 真实的 104 节点订阅按国家拆开后是 75 个国家，其中 60 多个只有 1 个节点。
  // 每个都生成一个 load-balance 组的话：
  //   · 策略组从 26 个膨胀到 101 个，用户找「日本」要翻好几屏，反而更难用；
  //   · 单节点没有分摊意义，"均衡"名不副实。
  // 所以只有 ≥2 个节点的国家单独成组（真正能均衡），
  // 单节点国家收进一个「单节点国家」组 —— 仍然在列表里、仍然可选到该国节点，
  // 只是不占用一整个均衡组的位置。这个组用 url-test（挑延迟最低的那一个），
  // 因为组内是国家各异的单节点，跨国家不能做哈希均衡。
  const pools: CountryPool[] = ProxyRegion.pools(nodes, regions);
  const balanceGroups: string[] = [];
  const singles: string[] = [];
  for (let i = 0; i < pools.length; i++) {
    const pool: CountryPool = pools[i];
    if (pool.nodes.length < 2) {
      for (let k = 0; k < pool.nodes.length; k++) {
        singles.push(pool.nodes[k]);
      }
      continue;
    }
    // 组名带两位国家代码，例如「应用 · 负载均衡 · JP 日本」：
    // 用户明确要求 JP/SG/US 这类代码和中文都要显示，便于在长列表里快速定位。
    const name: string = strategyName(groups, '负载均衡 · ' +
      ProxyRegion.displayName(pool.label, pool.code));
    // consistent-hashing：按目标域名哈希，同一站点的请求固定落在同一出口，
    // 比 round-robin 更适合网页会话（缓存、Cookie、风控都认同一 IP）。
    const balance: ParsedGroup = {
      name: name, type: 'load-balance', proxies: pool.nodes.slice(),
      lines: ['- name: app-balance', '  type: load-balance', '  strategy: consistent-hashing',
        '  url: ' + PROXY_TEST_URL, '  interval: 30', '  lazy: false']
    };
    result.push(balance);
    balanceGroups.push(name);
  }
  if (singles.length > 0) {
    const singleName: string = strategyName(groups, '负载均衡 · 单节点国家');
    result.push(urlTestGroup(singleName, singles));
    balanceGroups.push(singleName);
  }
  // 总入口：只有两个以上国家组时才需要一层 select 来切换；
  // 只有一个国家时它等价于那个组，多套一层反而让面板里出现重复项。
  if (balanceGroups.length >= 2) {
    // 注意这里必须是 select：load-balance 会把请求按域名哈希分到**不同国家**，
    // 那正是上一条注释里要避免的跨地区混流。select 由用户/默认值决定用哪个国家。
    result.push({
      name: strategyName(groups, '负载均衡'), type: 'select', proxies: balanceGroups.slice(),
      lines: ['- name: app-balance-root', '  type: select']
    });
  }

  // 地区组只在真的有节点时才生成：url-test 的空组成员列表是非法配置。
  const tiers: string[][] = [];
  if (jp.length > 0) {
    const n: string = strategyName(groups, '日本线路');
    result.push(urlTestGroup(n, jp));
    tiers.push([n]);
  }
  if (sg.length > 0) {
    const n: string = strategyName(groups, '新加坡线路');
    result.push(urlTestGroup(n, sg));
    tiers.push([n]);
  }
  if (us.length > 0) {
    const n: string = strategyName(groups, '美国线路');
    result.push(urlTestGroup(n, us));
    tiers.push([n]);
  }
  if (other.length > 0) {
    const n: string = strategyName(groups, '其他可用线路');
    result.push(urlTestGroup(n, other));
    tiers.push([n]);
  }
  // 智能线路：地区顺序即优先级。只有一个层级时它等价于那个层级，不必重复生成。
  if (tiers.length >= 2) {
    const members: string[] = [];
    for (let i = 0; i < tiers.length; i++) {
      members.push(tiers[i][0]);
    }
    result.push(fallbackGroup(strategyName(groups, '智能线路'), members));
  }

  result.push(urlTestGroup(strategyName(groups, '自动选择'), usableNames));
  result.push(fallbackGroup(strategyName(groups, '故障转移'), usableNames));

  return result.concat(groups);
}

/**
 * 判断某个分组名是否是"AI 类"分组（订阅里常见叫 AI / ChatGPT / OpenAI）。
 *
 * 只认独立的组名，不做模糊包含匹配：像「AI 加速节点」「ChatGPT 专用」这类自定义名字
 * 也一并接住；但不会把「Steam」「YouTube」这种名字里恰好带 ai 的组误判进来。
 */
export function isAiGroup(name: string): boolean {
  const n: string = name.trim().toLowerCase();
  return n === 'ai' || n === 'chatgpt' || n === 'openai' ||
    n.startsWith('ai ') || n.startsWith('ai-') || n.startsWith('ai_') ||
    n.indexOf('chatgpt') >= 0 || n.indexOf('openai') >= 0;
}

/**
 * AI 类流量应当优先落在哪个自动组上。
 *
 * 顺序就是用户的要求：日本 > 新加坡 > 美国 > 其余可用地区。
 * 「智能线路」本身是 fallback（日本 → 新加坡 → 美国 → 其他），
 * 有它就用它，这样断掉一层还能自动往下走；只有单层地区时才退而用该地区组。
 */
export function preferredAiGroup(appGroups: ParsedGroup[]): string {
  const labels: string[] = ['智能线路', '日本线路', '新加坡线路', '美国线路', '自动选择'];
  for (let i = 0; i < labels.length; i++) {
    const want: string = '应用 · ' + labels[i];
    const found: ParsedGroup | undefined = appGroups.find((g: ParsedGroup) =>
      g.name === want || g.name.startsWith(want + ' ·'));
    if (found !== undefined) {
      return found.name;
    }
  }
  return '';
}

/** 递归展开子分组，去重并阻止循环引用；DIRECT/REJECT 不作为节点测速。 */
export function groupNodes(group: ParsedGroup, groups: ParsedGroup[], nodes: ParsedNode[]): ParsedNode[] {
  const pending: string[] = group.proxies.slice();
  const visited: Set<string> = new Set();
  const result: ParsedNode[] = [];
  while (pending.length > 0) {
    const name: string = pending.shift() ?? '';
    if (visited.has(name)) {
      continue;
    }
    visited.add(name);
    const node: ParsedNode | undefined = nodes.find((n: ParsedNode) => n.name === name);
    if (node !== undefined) {
      result.push(node);
      continue;
    }
    const child: ParsedGroup | undefined = groups.find((g: ParsedGroup) => g.name === name);
    if (child !== undefined) {
      pending.push(...child.proxies);
    }
  }
  return result;
}
