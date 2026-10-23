/**
 * 代理配置的持久化存储。
 *
 * 存什么：
 *   · 订阅链接（用户填一次的 URL）
 *   · 当前选中的节点名
 *   · 是否启用代理
 *   · 上次拉取订阅的时间与节点数量（用于界面展示"最后更新时间"）
 *
 * 为什么不存整份节点配置：
 *   节点配置每次从订阅拉取（订阅内容会变），存一份快照容易和订阅不一致。
 *   只持久化"用户的选择"，其余每次启动按需拉取。
 *
 * 存储选型：@ohos.data.preferences。
 * 理由：数据量小（几个字符串）、读写频繁（界面每次打开都要读）、
 * 用不着数据库；preferences 是键值对，最贴合。
 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

/** 持久化的代理设置。 */
export interface ProxySettings {
  /** 订阅链接；空串表示尚未配置 */
  subscriptionUrl: string;
  /** 当前选中的节点名；空串表示用订阅默认 */
  selectedNode: string;
  /** 是否启用代理 */
  enabled: boolean;
  /** 上次成功拉取订阅的时间戳（毫秒），0 表示从未拉取 */
  lastFetchAt: number;
  /** 上次拉取到的节点数量 */
  nodeCount: number;
  /** 启动时自动测速并选择最快节点 */
  autoSelectOnStart: boolean;
  /** 链路劣化时自动切换到更优节点 */
  autoSwitchOnDegrade: boolean;
  /** 后台保持代理链路（申请长时任务，避免回前台断网） */
  keepAliveInBackground: boolean;
  /** 自动换节点后是否刷新网页，让长连接走新出口 */
  refreshAfterSwitch: boolean;
  /** 健康探测间隔（毫秒），0 表示关闭 */
  healthCheckIntervalMs: number;
  /** 「智能选路」卡片是否展开（记忆用户上次的收起/展开状态） */
  smartPanelExpanded: boolean;
  /**
   * 最近一次测速结果缓存（JSON 字符串：{ at, entries:[{name,delay}] }）。
   *
   * 存它的理由：面板每次打开都会重建 pingMap，104 个节点全部重测要十几秒，
   * 期间列表上没有任何延迟信息。缓存一份"10 分钟内的结果"，打开即可先显示，
   * 用户仍可随时点测速刷新。
   */
  latencyCache: string;
}

const PREF_NAME: string = 'proxy_settings';
const KEY_SUB_URL: string = 'subscription_url';
const KEY_NODE: string = 'selected_node';
const KEY_ENABLED: string = 'enabled';
const KEY_LAST_FETCH: string = 'last_fetch_at';
const KEY_NODE_COUNT: string = 'node_count';
const KEY_AUTO_SELECT: string = 'auto_select_on_start';
const KEY_AUTO_SWITCH: string = 'auto_switch_on_degrade';
const KEY_KEEP_ALIVE: string = 'keep_alive_background';
const KEY_REFRESH_AFTER: string = 'refresh_after_switch';
const KEY_HEALTH_MS: string = 'health_check_interval_ms';
const KEY_SMART_EXPANDED: string = 'smart_panel_expanded';
const KEY_LATENCY_CACHE: string = 'latency_cache';

/** 默认值：未配置状态；自动选路默认开启，后台保活默认开启。 */
export function defaultProxySettings(): ProxySettings {
  return {
    subscriptionUrl: '',
    selectedNode: '',
    enabled: false,
    lastFetchAt: 0,
    nodeCount: 0,
    autoSelectOnStart: true,
    autoSwitchOnDegrade: true,
    keepAliveInBackground: true,
    refreshAfterSwitch: true,
    healthCheckIntervalMs: 60000,
    smartPanelExpanded: true,
    latencyCache: ''
  };
}

/**
 * 代理设置的读写。
 *
 * 设计要点：所有方法都不抛异常，读失败返回默认值、写失败返回 false。
 * 这样界面不需要处处 try/catch，也不会因为存储异常导致整个设置页打不开。
 */
export class ProxySettingsStore {
  private static store: preferences.Preferences | null = null;
  /**
   * 最近一次读到/写入的设置快照。
   *
   * 用途：生命周期回调（onPageHide）是同步的，没法 await 一次读盘，
   * 而内存里的副本可能已经过期（用户刚在面板里改完还没触发页面重读）。
   * 所有写入都经过 save()，读写都更新这份快照，同步路径读它即可拿到最新值。
   */
  private static cachedSettings: ProxySettings | null = null;

  /** 同步读取最新已知设置；从未成功读过时返回 null。 */
  static cached(): ProxySettings | null {
    return ProxySettingsStore.cachedSettings;
  }

  /** 初始化（幂等）。应用启动时调用一次即可。 */
  static async init(ctx: common.UIAbilityContext): Promise<void> {
    if (ProxySettingsStore.store !== null) {
      return;
    }
    try {
      ProxySettingsStore.store = await preferences.getPreferences(ctx, PREF_NAME);
    } catch (err) {
      console.error('ProxySettingsStore.init 失败: ' + JSON.stringify(err));
    }
  }

  /** 读取全部设置。 */
  static async load(): Promise<ProxySettings> {
    const s: ProxySettings = defaultProxySettings();
    const store = ProxySettingsStore.store;
    if (store === null) {
      return s;
    }
    try {
      s.subscriptionUrl = (await store.get(KEY_SUB_URL, '')) as string;
      s.selectedNode = (await store.get(KEY_NODE, '')) as string;
      s.enabled = (await store.get(KEY_ENABLED, false)) as boolean;
      s.lastFetchAt = (await store.get(KEY_LAST_FETCH, 0)) as number;
      s.nodeCount = (await store.get(KEY_NODE_COUNT, 0)) as number;
      s.autoSelectOnStart = (await store.get(KEY_AUTO_SELECT, true)) as boolean;
      s.autoSwitchOnDegrade = (await store.get(KEY_AUTO_SWITCH, true)) as boolean;
      s.keepAliveInBackground = (await store.get(KEY_KEEP_ALIVE, true)) as boolean;
      s.refreshAfterSwitch = (await store.get(KEY_REFRESH_AFTER, true)) as boolean;
      s.healthCheckIntervalMs = (await store.get(KEY_HEALTH_MS, 60000)) as number;
      s.smartPanelExpanded = (await store.get(KEY_SMART_EXPANDED, true)) as boolean;
      s.latencyCache = (await store.get(KEY_LATENCY_CACHE, '')) as string;
      ProxySettingsStore.cachedSettings = s;
    } catch (err) {
      console.error('ProxySettingsStore.load 失败: ' + JSON.stringify(err));
    }
    return s;
  }

  /** 保存全部设置。 */
  static async save(s: ProxySettings): Promise<boolean> {
    const store = ProxySettingsStore.store;
    if (store === null) {
      return false;
    }
    try {
      await store.put(KEY_SUB_URL, s.subscriptionUrl);
      await store.put(KEY_NODE, s.selectedNode);
      await store.put(KEY_ENABLED, s.enabled);
      await store.put(KEY_LAST_FETCH, s.lastFetchAt);
      await store.put(KEY_NODE_COUNT, s.nodeCount);
      await store.put(KEY_AUTO_SELECT, s.autoSelectOnStart);
      await store.put(KEY_AUTO_SWITCH, s.autoSwitchOnDegrade);
      await store.put(KEY_KEEP_ALIVE, s.keepAliveInBackground);
      await store.put(KEY_REFRESH_AFTER, s.refreshAfterSwitch);
      await store.put(KEY_HEALTH_MS, s.healthCheckIntervalMs);
      await store.put(KEY_SMART_EXPANDED, s.smartPanelExpanded);
      await store.put(KEY_LATENCY_CACHE, s.latencyCache);
      await store.flush();
      // 写盘成功才更新快照：写失败时内存与磁盘不一致，宁可让同步路径读旧值。
      ProxySettingsStore.cachedSettings = s;
      return true;
    } catch (err) {
      console.error('ProxySettingsStore.save 失败: ' + JSON.stringify(err));
      return false;
    }
  }
}
