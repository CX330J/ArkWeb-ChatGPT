import { AbilityStage } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { webview } from '@kit.ArkWeb';

const DOMAIN = 0x0000;
const TAG = 'WebWarmup';

// 需要预连接的站点：主站 + SSO 登录域（登录后跳转最吃这一跳的握手时间）
const PRECONNECT_URLS: string[] = ['https://chatgpt.com', 'https://auth.openai.com'];

// 冷启动能碰到的最早业务时机。把内核加载与 DNS/TCP/TLS 预连接放在这里，
// 让它们与 ArkUI 首帧构建并行，而不是等页面 attach 完才开始。
//
// 官方约束核对结论：
// - initializeWebEngine：不可在子线程调用，全局只需要一次 -> 放在 AbilityStage.onCreate（主线程、早于 UIAbility）正确；
// - enableBackForwardCache：必须在 initializeWebEngine 之前设置 -> 当前顺序正确；
// - prepareForPageLoad(url, preconnect, socketPoolSize)：同步 API，无 await 语义。
//   官方另有一条建议：“请勿在同一次冷启动中调用超过 5 次，且两次调用间隔需 > 150ms”，
//   所以第二个域用 200ms 定时器延后发出 —— 早先两个域背靠背调用，间隔 0ms，违反了该约束。
//   是否“比实际加载提前 150ms 以上”由调用时机决定：AbilityStage.onCreate 远早于 UIAbility 的
//   onWindowStageCreate -> onControllerAttached -> loadUrl，因此冷启动链路天然满足。
export default class MyAbilityStage extends AbilityStage {
  onCreate(): void {
    let startMs: number = Date.now();
    try {
      let features: webview.BackForwardCacheSupportedFeatures = new webview.BackForwardCacheSupportedFeatures();
      features.nativeEmbed = true;
      features.mediaTakeOver = true;
      webview.WebviewController.enableBackForwardCache(features);
      webview.WebviewController.initializeWebEngine();
      // CDP 调试端口保持关闭（默认）。
      // 它会让同机任意进程读取网页的全部内容与登录态（Cookie/Storage），
      // 正式包绝不能开。排障时临时改成 true 即可，不要提交。
      webview.WebviewController.setWebDebuggingAccess(false);
      let initDoneMs: number = Date.now();
      // 第一个域立即预连接（此时离 loadUrl 还远）。
      let preconnected: number = MyAbilityStage.preconnect(PRECONNECT_URLS[0]);
      // 其余域按 >150ms 的间隔依次延后，既满足官方约束，又不用把 onCreate 拖住。
      for (let i = 1; i < PRECONNECT_URLS.length; i++) {
        const url: string = PRECONNECT_URLS[i];
        setTimeout(() => {
          MyAbilityStage.preconnect(url);
        }, 200 * i);
      }
      let endMs: number = Date.now();
      hilog.info(DOMAIN, TAG, 'web engine warmed, preconnect issued for %{public}d hosts', preconnected);
      // 性能埋点：hilog 自带毫秒时间戳，PERF 序列即可还原冷启动时间线（initDone 为内核初始化耗时，
      // total 为内核初始化 + 首个预连接下发耗时；这两段与 ArkUI 首帧并行，不阻塞页面）
      console.info('PERF warmup | init=' + (initDoneMs - startMs) + 'ms total=' + (endMs - startMs) +
        'ms preconnect=' + preconnected);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'web warmup exception: %{public}s', JSON.stringify(err));
      console.info('PERF warmup | failed total=' + (Date.now() - startMs) + 'ms');
    }
  }

  /** 单个域预连接；失败只记日志，预连接本身只是优化。 */
  private static preconnect(url: string): number {
    try {
      webview.WebviewController.prepareForPageLoad(url, true, 6);
      return 1;
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'prepareForPageLoad failed for %{public}s: %{public}s',
        url, JSON.stringify(err));
      return 0;
    }
  }
}
