/**
 * mihomo 配置生成器。
 *
 * ===========================================================================
 * YAML 缩进是这个模块最大的坑，改之前务必读完
 * ===========================================================================
 * 节点块 / 分组块内部的相对缩进必须原样保留。
 * Parser 已完成 normalize（把整块左移到基准 0 缩进，内部层级不变），
 * 本文件只负责在输出时加**同一份**前缀。
 *
 *   正确（prefix = "    "）：
 *       - name: A
 *         type: vless           <- 原块内 2 空格，加 4 后 6 空格，与 "- " 后内容对齐
 *         reality-opts:
 *           public-key: x        <- 原块内 4 空格，加 4 后 8 空格，在 reality-opts 下
 *
 *   错误（曾经的写法：对每行只加前缀，不看原缩进）：
 *       · 节点块：报 "yaml: line 14: mapping values are not allowed"
 *       · 分组块：报 "yaml: line 1968: ..."（因为分组里的 url/interval 字段被错位）
 *
 * 因此：**分组不再重建字段**，整块原样输出，只按需修正 name/type。
 *
 * ===========================================================================
 * 关键开关
 * ===========================================================================
 *   tun.enable = false        走"本地 SOCKS + ArkWeb 代理覆盖"，不建虚拟网卡
 *   bind-address 127.0.0.1    只允许本机连接
 */

import { ParsedNode, ParsedGroup, ParsedRule } from './SubscriptionLoader';
import { GroupSelection, strategyName, withAppStrategies, isAiGroup, preferredAiGroup } from './ProxyStrategies';

export interface ConfigBuildInput {
  nodes: ParsedNode[];
  groups: ParsedGroup[];
  rules: ParsedRule[];
  /** rule-providers 原始行（rules 里引用的规则集必须先定义） */
  ruleProviders: string[];
  /** 规则集缓存目录（绝对路径，替换掉订阅里的相对 ./Rules 前缀） */
  rulesDir: string;
  /** 选中的节点名（用户直接点节点时用） */
  selectedNode: string;
  /** 选中的分组名（用户点分组时用；非空则优先，由该分组的策略决定实际节点） */
  selectedGroup: string;
  mixedPort: number;
  controllerSecret: string;
  groupSelections: GroupSelection[];
}

export const DEFAULT_MIXED_PORT: number = 7890;

/** 输出一个已 normalize 的块，统一前缀（块内相对缩进不变）。 */
function emit(block: string[], prefix: string): string[] {
  const out: string[] = [];
  for (let i = 0; i < block.length; i++) {
    out.push(prefix + block[i]);
  }
  return out;
}

/** YAML 双引号转义。 */
function q(s: string): string {
  return '"' + s.replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"';
}

/**
 * 替换分组块里的 name 字段值（保持原缩进）。
 * 用于把分组名统一成我们解析出的名字，避免带转义字符导致组内引用对不上。
 */
function setGroupName(block: string[], newName: string): void {
  for (let i = 0; i < block.length; i++) {
    const ln: string = block[i];
    if (/^\s*-?\s*name\s*:/.test(ln)) {
      const ind: number = ln.length - ln.replace(/^\s*/, '').length;
      const dash: boolean = ln.trim().startsWith('- ');
      const prefix: string = ' '.repeat(ind) + (dash ? '- ' : '');
      block[i] = prefix + 'name: ' + q(newName);
      return;
    }
  }
}

/**
 * 替换分组块里 proxies 列表的内容（保持原缩进）。
 * 传入的 names 会替换掉原有列表项，其余字段（type/url/interval）保持不动。
 */
function setGroupProxies(block: string[], keyIndent: number, names: string[]): string[] {
  const out: string[] = [];
  let i: number = 0;
  let replaced: boolean = false;
  while (i < block.length) {
    const ln: string = block[i];
    const t: string = ln.trim();
    const ind: number = ln.length - ln.replace(/^\s*/, '').length;
    if (/^proxies\s*:/.test(t)) {
      // 写入该键
      out.push(' '.repeat(ind) + 'proxies:');
      // 跳过原有的列表项（缩进更深的 "- ..."）
      let j: number = i + 1;
      while (j < block.length) {
        const l2: string = block[j];
        const t2: string = l2.trim();
        const ind2: number = l2.length - l2.replace(/^\s*/, '').length;
        if (t2.length === 0) {
          j++;
          continue;
        }
        if (t2.startsWith('- ') && ind2 > ind) {
          j++;
          continue;
        }
        break;
      }
      // 插入新列表项
      const itemIndent: string = ' '.repeat(ind + 2);
      for (let k = 0; k < names.length; k++) {
        out.push(itemIndent + '- ' + q(names[k]));
      }
      replaced = true;
      i = j;
      continue;
    }
    out.push(ln);
    i++;
  }
  if (!replaced) {
    out.push(' '.repeat(keyIndent) + 'proxies:');
    const itemIndent: string = ' '.repeat(keyIndent + 2);
    for (let k = 0; k < names.length; k++) {
      out.push(itemIndent + '- ' + q(names[k]));
    }
  }
  return out;
}

export function buildMihomoConfig(input: ConfigBuildInput): string {
  const L: string[] = [];
  const nodes: ParsedNode[] = input.nodes;
  const groups: ParsedGroup[] = withAppStrategies(nodes, input.groups);
  const routeName: string = strategyName(groups, '出口');
  const requested: string = input.selectedGroup.length > 0 ? input.selectedGroup : input.selectedNode;
  // AI 类流量单独接管（见下方规则改写的注释）。只有订阅里确实存在 AI 组、
  // 且应用侧能给出地区优先组时才启用；否则 aiTarget 为空，行为与原来完全一致。
  const aiGroup: ParsedGroup | undefined = groups.find((g: ParsedGroup) => g.type === 'select' && isAiGroup(g.name));
  const aiAuto: string = aiGroup !== undefined ? preferredAiGroup(groups) : '';
  const aiTarget: string = aiGroup !== undefined && aiAuto.length > 0 ? aiGroup.name : '';
  const targets: string[] = groups.map((g: ParsedGroup) => g.name).concat(nodes.map((n: ParsedNode) => n.name));
  const chosen: string = targets.indexOf(requested) >= 0 ? requested : nodes[0].name;

  L.push('# 由应用自动生成，请勿手动修改（每次启用代理都会重新生成）');
  L.push('mixed-port: ' + input.mixedPort);
  L.push('allow-lan: false');
  L.push('bind-address: 127.0.0.1');
  L.push('mode: rule');
  // 日志级别提到 info：排查"代理起来了但页面打不开"时，
  // 需要看到内核实际选中的节点、拨号结果、握手失败原因。
  // 日常使用可以改回 warning 减少日志量。
  L.push('log-level: info');
  L.push('ipv6: false');
  // 开一个本地控制端口：便于用 HTTP 查询内核真实的代理状态与连接列表，
  // 是排查"流量到底有没有出去"最直接的手段。
  L.push('external-controller: 127.0.0.1:9090');
  L.push('secret: ' + q(input.controllerSecret));
  L.push('profile:');
  L.push('  store-selected: false');
  L.push('');
  L.push('tun:');
  L.push('  enable: false');
  L.push('');
  L.push('dns:');
  L.push('  enable: false');
  L.push('');

  // ---------- 节点 ----------
  L.push('proxies:');
  for (let i = 0; i < nodes.length; i++) {
    const emitted: string[] = emit(nodes[i].lines, '    ');
    for (let k = 0; k < emitted.length; k++) {
      L.push(emitted[k]);
    }
  }
  L.push('');

  // ---------- 分组 ----------
  // 整块原样输出，只确保 name 与 proxies 引用的名字是我们解析出的（无转义残留）。
  L.push('proxy-groups:');
  L.push('    - name: ' + q(routeName));
  L.push('      type: select');
  L.push('      proxies:');
  L.push('        - ' + q(chosen));
  for (let i = 0; i < targets.length; i++) {
    if (targets[i] !== chosen) {
      L.push('        - ' + q(targets[i]));
    }
  }
  if (groups.length > 0) {
    for (let i = 0; i < groups.length; i++) {
      const g: ParsedGroup = groups[i];
      // 复制一份再改，避免污染 Parser 的缓存
      const block: string[] = [];
      for (let k = 0; k < g.lines.length; k++) {
        block.push(g.lines[k]);
      }
      setGroupName(block, g.name);
      let members: string[] = g.proxies.slice();
      // AI 组默认排第一：地区优先组。用户自己保存过选择就尊重用户的选择（下面那段），
      // 没选过时 AI 流量自动落到"日本 → 新加坡 → 美国 → 其他"。
      const isAiTarget: boolean = aiTarget.length > 0 && g.name === aiTarget && g.type === 'select';
      if (isAiTarget && members.indexOf(aiAuto) < 0) {
        members = [aiAuto].concat(members);
      }
      const selection: GroupSelection | undefined = input.groupSelections.find((s: GroupSelection) => s.group === g.name);
      // 【AI 组特殊处理】用户以前手动点过某个国家组（例如"日本节点"），这个选择会被持久化。
      // 如果继续照搬，AI 组的第一项就变成"日本节点"这个 select 组 —— 它不会自动降级：
      // 日本 5 个节点全挂时，AI 流量跟着一起断，而不是落到新加坡。
      // 所以 AI 组只在用户显式选过**应用侧地区组**时才尊重选择；选的是订阅自带的
      // 国家 select 组时，仍然用 fallback 链（地区优先 + 自动降级）。
      const userPickedAppGroup: boolean = selection !== undefined &&
        selection.node.indexOf('应用 · ') === 0;
      // 负载均衡总入口（`应用 · 负载均衡`）同理：它是个 select，成员是各国均衡组。
      // 用户没选过时，默认把「日本」排到第一 —— 与 AI 流量的地区偏好保持一致，
      // 用户点开该组直接就是日本内均衡，而不是随机落到某个国家。
      const isBalanceRoot: boolean = g.type === 'select' && g.name.indexOf('应用 · 负载均衡') === 0;
      if (isBalanceRoot && selection === undefined) {
        const japan: string | undefined = members.find((name: string) => name.indexOf('日本') >= 0);
        if (japan !== undefined) {
          members = [japan].concat(members.filter((name: string) => name !== japan));
        }
      }
      if (g.type === 'select' && selection !== undefined && members.indexOf(selection.node) >= 0 &&
        (!isAiTarget || userPickedAppGroup || selection.node === aiAuto)) {
        members = [selection.node].concat(members.filter((name: string) => name !== selection.node));
      }
      const newBlock: string[] = setGroupProxies(block, 2, members);
      const emitted: string[] = emit(newBlock, '    ');
      for (let k = 0; k < emitted.length; k++) {
        L.push(emitted[k]);
      }
    }
  }
  L.push('');

  // ---------- 规则集（rule-providers）----------
  // 【必须放在 rules 之前，且必须存在】
  // 订阅的 rules 里大量写 RULE-SET,<名字>,<策略>，
  // 这些 <名字> 必须在本文件里有定义，否则内核报 "rule set [X] not found"。
  // 另外订阅里的 path 是相对路径（./Rules/...），内核会相对工作目录写文件，
  // 普通应用没有该目录的写权限，所以要替换成应用私有目录的绝对路径。
  if (input.ruleProviders.length > 0) {
    L.push('rule-providers:');
    for (let i = 0; i < input.ruleProviders.length; i++) {
      let ln: string = input.ruleProviders[i];
      // 把 path: ./Rules/xxx 改写为 path: <rulesDir>/xxx
      const m = /^(\s*path\s*:\s*)\.?\/?Rules\/(.+)$/.exec(ln);
      if (m !== null && m.length > 2) {
        ln = m[1] + input.rulesDir + '/' + m[2];
      } else {
        const m2 = /^(\s*path\s*:\s*)\.\/(.+)$/.exec(ln);
        if (m2 !== null && m2.length > 2) {
          ln = m2[1] + input.rulesDir + '/' + m2[2];
        }
      }
      L.push('    ' + ln);
    }
    L.push('');
  }

  // ---------- 规则 ----------
  L.push('rules:');
  if (input.rules.length > 0) {
    // 【过滤 GEOIP 规则】
    // GEOIP 规则需要 MMDB 数据库文件。普通应用没有可写的工作目录，
    // mihomo 尝试下载 MMDB 时报
    //   "can't download MMDB: open : no such file or directory"
    // 并让**整个配置解析失败**（实测：代理因此起不来，表现为点开关卡住）。
    //
    // 处理：把 GEOIP 规则整体跳过。副作用很小 ——
    // 订阅里 GEOIP,CN,DIRECT 只是"国内直连"的优化，
    // 去掉后国内站点也走代理，功能正常、只是流量多走一段。
    // 相比之下"代理完全起不来"要严重得多，所以这里选择跳过。
    for (let i = 0; i < input.rules.length; i++) {
      const raw: string = input.rules[i].raw;
      const head: string = raw.split(',')[0].trim().toUpperCase();
      if (head === 'GEOIP' || head === 'GEOSITE' || head === 'GEOIP6') {
        continue;
      }
      // 保留订阅直连/拦截规则，其余出口统一服从界面选择。
      const parts: string[] = raw.split(',');
      let targetIndex: number = parts.length - 1;
      if (parts[targetIndex].trim().toLowerCase() === 'no-resolve') {
        targetIndex--;
      }
      const target: string = parts[targetIndex].trim().replace(/^["']|["']$/g, '');
      if (target !== 'DIRECT' && target !== 'REJECT' && target !== 'REJECT-DROP' && target !== 'PASS') {
        // 【AI 域名保留订阅自己的 AI 分组】
        // 原实现把所有非直连规则的目标统一改写成「应用 · 出口」，这样做简单，
        // 但把订阅精心分好的 AI / Netflix / Telegram 分组全废掉了 —— ChatGPT 的流量
        // 也走"总出口"，于是 AI 组里选了什么完全不起作用。
        //
        // 现在只把目标明确指向 AI 组的规则保留下来，并让该组默认选中地区优先组
        // （日本 → 新加坡 → 美国 → 其他）。其余规则仍然归口到「应用 · 出口」，
        // 保证界面上的"当前出口"依然能控制绝大多数流量。
        if (aiTarget.length > 0 && target === aiTarget) {
          // 保持原目标不动
        } else {
          parts[targetIndex] = routeName;
        }
      }
      L.push('  - ' + q(parts.join(',')));
    }
    // 必须保证至少有一条 MATCH，否则流量无法兜底出站
    let hasMatch: boolean = false;
    for (let i = 0; i < input.rules.length; i++) {
      if (input.rules[i].raw.trim().toUpperCase().startsWith('MATCH')) {
        hasMatch = true;
        break;
      }
    }
    if (!hasMatch) {
      L.push('  - ' + q('MATCH,' + routeName));
    }
  } else {
    // 不用 GEOIP（依赖 MMDB 数据库，见上方说明）。
    // 内网直连用 IP-CIDR 覆盖常见私有网段，效果等价且无需数据库。
    L.push('  - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve');
    L.push('  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve');
    L.push('  - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve');
    L.push('  - IP-CIDR,172.16.0.0/12,DIRECT,no-resolve');
    L.push('  - ' + q('MATCH,' + routeName));
  }
  L.push('');

  return L.join('\n');
}
