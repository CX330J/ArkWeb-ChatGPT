import { promptAction } from '@kit.ArkUI'
import { webview } from '@kit.ArkWeb'
import { BusinessError } from '@kit.BasicServicesKit'
import { DownloadState, EventIdConstants } from '../contants/EventIdConstants'
import { EmitterUtil, ProgressThrottle } from '../utiles/EmitterUtil'
import { IAbstractDownloadHandler } from './IWebDownloadFile'

/**
 * @dec web 下载文件方法实现
 * @date 2025/3/11 20:26
 *
 * ========== 本轮修复汇总 ==========
 * [BUG-A] 静态 generateDefaultPath 同样缺 '/' → 已删除，统一走基类 generateDefaultPath
 * [BUG-B] static startDownload 直接用静态 _webDownloadItem.start(path)，
 *         绕过基类 ensureFileExtension / validatePath / prepareDirectory；
 *         且与基类的 this.webDownloadItem 是**两份状态**，onDownloadFinish 置空一份、
 *         另一份仍是旧引用 → 第二次下载后 cancel 取消的是上一次的 item。
 *         修法：删掉全部静态状态，实例方法转发基类，this.webDownloadItem 成为唯一事实来源。
 * [BUG-C] 进度事件每 ~100ms 一次 + 弹窗不可见时也在发 → 主线程被无意义重绘占满
 *         修法：ProgressThrottle（>=1% 且 >=100ms）+ 仅在弹窗可见时发送
 * [BUG-D] 'affffa' 裸字符串硬编码 → 改用 EventIdConstants.DOWNLOAD_DIALOG_EVENT_ID
 * [BUG-E] cancelDownload 在无 item 时静默什么都不做（点了没反应）
 *         修法：无 item 也关闭弹窗并给出明确提示
 */
export class WebDownloadFileHelper extends IAbstractDownloadHandler {
  private static instance: WebDownloadFileHelper = new WebDownloadFileHelper()

  /** 进度节流：>=1% 变化 且 >=100ms */
  private progressThrottle: ProgressThrottle = new ProgressThrottle(1, 100)
  /**
   * 弹窗当前是否可见。
   * 原问题：onDownloadUpdated 无论弹窗在不在都 emit，弹窗销毁期间的进度事件全部落空。
   * 修法：由弹窗在 aboutToAppear/aboutToDisappear 里置位；不可见时直接不发。
   */
  private static dialogVisible: boolean = true

  /**
   * 单例访问入口
   */
  static getInstance(): WebDownloadFileHelper {
    return WebDownloadFileHelper.instance
  }

  /** 弹窗可见性由 DownloadConfirmDialog 维护 */
  static setDialogVisible(visible: boolean): void {
    WebDownloadFileHelper.dialogVisible = visible
  }

  /**
   * 静态下载启动方法（保持旧调用方式可用）
   *
   * 原问题（任务点 3）：这里曾是**独立的一套**下载实现：
   *   `_webDownloadItem!.start(path)` 直接启动，跳过 ensureFileExtension / validatePath；
   *   而且 `_webDownloadItem` 与基类 `this.webDownloadItem` 是两个字段，
   *   handleDownloadStart 里复制一份、cleanup 里只清基类那份 → 状态分裂。
   * 修法：全部转发到实例基类方法，只保留 this.webDownloadItem 一份状态。
   * @returns true=已发起下载，false=无待下载项（调用方需提示用户）
   */
  static startDownload(customPath?: string): boolean {
    return WebDownloadFileHelper.instance.startDownload(customPath)
  }

  /** 打开下载弹窗 */
  static openDownloadPopUpWindow(): void {
    EmitterUtil.post<number>(EventIdConstants.DOWNLOAD_DIALOG_EVENT_ID, EventIdConstants.DOWNLOAD_DIALOG_OPEN)
  }

  /** 关闭下载弹窗 */
  static closeDownloadPopUpWindow(): void {
    EmitterUtil.post<number>(EventIdConstants.DOWNLOAD_DIALOG_EVENT_ID, EventIdConstants.DOWNLOAD_DIALOG_CLOSE)
  }

  /** 发布下载状态（供 UI 侧区分"待确认/下载中/完成/失败"） */
  private postState(state: DownloadState): void {
    EmitterUtil.post<number>(EventIdConstants.DOWNLOAD_STATE_EVENT_ID, state as number)
  }

  protected handleDownloadStart(): void {
    // 新下载开始：重置节流器，保证第一次进度一定发出去
    this.progressThrottle.reset()
    this.postState(DownloadState.PENDING)
    WebDownloadFileHelper.openDownloadPopUpWindow()
  }

  /**
   * 进度更新
   *
   * 原问题（任务点 7）：每次都 emitter.emit（跨线程序列化）+ 弹窗 @State 赋值 → Progress 重建。
   *   网页下载一个 200MB 文件会触发数千次，主线程持续被细小重绘打断（"下载时卡顿"）。
   * 修法：节流 + 不可见不发。
   */
  protected handleProgressUpdate(progress: number): void {
    const shouldEmit: boolean = this.progressThrottle.shouldEmit(
      progress, Date.now(), WebDownloadFileHelper.dialogVisible)
    if (!shouldEmit) {
      return
    }
    this.postState(DownloadState.DOWNLOADING)
    EmitterUtil.post<number>(EventIdConstants.DOWNLOAD_PROGRESS_EVENT_ID, Math.round(progress))
  }

  protected handleDownloadSuccess(): void {
    // 完成前补发 100%，避免节流把最后一段吃掉导致进度条停在 99%
    EmitterUtil.post<number>(EventIdConstants.DOWNLOAD_PROGRESS_EVENT_ID, 100)
    this.postState(DownloadState.SUCCESS)
    this.cleanupDownloadSession()
    WebDownloadFileHelper.closeDownloadPopUpWindow()
    promptAction.showToast({ message: '文件保存成功' })
  }

  protected handleDownloadFailure(message: string): void {
    this.postState(DownloadState.FAILED)
    this.cleanupDownloadSession()
    WebDownloadFileHelper.closeDownloadPopUpWindow()
    // 用户主动取消保存时已经把提示交给 cancel 流程，避免连续两条 toast
    if (message !== '已取消保存') {
      promptAction.showToast({ message })
    }
  }

  /**
   * 停止当前下载（供弹窗"取消"调用）
   *
   * 原问题：
   *  1) 原先只在有 item 时才动作，没有 item 就什么都不做 —— 弹窗"取消"点了没反应；
   *  2) 清理顺序是 cancel → cleanup → close → toast，然后弹窗又自己 close 一次（重复）；
   *  3) 明确用户取消也要弹 toast（"下载已取消"），属于必要的反馈，保留但只出一次。
   * 修法：无论有没有 item，都保证"关弹窗 + 明确反馈"。
   */
  static cancelDownload(): void {
    const helper: WebDownloadFileHelper = WebDownloadFileHelper.instance
    const cancelled: boolean = helper.cancelCurrentDownload()
    helper.progressThrottle.reset()
    // 取消后状态回落到 IDLE，避免 UI 停在"下载中"
    EmitterUtil.post<number>(EventIdConstants.DOWNLOAD_STATE_EVENT_ID, DownloadState.IDLE as number)
    WebDownloadFileHelper.closeDownloadPopUpWindow()
    promptAction.showToast({ message: cancelled ? '下载已取消' : '已关闭下载' })
  }

  /** 供外部查询是否有待确认的下载项（弹窗据此决定按钮是否可点） */
  static hasPendingDownload(): boolean {
    return WebDownloadFileHelper.instance.hasPendingItem()
  }
}
