import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { KeyboardAvoidMode, window } from '@kit.ArkUI';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
// lazy import：mihomo 链路依赖 libmihomo.so，顶层 import 会让 .so 在 Ability 创建时就被加载，
// 白白拉长首帧关键路径。这里只在 onDestroy 真正用到时才求值。
import lazy { ProxyManager } from '../mihomo/ProxyManager';
import lazy { BackgroundKeeper } from '../mihomo/BackgroundKeeper';

const DOMAIN = 0x0000;
const TAG = 'EntryAbility';
const ALLOWED_DEEP_LINK_HOSTS: string[] = ['chatgpt.com', 'auth.openai.com', 'chat.openai.com', 'ab.chatgpt.com'];
// 状态栏兜底高度（px）。仅在"取不到 TYPE_SYSTEM.topRect"时使用：全屏沉浸式下页面若拿到 0，
// Web 顶栏就会钻到系统状态栏底下与时间/电量图标重叠。常见手机状态栏约 32~40vp，
// 取 38vp 量级（密度 3~3.5 时约 114~133px）宁多勿少：多出的部分只是页面顶部留白，
// 少掉的部分则是"内容被状态栏压住"。
const FALLBACK_STATUS_BAR_PX: number = 126;

export default class EntryAbility extends UIAbility {
  private mainWindow: window.Window | null = null;
  // 监听回调保存为具名成员：window.off 只有在传入同一个函数引用时才能精确注销，
  // 否则重复进入 UIAbility 时监听器会不断累积（长时间使用后越来越卡的主因之一）。
  private onAvoidAreaChangeCallback: ((data: window.AvoidAreaOptions) => void) | null = null;
  private onWindowSizeChangeCallback: ((size: window.Size) => void) | null = null;
  // AppStorage 里已发布的像素值，用于“值没变就不写”，避免无谓的 AppStorage 通知扩散
  private publishedTop: number = -1;
  private publishedBottom: number = -1;
  private publishedWidth: number = -1;
  private publishedHeight: number = -1;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      this.logError('setColorMode exception', err);
    }
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onCreate');

    // Web 引擎预热与 BFCache 已前移到 MyAbilityStage.onCreate（更早，且不占 UIAbility 关键路径）
    AppStorage.setOrCreate('abilityWant', want);

    // 冷启动深链：解析出允许域名的 https 链接时写入 AppStorage，供 Index 页读取
    let coldStartUrl: string = this.extractUrlFromWant(want);
    if (coldStartUrl.length > 0) {
      AppStorage.setOrCreate('coldStartUrl', coldStartUrl);
      hilog.info(DOMAIN, TAG, 'cold start deep link: %{public}s', coldStartUrl);
    }
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onNewWant');
    // 热启动深链：Index 页通过 @StorageLink+@Watch 感知 coldStartUrl 变化
    let deepLinkUrl: string = this.extractUrlFromWant(want);
    if (deepLinkUrl.length > 0) {
      AppStorage.setOrCreate('coldStartUrl', deepLinkUrl);
      hilog.info(DOMAIN, TAG, 'warm start deep link: %{public}s', deepLinkUrl);
    }
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onDestroy');
    // onWindowStageDestroy 不一定先于 onDestroy 到达，这里兜底注销，确保监听器不随 UIAbility 回收残留
    this.detachWindowListeners();
    // 应用被真正销毁（不是切后台）时停内核并释放长时任务：
    // 切后台走的是 onBackground → BackgroundKeeper.acquire，不会到这里。
    // shutdown() 不改写"开启意愿"，下次启动仍会自动恢复代理。
    try {
      ProxyManager.shutdown();
    } catch (err) {
      this.logError('ProxyManager.shutdown exception', err);
    }
    BackgroundKeeper.release(this.context).catch((err: Object) => {
      hilog.warn(DOMAIN, TAG, 'release background task failed: %{public}s', JSON.stringify(err));
    });
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onWindowStageCreate');

    // === 关键顺序：先同步拿主窗口并发布首帧所需的 AppStorage 状态，再 loadContent ===
    // loadContent 的回调代表页面已经构建完成（aboutToAppear 早已执行），
    // 旧实现在回调里才第一次写 insets.top / sys.isDark，导致页面首帧读不到值：
    // 顶部内容被状态栏压住（深链/沉浸式下表现为“先重合、再跳一下”），深色模式首帧闪白。
    let windowClass: window.Window | null = null;
    try {
      windowClass = windowStage.getMainWindowSync();
    } catch (err) {
      this.logError('getMainWindowSync exception', err);
    }

    if (windowClass !== null) {
      this.mainWindow = windowClass;
      // 纯读取、不产生同步 IPC 的部分（尺寸 / 深浅色 / 安全区）在 loadContent 之前完成；
      // 写系统栏样式等会同步 IPC 的部分延后到 loadContent 回调里，避免拉长首帧关键路径。
      this.publishWindowSize(windowClass);
      this.publishDarkMode();
      this.publishAvoidAreaInsets(windowClass);
      this.subscribeWindowListeners(windowClass);
      this.applyImmersiveLayout(windowClass);
      // 窗口装饰（标题栏）必须在首帧之前关掉：
      // 它由系统绘制在状态栏那一行，与状态栏图标重叠；如果等到 loadContent 回调再关，
      // 用户会先看到一帧"应用名 + 页面标题 + 时间电量"叠在一起的画面。
      this.applyWindowDecoration(windowClass);
    }

    windowStage.loadContent('pages/Index', (err: BusinessError) => {
      if (err && err.code) {
        hilog.error(DOMAIN, TAG, 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, 'Succeeded in loading the content.');
      if (windowClass === null) {
        return;
      }
      // 页面已加载：系统栏样式这类较重的同步 IPC 放在这里，不占首帧关键路径
      this.applyChromeAfterContent(windowClass);
    });
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onConfigurationUpdate');
    let isDark: boolean = newConfig.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    let previousIsDark: boolean | undefined = AppStorage.get<boolean>('sys.isDark');
    // 先写状态：窗口即便还没创建，页面重建时也能读到正确主题（不丢状态）
    if (previousIsDark !== isDark) {
      AppStorage.setOrCreate('sys.isDark', isDark);
    }
    // 只有深浅色真的变化时才做窗口侧同步 IPC
    if (previousIsDark === isDark) {
      return;
    }
    let win: window.Window | null = this.mainWindow;
    if (win === null) {
      return;
    }
    this.applyWindowBackground(win, isDark);
    this.applySystemBarStyle(win, isDark);
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onWindowStageDestroy');
    // 注销全部窗口监听，避免重复进入时监听器累积
    this.detachWindowListeners();
    this.mainWindow = null;
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onBackground');
  }

  // 解析 want 中的深链 URL，仅接受允许域名列表内的 https 链接
  private extractUrlFromWant(want: Want): string {
    let uri: string = want.uri ?? '';
    if (uri.length === 0 || !uri.startsWith('https://')) {
      return '';
    }
    let rest: string = uri.substring('https://'.length);
    let host: string = rest;
    let slashIndex: number = rest.indexOf('/');
    if (slashIndex >= 0) {
      host = rest.substring(0, slashIndex);
    }
    let atIndex: number = host.lastIndexOf('@');
    if (atIndex >= 0) {
      host = host.substring(atIndex + 1);
    }
    let colonIndex: number = host.indexOf(':');
    if (colonIndex >= 0) {
      host = host.substring(0, colonIndex);
    }
    if (ALLOWED_DEEP_LINK_HOSTS.includes(host.toLowerCase())) {
      return uri;
    }
    return '';
  }

  // ==================== 首帧前（loadContent 之前）发布的 AppStorage 契约 ====================
  // 单位契约：'insets.top' / 'insets.bottom' / 'win.widthPx' / 'win.heightPx' 全部是物理像素 px（Index 侧用 px2vp 换算）

  // 窗口宽高（px）。窗口宽高决定 Index 侧 UA（移动/桌面）判定，必须首帧前进 AppStorage
  private publishWindowSize(windowClass: window.Window): void {
    try {
      let rect: window.Rect = windowClass.getWindowProperties().windowRect;
      this.writeSize(rect.width, rect.height);
    } catch (err) {
      this.logError('getWindowProperties exception', err);
    }
  }

  // 深浅色。Index 页 aboutToAppear 里用它决定 Web 底色（深色启动白闪的根因就是这里写晚了）
  private publishDarkMode(): void {
    let isDark: boolean = this.resolveIsDarkMode();
    let previous: boolean | undefined = AppStorage.get<boolean>('sys.isDark');
    if (previous !== isDark) {
      AppStorage.setOrCreate('sys.isDark', isDark);
    }
  }

  // 安全区 insets（px）。关心两个值：
  // - 顶部(TYPE_SYSTEM.topRect)：状态栏高度，页面据此让位，避免网页顶栏与系统状态栏重叠；
  // - 底部(TYPE_NAVIGATION_INDICATOR / TYPE_SYSTEM.bottomRect)：作为兜底写入，页面当前只避让顶部。
  // 关键：顶部必须"永远写一个大于 0 的值"。部分设备在窗口还没完成布局、旋转过程中、
  // 或手持姿态下 topRect 会返回 0；这种情况下直接写 0，页面就会整块钻到状态栏下面（重叠）。
  // 因此 0 视为"暂时取不到"，改用上一次的有效值，再退回固定兜底高度；只有拿到真实值才覆盖。
  private publishAvoidAreaInsets(windowClass: window.Window): void {
    try {
      let systemArea: window.AvoidArea = windowClass.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      let top: number = systemArea.topRect.height;
      this.writeTopInset(top);
      let bottom: number = systemArea.bottomRect.height;
      if (bottom > 0) {
        this.writeBottomInset(bottom);
      }
    } catch (err) {
      this.logError('getWindowAvoidArea TYPE_SYSTEM exception', err);
      // 读取异常时也要保证页面有一个可用的顶部安全区（否则就是状态栏重叠）
      this.writeTopInset(FALLBACK_STATUS_BAR_PX);
    }
    try {
      let indicatorArea: window.AvoidArea =
        windowClass.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      let bottom: number = indicatorArea.bottomRect.height;
      if (bottom > 0) {
        this.writeBottomInset(bottom);
      }
    } catch (err) {
      this.logError('getWindowAvoidArea TYPE_NAVIGATION_INDICATOR exception', err);
    }
  }

  // 顶部安全区统一入口：px <= 0 表示"暂时取不到"，用固定兜底值顶上；真实值到达后覆盖。
  // 值没变就不写 AppStorage，避免通知扩散到页面。
  private writeTopInset(px: number): void {
    let top: number = px > 0 ? px : FALLBACK_STATUS_BAR_PX;
    if (top === this.publishedTop) {
      return;
    }
    this.publishedTop = top;
    AppStorage.setOrCreate('insets.top', top);
  }

  private writeBottomInset(px: number): void {
    if (px === this.publishedBottom) {
      return;
    }
    this.publishedBottom = px;
    AppStorage.setOrCreate('insets.bottom', px);
  }

  // 值没变就不写，避免 AppStorage 通知扩散到所有 @StorageProp 订阅者
  private writeSize(width: number, height: number): void {
    if (width === this.publishedWidth && height === this.publishedHeight) {
      return;
    }
    this.publishedWidth = width;
    this.publishedHeight = height;
    AppStorage.setOrCreate('win.widthPx', width);
    AppStorage.setOrCreate('win.heightPx', height);
  }

  // ==================== 监听器：具名回调 + 精确注销 ====================

  private subscribeWindowListeners(windowClass: window.Window): void {
    // 先注销旧监听，保证重复进入时不重复订阅
    this.detachWindowListeners();

    let avoidAreaCb: (data: window.AvoidAreaOptions) => void = (data: window.AvoidAreaOptions): void => {
      // 旋转/分屏/折叠态变化时也会上报，此时 topRect 可能短暂为 0；统一走 writeXxxInset，
      // 由它们把 0 解释为"暂时取不到"并保留上一次的有效值，页面不会突然失去顶部避让。
      if (data.type === window.AvoidAreaType.TYPE_SYSTEM) {
        this.writeTopInset(data.area.topRect.height);
        let bottom: number = data.area.bottomRect.height;
        if (bottom > 0) {
          this.writeBottomInset(bottom);
        }
      } else if (data.type === window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR) {
        let bottom: number = data.area.bottomRect.height;
        if (bottom > 0) {
          this.writeBottomInset(bottom);
        }
      }
    };
    let sizeCb: (size: window.Size) => void = (size: window.Size): void => {
      this.writeSize(size.width, size.height);
    };

    try {
      windowClass.on('avoidAreaChange', avoidAreaCb);
      this.onAvoidAreaChangeCallback = avoidAreaCb;
    } catch (err) {
      this.logError('avoidAreaChange subscribe exception', err);
    }
    try {
      windowClass.on('windowSizeChange', sizeCb);
      this.onWindowSizeChangeCallback = sizeCb;
    } catch (err) {
      this.logError('windowSizeChange subscribe exception', err);
    }
  }

  private detachWindowListeners(): void {
    let windowClass: window.Window | null = this.mainWindow;
    if (windowClass === null) {
      this.onAvoidAreaChangeCallback = null;
      this.onWindowSizeChangeCallback = null;
      return;
    }
    let avoidAreaCb: ((data: window.AvoidAreaOptions) => void) | null = this.onAvoidAreaChangeCallback;
    if (avoidAreaCb !== null) {
      try {
        windowClass.off('avoidAreaChange', avoidAreaCb);
      } catch (err) {
        this.logError('avoidAreaChange unsubscribe exception', err);
      }
      this.onAvoidAreaChangeCallback = null;
    }
    let sizeCb: ((size: window.Size) => void) | null = this.onWindowSizeChangeCallback;
    if (sizeCb !== null) {
      try {
        windowClass.off('windowSizeChange', sizeCb);
      } catch (err) {
        this.logError('windowSizeChange unsubscribe exception', err);
      }
      this.onWindowSizeChangeCallback = null;
    }
  }

  // ==================== 沉浸式布局（loadContent 之前，纯下发，不阻塞首帧） ====================

  // 沉浸式布局：让内容延伸到状态栏/导航条下，配合 Index 侧 expandSafeArea + insets 避让达到原有效果。
  // 注意：window.Window.setWindowLayoutFullScreen 在新的 SDK 中并未废弃（废弃的是 API 9 的全局
  // window.setWindowLayoutFullScreen），因此保留该调用，观感与原来一致。
  private applyImmersiveLayout(windowClass: window.Window): void {
    try {
      windowClass.setWindowLayoutFullScreen(true).catch((err: BusinessError) => {
        this.logError('setWindowLayoutFullScreen failed', err);
      });
    } catch (err) {
      this.logError('setWindowLayoutFullScreen exception', err);
    }
    this.showStatusBar(windowClass);
  }

  // 明确要求系统状态栏"显示"（顶部时间/电量/信号那一条）。
  //
  // 【背景】此前这里曾调用 setSpecificSystemBarEnabled('status', false) 去隐藏状态栏，
  // 目的是消除"网页顶栏被状态栏压住"的重叠感 —— 但那是**方向错了**：
  // 用户要保留状态栏（看时间电量），只是不希望网页内容跑到它下面去。
  // 已改回 true：状态栏正常显示，网页内容通过安全区避让让出它的高度（见 Index 的顶部安全区处理）。
  //
  // 显式传 true 而不是"删掉不调用"：如果系统或其他代码路径改过这个开关，
  // 这里主动恢复可以保证进入本应用时状态栏一定是显示的。
  //
  // 该 API 属于 SystemCapability.Window.SessionManager，部分设备（如 2in1）不生效；
  // 失败只降级为"维持系统默认（通常就是显示）"，不影响任何功能。
  private showStatusBar(windowClass: window.Window): void {
    try {
      windowClass.setSpecificSystemBarEnabled('status', true, false).catch((err: BusinessError) => {
        this.logError('show status bar failed', err);
      });
    } catch (err) {
      this.logError('show status bar exception', err);
    }
  }

  // ==================== 页面内容加载完成后再做（不占首帧关键路径） ====================

  // 标题栏装饰：隐藏系统绘制的窗口标题栏。
  //
  // 【原实现的错误假设】这里曾写着"仅 2in1（PC）需要；手机/平板调用无意义"，于是手机上直接 return。
  // 但真机实测（Pura 80 Ultra / API 26）证明这个假设是错的：
  //   截图显示状态栏那一行同时出现【应用名「北矿课业」+ 系统时间 14:32 + 页面标题「聊天」】三样东西叠在一起，
  //   其中"应用名 + 页面标题"正是系统窗口装饰（window decor）画出来的，它占据 y≈63~112 这段区域，
  //   与状态栏（y≈64~112）完全重叠 —— 这才是用户看到的"顶栏冲突/重叠"的真正来源，
  //   而不是网页内容跑到状态栏下面（UI 树已证明网页顶栏在 y=133 以下是干净的）。
  //
  // 修法：不再按设备类型跳过，所有设备都尝试隐藏窗口装饰。
  // setWindowDecorHeight 只在 2in1 有意义（其合法区间 [37,112] vp），仍按设备类型限制；
  // 两个调用都各自 try/catch —— 不支持的设备上失败只记日志，不影响启动与任何功能。
  private applyWindowDecoration(windowClass: window.Window): void {
    try {
      windowClass.setWindowDecorVisible(false);
    } catch (err) {
      this.logError('setWindowDecorVisible exception', err);
    }
    // 仅 2in1 需要且能设置装饰高度
    if (deviceInfo.deviceType !== '2in1') {
      return;
    }
    try {
      windowClass.setWindowDecorHeight(40);
    } catch (err) {
      this.logError('setWindowDecorHeight exception', err);
    }
  }

  private applyChromeAfterContent(windowClass: window.Window): void {
    let isDark: boolean = this.resolveIsDarkMode();
    this.applyWindowBackground(windowClass, isDark);
    this.applySystemBarStyle(windowClass, isDark);

    // 键盘避让：OFFSET 整体上移窗口内容，网页视口不缩放，避免 ChatGPT 输入框被二次避让顶到屏幕顶部
    try {
      windowClass.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.OFFSET);
    } catch (err) {
      this.logError('setKeyboardAvoidMode exception', err);
    }
  }

  // 窗口背景按系统深浅色设置，防止启动白闪
  private applyWindowBackground(windowClass: window.Window, isDark: boolean): void {
    try {
      windowClass.setWindowBackgroundColor(isDark ? '#000000' : '#FFFFFF');
    } catch (err) {
      this.logError('setWindowBackgroundColor exception', err);
    }
  }

  // 系统栏透明，前景色跟随深浅色。
  // 原实现用的是已废弃的 callback 重载（'setWindowSystemBarProperties' has been deprecated），
  // 改用 Promise 重载（SDK 中未标注废弃）；该 API 对 2in1 不生效，故 2in1 上跳过以避免无效 IPC 与 WARN。
  private applySystemBarStyle(windowClass: window.Window, isDark: boolean): void {
    if (deviceInfo.deviceType === '2in1') {
      return;
    }
    let barProperties: window.SystemBarProperties = {
      statusBarColor: '#00000000',
      navigationBarColor: '#00000000',
      statusBarContentColor: isDark ? '#FFFFFF' : '#000000'
    };
    try {
      windowClass.setWindowSystemBarProperties(barProperties).catch((err: BusinessError) => {
        this.logError('setWindowSystemBarProperties failed', err);
      });
    } catch (err) {
      this.logError('setWindowSystemBarProperties exception', err);
    }
  }

  // 未显式设置时跟随系统；Configuration 文档标注默认浅色，故仅 DARK 视为深色
  private resolveIsDarkMode(): boolean {
    let config: Configuration = this.context.config;
    return config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
  }

  // 统一异常处理：console 只保留该模块的 hilog 日志，避免 JSON.stringify 在循环引用错误上二次抛异常
  private logError(message: string, err: Object | BusinessError): void {
    hilog.error(DOMAIN, TAG, '%{public}s: %{public}s', message, JSON.stringify(err));
  }
}
