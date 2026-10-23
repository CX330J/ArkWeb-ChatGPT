import { emitter } from '@kit.BasicServicesKit';

/**
 * 事件回调的统一签名（组件里保存这个引用，注销时原样传回即可）
 *
 * 原问题：调用方普遍写成
 *     EmitterUtil.on<number>(id, (event) => { ... })   // 匿名箭头函数
 *     EmitterUtil.off<number>(id, (event) => { })      // 又一个全新函数对象
 *   emitter.off 是按 (eventId, callback) **引用相等** 去移除监听的，
 *   两个不同的函数对象永远匹配不上 → 监听永远注销不掉。
 *   每次弹窗开关都残留一个旧监听，旧监听闭包还握着已销毁组件的 this：
 *     - 监听器数量线性增长 → 每次 emit 要遍历越来越多的回调 → 越用越卡；
 *     - 旧弹窗的回调仍会更新已销毁组件的 @State → 进度串台 / 非法状态更新告警。
 *   这里是"弹窗反复开关后越来越卡、进度串台"的根因。
 *
 * 修法：对外暴露统一的 EmitterCallback 类型 + 具名回调保存模式（见 EmitterUtil.on 的返回值
 *   与 off 的签名），组件把 on() 的返回值存成成员变量，disappear 时原样 off 掉。
 */
export type EmitterCallback<T> = Callback<emitter.GenericEventData<T>>;

/**
 * Emitter 工具类（进程内/线程间事件总线）
 *
 * ⚠️ 统一约定：eventId 一律 `normalize` 成 string 后再传给 emitter 的 on/off/emit/getListenerCount，
 * 原实现里 on/off 用 eventId.toString()、而 getListenerCount 却传原始值，
 * 传数字 id 时两者看到的不是同一个 key —— 调 getListenerCount 排查泄漏会一直得到 0。
 */
export class EmitterUtil {
  /**
   * eventId 归一化：string | number → string。
   * 与 emitter.emit(eventId: string) 的签名对齐，保证 on/off/count 用的是同一个 key。
   */
  static normalize(eventId: string | number): string {
    return typeof eventId === 'string' ? eventId : eventId.toString();
  }

  /**
   * 发送事件
   * @param eventId 事件 ID，string 类型不支持空字符串
   * @param eventData 发送的数据
   * @param priority 事件被发送的优先级
   */
  static post<T>(eventId: string | number, eventData: T, priority: emitter.EventPriority = emitter.EventPriority.HIGH): void {
    // 空 eventId 直接丢弃：emitter.emit 会抛 401 参数错误，在 onDownloadUpdated 这种
    // 100ms 级高频回调里抛异常会直接打断下载回调链
    if (eventId === '' || eventId === undefined || eventId === null) {
      return;
    }
    const genericEventData: emitter.GenericEventData<T> = { data: eventData };
    const options: emitter.Options = { priority: priority };
    emitter.emit(EmitterUtil.normalize(eventId), options, genericEventData);
  }

  /**
   * 订阅事件（只取 data，不需要手动注销时使用；需要注销请用 on()）
   * @param eventId 事件 ID
   * @param callback 回调（入参是裸 data）
   */
  static onSubscribe<T>(eventId: string | number, callback: Callback<T>): void {
    emitter.on<T>(EmitterUtil.normalize(eventId), (eventData: emitter.GenericEventData<T>) => {
      callback(eventData.data);
    });
  }

  /**
   * 单次订阅指定事件
   * @param eventId 事件 ID
   * @param callback 回调（入参是裸 data）
   */
  static onceSubscribe<T>(eventId: string | number, callback: Callback<T>): void {
    emitter.once<T>(EmitterUtil.normalize(eventId), (eventData: emitter.GenericEventData<T>) => {
      callback(eventData.data);
    });
  }

  /**
   * 取消某事件的【全部】订阅。
   * @param eventId 事件 ID
   */
  static unSubscribe(eventId: string | number): void {
    emitter.off(EmitterUtil.normalize(eventId));
  }

  /**
   * 取消某事件上指定的一个订阅（按引用匹配，必须传入 on() 返回的那个对象）
   * @param eventId 事件 ID
   * @param callback on() 的返回值
   */
  static unSubscribeOne<T>(eventId: string | number, callback: EmitterCallback<T>): void {
    emitter.off<T>(EmitterUtil.normalize(eventId), callback);
  }

  /**
   * 获取指定事件的订阅数。
   * 原问题：原实现 `emitter.getListenerCount(eventId)` 直接传原始值，而 on/off 传的是 toString 后的
   *   string，数字 id 下统计永远为 0，泄漏不可观测。
   * 修法：统一走 normalize。
   */
  static getListenerCount(eventId: string | number): number {
    return emitter.getListenerCount(EmitterUtil.normalize(eventId));
  }

  /**
   * 订阅事件（回调拿到完整 GenericEventData，可精确注销）
   * @param eventId 事件 ID
   * @param callback 回调
   * @returns 已注册的回调引用 —— **务必保存**，disappear 时传给 off()
   */
  static on<T>(eventId: string | number, callback: EmitterCallback<T>): EmitterCallback<T> {
    emitter.on<T>(EmitterUtil.normalize(eventId), callback);
    return callback;
  }

  /**
   * 单次订阅指定事件
   * @param eventId 事件 ID
   * @param callback 回调
   * @returns 已注册的回调引用
   */
  static once<T>(eventId: string | number, callback: EmitterCallback<T>): EmitterCallback<T> {
    emitter.once<T>(EmitterUtil.normalize(eventId), callback);
    return callback;
  }

  /**
   * 取消事件订阅，支持取消指定事件回调。
   *
   * 原问题：调用方传匿名箭头函数，引用不相等 → 注销永远失败（旧监听从不断开）。
   * 修法：调用方必须把 on() 的返回值存下来，原样传进来。
   */
  static off<T>(eventId: string | number, callback: EmitterCallback<T>): void {
    emitter.off<T>(EmitterUtil.normalize(eventId), callback);
  }
}

/**
 * 事件发送节流器（用于下载进度这类 100ms 级高频事件）
 *
 * 原问题：onDownloadUpdated 每 ~100ms 回调一次，每次都 emitter.emit 跨线程序列化 +
 *   弹窗侧 @State 赋值 → Progress 组件重建。一次下载动辄几千次通知，主线程被无意义的
 *   细小进度刷新占满（观感："下载时整个页面都在顿"）。
 *
 * 修法：两道闸门
 *   1) 只在弹窗可见时才发（visible 钩子），不可见时连 emit 都不发生；
 *   2) 百分比变化 >= minDeltaPercent 且距上次发送 >= minIntervalMs 才发，
 *      并对 100%（完成）做强制放行，保证进度条一定能走到头。
 */
export class ProgressThrottle {
  private lastPercent: number = -1;
  private lastEmitTs: number = 0;
  /** 最小百分比变化量（默认 1%） */
  private minDeltaPercent: number;
  /** 最小发送间隔毫秒（默认 100ms） */
  private minIntervalMs: number;

  // 原问题：写成 constructor(private minDeltaPercent: number, ...) 的"参数属性"形式，
  //   ArkTS 不允许（arkts-no-ctor-prop-decls），必须在类体里显式声明字段再在构造器里赋值。
  constructor(minDeltaPercent: number = 1, minIntervalMs: number = 100) {
    this.minDeltaPercent = minDeltaPercent;
    this.minIntervalMs = minIntervalMs;
  }

  /** 重置（新的一次下载开始时调用） */
  reset(): void {
    this.lastPercent = -1;
    this.lastEmitTs = 0;
  }

  /**
   * 判断本次进度是否应该发送
   * @param percent 0~100
   * @param nowMs 当前时间戳（Date.now()）
   * @param visible 弹窗是否可见
   * @returns true 表示需要发送
   */
  shouldEmit(percent: number, nowMs: number, visible: boolean): boolean {
    if (!visible) {
      return false;
    }
    const p: number = Math.round(percent);
    // 完成态强制放行：否则最后 1% 之内的小数变化可能被节流掉，进度条停在 99%
    if (p >= 100) {
      this.lastPercent = p;
      this.lastEmitTs = nowMs;
      return true;
    }
    if (this.lastPercent < 0) {
      this.lastPercent = p;
      this.lastEmitTs = nowMs;
      return true;
    }
    if (p - this.lastPercent < this.minDeltaPercent) {
      return false;
    }
    if (nowMs - this.lastEmitTs < this.minIntervalMs) {
      return false;
    }
    this.lastPercent = p;
    this.lastEmitTs = nowMs;
    return true;
  }
}
