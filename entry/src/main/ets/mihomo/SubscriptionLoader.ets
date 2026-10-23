/**
 * 订阅解析与 mihomo 配置生成。
 *
 * ===========================================================================
 * YAML 缩进是这里最容易出错的地方（已经踩过一次）
 * ===========================================================================
 * 订阅里的节点长这样（注意缩进层级）：
 *
 *   proxies:
 *       - client-fingerprint: chrome        <- 4 空格 + "- "，这是列表项起点
 *         flow: xtls-rprx-vision            <- 6 空格，与第一个 key 对齐
 *         reality-opts:                     <- 6 空格
 *           public-key: xxx                 <- 8 空格，嵌套在 reality-opts 下
 *           short-id: yyy                   <- 8 空格
 *         type: vless                       <- 6 空格
 *
 * 之前犯的错：把每行都"统一加 4 空格"，结果
 *   · 第一行变 "        - client-fingerprint: chrome"（8 空格 + -）
 *   · 后续行变 "          flow: ..."（10 空格）
 *   · 而 reality-opts 的子项被推得更深，层级关系被破坏
 *   · YAML 解析器报 "mapping values are not allowed in this context"
 *
 * 正确做法：**保留节点块内部的原始相对缩进**，只统一块的整体基准缩进。
 * 也就是先算出这一块里"列表项起始行"的原始缩进量，然后把所有行按同样的
 * 差值平移，保证内部层级关系完全不变。
 *
 * ===========================================================================
 * 分组（proxy-groups）与规则（rules）也要保留
 * ===========================================================================
 * 用户要求把订阅里的分组和规则都加载出来。
 * 这两段同样是 YAML 结构，处理方式与节点列表一致：
 * 保留原始块，只校正整体基准缩进。
 */

import { http } from '@kit.NetworkKit';
import { MihomoCore } from './MihomoCore';

interface ProviderPayload { name: string; body: string; }
interface ProviderRequest { name: string; url: string; }
interface NormalizeInput { body: string; providers: ProviderPayload[]; }
interface NormalizeResult { ok: boolean; yaml: string; error?: string; providers: ProviderRequest[]; }

/** 订阅解析结果。 */
export interface ParsedNode {
  name: string;
  type: string;
  /** 节点原始 YAML 行（不含任何额外缩进，保持内部相对层级） */
  lines: string[];
}

export interface ParsedGroup {
  name: string;
  type: string;
  /** 该分组包含的节点/子分组名 */
  proxies: string[];
  lines: string[];
}

export interface ParsedRule {
  /** 原始规则文本，如 "DOMAIN-SUFFIX,openai.com,PROXY" */
  raw: string;
}

export interface SubscriptionResult {
  ok: boolean;
  nodes: ParsedNode[];
  groups: ParsedGroup[];
  rules: ParsedRule[];
  /**
   * rule-providers 段的原始行（已 normalize 到基准 0 缩进）。
   * 订阅的 rules 里常写 RULE-SET,Steam,Steam 这类引用，
   * 必须把 rule-providers 一起带给内核，否则报 "rule set [X] not found"。
   */
  ruleProviders: string[];
  error?: string;
}

/** 从"列表项首行"里取 key 的值。 */
function fieldOf(line: string, key: string): string {
  const m = new RegExp('(?:^|[\\s-])' + key + '\\s*:\\s*(.+?)\\s*$').exec(line);
  if (m === null || m.length < 2) {
    return '';
  }
  return yamlScalar(m[1]);
}

function yamlScalar(value: string): string {
  if (value.startsWith('"') && value.endsWith('"')) {
    return decodeYamlString(value.substring(1, value.length - 1));
  }
  if (value.startsWith("'") && value.endsWith("'")) {
    return value.substring(1, value.length - 1).replace(/''/g, "'");
  }
  return value;
}

/**
 * 还原 YAML 双引号字符串里的转义序列。
 *
 * 【为什么需要】机场节点名常写成 "\U0001F1ED\U0001F1F0 V香港 01"，
 * 其中 \U0001F1ED 是国旗 emoji 的码点。如果原样显示会变成一串转义字符。
 * YAML 双引号内的合法转义：\\ \" \/ \0 \a \b \t \n \v \f \r \e \  \N \_ \L \P
 * 以及 \xXX（2位）、\uXXXX（4位）、\UXXXXXXXX（8位）。
 *
 * 注意：只应在**双引号字符串**里解码；单引号字符串里的反斜杠是字面量。
 * 这里为了简化，统一解码 —— 机场订阅里几乎都用双引号，且单引号里出现
 * 形如 \U0001F1ED 的概率极低，误判风险可接受。
 */
function decodeYamlString(s: string): string {
  if (s.indexOf('\\') < 0) {
    return s;
  }
  let out: string = '';
  let i: number = 0;
  while (i < s.length) {
    const ch: string = s.charAt(i);
    if (ch !== '\\' || i + 1 >= s.length) {
      out += ch;
      i++;
      continue;
    }
    const esc: string = s.charAt(i + 1);
    if (esc === 'U' && i + 9 < s.length + 0 && i + 10 <= s.length) {
      const hex: string = s.substring(i + 2, i + 10);
      if (/^[0-9A-Fa-f]{8}$/.test(hex)) {
        out += String.fromCodePoint(parseInt(hex, 16));
        i += 10;
        continue;
      }
    }
    if (esc === 'u' && i + 6 <= s.length) {
      const hex: string = s.substring(i + 2, i + 6);
      if (/^[0-9A-Fa-f]{4}$/.test(hex)) {
        out += String.fromCharCode(parseInt(hex, 16));
        i += 6;
        continue;
      }
    }
    if (esc === 'x' && i + 4 <= s.length) {
      const hex: string = s.substring(i + 2, i + 4);
      if (/^[0-9A-Fa-f]{2}$/.test(hex)) {
        out += String.fromCharCode(parseInt(hex, 16));
        i += 4;
        continue;
      }
    }
    // 常见单字符转义
    if (esc === 'n') {
      out += '\n';
      i += 2;
      continue;
    }
    if (esc === 't') {
      out += '\t';
      i += 2;
      continue;
    }
    if (esc === 'r') {
      out += '\r';
      i += 2;
      continue;
    }
    if (esc === '0') {
      out += '\0';
      i += 2;
      continue;
    }
    if (esc === '"' || esc === '\\' || esc === '/') {
      out += esc;
      i += 2;
      continue;
    }
    // 未知转义：原样保留反斜杠与字符
    out += '\\' + esc;
    i += 2;
  }
  return out;
}

/** 计算一行的前导空格数。 */
function indentOf(line: string): number {
  let i = 0;
  while (i < line.length && line.charAt(i) === ' ') {
    i++;
  }
  return i;
}

/**
 * 把一个 YAML 列表段（如 proxies: 下面那一串 "- ..."）切成多个块。
 *
 * @param lines 该段的所有行
 * @returns 每个块是若干行，块内保持原始缩进不变
 */
function splitYamlList(lines: string[]): string[][] {
  const blocks: string[][] = [];
  let cur: string[] = [];
  let itemIndent: number = -1;

  for (let i = 0; i < lines.length; i++) {
    const line: string = lines[i];
    if (line.trim().length === 0) {
      continue;
    }
    const ind: number = indentOf(line);
    const isItemStart: boolean = line.trim().startsWith('- ');

    if (isItemStart && (itemIndent < 0 || ind === itemIndent)) {
      if (itemIndent < 0) {
        itemIndent = ind;
      }
      // 遇到同级的 "- " 就开新块
      if (cur.length > 0) {
        blocks.push(cur);
      }
      cur = [line];
    } else if (cur.length > 0) {
      cur.push(line);
    }
  }
  if (cur.length > 0) {
    blocks.push(cur);
  }
  return blocks;
}

/**
 * 把块内所有行整体左移到"基准缩进 = 0"，同时保留内部相对层级。
 *
 * 例：
 *   输入  ["    - name: A", "      type: vless", "      reality-opts:", "        public-key: x"]
 *   输出  ["- name: A",     "  type: vless",     "  reality-opts:",     "    public-key: x"]
 * 这样后续再统一加目标缩进时，层级完全一致。
 */
function normalizeBlock(block: string[]): string[] {
  if (block.length === 0) {
    return [];
  }
  const base: number = indentOf(block[0]);
  const out: string[] = [];
  for (let i = 0; i < block.length; i++) {
    const line: string = block[i];
    if (line.length <= base) {
      out.push(line.trim());
    } else {
      out.push(line.substring(base));
    }
  }
  return out;
}

/** 把 normalize 后的块加上指定缩进输出。 */
function emitBlock(block: string[], prefix: string): string {
  const parts: string[] = [];
  for (let i = 0; i < block.length; i++) {
    parts.push(prefix + block[i]);
  }
  return parts.join('\n');
}

/** 从 YAML 里截取某个顶层 key 下的所有行，直到下一个顶层 key。 */
function sliceTopLevel(yaml: string, key: string): string[] {
  const lines: string[] = yaml.split('\n');
  const out: string[] = [];
  let inside: boolean = false;
  for (let i = 0; i < lines.length; i++) {
    const line: string = lines[i];
    const trimmed: string = line.trim();
    if (!inside) {
      if (new RegExp('^' + key + '\\s*:\\s*$').test(trimmed)) {
        inside = true;
      }
      continue;
    }
    // 顶格的另一个 key -> 本段结束
    if (trimmed.length > 0 && !line.startsWith(' ') && !line.startsWith('-') && !line.startsWith('#')) {
      break;
    }
    out.push(line);
  }
  return out;
}

/** 订阅拉取与解析。 */
export class SubscriptionLoader {
  /**
   * 最近一次成功拉取到的原始 YAML 文本。
   * 供 Subscriptions 落盘缓存（用户要求"下载到本地"）。
   * 用静态字段而不是返回值新增字段，是为了不改动 SubscriptionResult 的公开形状。
   */
  static lastRawYaml: string = '';
  /**
   * 主订阅响应头 profile-update-interval 声明的小时数；0 表示订阅未声明。
   *
   * 机场普遍用这个头告诉客户端"建议多久更新一次"。节点提供者（providers）的
   * 响应头不代表主订阅，所以 httpGet 只写 lastResponseIntervalHours，
   * 由 fetchAndParse 在主订阅请求完成后固定到本字段。
   */
  static lastUpdateIntervalHours: number = 0;
  private static lastResponseIntervalHours: number = 0;

  static async fetchAndParse(url: string): Promise<SubscriptionResult> {
    const empty: SubscriptionResult = { ok: false, nodes: [], groups: [], rules: [], ruleProviders: [] };
    if (url.trim().length === 0) {
      empty.error = '订阅链接为空';
      return empty;
    }
    let body: string = '';
    SubscriptionLoader.lastUpdateIntervalHours = 0;
    try {
      body = await SubscriptionLoader.httpGet(url);
      // 只认主订阅的响应头；providers 下载发生在后面，不会覆盖这个值。
      SubscriptionLoader.lastUpdateIntervalHours = SubscriptionLoader.lastResponseIntervalHours;
    } catch (err) {
      const msg = err instanceof Error ? err.message : JSON.stringify(err);
      empty.error = '拉取订阅失败: ' + msg;
      return empty;
    }
    if (body.length === 0) {
      empty.error = '订阅内容为空';
      return empty;
    }

    let yamlText: string = '';
    try {
      const input: NormalizeInput = { body: body, providers: [] };
      let normalized: NormalizeResult = JSON.parse(MihomoCore.normalizeSubscription(JSON.stringify(input)));
      if (!normalized.ok) { empty.error = normalized.error ?? '订阅格式无效'; return empty; }
      for (let i = 0; i < normalized.providers.length; i++) {
        const provider: ProviderRequest = normalized.providers[i];
        input.providers.push({ name: provider.name, body: await SubscriptionLoader.httpGet(provider.url) });
      }
      if (input.providers.length > 0) {
        normalized = JSON.parse(MihomoCore.normalizeSubscription(JSON.stringify(input)));
      }
      if (!normalized.ok || normalized.yaml.length === 0 || normalized.providers.length > 0) {
        empty.error = normalized.error ?? '节点提供者未完整下载'; return empty;
      }
      yamlText = normalized.yaml;
    } catch (err) {
      empty.error = '解析订阅失败：' + (err instanceof Error ? err.message : '格式错误');
      return empty;
    }

    const nodes: ParsedNode[] = SubscriptionLoader.parseProxies(yamlText);
    if (nodes.length === 0) {
      empty.error = '订阅里没有解析到任何节点';
      return empty;
    }
    const groups: ParsedGroup[] = SubscriptionLoader.parseGroups(yamlText);
    const rules: ParsedRule[] = SubscriptionLoader.parseRules(yamlText);
    const ruleProviders: string[] = SubscriptionLoader.parseRuleProviders(yamlText);
    // 记录原文，供落盘缓存
    SubscriptionLoader.lastRawYaml = yamlText;
    return { ok: true, nodes: nodes, groups: groups, rules: rules,
      ruleProviders: ruleProviders };
  }

  private static async httpGet(url: string): Promise<string> {
    const req = http.createHttp();
    try {
      const resp = await req.request(url, {
        method: http.RequestMethod.GET,
        header: {
          'User-Agent': 'clash-verge/v2.0.0',
          'Accept': 'text/yaml,application/yaml,*/*'
        },
        connectTimeout: 15000,
        readTimeout: 20000,
        expectDataType: http.HttpDataType.STRING
      });
      if (resp.responseCode !== 200) {
        throw new Error('HTTP ' + resp.responseCode);
      }
      SubscriptionLoader.lastResponseIntervalHours =
        SubscriptionLoader.intervalFromHeaders(resp.header);
      return typeof resp.result === 'string' ? resp.result : String(resp.result);
    } finally {
      req.destroy();
    }
  }

  /**
   * 从响应头取 profile-update-interval（小时）。
   *
   * 头名大小写不固定（不同服务端实现不一样），这里统一转小写比较。
   * 解析失败、缺失、非正数一律返回 0，由调用方按"未声明"处理。
   */
  private static intervalFromHeaders(header: Object): number {
    try {
      const map: Record<string, string> = header as Record<string, string>;
      const keys: string[] = Object.keys(map);
      for (let i = 0; i < keys.length; i++) {
        if (keys[i].toLowerCase() === 'profile-update-interval') {
          const hours: number = Number(map[keys[i]]);
          return !isNaN(hours) && hours > 0 ? hours : 0;
        }
      }
    } catch (err) {
      // 头信息结构异常时按未声明处理，不影响订阅本身
    }
    return 0;
  }

  static parseProxies(yaml: string): ParsedNode[] {
    const seg: string[] = sliceTopLevel(yaml, 'proxies');
    const blocks: string[][] = splitYamlList(seg);
    const nodes: ParsedNode[] = [];
    for (let i = 0; i < blocks.length; i++) {
      const norm: string[] = normalizeBlock(blocks[i]);
      let name: string = fieldOf(norm[0], 'name');
      let type: string = fieldOf(norm[0], 'type');
      // name/type 常不在第一行，往后找（且只看一级 key，缩进为 2 的行）
      for (let k = 1; k < norm.length; k++) {
        const ln: string = norm[k];
        if (indentOf(ln) !== 2) {
          continue;
        }
        if (name.length === 0) {
          const nm: string = fieldOf(ln, 'name');
          if (nm.length > 0) {
            name = nm;
          }
        }
        if (type.length === 0) {
          const tp: string = fieldOf(ln, 'type');
          if (tp.length > 0) {
            type = tp;
          }
        }
      }
      if (name.length === 0) {
        continue;
      }
      nodes.push({ name: name, type: type.length > 0 ? type : 'unknown', lines: norm });
    }
    return nodes;
  }

  /** 解析 proxy-groups 段。 */
  static parseGroups(yaml: string): ParsedGroup[] {
    const seg: string[] = sliceTopLevel(yaml, 'proxy-groups');
    const blocks: string[][] = splitYamlList(seg);
    const groups: ParsedGroup[] = [];
    for (let i = 0; i < blocks.length; i++) {
      const norm: string[] = normalizeBlock(blocks[i]);
      let name: string = fieldOf(norm[0], 'name');
      let type: string = fieldOf(norm[0], 'type');
      const proxies: string[] = [];
      let inProxies: boolean = false;
      let baseIndent: number = -1;
      for (let k = 0; k < norm.length; k++) {
        const ln: string = norm[k];
        const ind: number = indentOf(ln);
        if (ind === 2) {
          if (name.length === 0) {
            const nm: string = fieldOf(ln, 'name');
            if (nm.length > 0) {
              name = nm;
            }
          }
          if (type.length === 0) {
            const tp: string = fieldOf(ln, 'type');
            if (tp.length > 0) {
              type = tp;
            }
          }
          if (/^\s*proxies\s*:/.test(ln)) {
            inProxies = true;
            continue;
          }
          inProxies = false;
        }
        if (inProxies && ln.trim().startsWith('- ')) {
          if (baseIndent < 0) {
            baseIndent = ind;
          }
          if (ind === baseIndent) {
            const v: string = yamlScalar(ln.trim().substring(2).trim());
            if (v.length > 0) {
              proxies.push(v);
            }
          }
        }
      }
      if (name.length > 0) {
        groups.push({ name: name, type: type, proxies: proxies, lines: norm });
      }
    }
    return groups;
  }

  /**
   * 解析 rule-providers 段，**保留原始行**（normalize 到基准 0 缩进）。
   *
   * 为什么要保留：订阅的 rules 里大量使用 RULE-SET,<名字>,<策略> 形式，
   * 那些 <名字> 必须在同一份配置里有对应的 rule-providers 定义，
   * 否则 mihomo 解析时报 "rule set [X] not found"（实测踩过）。
   *
   * 这里不做结构化解析 —— rule-providers 的字段（behavior/interval/path/url）
   * 全部交给内核自己理解，我们只做缩进归一 + 路径改写。
   */
  static parseRuleProviders(yaml: string): string[] {
    const lines: string[] = yaml.split('\n');
    const out: string[] = [];
    let inside: boolean = false;
    let baseIndent: number = -1;
    for (let i = 0; i < lines.length; i++) {
      const line: string = lines[i];
      const t: string = line.trim();
      if (!inside) {
        if (/^rule-providers\s*:\s*$/.test(t)) {
          inside = true;
        }
        continue;
      }
      // 顶格的另一个顶层 key -> 本段结束
      if (t.length > 0 && !line.startsWith(' ') && !t.startsWith('#')) {
        break;
      }
      if (t.length === 0) {
        continue;
      }
      const ind: number = indentOf(line);
      if (baseIndent < 0) {
        baseIndent = ind;
      }
      // 统一减去基准缩进，保持内部相对层级
      out.push(ind >= baseIndent ? line.substring(baseIndent) : t);
    }
    return out;
  }

  /** 解析 rules 段。 */
  static parseRules(yaml: string): ParsedRule[] {
    const seg: string[] = sliceTopLevel(yaml, 'rules');
    const rules: ParsedRule[] = [];
    for (let i = 0; i < seg.length; i++) {
      const t: string = seg[i].trim();
      if (t.startsWith('- ')) {
        const v: string = yamlScalar(t.substring(2).trim());
        if (v.length > 0) {
          rules.push({ raw: v });
        }
      }
    }
    return rules;
  }
}
