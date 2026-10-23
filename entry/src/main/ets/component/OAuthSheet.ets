import { webview } from '@kit.ArkWeb';

/** 保留原项目的纯网页半屏预览，新窗口由宿主预先关联 controller。 */
@Component
export struct OAuthSheet {
  @Prop targetUrl: string = '';
  @Prop isDark: boolean = false;
  controller: webview.WebviewController = new webview.WebviewController();
  onSheetWebAttached: (controller: webview.WebviewController) => void = () => {};
  onSheetClosed: () => void = () => {};
  onRequestClose: () => void = () => {};
  private attached: boolean = false;

  aboutToDisappear(): void {
    if (this.attached) {
      try { this.controller.stop(); } catch (err) { console.warn('停止预览失败:', JSON.stringify(err)); }
    }
    this.attached = false;
    this.onSheetClosed();
  }

  build() {
    Column() {
      Web({ src: '', controller: this.controller })
        .javaScriptAccess(true).domStorageAccess(true).onlineImageAccess(true).imageAccess(true)
        .fileAccess(false).darkMode(WebDarkMode.Auto).mixedMode(MixedMode.Compatible)
        .backgroundColor(this.isDark ? '#171717' : '#FFFFFF')
        .onControllerAttached(() => {
          this.attached = true;
          this.onSheetWebAttached(this.controller);
        })
        .multiWindowAccess(true).allowWindowOpenMethod(true)
        .onWindowNew((event) => {
          if (!event) { return; }
          // 二级链接在当前预览打开；及时完成 handler，释放发起页面。
          event.handler.setWebController(null);
          if (/^https?:\/\//i.test(event.targetUrl)) { this.controller.loadUrl(event.targetUrl); }
        })
        .onWindowExit(() => this.onRequestClose())
        .onPermissionRequest((event: OnPermissionRequestEvent) => event.request.deny())
        .width('100%').height('100%')
    }.width('100%').height('100%')
  }
}
