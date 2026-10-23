/**
 * 订阅自动更新。
 *
 * 触发时机：页面回到前台 + 前台期间的定时检查（见 Index.onPageShow）。
 * 判断依据：距上次成功拉取的时间是否超过订阅声明的 `profile-update-interval`
 * （小时），未声明时按 24 小时。`SubscriptionLoader` 在拉取时把该响应头固定到
 * `lastUpdateIntervalHours`，`Subscriptions.fetch` 成功后再落到每条订阅上。
 *
 * 几个刻意的取舍：
 *   · **只在前台做**：后台更新会与长时任务、内核重建互相干扰，用户也看不到结果。
 *   · **内核忙时跳过**：更新当前启用订阅后会重启内核，和切节点/测速撞上会互相失败。
 *   · **从未成功拉取过的订阅不自动更新**（lastFetchAt=0）：添加订阅时已经同步拉过一次，
 *     这里再拉只会重复消耗流量。
 *   · 更新成功后若当前订阅正在运行，重启内核让新节点生效；这会有一次短暂断流，
 *     但频率由订阅自身的 interval 决定（通常 6~24 小时一次）。
 */

import { common } from '@kit.AbilityKit';
import { Subscriptions, Subscription } from './Subscriptions';
import { ProxyManager, ProxyState, OpResult } from './ProxyManager';

/** 订阅未声明间隔时的默认更新周期。 */
const DEFAULT_INTERVAL_HOURS: number = 24;
/** 两次检查之间的最小间隔：页面频繁回前台时不必每次都读订阅列表。 */
const CHECK_THROTTLE_MS: number = 30 * 60 * 1000;

export interface UpdateOutcome {
  /** 是否至少成功更新了一条订阅 */
  updated: boolean;
  /** 本轮的订阅 id（当前启用的那条） */
  subscriptionId: string;
  error?: string;
}

/**
 * 判断一条订阅是否到了更新时机（纯函数，便于回归测试）。
 *
 * @param lastFetchAt 上次成功拉取的时间戳（毫秒）
 * @param intervalHours 订阅声明的间隔（小时），<=0 表示未声明
 * @param now 当前时间戳（毫秒）
 */
export function subscriptionDue(lastFetchAt: number, intervalHours: number, now: number): boolean {
  if (lastFetchAt <= 0) {
    return false;
  }
  const hours: number = intervalHours > 0 ? intervalHours : DEFAULT_INTERVAL_HOURS;
  return now - lastFetchAt >= hours * 3600000;
}

export class SubscriptionUpdater {
  /** 同一时刻只跑一轮，避免前台/定时器重复触发时并发拉取同一订阅。 */
  private static inFlight: Promise<UpdateOutcome | null> | null = null;
  private static lastCheckAt: number = 0;

  /**
   * 到点才检查；调用方无需节流，直接 fire-and-forget 即可。
   * 返回 null 表示本轮没有需要更新的订阅（或内核正忙、未到检查时间）。
   */
  static maybeUpdate(ctx: common.UIAbilityContext): Promise<UpdateOutcome | null> {
    if (SubscriptionUpdater.inFlight !== null) {
      return SubscriptionUpdater.inFlight;
    }
    const now: number = Date.now();
    if (now - SubscriptionUpdater.lastCheckAt < CHECK_THROTTLE_MS) {
      return Promise.resolve(null);
    }
    SubscriptionUpdater.lastCheckAt = now;
    const task: Promise<UpdateOutcome | null> = SubscriptionUpdater.run(ctx)
      .catch((err: Object) => {
        console.warn('订阅自动更新异常: ' + JSON.stringify(err));
        return null;
      })
      .then((value: UpdateOutcome | null) => {
        SubscriptionUpdater.inFlight = null;
        return value;
      });
    SubscriptionUpdater.inFlight = task;
    return task;
  }

  private static async run(ctx: common.UIAbilityContext): Promise<UpdateOutcome | null> {
    await Subscriptions.init(ctx);
    const now: number = Date.now();
    const due: Subscription[] = [];
    const list: Subscription[] = Subscriptions.list();
    for (let i = 0; i < list.length; i++) {
      const s: Subscription = list[i];
      if (subscriptionDue(s.lastFetchAt, s.updateIntervalHours, now)) {
        due.push(s);
      }
    }
    if (due.length === 0) {
      return null;
    }
    // 内核正在切换/测速时不插队：更新当前订阅会触发内核重启，两边都会失败。
    if (ProxyManager.isBusy()) {
      return null;
    }
    const activeId: string = Subscriptions.getActiveId();
    let updatedActive: boolean = false;
    let updatedAny: boolean = false;
    let errorText: string = '';
    for (let i = 0; i < due.length; i++) {
      const sub: Subscription = due[i];
      const result = await Subscriptions.fetch(ctx, sub.id, false);
      if (result.ok) {
        updatedAny = true;
        if (sub.id === activeId) {
          updatedActive = true;
        }
      } else {
        errorText = result.error ?? '订阅更新失败';
        console.warn('订阅自动更新失败 [' + sub.name + ']: ' + errorText);
      }
    }
    // 只有"当前启用的订阅"更新成功才需要重启内核；其它订阅更新只刷新本地缓存。
    if (updatedActive && ProxyManager.getState() === ProxyState.RUNNING) {
      const restarted: OpResult = await ProxyManager.restartIfRunning(ctx);
      if (!restarted.ok) {
        errorText = restarted.error ?? errorText;
      }
    }
    return {
      updated: updatedAny,
      subscriptionId: activeId,
      error: errorText.length > 0 ? errorText : undefined
    };
  }
}
