import { webview } from '@kit.ArkWeb'
import { BusinessError } from '@kit.BasicServicesKit'
import { fileIo, picker } from '@kit.CoreFileKit'

const TAG = 'WebDownloadFileHelper'

/** 流式拷贝分块大小：1MB。大文件不再一次性 new ArrayBuffer(stat.size) */
const COPY_CHUNK_SIZE: number = 1024 * 1024

/** 启动路径到 cacheDir 的固定子目录 */
const DOWNLOAD_TEMP_SUBDIR: string = 'web_download'

/** 用户取消保存对应的错误码（对齐 FilePicker 的 13900042），供上层区分"取消"与"真失败" */
export const ERR_USER_CANCEL_SAVE: number = 13900042

/**
 * 用户取消保存的错误类型。
 * 原问题：saveFile 里 `throw new Error('文件保存失败: ' + message)` 把 BusinessError.code 丢掉，
 *   上层无法区分"用户点了取消"与"写盘失败"，取消也会被当成失败弹 toast。
 * 修法：自定义 Error 子类并显式声明 code（ArkTS 的 arkts-limited-throw 要求 throw Error 及其子类，
 *   且不允许给 Error 实例临时挂字段）。
 */
export class UserCancelError extends Error {
  code: number = ERR_USER_CANCEL_SAVE

  constructor() {
    super('用户取消保存')
    this.name = 'UserCancelError'
  }
}

/**
 * @dec web 下载文件抽象类
 * @date 2025/3/11 20:26
 *
 * ========== 本轮修复汇总（详见各方法内注释） ==========
 * [BUG-1] generateDefaultPath 缺 '/` → 落盘路径拼成 `.../web_downloadxxx.bin`，下载必失败
 * [BUG-2] defaultDir 未 mkdir → start() 因目录不存在抛错（又被 catch 吞掉 → "点了没反应"）
 * [BUG-3] webDownloadItem 在 onDownloadFinish/Failed 前后置 null，导致 startDownload 抛
 *         DOWNLOADER_NOT_INITIALIZED；且 stop/cancel 无处可取 item
 * [BUG-4] ensureFileExtension 对无扩展名文件会拼出 `xxx.` 甚至 `xxx.xxx` 的错误后缀
 * [BUG-5] copyFileContents 一次性 new ArrayBuffer(stat.size) → 大文件 OOM / 卡死
 * [BUG-6] copyFileContents 只 read 一次（大文件截断）、fd 异常时不关闭（句柄泄漏）
 * [BUG-7] saveFile 吞掉原始错误码、且临时文件永不清理（缓存膨胀）
 * [BUG-8] 委托回调重复注册（setDownloadDelegate 被多次调用时监听翻倍）
 */
export abstract class IAbstractDownloadHandler {
  public webDownloadDelegate: webview.WebDownloadDelegate = new webview.WebDownloadDelegate()
  /**
   * 当前下载项。
   *
   * 原问题：onDownloadFinish / onDownloadFailed 里立刻 `this.webDownloadItem = null`，
   *   而清理顺序又依赖 item.getFullPath() —— 一旦置空，saveFile 还在跑就已经拿不到路径；
   *   更关键的是"取消"按钮（DownloadConfirmDialog 的 cancelDownload）在 start 之前点，
   *   或清理后再点，直接抛 DOWNLOADER_NOT_INITIALIZED → 点了没反应。
   * 修法：只在真正进入空闲态（cleanupDownloadSession）时置空，并且清理延后到保存结束之后。
   */
  protected webDownloadItem: webview.WebDownloadItem | null = null
  protected downloadProgress: number = 0
  protected controller: webview.WebviewController | null = null
  protected isCustomPath: boolean = false
  /** 回调是否已注册，避免 setDownloadDelegate 重复调用时监听翻倍 */
  private callbacksBound: boolean = false
  /** 下载项的 guid → 防止旧 item 的事件串到新 item 上（多标签/连续下载） */
  protected currentGuid: string = ''

  /**
   * 设置下载委托
   *
   * 原问题：Index.ets 的 ensureDownloadDelegate() 在每次 onControllerAttached 都调用，
   *   setDownloadDelegate 每次都跑一遍 setupDelegateCallbacks，同一个 delegate 上
   *   监听器被重复注册 → 一次下载触发 N 次回调（N=重建次数），N 次 toast、N 次弹窗开关。
   * 修法：callbacksBound 幂等守卫。
   */
  setDownloadDelegate(controller: webview.WebviewController, delegate?: webview.WebDownloadDelegate): void {
    if (delegate) {
      this.webDownloadDelegate = delegate
    }
    try {
      this.controller = controller
      this.controller.setDownloadDelegate(this.webDownloadDelegate)
      if (!this.callbacksBound) {
        this.setupDelegateCallbacks(this.webDownloadDelegate)
        this.callbacksBound = true
      }
    } catch (error) {
      this.handleError(error as BusinessError)
    }
  }

  /**
   * 是否处于「等待用户确认」状态：onBeforeDownload 已到达但尚未 start()
   */
  hasPendingItem(): boolean {
    return this.webDownloadItem !== null
  }

  /**
   * 启动文件下载
   * @param customPath 自定义存储路径（需包含文件名）
   * @returns true=已发起下载；false=没有待下载项（调用方据此给出提示，而不是静默失败）
   *
   * 原问题：没有待下载项时 `throw new Error(...)`，而唯一调用方
   *   DownloadConfirmDialog 的 onClick 并不 try/catch，异常被框架吞掉 →
   *   用户点"保存"后界面无任何变化（"点了没反应"）。
   * 修法：改为返回 boolean；目录创建、路径校验、start 失败统一走 handleError 并返回 false。
   */
  startDownload(customPath?: string): boolean {
    if (!this.webDownloadItem) {
      console.warn(`${TAG} startDownload: 没有待下载项（onBeforeDownload 尚未到达或已结束）`)
      return false
    }
    try {
      const effectivePath: string = this.validatePath(customPath)
      // 顺序很重要：先建目录，再交给内核写文件
      this.prepareDirectory(effectivePath)
      this.webDownloadItem.start(effectivePath)
      this.downloadProgress = 0
      this.isCustomPath = !!customPath
      return true
    } catch (error) {
      this.handleError(error as BusinessError)
      return false
    }
  }

  /**
   * 取消当前下载（供弹窗"取消"按钮调用）
   * @returns true=确实取消了一个进行中的下载
   *
   * 原问题：取消只做 `item.cancel()` + 清理，临时文件与监听状态全留在内存/磁盘上，
   *   连续取消几次后 cacheDir/web_download 里全是半截文件。
   */
  cancelCurrentDownload(): boolean {
    const item: webview.WebDownloadItem | null = this.webDownloadItem
    if (!item) {
      return false
    }
    let cancelled: boolean = false
    try {
      item.cancel()
      cancelled = true
    } catch (error) {
      console.error(`${TAG} cancel 异常: ${JSON.stringify(error)}`)
    }
    const tempPath: string = this.safeGetFullPath(item)
    this.cleanupDownloadSession()
    // 取消后立刻删掉临时半截文件，避免缓存膨胀
    if (tempPath !== '') {
      this.deleteQuietly(tempPath)
    }
    return cancelled
  }

  /**
   * 准备存储目录
   *
   * 原问题：`fileIo.mkdirSync(dirPath)` 只建一级；cacheDir/web_download 在
   *   cacheDir 已存在的前提下能成功，但只要父目录缺失或并发创建就会抛
   *   "No such file or directory" —— 且这个异常被上层 catch 吞掉，"下载没反应"。
   * 修法：改用递归 mkdir(recursion=true)，并对已存在（EEXIST）静默放行。
   */
  prepareDirectory(fullPath: string): void {
    const sepIndex: number = fullPath.lastIndexOf('/')
    if (sepIndex <= 0) {
      return // 没有目录部分，无需创建
    }
    const dirPath: string = fullPath.substring(0, sepIndex)
    if (this.checkPathExists(dirPath)) {
      return
    }
    try {
      fileIo.mkdirSync(dirPath, true)
    } catch (error) {
      const be: BusinessError = error as BusinessError
      // 13900015 = File exists：并发/重复创建，属正常
      if (be.code !== 13900015) {
        throw error as Error
      }
    }
  }

  /** 抽象方法 - 处理下载开始 */
  protected abstract handleDownloadStart(): void

  /** 抽象方法 - 更新进度 */
  protected abstract handleProgressUpdate(progress: number): void

  /** 抽象方法 - 处理下载成功 */
  protected abstract handleDownloadSuccess(): void

  /** 抽象方法 - 处理下载失败 */
  protected abstract handleDownloadFailure(message: string): void

  /**
   * 通用文件保存方法（DocumentViewPicker 另存为）
   *
   * 原问题：
   *  1) `throw new Error('文件保存失败: ' + message)` 把 BusinessError.code 丢了，
   *     上层无法区分"用户手动取消选择器(13900042)"与"真的写失败"，于是取消也被当失败弹 toast；
   *  2) 用户取消选择器（返回空数组）时 documentSaveResult[0] 为 undefined，写文件直接崩；
   *  3) 临时文件下载完不做清理，cacheDir/web_download 无限增长。
   * 修法：保留原始 code、显式处理空结果、finally 里清理临时文件、异常时抛带 code 的 Error。
   */
  protected async saveFile(filePath: string): Promise<void> {
    const context = getContext()
    const fileName = this.extractFileName(filePath)
    const saveOptions = new picker.DocumentSaveOptions()
    saveOptions.newFileNames = [fileName]

    try {
      const documentSaveResult: Array<string> = await new picker.DocumentViewPicker(context).save(saveOptions)
      if (!documentSaveResult || documentSaveResult.length === 0 || !documentSaveResult[0]) {
        // 用户点返回取消了选择器。
        // 原问题：原实现会继续执行 copyFileContents(undefined) → 直接崩。
        // ArkTS 限制（arkts-limited-throw）：throw 只接受 Error 及其子类，不能 throw BusinessError 对象。
        // 这里抛一个带自定义 code 字段的引用列上的 UserCancelError（继承 Error，code 在类体里显式声明）。
        throw new UserCancelError()
      }
      await this.copyFileContents(filePath, documentSaveResult[0])
    } finally {
      // 无论保存成功、失败还是取消，临时文件都已无用：不清理会持续占用 cacheDir
      this.deleteQuietly(filePath)
    }
  }

  /**
   * 错误处理
   *
   * 原问题：任何错误都直接 cleanupDownloadSession()，包括 picker 被用户取消这种
   *   "非错误"，导致下载项被提前清空、后续 cancel 点不动。
   * 修法：只记录，清理交给调用方按语义决定。
   */
  protected handleError(error: BusinessError): void {
    console.error(`${TAG} ErrorCode: ${error?.code}, Message: ${error?.message}`)
  }

  /**
   * 清理下载会话
   *
   * 原问题（任务点 10）：只把内存引用置空，**从不删除** cacheDir/web_download 下的临时文件。
   *   每次下载（成功后由 saveFile 另存、失败后什么也不做）都会在缓存目录留一份完整副本，
   *   长时间使用后 cacheDir 膨胀到几百 MB，系统清缓存时还会连带把 Web 的数据清掉 → 越用越卡。
   * 修法：置空引用 + reset 进度 + 异步清理临时目录下本次残留文件。
   */
  protected cleanupDownloadSession(): void {
    this.webDownloadItem = null
    this.downloadProgress = 0
    this.currentGuid = ''
    this.isCustomPath = false
    this.purgeTempFiles()
  }

  /**
   * 清理下载临时目录内的残留文件（任务点 10）
   * 只删 web_download 子目录下的文件，不碰 cacheDir 其它内容；异步执行，不阻塞 UI 线程。
   */
  private purgeTempFiles(): void {
    try {
      const dir: string = `${getContext().cacheDir}/${DOWNLOAD_TEMP_SUBDIR}`
      if (!this.checkPathExists(dir)) {
        return
      }
      // listFile 不带 options 时只列出本层文件（不含子目录递归），正好符合"清空临时目录"的语义。
      // 注意：ListFileOptions 是 @ohos.file.fs 的顶层导出，不在 fileIo 命名空间内，
      // 这里用无参重载即可，避免额外的类型导入。
      fileIo.listFile(dir).then((files: Array<string>) => {
        if (!files) {
          return
        }
        for (let i = 0; i < files.length; i++) {
          // listFile 在 recursion:false 时只返回文件名（非全路径），必须拼回目录
          const name: string = files[i]
          const full: string = name.indexOf('/') >= 0 ? name : `${dir}/${name}`
          this.deleteQuietly(full)
        }
      }).catch((err: BusinessError) => {
        console.warn(`${TAG} listFile 失败: ${err?.code}`)
      })
    } catch (error) {
      console.error(`${TAG} purgeTempFiles 异常: ${JSON.stringify(error)}`)
    }
  }

  /**
   * 路径验证与处理
   */
  private validatePath(customPath?: string): string {
    if (customPath && customPath.length > 0) {
      return this.ensureFileExtension(customPath)
    }
    return this.generateDefaultPath()
  }

  /**
   * 生成默认下载路径
   *
   * 原问题（任务点 1）：`return ${defaultDir}${fileName}`
   *   → 得到 `/data/.../cache/web_downloadreport.pdf`，少了分隔符 '/'，
   *     内核 start() 时父目录 `/data/.../cache` 下找不到 `web_downloadreport.pdf` 的目录，
   *     直接报错 → 下载永远是 0%（"点了没反应 / 下载失败"）。
   * 修法：`${defaultDir}/${fileName}`；同时 prepareDirectory 会递归创建 defaultDir。
   */
  private generateDefaultPath(): string {
    const defaultDir = `${getContext().cacheDir}/${DOWNLOAD_TEMP_SUBDIR}`
    const fileName = this.sanitizeFileName(this.webDownloadItem?.getSuggestedFileName() ?? '')
      || `download_${Date.now()}.bin`
    return `${defaultDir}/${fileName}`
  }

  /**
   * 确保文件扩展名正确
   *
   * 原问题（任务点 3 关联）：原实现
   *   expectedExt = suggestedName.split('.').pop()   // 无扩展名时返回整个文件名
   *   currentExt  = path.split('.').pop()
   *   → 用户选 "report" 保存 report.pdf 时：currentExt='report' != expectedExt='pdf' →
   *     拼成 report.pdfpdf；suggestedName 无点（如 LICENSE）时 → 拼成 path.`LICENSE`
   *     （多出整整一个文件名当后缀）。
   * 修法：suggestedName 必须真含 '.' 才取后缀；path 已以该后缀结尾则不追加。
   */
  private ensureFileExtension(path: string): string {
    const suggestedName = this.webDownloadItem?.getSuggestedFileName() ?? ''
    const dotIndex: number = suggestedName.lastIndexOf('.')
    if (dotIndex <= 0 || dotIndex === suggestedName.length - 1) {
      return path // 建议名没有有效扩展名，保持用户选择不变
    }
    const expectedExt: string = suggestedName.substring(dotIndex + 1).toLowerCase()
    const lowerPath: string = path.toLowerCase()
    if (lowerPath.endsWith(`.${expectedExt}`)) {
      return path
    }
    return `${path}.${expectedExt}`
  }

  /** 路径存在性检查 */
  private checkPathExists(path: string): boolean {
    try {
      return fileIo.accessSync(path)
    } catch {
      return false
    }
  }

  /**
   * 初始化委托回调
   *
   * 原问题：
   *  1) onDownloadUpdated 里过滤逻辑为零：同一 item 的多次回调、以及上一个下载项迟到的
   *     回调都会写入 this.downloadProgress（进度串台）；
   *  2) onDownloadFinish 是 async，内部 await saveFile 期间 item 已被置空，
   *     若此时用户又触发一次下载，两个 item 的事件会交叉；
   *  3) 任何回调里抛出的异常都没有兜底。
   * 修法：所有回调 try/catch + 按 guid 过滤。
   */
  private setupDelegateCallbacks(delegate: webview.WebDownloadDelegate): void {
    delegate.onBeforeDownload((item: webview.WebDownloadItem) => {
      try {
        this.webDownloadItem = item
        this.currentGuid = this.safeGetGuid(item)
        this.downloadProgress = 0
        this.isCustomPath = false
        this.handleDownloadStart()
      } catch (error) {
        console.error(`${TAG} onBeforeDownload 异常: ${JSON.stringify(error)}`)
      }
    })

    delegate.onDownloadUpdated((item: webview.WebDownloadItem) => {
      try {
        if (!this.isCurrentItem(item)) {
          return // 非当前下载项（上一个下载的迟到回调），丢弃，避免进度串台
        }
        const percent: number = item.getPercentComplete()
        if (percent === this.downloadProgress) {
          return // 值没变就不回调，下游 @State 不会重建
        }
        this.downloadProgress = percent
        this.handleProgressUpdate(percent)
      } catch (error) {
        console.error(`${TAG} onDownloadUpdated 异常: ${JSON.stringify(error)}`)
      }
    })

    delegate.onDownloadFailed((item: webview.WebDownloadItem) => {
      try {
        if (!this.isCurrentItem(item)) {
          return
        }
        this.handleDownloadFailure('文件下载失败')
      } catch (error) {
        console.error(`${TAG} onDownloadFailed 异常: ${JSON.stringify(error)}`)
      }
    })

    delegate.onDownloadFinish(async (item: webview.WebDownloadItem) => {
      try {
        if (!this.isCurrentItem(item)) {
          return
        }
        const filePath = item.getFullPath()
        // 仅非自定义路径需要另存操作（自定义路径是用户直接指定的目标文件）
        if (!this.isCustomPath) {
          await this.saveFile(filePath)
        }
        this.handleDownloadSuccess()
      } catch (error) {
        // 用户在选择器里取消保存：属于正常操作，不该弹"失败"
        if (error instanceof UserCancelError) {
          this.handleDownloadFailure('已取消保存')
        } else {
          console.error(`${TAG} onDownloadFinish 保存失败: ${JSON.stringify(error)}`)
          this.handleDownloadFailure(this.isCustomPath ? '文件下载失败' : '文件保存失败')
        }
      }
    })
  }

  /** 取 guid，异常时返回空串（不抛出，避免打断内核回调链） */
  private safeGetGuid(item: webview.WebDownloadItem): string {
    try {
      return item.getGuid()
    } catch {
      return ''
    }
  }

  /** 取完整落盘路径，异常时返回空串 */
  private safeGetFullPath(item: webview.WebDownloadItem): string {
    try {
      const p: string = item.getFullPath()
      return p ?? ''
    } catch {
      return ''
    }
  }

  /** 回调是否属于当前下载项 */
  private isCurrentItem(item: webview.WebDownloadItem): boolean {
    if (this.webDownloadItem === null) {
      return true // 已被清理，交给后续逻辑兜底
    }
    if (this.currentGuid === '') {
      return true
    }
    const guid: string = this.safeGetGuid(item)
    return guid === '' || guid === this.currentGuid
  }

  /**
   * 提取文件名
   * 原问题：文件名里可能带 '?'、'#' 或已编码字符，直接当落盘名会生成非法路径。
   */
  private extractFileName(path: string): string {
    const match = path.match(/[^\\/]+$/)
    const raw: string = match ? match[0] : `file_${Date.now()}`
    return decodeURIComponent(raw)
  }

  /**
   * 文件名净化：去掉路径分隔符与非法字符，防止 suggestedFileName 带 '/' 时逃逸出 temp 目录
   */
  private sanitizeFileName(name: string): string {
    if (!name) {
      return ''
    }
    const cleaned: string = name.replace(/[\\/:*?"<>|\r\n\t]/g, '_').trim()
    if (cleaned === '' || cleaned === '.' || cleaned === '..') {
      return ''
    }
    return cleaned
  }

  /** 静默删除，失败不影响主流程 */
  private deleteQuietly(path: string): void {
    if (!path) {
      return
    }
    try {
      fileIo.unlink(path).catch((err: BusinessError) => {
        console.warn(`${TAG} unlink 失败: ${path} code=${err?.code}`)
      })
    } catch (error) {
      console.warn(`${TAG} unlink 异常: ${JSON.stringify(error)}`)
    }
  }

  /**
   * 复制文件内容
   *
   * 原问题（任务点 8）：
   *   `const buffer = new ArrayBuffer(stat.size)` —— 一个 500MB 的安装包直接申请 500MB
   *   ArrayBuffer，ArkTS 侧的 JS 堆瞬间打满 → 触发 GC 停顿甚至 OOM 卡死；
   *   而且只 `read` 一次，超过单次读上限时只复制了前一段（文件不完整）。
   *
   * 修法：1MB 分块流式拷贝；read 返回值控制循环；finally 保证两个 fd 一定关闭。
   */
  private async copyFileContents(sourcePath: string, destPath: string): Promise<void> {
    let sourceFd: fileIo.File | null = null
    let destFd: fileIo.File | null = null
    try {
      sourceFd = await fileIo.open(sourcePath, fileIo.OpenMode.READ_ONLY)
      destFd = await fileIo.open(destPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC)

      let finished: boolean = false
      while (!finished) {
        const chunk: ArrayBuffer = new ArrayBuffer(COPY_CHUNK_SIZE)
        const readLen: number = await fileIo.read(sourceFd.fd, chunk)
        if (readLen <= 0) {
          finished = true
          break
        }
        // 只写实际读到的字节，避免把 buffer 尾部零字节写进目标文件
        if (readLen >= COPY_CHUNK_SIZE) {
          await fileIo.write(destFd.fd, chunk)
        } else {
          await fileIo.write(destFd.fd, chunk.slice(0, readLen))
        }
      }
    } finally {
      // 原实现异常路径下 fd 永不关闭 → 长时间使用句柄耗尽
      if (sourceFd !== null) {
        try {
          await fileIo.close(sourceFd)
        } catch (e) {
          console.warn(`${TAG} close source 失败: ${JSON.stringify(e)}`)
        }
      }
      if (destFd !== null) {
        try {
          await fileIo.close(destFd)
        } catch (e) {
          console.warn(`${TAG} close dest 失败: ${JSON.stringify(e)}`)
        }
      }
    }
  }
}
