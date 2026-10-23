/**
 * 系统网络变化监听。
 *
 * 要解决的问题：
 *   代理链路是"应用 → 本地内核 → 节点 → 目标"。切换 Wi-Fi/蜂窝、断网再恢复时，
 *   内核到节点的那段连接会全部失效，但应用侧状态仍然是 RUNNING ——
 *   页面表现为"一直转圈/请求失败"，而代理管理器和健康探测都要等到下一个周期
 *   （默认 60 秒，后台回来才立即）才会发现。
 *
 * 做法：
 *   订阅默认网络的 netAvailable / netLost。网络恢复时通知调用方立刻做一次
 *   "内核探活 + 重新下发代理设置"，比等健康探测的下一轮快得多。
 *
 * 为什么只监听"可用/丢失"两种事件：
 *   netCapabilitiesChange 在 Wi-Fi 与蜂窝之间切换时会连着触发多次，
 *   而每次恢复都要重建连接，重复触发没有意义。调用方自己做了去抖（见 Index）。
 */

import { connection } from '@kit.NetworkKit';

export type NetworkChangeListener = () => void;

export class NetworkWatcher {
  private static netConnection: connection.NetConnection | null = null;
  private static listener: NetworkChangeListener | null = null;
  /**
   * 上一次已知的联网状态：只有"从断开变为恢复"才通知，避免重复恢复。
   *
   * 初值不能假定为 true。应用在断网状态下冷启动时，第一次 netAvailable 之前
   * 根本不会收到 netLost，若初值是 true，那么"网络真正恢复"的那一刻会被
   * 当成"本来就在线"而丢掉 —— 恰好是这个功能最该起作用的那一次。
   * 所以注册前先向系统查一次默认网络。
   */
  private static online: boolean = true;

  static isOnline(): boolean {
    return NetworkWatcher.online;
  }

  /**
   * 开始监听；重复调用只替换回调，不重复注册（系统侧的监听器会累积）。
   */
  static start(onAvailable: NetworkChangeListener): void {
    NetworkWatcher.listener = onAvailable;
    if (NetworkWatcher.netConnection !== null) {
      return;
    }
    // 用系统当前的真实状态做基线（id === 0 表示没有默认网络）。
    NetworkWatcher.online = NetworkWatcher.queryOnline();
    try {
      const net: connection.NetConnection = connection.createNetConnection();
      // 先落引用再注册：register 的回调是异步的，这段窗口里若又来一次 start()，
      // 靠这个引用挡住第二次 createNetConnection（否则会注册出两条连接）。
      NetworkWatcher.netConnection = net;
      net.on('netAvailable', () => {
        const wasOffline: boolean = !NetworkWatcher.online;
        NetworkWatcher.online = true;
        // 只在"恢复"时通知：首次注册时系统也会回调一次，那时没有需要修复的东西。
        if (wasOffline && NetworkWatcher.listener !== null) {
          NetworkWatcher.listener();
        }
      });
      net.on('netLost', () => {
        NetworkWatcher.online = false;
      });
      // 注册失败必须回滚引用：留着它会让 start() 的幂等判断永久跳过重建，
      // 这个页面实例内就再也监听不到网络变化了。
      net.register((err: Object) => {
        if (!err) {
          return;
        }
        console.warn('NetworkWatcher: 注册失败 ' + JSON.stringify(err));
        if (NetworkWatcher.netConnection === net) {
          NetworkWatcher.netConnection = null;
        }
        try { net.unregister(() => {}); } catch (unregisterError) { /* 未注册成功，忽略 */ }
      });
    } catch (err) {
      // 没有 GET_NETWORK_INFO 权限或系统能力缺失时走到这里：退化为"不监听"。
      console.warn('NetworkWatcher: 初始化失败 ' + JSON.stringify(err));
      NetworkWatcher.netConnection = null;
    }
  }

  /** 同步查询系统当前是否有默认网络；查询失败按"在线"处理，避免误报恢复。 */
  private static queryOnline(): boolean {
    try {
      const handle: connection.NetHandle = connection.getDefaultNetSync();
      return handle !== undefined && handle !== null && handle.netId !== 0;
    } catch (err) {
      return true;
    }
  }

  /** 停止监听并释放系统侧注册。 */
  static stop(): void {
    NetworkWatcher.listener = null;
    // 复位基线：下一个页面实例 start() 时会重新查询，不会继承这一轮的旧值。
    NetworkWatcher.online = true;
    const net: connection.NetConnection | null = NetworkWatcher.netConnection;
    if (net === null) {
      return;
    }
    NetworkWatcher.netConnection = null;
    try {
      net.unregister((err: Object) => {
        if (err) {
          console.warn('NetworkWatcher: 注销失败 ' + JSON.stringify(err));
        }
      });
    } catch (err) { /* 已注销或系统能力缺失：忽略 */ }
  }
}
