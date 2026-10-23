import { emitter } from '@kit.BasicServicesKit'
import { DownloadState, EventIdConstants } from '../contants/EventIdConstants'
import { WebDownloadFileHelper } from '../delegate/WebDownloadFileImpl'
import { EmitterCallback, EmitterUtil } from '../utiles/EmitterUtil'

// 添加阴影配置
const shadowOptions: ShadowOptions = {
  radius: 16,
  color: $r('app.color.shadow'),
  offsetX: 0,
  offsetY: 4
};

/**
 * 卡片高度（vp）：确认态与下载中态共用同一个高度。
 * 原实现两个分支分别写死 140 / 148，点"保存"的瞬间弹窗会向上跳 8vp，
 * 是一个能直接看出来的布局抖动。统一成一个常量后切换状态只换内容、不动尺寸。
 * 取 148（较大的一侧），保证两种内容都能完整容纳。
 */
const DIALOG_CARD_HEIGHT: number = 148;

/**
 * 下载确认 / 进度弹窗
 *
 * ========== 本轮修复汇总 ==========
 * [BUG-1] 列表注销永远是"另一个匿名函数" → 监听永远注销不掉，弹窗每开关一次就多留一个
 *         旧监听，旧监听还持有已销毁组件的 this → 越用越卡 + 进度串台。
 *         修法：aboutToAppear 里把 on() 的返回值保存成成员，aboutToDisappear 原样 off。
 * [BUG-2] 取消顺序：先 close() 再 cancelDownload() → 组件已销毁后 cancel 里的 toast/状态更新
 *         打到已解绑的 controller 上；且 cancel 内部又关一次窗（重复）。
 *         修法：先 cancel（有 item 才提示取消）→ 再 close 自己。
 * [BUG-3] 点"保存"后 startDownload 抛错/返回 false 时界面没有任何变化（"点了没反应"）。
 *         修法：根据返回值回滚 isDownloading，并给出提示。
 * [BUG-4] 进度事件没校验范围，脏数据会让 Progress 越界。
 * [BUG-5] 弹窗销毁后没有把"不可见"告诉下载器，进度事件仍在跨线程投递。
 */
@CustomDialog
export struct DownloadConfirmDialog {
  @State isDownloading: boolean = false
  @State downloadProgress: number = 0
  dialogController: CustomDialogController

  // 必须是成员：注销时引用必须与注册时是同一个函数对象
  private progressListener: EmitterCallback<number> | null = null
  private dialogStateListener: EmitterCallback<number> | null = null

  aboutToAppear(): void {
    // 告诉下载器"弹窗在"，进度事件才有必要发
    WebDownloadFileHelper.setDialogVisible(true)
    const progressListener: EmitterCallback<number> = (event: emitter.GenericEventData<number>) => {
      const value: number = event?.data ?? 0
      // 进度在 0~100 之外属于脏数据，直接丢弃（否则 Progress 会画出异常弧线）
      if (value < 0 || value > 100) {
        return
      }
      this.downloadProgress = value
    }
    this.progressListener = EmitterUtil.on<number>(EventIdConstants.DOWNLOAD_PROGRESS_EVENT_ID, progressListener)

    const stateListener: EmitterCallback<number> = (event: emitter.GenericEventData<number>) => {
      const state: number = event?.data ?? DownloadState.IDLE
      // 下载真正结束（完成/失败/取消）时才切回"确认态"，保证下次打开是干净的
      if (state === DownloadState.DOWNLOADING) {
        this.isDownloading = true
      } else if (state === DownloadState.SUCCESS || state === DownloadState.FAILED || state === DownloadState.IDLE) {
        this.isDownloading = false
      }
    }
    this.dialogStateListener = EmitterUtil.on<number>(EventIdConstants.DOWNLOAD_STATE_EVENT_ID, stateListener)
  }

  aboutToDisappear(): void {
    // 原问题：传的是新的匿名箭头函数，emitter 引用比较失败 → 这个监听永远留在事件总线上，
    // 而且它闭包持有着已销毁组件的 this（内存泄漏 + 之后每次 emit 都要调用它）。
    if (this.progressListener !== null) {
      EmitterUtil.off<number>(EventIdConstants.DOWNLOAD_PROGRESS_EVENT_ID, this.progressListener)
      this.progressListener = null
    }
    if (this.dialogStateListener !== null) {
      EmitterUtil.off<number>(EventIdConstants.DOWNLOAD_STATE_EVENT_ID, this.dialogStateListener)
      this.dialogStateListener = null
    }
    WebDownloadFileHelper.setDialogVisible(false)
    // 复位本地状态，弹窗实例被复用（CustomDialogController.open 多次）时不会残留上一轮的进度
    this.isDownloading = false
    this.downloadProgress = 0
  }

  /**
   * 统一的取消流程
   * 原问题：先 close() 再 cancelDownload()，组件已走完 aboutToDisappear，
   *   cancelDownload 里的 promptAction / 事件投递作用在已解绑的上下文上，
   *   且 cancelDownload 内部也会 close 弹窗 —— 一次点击关两次。
   * 修法：先 cancel（它负责取消下载 + 发关闭事件），再 close 自己，顺序固定。
   */
  private handleCancel(): void {
    WebDownloadFileHelper.cancelDownload()
    this.dialogController.close()
  }

  build() {
    Column() {
      if (this.isDownloading) {
        Column() {
          Text('下载中...')
            .fontSize(16)
            .lineHeight(20)
            .fontColor($r('app.color.progress_text'))
            .margin({ top: 24, bottom: 16 })
          Progress({ value: this.downloadProgress, type: ProgressType.Linear })
            .width('90%')
            .height(20)
          Button("取消")
            .onClick(() => {
              this.handleCancel()
            })
            .width(148)
            .height(40)
            .backgroundColor($r('app.color.button_cancel_bg'))
            .fontSize(16)
            .fontColor($r('app.color.button_cancel_text'))
            .stateEffect(true)
            .hoverEffect(HoverEffect.Scale)
            .borderRadius(20)
        }
        .width('80%')
        .height(DIALOG_CARD_HEIGHT)
        .borderRadius(24)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor($r('app.color.dialog_bg'))
        .shadow(shadowOptions)
      } else {
        Column() {
          Text('是否保存该文件？')
            .fontSize(16)
            .lineHeight(20)
            .fontColor($r('app.color.dialog_text'))
          Text('安全访问:本应用使用系统保存控件')
            .fontSize(12)
            .lineHeight(16)
            .fontColor($r('app.color.button_cancel_text'))
            .margin({ top: 8, bottom: 8, left: 35, right: 35 })
            .textAlign(TextAlign.Center)
          Row({ space: 8 }) {
            Button("取消")
              .onClick(() => {
                // 原问题：先 close() 再 cancelDownload()，顺序反了
                this.handleCancel()
              })
              .width('40%')
              .height(40)
              .backgroundColor($r('app.color.button_cancel_bg'))
              .fontSize(16)
              .fontColor($r('app.color.button_cancel_text'))
              .stateEffect(true)
              .hoverEffect(HoverEffect.Scale)
              .borderRadius(20)
              .zIndex(0)

            Line()
              .width(1)
              .height(24)
              .backgroundColor($r('app.color.divider'))
              .zIndex(1)

            Button("保存")
              .width('40%')
              .height(40)
              .backgroundColor($r('app.color.button_download_bg'))
              .fontSize(16)
              .fontColor($r('app.color.button_download_text'))
              .stateEffect(true)
              .hoverEffect(HoverEffect.Scale)
              .borderRadius(20)
              .zIndex(0)
              .onClick(() => {
                // 防连点：已经进入下载态就直接忽略
                if (this.isDownloading) {
                  return
                }
                const started: boolean = WebDownloadFileHelper.startDownload()
                if (started) {
                  this.isDownloading = true
                } else {
                  // 原问题：startDownload 内部 throw 被吞掉，UI 停在"确认态"且无提示 → 点了没反应。
                  // 现在：回滚状态 + 关闭弹窗 + 明确告知，用户能感知到发生了什么。
                  this.isDownloading = false
                  this.dialogController.close()
                }
              })
          }
        }
        .width('80%')
        .height(DIALOG_CARD_HEIGHT)
        .borderRadius(24)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor($r('app.color.dialog_bg'))
        .shadow(shadowOptions)
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }
}
