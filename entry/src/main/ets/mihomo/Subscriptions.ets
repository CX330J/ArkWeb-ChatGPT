/**
 * 订阅管理：支持多个订阅链接并存，每个订阅独立下载缓存到本地。
 *
 * ===========================================================================
 * 数据模型
 * ===========================================================================
 *   Subscription  一条订阅 = 链接 + 名称 + 上次拉取时间 + 原始 YAML 缓存文件
 *   配置文件存在应用私有目录 filesDir/subscriptions/<id>.yaml
 *   元信息（名字、链接、时间）存在 preferences
 *
 * 为什么要把 YAML 落盘：
 *   用户要求"下载到本地"。好处是：
 *     · 后端服务临时不可用时仍能启用代理（用上次缓存的节点）
 *     · 切订阅、切节点不需要重新联网
 *     · 启动更快，不用等网络
 *
 * ===========================================================================
 * 选什么来出网：分组 或 节点
 * ===========================================================================
 * Clash 的核心机制是 proxy-groups（策略组）。订阅里常见：
 *   · 自动选择 / url-test -> 自动挑延迟最低的节点
 *   · 手动选择 / select   -> 用户在组内手动挑
 *   · 故障转移 / fallback -> 按顺序容灾
 * 所以"选分组"才是正确的用法。规则（rules）由订阅自带，不需要用户干预，
 * 因此界面上不展示规则。
 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { GroupSelection } from './ProxyStrategies';
import { MihomoCore } from './MihomoCore';

import { SubscriptionLoader, SubscriptionResult, ParsedNode, ParsedGroup,
  ParsedRule } from './SubscriptionLoader';

/** 一条订阅的元信息。 */
export interface Subscription {
  /** 稳定 id（时间戳生成） */
  id: string;
  /** 显示名（默认取订阅域名，可后续让用户改） */
  name: string;
  /** 订阅链接 */
  url: string;
  /** 上次成功拉取的时间戳（毫秒），0 表示未拉取 */
  lastFetchAt: number;
  /** 缓存的节点数 */
  nodeCount: number;
  /** 缓存的分组数 */
  groupCount: number;
  /** 订阅声明的更新间隔（小时）；0 表示未声明，自动更新按默认 24h */
  updateIntervalHours: number;
}

/** 解析后的订阅内容（内存）。 */
export interface SubscriptionData {
  nodes: ParsedNode[];
  groups: ParsedGroup[];
  rules: ParsedRule[];
  /** rule-providers 原始行（rules 里的 RULE-SET 引用依赖它） */
  ruleProviders: string[];
}

const PREF_NAME: string = 'proxy_subs_v2';
const KEY_SUBS: string = 'subscriptions';
const KEY_ACTIVE: string = 'active_sub_id';
const KEY_ACTIVE_GROUP: string = 'active_group';
const KEY_ACTIVE_NODE: string = 'active_node';
const KEY_ENABLED: string = 'proxy_enabled';
const KEY_GROUP_SELECTIONS: string = 'group_selections';
const SUB_DIR: string = 'subscriptions';

export class Subscriptions {
  private static store: preferences.Preferences | null = null;
  private static subs: Subscription[] = [];
  private static activeId: string = '';
  /** 选中的分组名（优先）。空表示用 activeNode */
  private static activeGroup: string = '';
  private static activeNode: string = '';
  private static enabled: boolean = false;
  private static groupSelections: GroupSelection[] = [];
  private static initialization: Promise<void> | null = null;
  /** id -> 已解析数据（内存缓存） */
  private static dataCache: Map<string, SubscriptionData> = new Map();

  /** 初始化：加载元信息。 */
  static async init(ctx: common.UIAbilityContext): Promise<void> {
    if (Subscriptions.initialization === null) {
      Subscriptions.initialization = Subscriptions.loadPreferences(ctx);
    }
    await Subscriptions.initialization;
  }

  private static async loadPreferences(ctx: common.UIAbilityContext): Promise<void> {
    try {
      Subscriptions.store = await preferences.getPreferences(ctx, PREF_NAME);
      const raw: string = (await Subscriptions.store.get(KEY_SUBS, '')) as string;
      Subscriptions.subs = Subscriptions.parseSubsJson(raw);
      Subscriptions.activeId = (await Subscriptions.store.get(KEY_ACTIVE, '')) as string;
      Subscriptions.activeGroup = (await Subscriptions.store.get(KEY_ACTIVE_GROUP, '')) as string;
      Subscriptions.activeNode = (await Subscriptions.store.get(KEY_ACTIVE_NODE, '')) as string;
      Subscriptions.enabled = (await Subscriptions.store.get(KEY_ENABLED, false)) as boolean;
      const choices: string = (await Subscriptions.store.get(KEY_GROUP_SELECTIONS, '[]')) as string;
      const parsed: GroupSelection[] = JSON.parse(choices);
      Subscriptions.groupSelections = Array.isArray(parsed) ? parsed : [];
    } catch (err) {
      console.error('Subscriptions.init 失败: ' + JSON.stringify(err));
    }
  }

  private static parseSubsJson(raw: string): Subscription[] {
    if (raw.length === 0) {
      return [];
    }
    try {
      const arr = JSON.parse(raw) as Subscription[];
      return Array.isArray(arr) ? arr : [];
    } catch (err) {
      return [];
    }
  }

  private static async persist(): Promise<void> {
    const st = Subscriptions.store;
    if (st === null) {
      return;
    }
    try {
      await st.put(KEY_SUBS, JSON.stringify(Subscriptions.subs));
      await st.put(KEY_ACTIVE, Subscriptions.activeId);
      await st.put(KEY_ACTIVE_GROUP, Subscriptions.activeGroup);
      await st.put(KEY_ACTIVE_NODE, Subscriptions.activeNode);
      await st.put(KEY_ENABLED, Subscriptions.enabled);
      await st.put(KEY_GROUP_SELECTIONS, JSON.stringify(Subscriptions.groupSelections));
      await st.flush();
    } catch (err) {
      console.error('Subscriptions.persist 失败: ' + JSON.stringify(err));
    }
  }

  // ---------- 读取 ----------
  static list(): Subscription[] {
    return Subscriptions.subs;
  }
  static getActiveId(): string {
    return Subscriptions.activeId;
  }
  static getActiveGroup(): string {
    return Subscriptions.activeGroup;
  }
  static getActiveNode(): string {
    return Subscriptions.activeNode;
  }
  /**
   * 当前订阅的节点 / 分组（同步读内存缓存）。
   *
   * 只返回已解析进 dataCache 的数据：调用方必须先用 getActiveData / loadCached
   * 触发解析。返回空数组而不是抛异常，让"还没加载"和"订阅没有节点"走同一条分支。
   */
  static getActiveNodes(): ParsedNode[] {
    const active: Subscription | null = Subscriptions.getActive();
    if (active === null) {
      return [];
    }
    const data: SubscriptionData | undefined = Subscriptions.dataCache.get(active.id);
    return data !== undefined ? data.nodes : [];
  }
  static getActiveGroups(): ParsedGroup[] {
    const active: Subscription | null = Subscriptions.getActive();
    if (active === null) {
      return [];
    }
    const data: SubscriptionData | undefined = Subscriptions.dataCache.get(active.id);
    return data !== undefined ? data.groups : [];
  }
  static isEnabled(): boolean {
    return Subscriptions.enabled;
  }

  static getGroupSelections(): GroupSelection[] {
    return Subscriptions.groupSelections.filter((s: GroupSelection) => s.subscriptionId === Subscriptions.getActiveId());
  }

  static async setGroupSelection(group: string, node: string): Promise<void> {
    const id: string = Subscriptions.getActiveId();
    Subscriptions.groupSelections = Subscriptions.groupSelections.filter((s: GroupSelection) =>
      s.subscriptionId !== id || s.group !== group);
    Subscriptions.groupSelections.push({ subscriptionId: id, group: group, node: node });
    await Subscriptions.persist();
  }

  static async setSelection(group: string, node: string): Promise<void> {
    Subscriptions.activeGroup = group;
    Subscriptions.activeNode = node;
    await Subscriptions.persist();
  }
  static getActive(): Subscription | null {
    for (let i = 0; i < Subscriptions.subs.length; i++) {
      if (Subscriptions.subs[i].id === Subscriptions.activeId) {
        return Subscriptions.subs[i];
      }
    }
    return Subscriptions.subs.length > 0 ? Subscriptions.subs[0] : null;
  }

  /** 当前订阅的缓存文件路径。 */
  private static cachePath(ctx: common.UIAbilityContext, id: string): string {
    return ctx.filesDir + '/' + SUB_DIR + '/' + id + '.yaml';
  }

  private static ensureDir(ctx: common.UIAbilityContext): void {
    const dir: string = ctx.filesDir + '/' + SUB_DIR;
    try {
      if (!fileIo.accessSync(dir)) {
        fileIo.mkdirSync(dir);
      }
    } catch (err) {
      // 已存在时 mkdir 会报错，忽略
    }
  }

  // ---------- 增删改 ----------
  /** 添加一条订阅（不拉取，只登记）。 */
  static async add(url: string): Promise<Subscription | null> {
    const u: string = url.trim();
    if (u.length === 0) {
      return null;
    }
    // 已存在相同链接则直接返回
    for (let i = 0; i < Subscriptions.subs.length; i++) {
      if (Subscriptions.subs[i].url === u) {
        return Subscriptions.subs[i];
      }
    }
    const s: Subscription = {
      id: Date.now().toString() + '_' + Math.floor(Math.random() * 1000).toString(),
      name: Subscriptions.nameFromUrl(u),
      url: u,
      lastFetchAt: 0,
      nodeCount: 0,
      groupCount: 0,
      updateIntervalHours: 0
    };
    Subscriptions.subs.push(s);
    if (Subscriptions.activeId.length === 0) {
      Subscriptions.activeId = s.id;
    }
    await Subscriptions.persist();
    return s;
  }

  static async remove(id: string): Promise<void> {
    const next: Subscription[] = [];
    for (let i = 0; i < Subscriptions.subs.length; i++) {
      if (Subscriptions.subs[i].id !== id) {
        next.push(Subscriptions.subs[i]);
      }
    }
    Subscriptions.subs = next;
    Subscriptions.dataCache.delete(id);
    if (Subscriptions.activeId === id) {
      Subscriptions.activeId = Subscriptions.subs.length > 0 ? Subscriptions.subs[0].id : '';
      Subscriptions.activeGroup = '';
      Subscriptions.activeNode = '';
    }
    await Subscriptions.persist();
  }

  static async setActive(id: string): Promise<void> {
    Subscriptions.activeId = id;
    Subscriptions.activeGroup = '';
    Subscriptions.activeNode = '';
    await Subscriptions.persist();
  }

  static async setActiveGroup(name: string): Promise<void> {
    Subscriptions.activeGroup = name;
    await Subscriptions.persist();
  }

  static async setActiveNode(name: string): Promise<void> {
    Subscriptions.activeNode = name;
    await Subscriptions.persist();
  }

  static async setEnabled(on: boolean): Promise<void> {
    Subscriptions.enabled = on;
    await Subscriptions.persist();
  }

  /** 从 URL 猜一个显示名（取域名首段）。 */
  private static nameFromUrl(url: string): string {
    const m = /https?:\/\/([^/]+)/.exec(url);
    if (m === null || m.length < 2) {
      return '订阅';
    }
    const host: string = m[1];
    const parts: string[] = host.split('.');
    return parts.length > 0 ? parts[0] : host;
  }

  // ---------- 拉取与缓存 ----------
  /**
   * 拉取指定订阅并把原始 YAML 落盘。
   * 返回解析结果；失败时若本地有缓存则回退到缓存。
   */
  static async fetch(ctx: common.UIAbilityContext, id: string,
    allowFallback: boolean = true): Promise<SubscriptionResult> {
    let target: Subscription | null = null;
    for (let i = 0; i < Subscriptions.subs.length; i++) {
      if (Subscriptions.subs[i].id === id) {
        target = Subscriptions.subs[i];
        break;
      }
    }
    if (target === null) {
      return { ok: false, nodes: [], groups: [], rules: [], ruleProviders: [], error: '订阅不存在' };
    }

    const core = MihomoCore.load(ctx.bundleCodeDir, ctx.filesDir);
    if (!core.ok) {
      return { ok: false, nodes: [], groups: [], rules: [], ruleProviders: [], error: '订阅解析内核加载失败' };
    }
    const r: SubscriptionResult = await SubscriptionLoader.fetchAndParse(target.url);
    if (r.ok) {
      // 落盘原始 YAML（用户要求下载到本地）
      Subscriptions.ensureDir(ctx);
      try {
        const yaml: string = SubscriptionLoader.lastRawYaml;
        if (yaml.length > 0) {
          const p: string = Subscriptions.cachePath(ctx, id);
          const f = fileIo.openSync(p,
            fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
          fileIo.writeSync(f.fd, yaml);
          fileIo.closeSync(f);
        }
      } catch (err) {
        console.warn('订阅 YAML 落盘失败: ' + JSON.stringify(err));
      }
      Subscriptions.dataCache.set(id, {
        nodes: r.nodes, groups: r.groups, rules: r.rules,
        ruleProviders: r.ruleProviders
      });
      target.lastFetchAt = Date.now();
      target.nodeCount = r.nodes.length;
      target.groupCount = r.groups.length;
      // 记录订阅自己声明的更新间隔，供 SubscriptionUpdater 判断何时再拉。
      target.updateIntervalHours = SubscriptionLoader.lastUpdateIntervalHours;
      await Subscriptions.persist();
      return r;
    }

    // 失败：尝试用本地缓存
    if (allowFallback) {
      const cached: SubscriptionData | null = await Subscriptions.loadCached(ctx, id);
      if (cached !== null && cached.nodes.length > 0) {
        return {
          ok: true, nodes: cached.nodes, groups: cached.groups, rules: cached.rules,
          ruleProviders: cached.ruleProviders,
          error: '网络失败，已使用本地缓存（' + (r.error ?? '') + '）'
        };
      }
    }
    return r;
  }

  /** 从本地 YAML 缓存重新解析（不联网）。 */
  static async loadCached(ctx: common.UIAbilityContext,
    id: string): Promise<SubscriptionData | null> {
    const mem = Subscriptions.dataCache.get(id);
    if (mem !== undefined) {
      return mem;
    }
    try {
      const p: string = Subscriptions.cachePath(ctx, id);
      if (!fileIo.accessSync(p)) {
        return null;
      }
      const content: string = fileIo.readTextSync(p);
      if (content.length === 0) {
        return null;
      }
      const nodes: ParsedNode[] = SubscriptionLoader.parseProxies(content);
      const groups: ParsedGroup[] = SubscriptionLoader.parseGroups(content);
      const rules: ParsedRule[] = SubscriptionLoader.parseRules(content);
      const rps: string[] = SubscriptionLoader.parseRuleProviders(content);
      const data: SubscriptionData = {
        nodes: nodes, groups: groups, rules: rules, ruleProviders: rps
      };
      Subscriptions.dataCache.set(id, data);
      return data;
    } catch (err) {
      console.warn('读取订阅缓存失败: ' + JSON.stringify(err));
      return null;
    }
  }

  /**
   * 当前活动订阅的数据 —— **只读本地，绝不联网**。
   *
   * 【这条约束很重要】
   * 用户明确要求"不能每打开一次设置就重新抓一遍节点"。
   * 所以本方法只做两件事：查内存缓存、读磁盘 YAML。
   * 需要联网时必须由用户显式点"刷新订阅"或首次添加订阅触发。
   *
   * 若本地没有任何缓存，返回 null，界面提示用户点"刷新订阅"。
   */
  static async getActiveData(ctx: common.UIAbilityContext): Promise<SubscriptionData | null> {
    const s: Subscription | null = Subscriptions.getActive();
    if (s === null) {
      return null;
    }
    return Subscriptions.loadCached(ctx, s.id);
  }

  /** 启用代理时用：先读本地，实在没有才联网（仍受 allowNetwork 控制）。 */
  static async getActiveDataForStart(ctx: common.UIAbilityContext,
    allowNetwork: boolean): Promise<SubscriptionData | null> {
    const local: SubscriptionData | null = await Subscriptions.getActiveData(ctx);
    if (local !== null && local.nodes.length > 0) {
      return local;
    }
    if (!allowNetwork) {
      return null;
    }
    const s: Subscription | null = Subscriptions.getActive();
    if (s === null) {
      return null;
    }
    const r: SubscriptionResult = await Subscriptions.fetch(ctx, s.id, false);
    if (r.ok) {
      return { nodes: r.nodes, groups: r.groups, rules: r.rules,
        ruleProviders: r.ruleProviders };
    }
    return null;
  }
}
