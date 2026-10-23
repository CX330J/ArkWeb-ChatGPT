/**
 * 事件 ID 常量（emitter 跨线程 / 进程内事件总线的唯一事实来源）
 *
 * 原问题：
 *  1) 弹窗开关事件 'affffa' 在 WebDownloadFileImpl / Index.ets 里以裸字符串重复硬编码，
 *     改一处漏一处就静默失效（表现为"点下载没反应"）。
 *  2) 只有进度事件有常量，打开/关闭事件没有，无法统一做节流与监听计数观测。
 *
 * 修法：把三个事件 ID 收敛成常量，并新增 DOWNLOAD_STATE_EVENT_ID（状态机事件，
 *      payload 见 DownloadState），进度事件保留原值以免影响其它消费方。
 */
export class EventIdConstants {
  /** 下载进度事件（payload: number 0~100，已按 1% / 100ms 节流） */
  static DOWNLOAD_PROGRESS_EVENT_ID: string = 'downloadProgressEventId'

  /**
   * 原 'affffa'：下载弹窗开关事件。
   * 保留原始字符串字面量，保证 Index.ets 里已有的 `EmitterUtil.on<number>('affffa', ...)`
   * 在未改动时依然收得到（向后兼容）。
   */
  static DOWNLOAD_DIALOG_EVENT_ID: string = 'affffa'

  /** 弹窗开关事件 payload：打开 */
  static DOWNLOAD_DIALOG_OPEN: number = 1
  /** 弹窗开关事件 payload：关闭 */
  static DOWNLOAD_DIALOG_CLOSE: number = 2

  /** 下载状态机事件（payload 为 DownloadState 枚举值的 number） */
  static DOWNLOAD_STATE_EVENT_ID: string = 'downloadStateEventId'
}

/**
 * 下载状态机。
 *
 * 原问题：下载生命周期的状态只由 "affffa=1/2" 表达，无法区分
 * "刚到 onBeforeDownload 还没真正 start、此时用户点保存会 DOWNLOADER_NOT_INITIALIZED"
 * 与 "已在下载中" —— 这就是"点『保存』没反应也不报错"的根因。
 */
export enum DownloadState {
  /** 空闲，无下载项 */
  IDLE = 0,
  /** onBeforeDownload 已到达，等待用户确认（此时 startDownload 才合法） */
  PENDING = 1,
  /** 已调用 item.start()，正在下载 */
  DOWNLOADING = 2,
  /** 下载完成且保存成功 */
  SUCCESS = 3,
  /** 下载失败 / 保存失败 / 用户取消 */
  FAILED = 4
}
