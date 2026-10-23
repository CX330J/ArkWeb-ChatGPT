//这个框架是github框架的上载版本

import { webview } from '@kit.ArkWeb';
import { BusinessError, pasteboard, deviceInfo, emitter } from '@kit.BasicServicesKit';
import { window, promptAction } from '@kit.ArkUI';
import { abilityAccessCtrl, common, Permissions, Want } from '@kit.AbilityKit';
import { resourceManager } from '@kit.LocalizationKit';
import { DownloadConfirmDialog } from '../component/DownloadConfirmDialog'
import { IAbstractDownloadHandler } from '../delegate/IWebDownloadFile'
import { EmitterUtil, EmitterCallback } from '../utiles/EmitterUtil'
import { OAuthSheet } from '../component/OAuthSheet'
// Mihomo 代理内核封装（阶段 1：仅验证 Go c-shared 内核能否 dlopen）。
// 独立成模块，避免把 NAPI 相关代码混进这个已经很长的页面文件。
// 代理 UI 与状态：浮窗（贴右边缘三段式交互）+ 设置面板 + 管理器
import { ProxyFab } from '../component/ProxyFab';
import { ProxySettingsPanel } from '../component/ProxySettingsPanel';
import { ProxyManager, ProxyState, OpResult } from '../mihomo/ProxyManager';
import { AutoSelect, AutoSelectResult, ProxyHealth } from '../mihomo/AutoSelect';
import { BackgroundKeeper } from '../mihomo/BackgroundKeeper';
import { NetworkWatcher } from '../mihomo/NetworkWatcher';
import { ProxySettingsStore, ProxySettings, defaultProxySettings } from '../mihomo/ProxySettings';
import { Subscriptions } from '../mihomo/Subscriptions';
import { SubscriptionUpdater } from '../mihomo/SubscriptionUpdater';
import { CHAT_INPUT_FOCUS_JS, TOUCH_RESPONSE_CSS, HOVER_FIX_JS, PULL_REFRESH_JS } from '../component/WebInteractionScripts';
import { MEASURED_RENDER_JS, SCROLL_PERF_JS, SIDEBAR_SCROLL_CSS } from '../component/WebPerformanceScripts';
// 写 mihomo 配置文件用。**必须是普通 import，不能用 lazy**：
// lazy 导入在 aboutToAppear 阶段可能尚未求值，调用会静默失败（实测踩过）。
// 与文件后面 `import lazy { fileIo as fs }` 是两个不同的本地名，不冲突。
import { fileIo } from '@kit.CoreFileKit';
// 以下模块只在事件回调里用到：改为 lazy，把它们的求值开销移出冷启动关键路径
// （官方冷启动文档：减少启动路径上的模块数量与 import 规模）
import lazy { WebDownloadFileHelper } from '../delegate/WebDownloadFileImpl'
import lazy { http } from '@kit.NetworkKit';
import lazy { image } from '@kit.ImageKit';
import lazy { photoAccessHelper } from '@kit.MediaLibraryKit';
import lazy { cameraPicker } from '@kit.CameraKit';
import lazy { fileIo as fs, picker } from '@kit.CoreFileKit';
import lazy { call } from '@kit.TelephonyKit';


//const url = "https://web.feishu.cn"; //飞书
//const url = "https://music.163.com";  //网易云音乐
//const url = "https://www.bilibili.com";  //B站
//const url = "https://chat.deepseek.com";  //deepseek
//const url = "https://www.iconfont.cn";  //阿里巴巴矢量图库
const url = "https://chatgpt.com";
//const url = $rawfile('index (2).html')
//const url = "https://oc.sjtu.edu.cn";
//const url = "https://shuiyuan.sjtu.edu.cn";

// UA设置（修改为更精准的移动端标识）
const forceMobileUA = false;  // 强制手机UA开关设置为true
const mobileUserAgent = "Mozilla/5.0 (Linux; Android 13; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36"; // 移动端Chrome UA
const pcUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"; // PC端Chrome UA
const titleBlankHeight = 0;  //空白标题栏的高度，如果你的网页最上面一排没有按钮和需要点击的内容，可以设置为0

// 注入脚本作用的站点规则（web.d.ts:3561-3568 通配符语义）
// 规则 2 是精确匹配；规则 3 的 "https://*.x.com" 是模糊匹配，只命中 xxx.x.com 这类子域，
// **不命中裸域 x.com 本身** —— 所以 'https://chatgpt.com' 必须保留，它和 'https://*.chatgpt.com' 不重复。
// 'https://auth.openai.com' 已经落在 'https://*.openai.com' 的模糊匹配范围内，属冗余但无害；
// 保留是为了"登录域必须生效"这条语义在代码里一眼可见（规则一旦写错，整条 scriptRules 会失效）。
const SCRIPT_RULES: Array<string> = ['https://chatgpt.com', 'https://*.chatgpt.com', 'https://*.openai.com', 'https://auth.openai.com'];

// 主题上报脚本：documentStart 时上报初始深浅色，并监听系统深浅色变化。
// 三个要点：
// 1) documentStart 早于 javaScriptProxy 的注入，首次调用 window.ohosBridge 大概率还不存在 -> 失败，
//    所以首次上报必须"失败即重试"：最多 3 次、间隔 200ms，成功立刻停。重试是有限次 setTimeout，
//    不产生常驻定时器；也只在首帧后最多 600ms 内活动，不影响滚动/长会话帧率。
// 2) 拿到桥后立刻补报一次，这是"深色模式下首帧白闪 / 状态栏颜色不对"的兜底来源：
//    宿主侧 aboutToAppear 若还没拿到 sys.isDark，这里会把网页侧真实深浅色回灌给原生窗口。
// 3) 幂等守卫（同 VIEWPORT_FIX_JS / SCROLL_PERF_JS 的做法）：正常一次导航只会注入一次，
//    但如果宿主将来在"同一文档"上重复下发（例如复用 Web 组件重新 attach），
//    matchMedia 监听器会越挂越多，每次深浅色变化就多发 N 次跨线程上报。
//    加一个标记位让重复注入直接返回，代价是一次属性判断。
const THEME_JS: string = '(function(){try{'
  + 'if(window.__ohosTh){return;}window.__ohosTh=1;'
  + 'var mq=null;try{mq=window.matchMedia(\'(prefers-color-scheme: dark)\');}catch(e0){};'
  + 'var tries=0,reported=false;'
  // 上报一次；返回 true 表示桥可用、已上报成功（此后不再重试）
  + 'function push(){try{var b=window.ohosBridge;if(!b||!b.onWebTheme){return false;}b.onWebTheme(mq&&mq.matches===true);return true;}catch(e){return false;}};'
  // 兼容 SPA 重建：onWebTheme 一旦成功，之后每次变化都走 push，不再消耗重试次数
  + 'function attempt(){tries++;try{if(push()){reported=true;}}catch(e){}'
  + 'if(!reported&&tries<3){setTimeout(attempt,200);}};'
  + 'if(!push()){setTimeout(attempt,200);}else{reported=true;}'
  + 'if(mq){try{if(mq.addEventListener){mq.addEventListener(\'change\',function(){push();});}'
  + 'else if(mq.addListener){mq.addListener(function(){push();});}}catch(e1){}}'
  + '}catch(e2){}})();';

// 视口补丁：保证 viewport-fit=cover（沉浸式：网页内容可延伸到系统栏下，状态栏避让由宿主控制）
// 关键点：**不改动网页已有的 viewport content**。移动端浏览器（含 ArkWeb）对 viewport 的 HTML 属性改
// 不触发重解析，运行时改它是无效操作，只会白白多一次属性写入 + 样式重算；因此只在"完全没有 meta viewport"
// 时才新建（此时 documentStart 时机尚早，新建的 meta 还能被正常解析）。
// 原先用 querySelector("meta[name=viewport]")：属性选择器没有索引，会退化成遍历所有 meta，
// 而且 chatgpt.com 里有更早树的 meta；documentStart 跑在首帧关键路径上，改成 O(1) 的固定探测。
const VIEWPORT_FIX_JS: string = '(function(){try{'
  + 'if(window.__ohosVf){return;}window.__ohosVf=1;'
  + 'var d=document;if(!d)return;'
  + 'var m=d.querySelector(\'meta[name="viewport"]\');if(m)return;'
  + 'var h=d.head||d.documentElement;if(!h)return;'
  + 'm=d.createElement("meta");m.setAttribute("name","viewport");'
  + 'm.setAttribute("content","width=device-width, initial-scale=1.0, viewport-fit=cover");'
  + 'h.appendChild(m);}catch(e){}})();';

// 隐藏"下载 App"横幅（所有设备）——用前缀匹配 ^= 而非子串匹配 *=，浏览器可索引，避免样式重算变慢。
// 三条规则拆成 2 个独立 <style>：CSS 的规则列表是"一损俱损"的，只要有一条选择器解析失败，
// 整个列表后面的规则都会被丢弃；`i`（大小写不敏感）标志在旧内核上未必支持，拆开后即使那条坏了，
// ^= 前缀规则那条仍然生效。另外挂 onerror 自删：解析失败时 style 元素会触发 error，
// 直接把它摘掉，保证"注入失败也绝不影响网页自身的样式"。
const HIDE_DOWNLOAD_SEL_MAIN: string = '[data-testid^="download-app"]{display:none !important}';
const HIDE_DOWNLOAD_SEL_I: string = '[aria-label^="Download app" i]{display:none !important}';
// 风险低的放前、依赖 `i` 标志的放后；两个 style 各自独立解析，一个坏不影响另一个
const HIDE_DOWNLOAD_CSS_LOW_RISK: string = HIDE_DOWNLOAD_SEL_MAIN;
const HIDE_DOWNLOAD_CSS_RISKY: string = HIDE_DOWNLOAD_SEL_I;

// 通用小工具：往 head 追加一个带 id 的 <style>。
// 要点：①去重守卫（getElementById，O(1)）②onerror 自删 ③CSS 用 JSON.stringify 转义，
// 避免像旧代码那样用单引号包裹 CSS 再混进含引号的选择器，一旦不匹配就是整段注入脚本语法错误。
// 所有 <style> 注入都由这里生成，保证"同一个 IIFE + try/catch 包裹"的形态一致。
function buildStyleInjectJs(id: string, css: string): string {
  return '(function(){try{'
    + 'var d=document;if(!d)return;'
    // 去重守卫：刷新（bfcache 恢复）或 SPA 导航重复注入时直接返回，避免 <style> 越堆越多
    + 'if(d.getElementById(' + JSON.stringify(id) + ')){return;}'
    + 'var h=d.head||d.documentElement;if(!h)return;'
    + 'var s=d.createElement("style");s.setAttribute("id",' + JSON.stringify(id) + ');'
    + 's.onerror=function(){try{if(s.parentNode){s.parentNode.removeChild(s);}}catch(e0){}};'
    + 's.textContent=' + JSON.stringify(css) + ';'
    + 'h.appendChild(s);}catch(e){}})();';
}

const HIDE_DOWNLOAD_STYLE_JS: string = buildStyleInjectJs('ohos-hide-download-a', HIDE_DOWNLOAD_CSS_LOW_RISK)
  + buildStyleInjectJs('ohos-hide-download-b', HIDE_DOWNLOAD_CSS_RISKY);

// ====== 注入项（模块级常量：不再用 @State 承载，避免多一次无谓的状态更新）======
// 时机说明：宿主用的是 runJavaScriptOnDocumentStart / runJavaScriptOnDocumentEnd（API 15+），
// 这两个 API 文档明确写的是"按数组顺序执行"，所以下面的数组顺序 = 真实执行顺序，不要随意调整。
// 注意：同一次注入里"内容完全相同"的脚本会被静默去重——本文件里每个 ScriptItem 的 script
// 都互不相同（以文件内唯一常量名开头的注释区分），不要把它们拼成同一段字符串。
//
// documentStart 提前安装聚焦、触摸能力和主题补丁；此时不查询页面内容。
// 【侧栏条目触摸修正】修掉"手指落在某个条目上就滑不动"和"项目条目一按就能拖动"。
//
// 真机现象（用户实测，两阶段）：
//   ① 手指落在具体对话项上时侧栏完全不滚，手感像用鼠标拖动 -> 已修
//   ② 用户复核后补充：「项目」分组下的条目"不用点击直接可以拖动"，而「对话」项不会乱走。
//      也就是说对话项已经正常，但项目条目仍然按着就跟着手指跑，必须也只能滚动/点击。
//
// 根因（在保存下来的 ChatGPT.html 里可直接看到）：
//   侧栏所有可排序条目外层都带 dnd-kit 的 class `touch-none`：
//     <div class="after:block after:h-px after:content-[''] last:after:hidden touch-none"
//          role="listitem" aria-roledescription="sortable">
//   `.touch-none{touch-action:none}`（在 886701.b3a8fdb21c.css 里确认），语义是"这个元素上
//   所有触摸手势都不交给浏览器处理"。于是手指按在条目上时，内核拿不到垂直滚动这个动作，
//   整串触摸被交给页面的拖拽排序逻辑 -> 拖不起来也滚不动；项目条目上则直接被拖走。
//   侧栏空白处没有这个类，所以那里起手是正常的（这也解释了现象与起点强相关）。
//
//   关键差异（对比 HTML 全文 20 处 touch-none 元素，按标记分组）：
//     · 对话条目(8)  : role=listitem + data-pinned-content-tab-drop-key + touch-none
//     · 项目内对话(8): role=listitem + touch-none      <- 没有 drop-key，旧规则漏掉
//     · 项目分组行(3): role=listitem + aria-roledescription="sortable" + touch-none  <- 纯拖拽项
//     · 其它(1)     : 无 role 的容器
//   上一版规则只认 data-pinned-content-tab-drop-key，故只覆盖了对话条目；
//   项目分组行与项目内对话用的是另一套标记，所以"项目能直接拖动"没有解决。
//
// 修法：不再依赖某一个 data 属性，直接对准"带 touch-none 的条目"这个统一的拖拽容器特征，
// 用多条通用选择器做并集覆盖，并附带一条兜底规则按 class 子串匹配，避免网页改版后再次漏掉。
//   · pan-y 保留了垂直滚动 -> 手指按在条目上也能滚动列表，
//     同时单指纵向拖动不再被认作拖拽排序手势，项目条目也就不会跟着手指跑
//   · pan-y 仍然禁用了水平/缩放等其它手势 -> 不影响（也不触发）拖拽排序的横向交互
//   · 全部用 !important 压过工具类 .touch-none 的同等优先级
//   · 选择器都带 role/aria/class 特征，不会波及 .contents 内部按钮的点击
// 这是移动端 dnd-kit 的标准兼容做法（拖拽排序与页面滚动共存）。
const SIDEBAR_TOUCH_CSS: string =
  // 1) 对话条目：有 drop-key 的置顶/最近对话
  '[data-pinned-content-tab-drop-key],'
  // 2) 所有 dnd-kit 可排序条目（含项目分组行、项目内对话行）
  + '[aria-roledescription="sortable"],'
  // 3) 侧栏列表条目本身（覆盖没有 drop-key 也没有 sortable 的 listitem）
  + '[role="listitem"],'
  // 4) 任意 *-drop-key / *-drop-target 的拖放容器（项目条目可能挂其它前缀）
  + '[data-pinned-content-tab-drop-key],[class*="drop-key"],'
  + '[data-sidebar-project-kind],[data-sidebar-project-container-id],'
  + '[data-app-action-sidebar-project-row],[data-app-action-sidebar-project-id],'
  // 5) 旧的内部内容层兜底
  + '[role="listitem"]>.overflow-hidden>.contents{'
  + 'touch-action:pan-y!important;'
  + '}'
  // 6) 兜底：任何直接带 touch-none 工具类的元素（网页无论怎么改标记都覆盖得到）
  + '[class~="touch-none"]{touch-action:pan-y!important;}'
  // 7) 子串兜底：class 里含 touch-none 变体（如 xxx:touch-none）的元素
  + '[class*="touch-none"]{touch-action:pan-y!important;}';

const SIDEBAR_TOUCH_JS: string = buildStyleInjectJs('ohos-sidebar-touch', SIDEBAR_TOUCH_CSS);

const DOC_START_SCRIPTS: Array<ScriptItem> = [
  { script: CHAT_INPUT_FOCUS_JS, scriptRules: SCRIPT_RULES },
  // 0) 触摸媒体查询修正：必须在网页任何脚本之前执行，才能改掉它对 hover/指针能力的判断。
  //    放第一位是因为它只包裹 matchMedia 一个函数，不碰 DOM，开销可忽略。
  { script: HOVER_FIX_JS, scriptRules: SCRIPT_RULES },
  // 1) 主题深浅色上报（仅 matchMedia + 有限次重试，不碰 DOM）
  { script: THEME_JS, scriptRules: SCRIPT_RULES }
];

// 【documentEnd】页面解析完成、DOM 与样式表就绪后按顺序执行。
// 先补齐视口与触摸样式，再按消息和侧栏行的真实高度启用屏幕外渲染跳过。
const DOC_END_SCRIPTS: Array<ScriptItem> = [
  // 1) 视口补丁：补齐 viewport-fit=cover（O(1)，不改网页已有 content）
  { script: VIEWPORT_FIX_JS, scriptRules: SCRIPT_RULES },
  // 2) 隐藏"下载 App"横幅：两条规则各自独立 <style>，带 id 去重与 onerror 自删
  { script: HIDE_DOWNLOAD_STYLE_JS, scriptRules: SCRIPT_RULES },
  // 2.5) 侧栏对话项触摸修正：去掉拖拽排序留下的 touch-action:none，恢复垂直滚动
  { script: SIDEBAR_TOUCH_JS, scriptRules: SCRIPT_RULES },
  { script: buildStyleInjectJs('ohos-touch-response', TOUCH_RESPONSE_CSS), scriptRules: SCRIPT_RULES },
  // 2.6) 侧栏滚动链隔离：滚到边界时不再把整个页面一起拽动
  { script: buildStyleInjectJs('ohos-sidebar-scroll', SIDEBAR_SCROLL_CSS), scriptRules: SCRIPT_RULES },
  // 2.65) 长距离下拉刷新：只读触摸坐标，不拦截事件，不影响现有手势屏蔽
  { script: PULL_REFRESH_JS, scriptRules: SCRIPT_RULES },
  // 2.7) 滚动期减负：scroll 监听降级 passive + 滚动中暂停无限动画
  { script: SCROLL_PERF_JS, scriptRules: SCRIPT_RULES },
  { script: MEASURED_RENDER_JS, scriptRules: SCRIPT_RULES },
];

// UA 选择：手机/可穿戴/窄竖屏 → 移动端 UA；其余（平板、2in1 宽窗）→ PC UA。
//
// BFCache（前进/后退缓存）配置：
// size = 可缓存的页面实例数。默认 1、最大 50 —— 取 3 覆盖"最常返回的那一两跳"，
//        再多会让整个页面树（DOM/JS 堆）留很多份，是实打实的内存。
// timeToLive = 缓存存活秒数，默认 600。保持默认值即可。
const BF_CACHE_SIZE: number = 3;
const BF_CACHE_TTL_SECONDS: number = 600;

// 状态栏兜底高度（vp）：只在读不到 insets.top 时使用。
// 常见手机状态栏约 32~40vp，取 40 是"宁可多让一点"的安全侧：
// 多让只有顶部少量留白，少让则会让网页顶栏压住时间/电量（真机上已经出现过）。
const FALLBACK_STATUS_BAR_VP: number = 40;

// SSO 登录域：首屏稳定后预取它（用户点"用 Google/Microsoft 登录"时会跳到该域）。
// 这是 prefetchPage 的正确用法——预取"稍后才打开"的页面，而不是马上要加载的当前页。
const AUTH_ORIGIN: string = 'https://auth.openai.com';
// 主站 origin：回到前台时预连接用（与 AbilityStage 冷启动预连接的目标保持一致）。
const HOME_ORIGIN: string = 'https://chatgpt.com';

// 同步实现：冷启动路径上不再依赖 window.getLastWindow 的异步回调。
// 设备类型缓存：'' 表示尚未取值（首次取值后不再重复读系统属性）。
// 必须声明在 resolveUserAgent 之前：虽然函数声明会提升、运行期不会真的出错，
// 但"读一个定义在后面的变量"极易再次写回上一版那种"忘了走缓存函数"的缺陷，顺序摆正更安全。
let cachedDeviceType: string = '';

function getDeviceTypeCached(): string {
  if (cachedDeviceType.length === 0) {
    try {
      cachedDeviceType = deviceInfo.deviceType;
    } catch (err) {
      cachedDeviceType = 'default';
    }
  }
  return cachedDeviceType;
}

function resolveUserAgent(widthPx: number, landscape: boolean): string {
  // deviceInfo.deviceType 是系统属性读取，放在冷启动路径上每次问一次不划算：模块级缓存一次即可。
  // 【曾有缺陷】这里原先直接读 cachedDeviceType，而它是空串初值、只有 getDeviceTypeCached() 才会填充，
  // 但 getDeviceTypeCached() 从来没有被任何地方调用 —— 结果 deviceType 恒为 ''，
  // 手机上的 "deviceType === 'phone'" 判断永远是 false，只能靠 isSmallScreen(宽度<600px) 兜底。
  // 对 600px 以上的手机 / 折叠屏展开态，就会误判成 PC UA → 加载桌面版页面：
  // DOM 与 JS 工作量都远大于移动版，是最直接的"打开慢、滑动卡"来源之一。
  // 现在改为走缓存函数，确保首次真的读到 system 值。
  const deviceType: string = getDeviceTypeCached();
  const isSmallScreen: boolean = !landscape && widthPx > 0 && widthPx < 600;
  return (forceMobileUA || deviceType === 'phone' || deviceType === 'wearable' || isSmallScreen)
    ? mobileUserAgent : pcUserAgent;
}

// ====== URL scheme 前缀表：onLoadIntercept 每次导航都会调用，用最短匹配表替代一长串 indexOf 链 ======
// 命中即返回 true（表示"已被外部应用处理，拦截本次导航"），未命中返回 false（正常加载）。
const SCHEME_MAILTO: string = 'mailto:';
const SCHEME_TEL: string = 'tel:';
const SCHEME_SMS: string = 'sms:';
const SCHEME_WEIXIN: string = 'weixin://';
const SCHEME_QQ_LOGIN: string = 'https://xui.ptlogin2.qq.com/';

// 用首字母做一层预判：ChatGPT 的绝大多数导航都以 h(H)、r、b 等开头，直接在第一步就被挡掉，
// 不再对每个 URL 逐条跑 6 次 indexOf（每次 indexOf 命中失败都要扫一遍字符串）。
function mayBeExternalScheme(requestUrl: string): boolean {
  if (requestUrl.length < 5) {
    return false;
  }
  const first: string = requestUrl.charAt(0);
  return first === 'm' || first === 't' || first === 's' || first === 'w' || first === 'h';
}

// 冷启动首帧底色兜底：EntryAbility 若因异常没写入 'sys.isDark'，深色模式下会先画一帧白色（启动白闪）。
// 链路：AppStorage('sys.isDark') → resourceManager 当前配置的 colorMode → 白色。
// 注意：Context 基类上没有 config 字段、ApplicationContext 也没有 getConfigurationSync()；
// resourceManager.getConfigurationSync() 是唯一"同步取当前配置、不在首帧挂异步"的可靠兜底。
function resolveColdStartDark(): boolean {
  try {
    const stored: boolean | undefined = AppStorage.get<boolean>('sys.isDark');
    if (stored !== undefined) {
      return stored === true;
    }
    const ctx = getContext();
    if (ctx !== undefined && ctx !== null) {
      const rmCfg: resourceManager.Configuration = ctx.resourceManager.getConfigurationSync();
      return rmCfg.colorMode === resourceManager.ColorMode.DARK;
    }
  } catch (err) {
    // 兜底链路全部失败时按浅色处理，与旧行为一致
  }
  return false;
}

// 原生桥接对象：供网页 JS 调用（window.ohosBridge.xxx）
class OhosBridge {
  private appContext: common.UIAbilityContext | undefined = undefined;
  private lastIsDark: boolean = false;
  private applied: boolean = false;
  /**
   * 下拉刷新的回调，由页面在构造后注入。
   *
   * 为什么不在这里直接持有 controller：
   *   桥对象在 controller 挂载前就创建了（构造早于 Web 组件），直接存 controller 会拿到
   *   一个还没 attach 的实例；而且刷新要避开"页面不可见/正在加载"等状态，这些判断都在页面里。
   */
  onPullRefreshRequest: () => void = () => {};
  // 主窗口实例缓存：页面生命周期内窗口对象不会变，拿到一次就够。
  // 原实现每次深浅色切换都重新 window.getLastWindow(ctx)，而窗口属性重设本身还要 2 次 IPC，
  // 等于每次切换多付一次"查找窗口"的异步往返。缓存后只在首次真正去取。
  private cachedWindow: window.Window | null = null;

  constructor(context: common.UIAbilityContext) {
    this.appContext = context;
  }

  // 网页主题上报：同步系统栏前景色与窗口背景色。
  // 同一深浅色重复上报会被吞掉——窗口属性重设是主线程上的重操作，网页多次上报会造成无谓抖动。
  onWebTheme(isDark: boolean): void {
    if (this.applied && this.lastIsDark === isDark) {
      return;
    }
    this.applied = true;
    this.lastIsDark = isDark;
    AppStorage.setOrCreate('web.isDark', isDark);
    const ctx = this.appContext;
    if (!ctx) {
      return;
    }
    // 已缓存窗口就直接同步设置，省掉一次 getLastWindow 的异步往返
    const cached: window.Window | null = this.cachedWindow;
    if (cached !== null) {
      this.applyThemeToWindow(cached, isDark);
      return;
    }
    try {
      window.getLastWindow(ctx).then((win) => {
        this.cachedWindow = win;
        this.applyThemeToWindow(win, isDark);
      }).catch((err: BusinessError) => {
        console.error('获取窗口失败: ' + err.code + ', ' + err.message);
      });
    } catch (error) {
      console.error('onWebTheme异常:', JSON.stringify(error));
    }
  }

  /**
   * 网页长距离下拉到底 -> 刷新当前页。
   *
   * 只做一次"转发"，所有状态判断（是否可见、是否正在加载、当前 URL 是否可刷新）
   * 都留给页面里的回调 —— 桥对象不该知道页面生命周期。
   */
  onPullRefresh(): void {
    try {
      this.onPullRefreshRequest();
    } catch (err) {
      console.error('onPullRefresh异常:', JSON.stringify(err));
    }
  }

  // 真正下发窗口配色。单独抽出来，便于缓存命中与未命中两条路径复用同一段逻辑。
  private applyThemeToWindow(win: window.Window, isDark: boolean): void {
    try {
      const barProps: window.SystemBarProperties = { statusBarContentColor: isDark ? '#FFFFFF' : '#000000' };
      win.setWindowSystemBarProperties(barProps);
      win.setWindowBackgroundColor(isDark ? '#000000' : '#FFFFFF');
    } catch (e) {
      // 窗口可能已被销毁（页面退出途中）：清掉缓存，下次重新获取
      this.cachedWindow = null;
      console.error('同步窗口颜色异常:', JSON.stringify(e));
    }
  }
}

// 图片/视频扩展名集合（ChatGPT 的 accept 用的是扩展名而非 MIME 类型）
// 用 Set 而不是 Array：原先每个扩展名都跑一次 Array.indexOf（线性扫描），accept 里有两三百项时会退化成 O(n²)。
const IMAGE_EXTS: Set<string> = new Set<string>(['tif', 'pjp', 'pjpeg', 'jfif', 'bmp', 'ico', 'xbm', 'svgz', 'gif', 'svg', 'apng', 'tiff', 'png', 'jpg', 'webp', 'hevc', 'jpe', 'avif', 'heif', 'jpeg', 'heic']);
const VIDEO_EXTS: Set<string> = new Set<string>(['avi', 'mov', 'ogv', 'mpe', 'webm', 'm4v', 'mpg', 'mp4', 'mpeg', 'ogm', 'mkv', '3gp', 'wmv', 'asf', 'qt']);

// 定义菜单类型枚举
enum MenuType {
  IMAGE = "IMAGE",
  LINK = "LINK",
  EDITABLE = "EDITABLE",
  SELECTION = "SELECTION"
}

// 上下文菜单的一次性状态：原先散在 6 个 @State 里，长按时会触发 6 次独立的状态更新 -> 6 次 UI 刷新。
// 收成一个对象后，赋值一次只触发 1 次刷新；对象本身不加 @Observed（菜单内容只按 currentMenuType 分发）。
// 注意：菜单位置不放这里 —— 它必须是 @State 才能驱动 popup 的 offset，见 WebComponent.menuOffsetX/Y。
class ContextMenuState {
  currentType: MenuType = MenuType.IMAGE;
  menuHeight: number = 0;
  linkUrl: string = '';
  imageUrl: string = '';
}


@Entry
@Component
struct WebComponent {
  permissionsGranted: boolean = false;
  needReloadWhenVisible: boolean = false;
  webIsVisible: boolean = false;
  // Web 组件与 controller 绑定完成、且首帧导航已发起的标记
  private webAttached: boolean = false;
  renderReloadMaxForCrashed: number = 5;
  renderReloadCountForCrashed: number = 0;
  renderReloadMaxForOthers: number = 10;
  renderReloadCountForOthers: number = 0;
  controller: webview.WebviewController = new webview.WebviewController();
  // 下载委托按需创建：页面构造期不再求值 WebDownloadFileImpl
  webDownloadFile: IAbstractDownloadHandler | undefined = undefined;
  downloadWebLoading: CustomDialogController = new CustomDialogController({
    builder: DownloadConfirmDialog(),
    customStyle: true,
    alignment: DialogAlignment.Bottom,
    autoCancel: false,
    isModal: false,
    openAnimation: {
      duration: 200,
      curve: Curve.Ease,
      delay: 0,
      playMode: PlayMode.Normal,
    }
  })
  private result: WebContextMenuResult | undefined = undefined;
  // 上下文菜单显隐。命中/未命中都在外层容器上，不牵动 Web 子树。
  @State showMenu: boolean = false;
  // 菜单弹出的位置（vp）。单独用 @State 承载：popup 的 offset 只依赖这两个值，
  // 网页内容的滚动/长按不会因为它们变化而重建 Web 组件。
  @State menuOffsetX: number = 0;
  @State menuOffsetY: number = 0;
  private menuState: ContextMenuState = new ContextMenuState();
  // 【不是 @State】currentUrl 只在方法里读写（loadUrl / 深链 / 重载），从未出现在 build() 的组件树中。
  // 声明成 @State 时，每次赋值都会走一遍"标记脏 + 通知订阅者 + 触发重建检查"的流程，
  // 却没有任何 UI 依赖它 —— 纯属开销。改成普通字段即可。
  private currentUrl: string = url;
  @State oauthVisible: boolean = false;
  @State oauthUrl: string = '';
  @StorageLink('coldStartUrl') @Watch('onColdStartUrlChange') coldStartUrl: string = '';
  // 系统状态栏高度（px）。EntryAbility 在 loadContent 之前写入 AppStorage，首帧即可读到。
  // 用于给页面容器加顶部让位，避免网页顶栏画到状态栏上（真机实测必须显式让位，隐式安全区不生效）。
  @StorageProp('insets.top') insetsTopPx: number = 0;
  // 系统深浅色。代理浮窗与设置面板靠它切换配色 —— 它们叠在网页之上，
  // 若写死浅色，在深色模式的 ChatGPT 页面上会非常刺眼（实测过）。
  @StorageProp('sys.isDark') sysIsDark: boolean = false;
  // 代理浮窗与设置面板的状态。
  // proxyState 用 @State 承载：它的变化只影响浮窗颜色与文案，
  // 而浮窗是 Stack 的独立子节点，不会连带重建 Web 子树。
  @State proxyState: ProxyState = ProxyState.IDLE;
  @State proxyPanelVisible: boolean = false;
  private proxyStartupReady: boolean = false;
  private initialNavigationStarted: boolean = false;
  private pageDisposed: boolean = false;
  /** 上一次看到的代理状态，用来区分"刚启动"和"运行中换节点"。 */
  private lastProxyState: ProxyState = ProxyState.IDLE;
  private readonly proxyListener = (state: ProxyState, routeChanged: boolean): void => {
    if (this.pageDisposed) { return; }
    const previous: ProxyState = this.lastProxyState;
    this.lastProxyState = state;
    this.proxyState = state;
    // 代理起来才需要健康探测；关掉代理就停掉，避免空转探测。
    if (state === ProxyState.RUNNING) {
      this.startLinkHealth();
    } else {
      ProxyHealth.stop();
      ProxyHealth.reset();
    }
    if (routeChanged && this.webAttached && this.initialNavigationStarted) {
      // RUNNING -> RUNNING 才是"换节点"；STARTING -> RUNNING 是代理刚起来，
      // 这时无论设置如何都必须刷新，否则页面上的长连接还停留在旧出口。
      const isSwitch: boolean = previous === ProxyState.RUNNING;
      if (isSwitch && !this.proxySettings.refreshAfterSwitch) { return; }
      // 后台不重载：onPageShow 恢复页面时会重新建连；在后台刷新只是把
      // CPU 和流量花在用户看不见的页面上。标记一下，回到前台再补。
      if (!this.pageVisible) {
        this.reloadPendingAfterShow = true;
        return;
      }
      // 现在就要刷新了，之前挂起的补刷作废，避免回到前台再白刷一次。
      this.reloadPendingAfterShow = false;
      try {
        // 网络错误页需要回到失败前的地址；正常页面 refresh 保留 SPA 当前会话地址。
        const current: string = this.controller.getUrl();
        if (/^https?:\/\//i.test(current)) { this.controller.refresh(); }
        else { this.controller.loadUrl(this.currentUrl); }
      } catch (err) { console.error('代理切换后重载失败:', JSON.stringify(err)); }
    }
  };

  private async restoreProxyAtStartup(): Promise<void> {
    try {
      await this.loadProxySettings();
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      // restore -> enable -> startCore 会登记 pendingAutoSelect，
      // enable 返回后异步跑自动选路；这里不再补一次（否则启动会测速两遍）。
      await ProxyManager.restore(ctx);
    } finally {
      this.proxyStartupReady = true;
      if (!this.pageDisposed && this.webAttached && !this.initialNavigationStarted) {
        this.initialNavigationStarted = true;
        this.applyUaAndLoad();
      }
    }
  }
  private previewController: webview.WebviewController = new webview.WebviewController();
  private popupController: webview.WebviewController | undefined = undefined;
  uiContext: UIContext = this.getUIContext();
  context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
  private jsBridge: OhosBridge = new OhosBridge(this.context);
  /** 下拉刷新冷却：避免用户连续下拉把页面反复重载（每次重载都会丢失当前流式输出）。 */
  private lastPullRefreshAt: number = 0;
  private readonly pullRefreshCooldownMs: number = 3000;
  // 自动换路状态：避免"探测失败 -> 换节点 -> 刷新"在短时间内反复触发
  private autoSwitchInFlight: boolean = false;
  private lastAutoSwitchAt: number = 0;
  private readonly autoSwitchCooldownMs: number = 45000;
  /** 手动选节点后的保护期：这段时间内不做自动换路，尊重用户的选择。 */
  private readonly manualSelectGraceMs: number = 120000;
  private proxySettings: ProxySettings = defaultProxySettings();
  /** 回到前台后第一次 onPageShow 已完成（AbilityStage 已预连接，不必重复）。 */
  private firstShowDone: boolean = false;
  /** 网络恢复触发的修复最近一次时间，用来去抖（Wi-Fi/蜂窝切换会连发多次）。 */
  private lastNetRecoverAt: number = 0;
  private readonly netRecoverDebounceMs: number = 5000;
  /** 页面当前是否可见。健康探测 / 自动换路只在可见时运行，后台不应占用 CPU。 */
  private pageVisible: boolean = true;
  /** 后台期间发生过"换节点应刷新"，回到前台补做一次。 */
  private reloadPendingAfterShow: boolean = false;
  /** 进入后台的时刻；0 表示当前在前台。用来决定回前台时要不要重新下发代理设置。 */
  private hiddenAt: number = 0;
  /** 是否曾经进过后台。冷启动的第一次 onPageShow 不该重新下发代理设置。 */
  private everHidden: boolean = false;
  /**
   * 后台超过这个时长才重新下发 ArkWeb 代理设置。
   * 重新下发会重置 ArkWeb 的网络栈，可能打断正在流式输出的回复；
   * 短暂切一下（回消息、看时间）代理设置根本没被系统动过，没必要付这个代价。
   */
  private readonly reapplyProxyAfterMs: number = 30000;

  /**
   * 读取代理设置。自动选路 / 健康探测 / 后台保活都受这些开关控制，
   * 每次生命周期切换都重新读一次，用户在面板里改了立刻生效。
   */
  private async loadProxySettings(): Promise<void> {
    try {
      await ProxySettingsStore.init(this.context);
      this.proxySettings = await ProxySettingsStore.load();
    } catch (err) {
      this.proxySettings = defaultProxySettings();
    }
  }

  /**
   * 系统网络恢复（换 Wi-Fi、断网重连、飞行模式关闭）时的修复。
   *
   * 为什么需要：内核到节点的长连接会随网络切换全部失效，而应用侧状态仍是 RUNNING，
   * 页面只会表现为"请求一直失败"。等健康探测的下一轮（默认 60 秒）太慢，
   * 用户体感就是"换了个 Wi-Fi 就再也连不上，得重启应用"。
   *
   * 做三件事：确认内核还活着（recover）、重新下发 ArkWeb 代理设置、刷新待补的重载。
   * 不去做测速选路：网络刚恢复时所有节点都在重新建连，此刻测速结果不可信，
   * 选出来的节点下一分钟可能又变差。交给常规的健康探测与自动换路。
   */
  private onNetworkRecovered(): void {
    if (this.pageDisposed) {
      return;
    }
    const now: number = Date.now();
    if (now - this.lastNetRecoverAt < this.netRecoverDebounceMs) {
      return;
    }
    this.perfMark('netRecovered');
    if (ProxyManager.getState() !== ProxyState.RUNNING) {
      return;
    }
    // 后台不修复：onPageShow 本来就会 recover，在后台还可能触发一次
    // 重建内核 + 自动选路（十几秒的测速），白白占用后台 CPU。
    // 注意这里**不能先更新 lastNetRecoverAt**：去抖是为"连发事件"准备的，
    // 若后台这次就把窗口用掉，紧接着回到前台后的第一个事件会被丢掉。
    if (!this.pageVisible) {
      this.reloadPendingAfterShow = true;
      return;
    }
    this.lastNetRecoverAt = now;
    ProxyManager.recover(this.context, true).then((recovered: OpResult) => {
      if (this.pageDisposed || !recovered.ok) {
        return;
      }
      this.flushPendingReload();
    }).catch(() => {});
  }

  /**
   * 启动时的自动选路不在这里单独触发。
   *
   * ProxyManager.enable / restartIfRunning 已经在释放 busy 之后异步跑了一次
   * （见 runPendingAutoSelect），覆盖了"冷启动恢复"、"用户开启代理"、"切换订阅"三条路径；
   * 页面再调一次只会让同一轮测速排队，没有额外收益。
   */

  /**
   * 链路劣化时的自愈：重新测速选一个更优节点，换完刷新。
   * 仅在"链路确实不通"时触发（ProxyHealth 连续失败），不是定期无脑换路。
   * 有冷却时间，避免在"两个都很差"的节点之间来回跳。
   */
  private onLinkDegraded(): void {
    if (this.pageDisposed || this.autoSwitchInFlight) {
      return;
    }
    if (!this.proxySettings.autoSwitchOnDegrade) {
      return;
    }
    const now: number = Date.now();
    if (now - this.lastAutoSwitchAt < this.autoSwitchCooldownMs) {
      return;
    }
    // 用户刚手动选过节点：短期内不要被自动逻辑覆盖，否则"点了不生效"。
    if (now - ProxyManager.getLastManualSelectAt() < this.manualSelectGraceMs) {
      return;
    }
    this.lastAutoSwitchAt = now;
    this.autoSwitchInFlight = true;
    this.perfMark('linkDegraded', 'start auto switch');
    // 先确认内核还活着。内核死了的情况下测速会全部失败，此时换节点毫无意义，
    // 必须先重建内核；内核正常时 recover 只是一次本地请求，几乎无成本。
    ProxyManager.recover(this.context).then((recovered: OpResult) => {
      if (this.pageDisposed) {
        this.autoSwitchInFlight = false;
        return;
      }
      if (!recovered.ok) {
        // 重建失败时不要把 inFlight 永远钉住，否则之后再也不会自愈。
        this.autoSwitchInFlight = false;
        this.perfMark('recoverFailed', recovered.error ?? '');
        return;
      }
      // 【负载均衡出口不参与应用层换路】
      // 用户选择「应用 · 负载均衡 · XX」时，节点切换由内核按健康检查自己做：
      // 挂了就踢出轮转、下次连接自动换一个，全程无感。
      // 应用层再插一手只会把出口从"组"改成"单个节点"，均衡失效，
      // 并且 select 会清连接、发 routeChanged，把网页刷掉 —— 正是用户明确不要的。
      // 内核已经死掉的情况前面 recover 已经处理过，这里只是不改出口。
      return ProxyManager.routeUsesBalance().then((balanced: boolean) => {
        if (this.pageDisposed) {
          this.autoSwitchInFlight = false;
          return;
        }
        if (balanced) {
          this.autoSwitchInFlight = false;
          this.perfMark('autoSwitch', 'skipped: balance group');
          return;
        }
        return AutoSelect.run(this.context).then((result: AutoSelectResult) => {
          this.autoSwitchInFlight = false;
          if (this.pageDisposed) {
            return;
          }
          this.perfMark('autoSwitch', (result.ok ? result.node + ' ' + result.latencyMs.toString() + 'ms' :
            'failed ' + (result.error ?? '')));
          // 出口真的换了才补一次刷新；"保持当前"不刷新。
          // 健康探测触发的换路里 previous 已经是 RUNNING，proxyListener 会按设置刷新；
          // 但冷启动/回前台的第一轮选路不走 proxyListener（它只在 routeChanged 时发），
          // 这里补上，避免页面还挂在旧出口上。
          if (result.ok && result.routeChanged === true && this.proxySettings.refreshAfterSwitch) {
            this.reloadAfterRouteChange();
          }
        });
      });
    }).catch((err: Object) => {
      this.autoSwitchInFlight = false;
      console.error('自动换路异常: ' + JSON.stringify(err));
    });
  }
  // JS 桥配置对象提到成员字段（不再写在 build() 内联位置）。
  // 【如实说明收益】bindPopup/bindSheet 已经移出 Web 节点，Web 节点不再位于任何 @State 的更新路径上，
  // 所以内联字面量实际上只在首次 build() 时创建一次 —— 这项改动当前几乎没有性能收益。
  // 保留它的理由是两个低成本的正确性收益：
  //   ① 配置语义上就该只定义一次，放在字段里不会被人误以为"每次都会重新注册"；
  //   ② 若将来有人把 bindPopup/bindSheet 移回 Web，内联写法会重新变成"每次状态变化都重建配置"，
  //      字段写法天然免疫。
  // 注意：object/controller 是引用类型，字段声明顺序必须在它们之后初始化（当前 controller 在 438 行、
  // jsBridge 在 472 行，均早于此处）。
  private jsProxyConfig: JavaScriptProxy = {
    object: this.jsBridge,
    name: 'ohosBridge',
    methodList: ['onWebTheme', 'onPullRefresh'],
    controller: this.controller
  };
  private webBg: string = '#FFFFFF';
  // 网页侧权限引导弹窗是否正在显示（互斥锁）：防止并发权限请求叠出多个对话框导致请求挂起
  private permissionDialogShowing: boolean = false;

  // 性能埋点：hilog 自带毫秒时间戳，PERF 序列即可还原冷启动时间线
  private perfMark(stage: string, detail?: string): void {
    console.info('PERF ' + stage + (detail ? ' | ' + detail : ''));
  }

  // 状态栏高度换算成 vp，供容器顶部让位使用。
  // 兜底两层：
  //   ① insets.top 正常（EntryAbility 已写）→ 直接换算；
  //   ② 读不到（0）→ 用 FALLBACK_STATUS_BAR_VP，宁可多让几 vp 也不能让网页压到状态栏上
  //      （多让只是顶部留一点白，少让则是时间/电量被内容盖住，后者明显更糟）。
  private statusBarTopVp(): number {
    const px: number = this.insetsTopPx;
    if (px <= 0) {
      return FALLBACK_STATUS_BAR_VP;
    }
    try {
      return this.uiContext.px2vp(px);
    } catch (err) {
      return FALLBACK_STATUS_BAR_VP;
    }
  }

  // 首次导航：UA 必须在 loadUrl 之前设置（官方文档：先 setCustomUserAgent，再通过 loadUrl 加载页面），
  // 否则整页会被加载两遍 —— 基线 hilog 中 chatgpt.com 的加载正好出现了两次。
  // 窗口宽高由 EntryAbility 写入 AppStorage（px），这里同步读取，冷启动路径上不再有异步 getWindow。
  private applyUaAndLoad(): void {
    let widthPx: number = AppStorage.get<number>('win.widthPx') ?? 0;
    let heightPx: number = AppStorage.get<number>('win.heightPx') ?? 0;
    let ua: string = resolveUserAgent(widthPx, widthPx > heightPx);
    try {
      this.controller.setCustomUserAgent(ua);
      this.perfMark('uaSet', ua.indexOf('Mobile') >= 0 ? 'mobile' : 'pc');
    } catch (error) {
      console.error('setCustomUserAgent异常:', JSON.stringify(error));
    }
    try {
      // 网络可用只需在加载前声明一次；原先放在 onPageEnd 会随每次导航重复通知内核
      this.controller.setNetworkAvailable(true);
    } catch (error) {
      console.error('setNetworkAvailable异常:', JSON.stringify(error));
    }
    // 【已移除：对当前页面的 prefetchPage】
    // 原实现在 loadUrl 之前调用 prefetchPage(currentUrl)，期望主文档命中缓存。
    // 模拟器实测证明这条路走不通：
    //   prefetchLead（预取→loadUrl 间隔）实测 12~53ms
    //   而 loadUrl→pageBegin 需要 735ms（旧真机基线 879ms）
    //   预取自己也要走 DNS+TCP+TLS+TTFB，12ms 时缓存必然为空，loadUrl 只能重新发起整条请求。
    // 要让它命中就得等它完整返回（约 700ms），那还不如直接 loadUrl。
    // prefetchPage 的正确用途是"预取稍后才会打开的页面"（登录后跳转、下一个会话），
    // 而不是"马上要 loadUrl 的同一个 URL"。相关预取已挪到 onPageEnd 里按需发起（见 prefetchNextPage）。
    try {
      this.controller.loadUrl(this.currentUrl);
      this.perfMark('loadUrlCalled', this.currentUrl);
    } catch (error) {
      console.error('首次 loadUrl 异常:', JSON.stringify(error));
    }
  }

  // 首屏加载完成后，对未来可能打开的页面做预取（这才是 prefetchPage 的正确用法）。
  // 依据（实测）：prefetchPage 对"紧跟着 loadUrl 的同一 URL"无效（提前量仅 12~53ms，
  // 远小于一次请求所需的 700ms+）。但首屏稳定后我们有充足的空闲时间，
  // 此时预取 SSO 登录域，用户点"用 Google 登录"时该页面能直接从缓存打开。
  // 只预取一个 URL：官方限制 500ms 内重复预取只认第一次，且这里不需要多个。
  private prefetchNextPage(): void {
    const nextUrl: string = AUTH_ORIGIN;
    try {
      this.controller.prefetchPage(nextUrl);
      this.perfMark('prefetchNext', nextUrl);
    } catch (error) {
      // 预取失败不影响任何功能，下次打开时正常加载即可
      console.warn('prefetchNextPage 失败: ' + JSON.stringify(error));
    }
  }

  // 下载能力按需装配：首次需要时才求值 WebDownloadFileImpl 模块，把开销推到首屏之后。
  // 幂等：重复调用直接返回（内部 callbacksBound 也保证回调不重复注册）。
  //
  // 【为什么用 getInstance() 而不是 new】getInstance() 返回的是模块内已有的静态单例。
  // 原实现这里写 new WebDownloadFileHelper()，而该模块顶部是
  //     private static instance = new WebDownloadFileHelper()
  // ——lazy import 在本函数首次访问该类时就求值模块、顺手建好了单例；
  // 我们再 new 一个，就会同时存在两个实例（各持有一个 WebDownloadDelegate）。
  // 更关键的是语义不一致：openDownloadPopUpWindow / cancelDownload / hasPendingDownload
  // 这些静态方法操作的都是【单例】，而真正接到 controller 上的却是我们 new 的那个 ——
  // 两个对象状态不同步，后续任何"在静态方法里改状态、在实例上读状态"的改动都会踩坑。
  // 统一走单例后，全应用只有一个下载处理器，状态来源唯一。
  private ensureDownloadDelegate(): void {
    if (this.webDownloadFile !== undefined) {
      return;
    }
    let helper: IAbstractDownloadHandler = WebDownloadFileHelper.getInstance();
    this.webDownloadFile = helper;
    helper.setDownloadDelegate(this.controller);
  }

  // BFCache（前进/后退缓存）容量配置。
  // 背景：enableBackForwardCache 只负责"打开开关"，不改配置时容量默认 1、过期时间默认 600s。
  // 容量 1 意味着只有栈顶那一页能整实例缓存，往前多退一步就要重新完整加载 —— 这是网页应用
  // "返回键很慢、且回来丢了滚动位置"的典型原因。调到 3 是覆盖最常见的两跳返回，同时限制内存占用。
  // 该 API 要求 controller 已绑定（未绑定抛 17100001），所以只能在 onControllerAttached 里调用。
  private applyBackForwardCacheOptions(): void {
    try {
      let options: webview.BackForwardCacheOptions = new webview.BackForwardCacheOptions();
      options.size = BF_CACHE_SIZE;
      options.timeToLive = BF_CACHE_TTL_SECONDS;
      this.controller.setBackForwardCacheOptions(options);
      this.perfMark('bfCacheConfigured', 'size=' + BF_CACHE_SIZE);
    } catch (error) {
      // 配置失败只是回到默认容量（行为与改动前一致），不影响页面加载
      console.error('setBackForwardCacheOptions异常:', JSON.stringify(error));
    }
  }

  // 渲染进程退出后的重载：统一入口，保证"可见才加载 + 加载失败不抛到回调外"
  private reloadAfterRenderExit(): void {
    this.perfMark('renderReload', this.currentUrl);
    try {
      this.controller.loadUrl(this.currentUrl);
    } catch (error) {
      console.error('渲染进程退出后重载异常:', JSON.stringify(error));
      // loadUrl 失败（如 controller 未绑定）：留到下次可见时再补，避免彻底白屏
      this.needReloadWhenVisible = true;
    }
  }

  // 文件选择被取消/异常时的收尾：回填空列表让网页的 <input type=file> 结束等待态。
  // 不回填的话网页会一直以为"用户还在选文件"，后续点击上传没有任何反应。
  private notifyFileSelectorAbort(event: OnShowFileSelectorEvent): void {
    try {
      event.result.handleFileList([]);
    } catch (err) {
      console.error('handleFileList(空)异常:', JSON.stringify(err));
    }
  }

  // 【已移除：启动后预申请权限】
  // 原实现会在 onPageEnd 后立刻 requestPermissionsFromUser(CAMERA, MICROPHONE)，
  // 也就是用户刚打开应用、还没打算用语音/拍照时，就先被两个系统权限框挡一下。
  // 这既打断首屏体验，也让用户在毫无语境的情况下作出授权决定。
  // 现在改为完全按需：网页真正请求麦克风/相机（onPermissionRequest）时才申请，
  // 见 grantIfSystemAllowed -> requestSystemPermissionDirectly。

  // 冷启动/热启动深链：EntryAbility 写入 AppStorage 'coldStartUrl' 后触发
  onColdStartUrlChange(): void {
    if (!this.coldStartUrl || this.coldStartUrl.length === 0) {
      return;
    }
    if (this.coldStartUrl === this.currentUrl) {
      return;
    }
    this.currentUrl = this.coldStartUrl;
    // controller 尚未绑定：只记录目标 URL，首次加载统一由 onControllerAttached 发起
    if (!this.webAttached || !this.proxyStartupReady) {
      return;
    }
    try {
      this.controller.loadUrl(this.currentUrl);
    } catch (error) {
      console.error('深链loadUrl异常:', JSON.stringify(error));
    }
  }

  // 从网络URL加载并保存图片到相册
  async saveNetworkImageToGallery(url: string): Promise<boolean> {
    if (!url) {
      console.error('图片URL为空');
      return false;
    }

    // 资源句柄声明在 try 之外：异常路径上也要能释放（原先失败分支直接 return，pixelMap/http 全泄漏，
    // 反复保存长会话图片后内存涨上去，表现为越来越卡）
    let httpInstance: http.HttpRequest | undefined = undefined;
    let pixelMap: image.PixelMap | undefined = undefined;
    let imageSource: image.ImageSource | undefined = undefined;
    let imagePackerApi: image.ImagePacker | undefined = undefined;
    let fileFd: number = -1;
    try {
      // 1. 通过HTTP请求下载图片
      httpInstance = http.createHttp();
      // 显式要 ArrayBuffer：不设 expectDataType 时默认按 Content-Type 解析，
      // 图片可能被当成 string 返回，createImageSource 会直接抛错（保存图片失败的隐蔽根因）
      const response = await httpInstance.request(url, {
        method: http.RequestMethod.GET,
        connectTimeout: 60000,
        readTimeout: 60000,
        expectDataType: http.HttpDataType.ARRAY_BUFFER
      });

      if (response.responseCode !== http.ResponseCode.OK) {
        console.error('HTTP请求失败，状态码: ' + response.responseCode);
        return false;
      }

      const imageData: ArrayBuffer = response.result as ArrayBuffer;
      if (!imageData || imageData.byteLength === 0) {
        console.error('获取到的图片数据为空');
        return false;
      }

      // 2. 创建图片源并获取PixelMap
      imageSource = image.createImageSource(imageData);
      pixelMap = await imageSource.createPixelMap();

      // 3. 打包为JPEG格式
      imagePackerApi = image.createImagePacker();
      const packOpts: image.PackingOption = { format: 'image/jpeg', quality: 98 };
      const buffer: ArrayBuffer = await imagePackerApi.packToData(pixelMap, packOpts);

      // 4. 保存到相册
      const helper = photoAccessHelper.getPhotoAccessHelper(this.context);
      const uri = await helper.createAsset(photoAccessHelper.PhotoType.IMAGE, 'jpg');
      const file = await fs.open(uri, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
      fileFd = file.fd;
      await fs.write(file.fd, buffer);

      return true;
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      console.error('保存图片失败。Code: ' + err.code + ', message: ' + err.message);
      return false;
    } finally {
      // 5. 无论成功失败都释放：文件句柄 → PixelMap → ImageSource → ImagePacker → HTTP
      if (fileFd >= 0) {
        try {
          await fs.close(fileFd);
        } catch (err) {
          console.error('关闭文件失败:', JSON.stringify(err));
        }
      }
      if (pixelMap !== undefined) {
        try {
          await pixelMap.release();
        } catch (err) {
          console.error('释放PixelMap失败:', JSON.stringify(err));
        }
      }
      if (imageSource !== undefined) {
        try {
          await imageSource.release();
        } catch (err) {
          console.error('释放ImageSource失败:', JSON.stringify(err));
        }
      }
      if (imagePackerApi !== undefined) {
        try {
          await imagePackerApi.release();
        } catch (err) {
          console.error('释放ImagePacker失败:', JSON.stringify(err));
        }
      }
      if (httpInstance !== undefined) {
        try {
          httpInstance.destroy();
        } catch (err) {
          console.error('销毁http实例失败:', JSON.stringify(err));
        }
      }
    }
  }

  // 图片菜单构建器 - 直接包含 SaveButton
  @Builder
  ImageMenuBuilder() {
    Column() {
      // 使用系统安全控件 SaveButton，点击直接保存
      SaveButton()
        .fontSize(14)
        .fontColor('#FFFFFF')           // 深色字体
        .backgroundColor('#000000')     // 浅灰背景
        .width(100)
        .height(45)
        .onClick(async (event: ClickEvent, result: SaveButtonOnClickResult) => {
          this.showMenu = false;
          if (result === SaveButtonOnClickResult.SUCCESS) {
            const success = await this.saveNetworkImageToGallery(this.menuState.imageUrl);
            if (success) {
              promptAction.showToast({ message: '已保存至相册！' });
            } else {
              promptAction.showToast({ message: '保存失败，请重试' });
            }
          } else {
            promptAction.showToast({ message: '授权失败' });
          }
        })
    }
    .width(100)
    .backgroundColor(Color.Black)
    .borderRadius(8)
    .shadow({
      radius: 10,
      color: '#33000000',
      offsetX: 0,
      offsetY: 2
    })
  }

  // 链接菜单构建器（复制链接 + 系统浏览器打开）
  @Builder
  LinkMenuBuilder() {
    Menu() {
      MenuItem({ content: '复制链接' })
        .width(160)
        .height(50)
        .onClick(() => {
          const targetLink: string = this.menuState.linkUrl;
          this.hideMenu();
          if (targetLink.length === 0) {
            return;
          }
          try {
            const pasteData = pasteboard.createData('text/plain', targetLink);
            pasteboard.getSystemPasteboard().setData(pasteData).catch((error: BusinessError) => {
              console.error('复制链接失败: ' + error.code + ', ' + error.message);
            });
          } catch (error) {
            console.error('复制链接异常:', JSON.stringify(error));
          }
        })
      MenuItem({ content: '在系统浏览器打开' })
        .width(160)
        .height(50)
        .onClick(() => {
          const targetLink: string = this.menuState.linkUrl;
          this.hideMenu();
          this.openInSystemBrowser(targetLink);
        })
    }
    .width(160)
    .height(100)
  }

  // 用系统浏览器打开链接
  private openInSystemBrowser(targetUrl: string): void {
    if (!targetUrl) {
      return;
    }
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      let want: Want = {
        action: 'ohos.want.action.viewData',
        entities: ['entity.system.browsable'],
        uri: targetUrl
      };
      context.startAbility(want).then((data) => {
        console.info('系统浏览器打开成功: ' + JSON.stringify(data));
      }).catch((err: BusinessError) => {
        console.error('系统浏览器打开失败: ' + err.code + ', ' + err.message);
        promptAction.showToast({ message: '打开系统浏览器失败' });
      });
    } catch (error) {
      console.error('系统浏览器打开异常:', JSON.stringify(error));
      promptAction.showToast({ message: '打开系统浏览器失败' });
    }
  }

  // 外链 scheme 统一分发：从 onLoadIntercept 里抽出来，让导航回调只做"查表 + 返回 bool"，
  // 回调体短、无重复 getHostContext，热路径上分配更少。
  // tel: 的边界：digits 可能带 + 与 -，直接传原始尾串给 makeCall。
  private dispatchExternalScheme(scheme: string, requestUrl: string): void {
    if (scheme === 'tel://' || scheme === SCHEME_TEL) {
      const phoneNumber: string = requestUrl.substring(scheme.length);
      try {
        call.makeCall(phoneNumber, (err) => {
          if (!err) {
            console.info('拉起拨号界面成功');
          } else {
            console.error('拉起拨号界面失败: ' + JSON.stringify(err));
            promptAction.showToast({ message: '拉起拨号界面失败' });
          }
        });
      } catch (error) {
        console.error('拨号异常:', JSON.stringify(error));
        promptAction.showToast({ message: '拉起拨号界面失败' });
      }
      return;
    }
    let want: Want;
    if (scheme === SCHEME_MAILTO) {
      want = { action: 'ohos.want.action.sendToData', uri: requestUrl };
    } else if (scheme === SCHEME_SMS) {
      want = { bundleName: 'com.ohos.mms', action: 'ohos.want.action.viewData', uri: requestUrl };
    } else if (scheme === SCHEME_WEIXIN) {
      want = { bundleName: 'com.tencent.wechat', action: 'ohos.want.action.viewData', uri: requestUrl };
    } else {
      // SCHEME_QQ_LOGIN（https 前缀的 QQ 登录链接）
      want = { action: 'ohos.want.action.viewData', entities: ['entity.system.browsable'], uri: requestUrl };
    }
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      context.startAbility(want).then(() => {
        console.info('外链拉起成功: ' + scheme);
      }).catch((err: BusinessError) => {
        console.error('外链拉起失败: ' + scheme + ' ' + err.code + ', ' + err.message);
        promptAction.showToast({ message: scheme === SCHEME_MAILTO ? '拉起邮件应用失败，请检查是否安装邮件应用' : '拉起外部应用失败' });
      });
    } catch (error) {
      console.error('外链拉起异常:', JSON.stringify(error));
      promptAction.showToast({ message: '拉起外部应用失败' });
    }
  }

  // 可编辑区域菜单构建器
  @Builder
  EditableMenuBuilder() {
    Menu() {
      MenuItem({ content: '剪切' })
        .width(100)
        .height(50)
        .onClick(() => {
          this.hideMenu();
          this.result?.cut();
        })
      MenuItem({ content: '复制' })
        .width(100)
        .height(50)
        .onClick(() => {
          this.hideMenu();
          this.result?.copy();
        })
      MenuItem({ content: '粘贴' })
        .width(100)
        .height(50)
        .onClick(() => {
          this.hideMenu();
          this.result?.paste();
        })
      MenuItem({ content: '全选' })
        .width(100)
        .height(50)
        .onClick(() => {
          this.hideMenu();
          this.result?.selectAll();
        })
    }
    .width(100)
    .height(200)
  }

  // 选中文本菜单构建器
  @Builder
  SelectionMenuBuilder() {
    Menu() {
      MenuItem({ content: '复制' })
        .width(100)
        .height(50)
        .onClick(() => {
          this.hideMenu();
          this.result?.copy();
        })
    }
    .width(100)
    .height(50)
  }

  // 关菜单：showMenu 已经为 false 时不重复赋值（@State 重复赋同值也会走一次状态刷新）
  private hideMenu(): void {
    if (this.showMenu) {
      this.showMenu = false;
    }
  }

  // 动态菜单构建器
  @Builder
  MenuBuilder() {
    if (this.menuState.currentType === MenuType.IMAGE) {
      this.ImageMenuBuilder();
    } else if (this.menuState.currentType === MenuType.LINK) {
      this.LinkMenuBuilder();
    } else if (this.menuState.currentType === MenuType.EDITABLE) {
      this.EditableMenuBuilder();
    } else if (this.menuState.currentType === MenuType.SELECTION) {
      this.SelectionMenuBuilder();
    }
  }

  // 半屏预览沿用原项目的纯网页内容。
  @Builder
  OAuthSheetBuilder() {
    OAuthSheet({
      targetUrl: this.oauthUrl,
      isDark: this.sysIsDark,
      controller: this.previewController,
      onSheetWebAttached: (ctl: webview.WebviewController) => {
        this.popupController = ctl;
      },
      onRequestClose: () => { this.oauthVisible = false; },
      onSheetClosed: () => {
        this.popupController = undefined;
      }
    })
  }

  onBackPress() {
    if (this.proxyPanelVisible) { this.proxyPanelVisible = false; return true; }
    if (this.oauthVisible) {
      if (this.popupController !== undefined && this.popupController.accessBackward()) {
        this.popupController.backward();
      } else { this.oauthVisible = false; }
      return true;
    }
    if (this.controller.accessStep(-1)) {
      this.controller.backward();
      return true
    } else {
      return false
    }
  }

  // 系统权限已授予时静默放行网页权限请求；未授予才走引导弹窗（避免"未点本次允许后永不再弹"的死局）
  private async grantIfSystemAllowed(event: OnPermissionRequestEvent, resources: Array<string>): Promise<void> {
    let allGranted = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const tokenId: number = context.applicationInfo.accessTokenId;
      const atManager = abilityAccessCtrl.createAtManager();
      for (let i = 0; i < resources.length; i++) {
        let perm: string = '';
        if (resources[i] === 'TYPE_AUDIO_CAPTURE') {
          perm = 'ohos.permission.MICROPHONE';
        } else if (resources[i] === 'TYPE_VIDEO_CAPTURE') {
          perm = 'ohos.permission.CAMERA';
        }
        if (perm === '') {
          allGranted = false;
          break;
        }
        const status = await atManager.checkAccessToken(tokenId, perm as Permissions);
        if (status !== abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
          allGranted = false;
          break;
        }
      }
      if (allGranted) {
        event.request.grant(resources);
        this.permissionsGranted = true;
        console.info('系统权限已授予，自动放行网页权限请求');
        return;
      }
    } catch (err) {
      console.error('检查系统权限异常:', JSON.stringify(err));
    }
    // 走到这里说明网页要麦克风/相机、但系统权限还没给。
    // 【改进】以前这里是先弹一个自制引导框，让用户再手动"前往设置"绕一圈；
    // 现在直接调系统权限申请 —— 用户此刻正是想用语音/拍照，弹系统框的语境是对的，
    // 一次授权到位，不用中途跳设置再回来。授权成功就直接放行网页请求。
    const systemGranted: boolean = await this.requestSystemPermissionDirectly(resources);
    if (systemGranted) {
      event.request.grant(resources);
      this.permissionsGranted = true;
      console.info('系统权限申请通过，已放行网页请求');
      return;
    }
    // 系统权限申请失败/被拒：给一次明确引导（此时不再有"点本次允许就绕过"的假选项）。
    // 弹窗防重入：grantIfSystemAllowed 是 async，多个权限请求（语音+视频同时申请，或连点麦克风）
    // 会各自走到这里、各自弹一个对话框，叠成一摞后只有一个能正常返回，其余请求一直挂起
    // （网页侧表现为"点了没反应"）。用 permissionDialogShowing 做互斥，后来的请求直接拒绝，
    // 让网页自己重试（比静默挂起安全，也不会让用户看到重复弹窗）。
    if (this.permissionDialogShowing) {
      this.denyQuietly(event);
      return;
    }
    this.permissionDialogShowing = true;
    promptAction.showDialog({
      title: '麦克风、相机权限',
      message: '为使用语音输入和音视频通话功能，应用需要访问麦克风、相机。\n请前往「设置」中为本应用开启对应权限后重新试一次。',
      buttons: [
        { text: '取消', color: '#666666' },
        { text: '前往设置', color: '#0A59F7' }
      ]
    }).then((data) => {
      this.permissionDialogShowing = false;
      if (data.index === 1) {
        this.toSysSettingPage();
      } else {
        console.info('用户拒绝授权');
      }
      this.denyQuietly(event);
    }).catch((err: Error) => {
      // 弹窗本身失败（例如页面已销毁）也必须解除互斥，否则后续权限请求会被永久拒绝
      this.permissionDialogShowing = false;
      console.error('弹窗异常:', err.message);
      this.denyQuietly(event);
    });
  }

  // 直接向系统申请网页所需的那几个权限（仅麦克风/相机），返回是否全部通过。
  // 与"启动后就预申请"的区别：这里是在用户真的要用语音/拍照时才申请，语境正确、不乱弹框。
  private async requestSystemPermissionDirectly(resources: Array<string>): Promise<boolean> {
    const wanted: Array<Permissions> = [];
    for (let i = 0; i < resources.length; i++) {
      if (resources[i] === 'TYPE_AUDIO_CAPTURE') {
        wanted.push('ohos.permission.MICROPHONE');
      } else if (resources[i] === 'TYPE_VIDEO_CAPTURE') {
        wanted.push('ohos.permission.CAMERA');
      }
    }
    if (wanted.length === 0) {
      return false;
    }
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const result = await abilityAccessCtrl.createAtManager().requestPermissionsFromUser(context, wanted);
      const grantResults = result.authResults;
      for (let i = 0; i < grantResults.length; i++) {
        if (grantResults[i] !== 0) {
          return false;
        }
      }
      return true;
    } catch (err) {
      console.error('直接申请系统权限异常:', JSON.stringify(err));
      return false;
    }
  }

  // 明确拒绝未放行的权限请求，避免请求挂起导致后续权限请求不再触发
  private denyQuietly(event: OnPermissionRequestEvent): void {
    try {
      event.request.deny();
    } catch (err) {
      console.error('deny异常:', JSON.stringify(err));
    }
  }

  private toSysSettingPage() {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      context.startAbility({
        bundleName: 'com.huawei.hmos.settings',
        abilityName: 'com.huawei.hmos.settings.MainAbility',
        uri: 'application_info_entry',
        parameters: {
          pushParams: context.abilityInfo.bundleName
        }
      }).then(() => {
        console.info('跳转到设置页面成功');
      }).catch((err: BusinessError) => {
        console.error(`跳转到设置页面失败: ${err.code}, ${err.message}`);
        promptAction.showToast({ message: '跳转失败，请手动前往设置' });
      });
    } catch (error) {
      console.error('跳转到设置页面异常:', JSON.stringify(error));
      promptAction.showToast({ message: '跳转失败，请手动前往设置' });
    }
  }

  // 加载本地错误页（Agent B 提供 rawfile/web_error.html）
  private loadErrorPage(failUrl: string, code: number): void {
    try {
      if (!failUrl || failUrl.indexOf('web_error.html') >= 0) {
        return;
      }
      const errorUrl: string = 'resource://rawfile/web_error.html?code=' + code + '&target=' + encodeURIComponent(failUrl);
      this.controller.loadUrl(errorUrl);
    } catch (error) {
      console.error('加载错误页异常:', JSON.stringify(error));
    }
  }

  // 下载弹窗事件回调：必须保存具名引用，否则 off 时用新的匿名箭头函数永远注销不掉，
  // 每次进出页面都会多留一个监听，弹窗开合越来越卡。
  // 类型用 EmitterUtil 导出的 EmitterCallback（emitter.on 的回调签名），注销时原样传回即可匹配。
  private readonly onDownloadEvent: EmitterCallback<number> = (event: emitter.GenericEventData<number>): void => {
    if (event?.data === 1) {
      this.downloadWebLoading.open();
    } else {
      this.downloadWebLoading.close();
    }
  };

  aboutToAppear(): void {
    this.pageDisposed = false;
    // 网页长距离下拉 -> 刷新当前页。桥对象在构建期就存在，这里只注入回调，
    // 不在回调里捕获 this 之外的东西，避免页面销毁后仍被引用。
    this.jsBridge.onPullRefreshRequest = () => { this.onPullRefresh(); };
    ProxyManager.subscribe(this.proxyListener);
    // 网络切换/断网恢复：内核到节点的连接会整体失效，要及时探活并重下发代理设置。
    NetworkWatcher.start(() => { this.onNetworkRecovered(); });
    // 不 await：启动链路不能阻塞首帧。restoreProxyAtStartup 内部是 try/finally，
    // 加 catch 只为吞掉"不该发生但发生了"的异常，避免变成未处理的 Promise 拒绝。
    this.restoreProxyAtStartup().catch((err: Object) => {
      console.error('启动恢复代理异常: ' + JSON.stringify(err));
    });
    this.perfMark('aboutToAppear');
    // Web 底色与窗口背景色对齐：不透明底色可省去一层混合，视觉与原先的 Transparent 一致。
    // 兜底：EntryAbility 若因异常没写 'sys.isDark'，深色模式下会先画一帧白底（启动白闪）。
    const isDark: boolean = resolveColdStartDark();
    this.webBg = isDark ? '#000000' : '#FFFFFF';
    this.perfMark('webBg', this.webBg);
    EmitterUtil.on<number>('affffa', this.onDownloadEvent);
    // 冷启动深链：记录目标 URL，实际加载在 onControllerAttached 里设完 UA 后发起
    if (this.coldStartUrl && this.coldStartUrl.length > 0) {
      this.currentUrl = this.coldStartUrl;
    }
    // Mihomo 内核加载（阶段 1：只验证能否 dlopen，不启动任何代理）。
    // 放在 aboutToAppear 末尾、且不等待结果：它是一次同步 dlopen（47MB 内核），
    // 但它不影响首帧 —— 首帧由 webBg/Web 组件决定，这里只是提前把内核准备好。
    // 失败不抛异常，只记录日志；应用在没有代理的情况下照常可用。
  }

  // ==================== 前后台生命周期：让 Web 内核跟随应用状态暂停/恢复 ====================
  // 页面切后台后若不暂停，网页里的定时器、动画、流式回复仍在出帧抢 CPU，
  // 回到前台那一下（以及之后的第一批点击）就要排在它们后面 —— 这是"切出去再回来一顿"的常见来源。
  // onPageHide / onPageShow 是 @Entry 组件的页面级回调，语义已经是"页面不可见 / 重新可见"，
  // 不需要再额外订阅 Ability 生命周期。
  // 注意：这里只做 controller 的一次轻量调用（内核侧挂起/恢复），不在回调里做任何耗时操作。
  onPageShow(): void {
    this.perfMark('pageShow');
    this.pageVisible = true;
    this.setWebActive(true);
    // 回到前台先重建到主站的连接：后台期间原有 socket 多半已被系统回收或 NAT 超时，
    // 等网页自己发现"连接已死→重连"要多花一个 RTT 甚至一次超时。预连接不产生页面请求，
    // 只是把 DNS/TCP/TLS 提前做好，页面下一个请求直接复用。
    //
    // 冷启动的第一次 onPageShow 要跳过：MyAbilityStage 在 loadUrl 之前已经对同样两个域
    // 做过预连接，这里再发一遍既不会更快（同一次冷启动的调用配额），又白白多占 2 次配额。
    if (this.firstShowDone) {
      this.warmConnections();
    }
    this.firstShowDone = true;
    // 回到前台就释放长时任务：它是为"后台不被回收"申请的，前台还挂着只会白耗电，
    // 且通知栏会一直保留一条"正在运行"的提示。
    // 这里**不做 isActive() 判断**：onPageHide 的 acquire 可能还在队列里没跑完，
    // isActive() 此刻仍是 false，跳过 release 就会让刚申请到的任务一直留到下次切后台。
    // releaseInner 在未持有时是空操作，无条件调用只是多排一次队，却能把顺序理顺。
    BackgroundKeeper.release(this.context).catch(() => {});
    // 回前台时按"后台停留时长"决定是否重新下发代理设置：短切换不值得重置网络栈。
    // 冷启动的第一次 onPageShow 从没进过后台，此时 restore 可能刚下发过代理设置，
    // 再下发一次只会重置 ArkWeb 网络栈、打断正在进行的首屏导航。
    const reapplied: boolean = this.everHidden &&
      (this.hiddenAt === 0 || (Date.now() - this.hiddenAt) >= this.reapplyProxyAfterMs);
    this.hiddenAt = 0;
    // 回到前台：重新读设置（用户可能在面板里改过），再决定要不要重启健康探测。
    this.loadProxySettings().then(() => {
      if (this.pageDisposed) {
        return;
      }
      this.startLinkHealth();
      // 回到前台的第一件事：确认内核还活着。
      // 后台被系统回收时，状态变量仍是 RUNNING，但 127.0.0.1:7890 已经没人监听 ——
      // 这时做健康探测只会得到"探测失败"，而探测失败又触发选路，选路同样失败，永远恢复不了。
      // 所以先 recover（内核不通就重建），再做链路探测。
      if (ProxyManager.getState() === ProxyState.RUNNING) {
        ProxyManager.recover(this.context, reapplied).then((recovered: OpResult) => {
          if (this.pageDisposed) {
            return;
          }
          if (!recovered.ok) {
            this.perfMark('resumeRecoverFail', recovered.error ?? '');
            // 代理没恢复就别刷新：刷了也只会落到网络错误页，
            // 而且待补的刷新标记要留住，等真正恢复后再补。
            // 健康探测照做 —— recover 失败也可能只是"正在切换连接"，
            // 此时探测返回中性结果，不会误触发换路。
          } else {
            // 后台期间发生过换节点：那时没有刷新页面（看不见的页面刷新只是白耗资源），
            // 现在补一次，让长连接走新出口。放在 recover 之后，避免代理还没恢复就刷新。
            this.flushPendingReload();
          }
          ProxyHealth.check(this.context).then((result) => {
            // 用"连续失败达到阈值"判决，而不是单次探测结果：
            // 回前台第一次请求常因连接刚建好而偶发超时，单次失败就换路会在
            // 正常节点之间来回跳。真正的坏链路由周期探测的第二、三次失败兜住。
            if (!this.pageDisposed && ProxyHealth.isUnhealthy()) {
              this.perfMark('resumeHealthFail', result.error ?? '');
              this.onLinkDegraded();
            }
          }).catch(() => {});
        }).catch(() => {});
      } else if ((ProxyManager.getState() === ProxyState.ERROR || ProxyManager.getState() === ProxyState.IDLE) &&
        Subscriptions.isEnabled() && this.proxyStartupReady) {
        // IDLE 也重试：冷启动时 restore 可能因为一次临时失败（例如读不到本地节点）
        // 没有把内核拉起来，而用户的开启意愿还在。proxyStartupReady 保证不会和
        // 冷启动那次 restore 抢同一个内核。
        this.retryEnableAfterResume();
      }
    }).catch(() => {});
    // 订阅自动更新：按订阅声明的 profile-update-interval（未声明按 24h）判断是否到点。
    // 内部有 30 分钟节流，这里每次回前台直接调用即可；不 await，失败不影响页面。
    SubscriptionUpdater.maybeUpdate(this.context).catch(() => {});
  }

  /**
   * 出口换掉之后刷新页面，让页面上的长连接走新节点。
   *
   * 与 proxyListener 里那段刷新同源，但去掉了"必须是 RUNNING -> RUNNING"的判断：
   * 那条判断是为了区分"代理刚启动"和"运行中换节点"，而这里的调用方（选路回调）
   * 已经明确知道"出口真的变了"。后台/不可见时同样只记标记，回到前台再补。
   */
  private reloadAfterRouteChange(): void {
    if (!this.webAttached || !this.initialNavigationStarted) {
      return;
    }
    if (!this.pageVisible) {
      this.reloadPendingAfterShow = true;
      return;
    }
    this.reloadPendingAfterShow = false;
    try {
      const current: string = this.controller.getUrl();
      if (/^https?:\/\//i.test(current)) {
        this.controller.refresh();
        this.perfMark('routeReload', current);
      }
    } catch (err) {
      console.error('换路后重载失败:', JSON.stringify(err));
    }
  }

  /**
   * 网页长距离下拉 -> 重新加载当前页面。
   *
   * 只刷新 http(s) 页面：错误页、about:blank、还在加载中的页面都不重载 ——
   * 加载中重载会把正在进行的首屏导航打断，反而更慢。
   */
  private onPullRefresh(): void {
    if (this.pageDisposed || !this.pageVisible) {
      return;
    }
    const now: number = Date.now();
    if (now - this.lastPullRefreshAt < this.pullRefreshCooldownMs) {
      return;
    }
    if (!this.webAttached || !this.initialNavigationStarted) {
      return;
    }
    try {
      const current: string = this.controller.getUrl();
      if (!/^https?:\/\//i.test(current)) {
        return;
      }
      this.lastPullRefreshAt = now;
      this.controller.refresh();
      this.perfMark('pullRefresh', current);
    } catch (err) {
      console.error('下拉刷新失败:', JSON.stringify(err));
    }
  }

  /**
   * 回前台时状态已停在 ERROR：重试一次启动。
   *
   * 典型触发路径：重建内核/启动代理的过程中被切到后台，进程被冻结到就绪超时，
   * 回来时状态已是 ERROR。以前这里什么都不做，ERROR 会一直钉住，只能手动
   * 去面板里关一次再开。现在自动重试一次；是否该开代理由用户意愿
   * （Subscriptions.isEnabled）决定，不会擅自打开用户没开过的代理。
   *
   * 先等 busy 释放：回前台那一刻可能还有上一次 enable 的收尾在跑，
   * 立刻调用只会拿到"正在切换连接"。等不到就不重试，交给下一次前台/手动操作。
   */
  private retryEnableAfterResume(): void {
    this.perfMark('resumeRetryEnable');
    const deadline: number = Date.now() + 15000;
    const attempt = (): void => {
      if (this.pageDisposed) { return; }
      if (ProxyManager.isBusy() && Date.now() < deadline) {
        setTimeout(attempt, 300);
        return;
      }
      const now: ProxyState = ProxyManager.getState();
      // 等待期间状态可能已经被别处修好了（例如面板里手动开启），那就什么都不用做。
      if ((now !== ProxyState.ERROR && now !== ProxyState.IDLE) || !Subscriptions.isEnabled()) {
        return;
      }
      ProxyManager.enable(this.context, false, false).then((retried: OpResult) => {
        if (this.pageDisposed) { return; }
        if (retried.ok) {
          this.flushPendingReload();
        } else {
          this.perfMark('resumeRetryFail', retried.error ?? '');
        }
      }).catch(() => {});
    };
    // 延后一拍：让被冻结前那次 enable 的续体先跑完（它可能刚好失败并落定 ERROR）。
    setTimeout(attempt, 300);
  }

  /** 补做后台期间被推迟的刷新；失败不影响功能（页面自己也会建连）。 */
  private flushPendingReload(): void {
    if (!this.reloadPendingAfterShow || this.pageDisposed) {
      return;
    }
    // 仍不可见（例如后台里网络刚好恢复）就继续挂着，回到前台再刷。
    if (!this.pageVisible) {
      return;
    }
    this.reloadPendingAfterShow = false;
    if (!this.webAttached || !this.initialNavigationStarted) {
      return;
    }
    try {
      const current: string = this.controller.getUrl();
      if (/^https?:\/\//i.test(current)) {
        this.controller.refresh();
        this.perfMark('deferredReload', current);
      } else {
        this.controller.loadUrl(this.currentUrl);
        this.perfMark('deferredReload', this.currentUrl);
      }
    } catch (err) {
      console.error('延后刷新失败:', JSON.stringify(err));
    }
  }

  onPageHide(): void {
    this.perfMark('pageHide');
    this.pageVisible = false;
    this.everHidden = true;
    this.hiddenAt = Date.now();
    this.setWebActive(false);
    // 进后台前的收尾：健康探测在后台没有意义（探测本身要占 CPU），
    // 但代理链路必须保持，否则回来就是"网页在、网不通"。
    ProxyHealth.stop();
    // 用存储层的同步快照，而不是 this.proxySettings：用户可能刚在面板里
    // 改了开关但面板还没关闭（onDisappear 不会触发），内存副本就是旧的。
    const cached: ProxySettings | null = ProxySettingsStore.cached();
    if (cached !== null) {
      this.proxySettings = cached;
    }
    // STARTING 也要保活：这段时间正在重建内核，进程一被冻结重建就断在半路，
    // 回来时既没有可用内核、状态又停在 ERROR —— 正是"后台回来网不通"的一种。
    // ERROR 不在其列：那里没有"正在进行的工作"需要保住，回前台会重试启动；
    // 而配置本身坏掉时（订阅无效、内核起不来）一直续期只会白占一条常驻任务。
    const state: ProxyState = ProxyManager.getState();
    const wantsProxy: boolean = state === ProxyState.RUNNING || state === ProxyState.STARTING;
    if (this.proxySettings.keepAliveInBackground && wantsProxy) {
      BackgroundKeeper.acquire(this.context).then((r) => {
        if (!r.ok) {
          this.perfMark('keepAliveFail', r.error ?? '');
        }
      }).catch(() => {});
    }
  }

  /**
   * 预连接主站与登录域。
   *
   * 官方约束：同一次冷启动调用不超过 5 次，且两次调用间隔需大于 150ms。
   * 所以第二个域必须延后发出，不能和第一个背靠背（间隔 0ms 会违反约束）。
   * 回到前台是低频事件，这点延迟无感；失败只记日志，预连接本身只是优化。
   */
  private warmConnections(): void {
    try {
      webview.WebviewController.prepareForPageLoad(HOME_ORIGIN, true, 6);
      this.perfMark('warmConnections', HOME_ORIGIN);
    } catch (error) {
      console.warn('回到前台预连接失败: ' + JSON.stringify(error));
    }
    setTimeout(() => {
      if (this.pageDisposed) {
        return;
      }
      try {
        webview.WebviewController.prepareForPageLoad(AUTH_ORIGIN, true, 6);
      } catch (error) { /* 预热失败不影响功能 */ }
    }, 200);
  }

  /** 按当前设置启动周期健康探测；间隔为 0 或关闭开关时不启动。 */
  private startLinkHealth(): void {
    if (this.pageDisposed) {
      return;
    }
    // 后台不探测：onPageHide 里已经停掉，但代理状态回调（例如自动选路完成）
    // 也可能在后台把探测重新拉起来 —— 那会在后台白耗 CPU，还可能触发一次
    // 后台换节点 + 刷新。回到前台时 onPageShow 会重新启动。
    if (!this.pageVisible) {
      return;
    }
    if (!this.proxySettings.autoSwitchOnDegrade || this.proxySettings.healthCheckIntervalMs <= 0) {
      ProxyHealth.stop();
      return;
    }
    // 不做 isRunning() 早退：ProxyHealth.start 内部已做幂等处理，
    // 而且重复调用需要刷新回调 —— 页面重建后旧回调还指向上一个已销毁的实例。
    ProxyHealth.start(this.proxySettings.healthCheckIntervalMs, 2, (healthy: boolean) => {
      if (!healthy && !this.pageDisposed) {
        this.perfMark('healthDegraded', 'consecutive failures reached threshold');
        this.onLinkDegraded();
      }
    });
  }

  // active=true → onActive()（恢复出帧与 JS 定时器）；false → onInactive()（挂起渲染，省电且不抢 CPU）。
  // controller 未绑定（17100001）或页面已销毁时直接跳过：这两个 API 都会抛异常。
  private setWebActive(active: boolean): void {
    if (!this.webAttached) {
      return;
    }
    try {
      if (active) {
        this.controller.onActive();
      } else {
        this.controller.onInactive();
      }
    } catch (error) {
      console.error('setWebActive异常 active=' + active + ': ' + JSON.stringify(error));
    }
  }

  aboutToDisappear(): void {
    this.pageDisposed = true;
    NetworkWatcher.stop();
    ProxyManager.unsubscribe(this.proxyListener);
    // dispose 而不是 stop：页面销毁后静态回调还指着这个实例会延长它的存活期，
    // 而 stop 只停表（start 重建计时器时也要用它，不能清回调）。
    ProxyHealth.dispose();
    BackgroundKeeper.release(this.context).catch(() => {});
    // 释放权限弹窗互斥锁：页面销毁时挂起的 showDialog promise 可能不会再回来，
    // 不显式复位的话，若本页被重新创建而复用了同一实例状态，后续权限请求会被一直拒绝。
    this.permissionDialogShowing = false;
    EmitterUtil.off<number>('affffa', this.onDownloadEvent);
    webview.WebCookieManager.saveCookieAsync((error) => {
      if (error) {
        console.error('Cookie保存失败: ' + error.code + ',  ' + error.message);
      }
    })
  }

  build() {
    // 外层用 Stack：底层是原有的 Web 容器，上层叠一个贴右边缘的代理浮窗。
    // 为什么用 Stack 而不是在 Column 里加子节点：
    //   浮窗要"浮"在网页之上、贴右边缘、且不参与 Web 的布局计算。
    //   若放进 Column，会挤占 Web 的 layoutWeight 空间、改变网页视口宽度，
    //   进而触发网页重排（ChatGPT 是响应式的，宽度变化会重算布局）。
    Stack({ alignContent: Alignment.TopEnd }) {
      Column() {
      // src 置空：首次导航延后到 onControllerAttached 里设完 UA 再用 loadUrl 发起，
      // 避免"先按默认 UA 加载一遍、再设 UA 刷新一遍"的整页二次加载
      Web({ src: '', controller: this.controller })
            .layoutWeight(1)
            // 【手势拦截：修复"侧边栏/列表滑动不滚动、像在用鼠标拖拽"】
            //
            // 真机实测链条（Pura 80 Ultra / API 26）：
            //   · 在侧边栏列表里上下滑 -> 网页侧一个 scroll 事件都不产生（注入探针实测）
            //   · hilog 里出现 LongPressRecognizer 命中、"LongPress move over max threshold"，
            //     随后 "AceDrag Trigger pan onReject / Drag event canceled"
            //   · 触摸事件本身是正常的（OnTouchPress/OnTouchMove 齐全，pointerType=touch）
            // 结论：网页没坏，是 ArkUI 在 Web 组件上**内置的拖拽(PAN)/长按手势识别器**
            //       抢先接受了这串触摸，事件被判给手势系统，Web 内部的滚动就不再发生，
            //       表现就是"用手指拖着一个东西移动"，而不是手机原生的滚动。
            //
            // 修法：用 onGestureRecognizerJudgeBegin 做手势裁判 ——
            //   凡是落在 Web 区域上的 PAN（拖拽）与 LONG_PRESS，一律 REJECT，
            //   让触摸完整回流给 Web 内核，由内核按移动端规则处理滚动与长按。
            //   只拦这两类：点击(TAP)、滑动翻页等其它手势不受影响，避免影响正常交互。
            //
            // 【为什么不继续用 monopolizeEvents】之前试过它，真机上实测
            //   "monopolize on by node id:secure_field" —— 作用到了输入框的安全字段上，
            //   侧边栏滚动依旧不生效，说明它解决的不是这条链路。
            .onGestureRecognizerJudgeBegin((event: BaseGestureEvent, current: GestureRecognizer) => {
              try {
                const t: number = current.getType();
                // 只拒绝"拖拽类"手势：PAN(2) 与 DRAG(6)，以及长按(1)。
                // TAP(0)/SWIPE(4)/PINCH(3) 等保持 CONTINUE，避免影响点击与缩放。
                if (t === GestureControl.GestureType.PAN_GESTURE ||
                    t === GestureControl.GestureType.DRAG ||
                    t === GestureControl.GestureType.LONG_PRESS_GESTURE) {
                  return GestureJudgeResult.REJECT;
                }
              } catch (err) {
                // 取类型失败时不做拦截，保持系统默认行为
              }
              return GestureJudgeResult.CONTINUE;
            })
            // 【顶部避让状态栏】
            // 系统状态栏是**显示**的（EntryAbility 里 setSpecificSystemBarEnabled('status', true)），
            // 必须给它让出高度，否则网页顶栏会被时间/电量压住 —— 这正是最初报告的"顶部重叠"问题。
            // 父容器（下面的 Column）默认避开顶部安全区，Web 作为子节点继承该内缩，
            // 所以布局上 Web 已经从 y=状态栏高度 开始（真机实测 bounds=[0,133][1276,2848]）。
            //
            // 【为什么不再写任何 expandSafeArea / ignoreLayoutSafeArea】
            // expandSafeArea 只改变"绘制区域"，不改变布局。在 Web（独立合成层）上使用它，
            // 会让内核把图层向上/向下扩张后重绘，合成时出现内容回填 ——
            // 真机像素分析证实：布局起点 y=133 正确，但 y=80~100 仍有横跨全屏的网页内容，
            // 与状态栏图标（y=64~112）重叠。去掉这两个修饰器后，Web 就老老实实只画在自己的布局框内。
            // 代价：网页底色不再延伸到最底部导航条后面。相比"顶部内容被状态栏压住"，这个取舍是值得的。
            // ==================== 处理url scheme跳转外部应用 ====================
            .onLoadIntercept((event) => {
              if (!event) {
                return false;
              }
              const requestUrl: string = event.data.getRequestUrl();
              // 首字母预判：绝大多数导航(https 开头的 h、r 等)在这里直接短路，不再跑 6 次 indexOf。
              // 注意 'h' 仍要放行，因为 QQ 登录链接是 https 前缀，需要往下走一次比较。
              if (!mayBeExternalScheme(requestUrl)) {
                return false;
              }
              // 只取一次子串做前缀比较，避免对整条 URL 反复做 indexOf(0)
              const head: string = requestUrl.length > 32 ? requestUrl.substring(0, 32) : requestUrl;
              // tel:// 必须先判，否则会被 tel: 分支吞掉（原实现用两次 indexOf 做排除，语义等价的表驱动写法）
              let scheme: string = '';
              if (head.indexOf(SCHEME_MAILTO) === 0) {
                scheme = SCHEME_MAILTO;
              } else if (head.indexOf('tel://') === 0) {
                scheme = 'tel://';
              } else if (head.indexOf(SCHEME_TEL) === 0) {
                scheme = SCHEME_TEL;
              } else if (head.indexOf(SCHEME_SMS) === 0) {
                scheme = SCHEME_SMS;
              } else if (head.indexOf(SCHEME_WEIXIN) === 0) {
                scheme = SCHEME_WEIXIN;
              } else if (head.indexOf(SCHEME_QQ_LOGIN) === 0) {
                scheme = SCHEME_QQ_LOGIN;
              }
              if (scheme.length === 0) {
                return false;  // 命中首字母但不在 scheme 表里：直接放行，不做任何分配
              }
              this.dispatchExternalScheme(scheme, requestUrl);
              return true;
            })
            // ==================== 处理url scheme跳转外部应用 处理结束 ====================
            .onContextMenuShow((event) => {
              try {
                if (!event) {
                  return false;
                }
                // 先在普通字段里算好全部内容，最后一次 showMenu=true 触发唯一一次 UI 刷新。
                // 原实现逐项写 6 个 @State，长按一次要触发 6 轮状态通知与重建。
                const st: ContextMenuState = this.menuState;
                st.linkUrl = event.param.getLinkUrl();
                const srcUrl: string = event.param.getSourceUrl();
                if (srcUrl) {
                  st.imageUrl = srcUrl;
                }
                if (event.param.isEditable()) {
                  st.currentType = MenuType.EDITABLE;
                  st.menuHeight = 200;
                } else if (event.param.getMediaType() === 1) {
                  st.currentType = MenuType.IMAGE;
                  st.menuHeight = 100;
                } else if (event.param.getSelectionText().length > 0) {
                  st.currentType = MenuType.SELECTION;
                  st.menuHeight = 50;
                } else if (event.param.getUnfilteredLinkUrl().length > 0) {
                  st.currentType = MenuType.LINK;
                  st.menuHeight = 100;
                } else {
                  // 空白处长按：交给系统默认菜单，不弹自定义菜单（也就不触发任何状态更新）
                  return false;
                }
                this.result = event.result;
                const winWidth: number = AppStorage.get<number>('win.widthPx') ?? 0;
                const winHeight: number = AppStorage.get<number>('win.heightPx') ?? 0;
                // 位置直接算给 @State（popup 的 offset 绑定它们），最后一次性打开 showMenu，
                // 避免 offset 先用旧值闪一帧。
                this.menuOffsetX = this.uiContext.px2vp(event.param.x() - winWidth / 2) + 50;
                this.menuOffsetY = this.uiContext.px2vp(event.param.y() - (winHeight - titleBlankHeight) / 2) + st.menuHeight / 2;
                this.showMenu = true;
                return true;
              } catch (error) {
                console.error('onContextMenuShow异常:', JSON.stringify(error));
                return false;
              }
            })
            // 【注意】上下文菜单的 bindPopup 已从 Web 上移到外层 Column（见 build 末尾）。
            // 原因：bindPopup 是 Web 的修饰器时，showMenu 每次变化都会让整个 build() 重跑，
            // 而 build() 里挂了 19 个 Web 事件回调，全部要重新创建闭包并重新下发原生侧 ——
            // 长按一次（开+关）就是两轮这样的重建，是"长按菜单有点卡"的直接原因。
            // 移到外层容器后，菜单开合只重建 popup 挂载点，Web 子树保持不动。
            .onControllerAttached(() => {
              this.perfMark('controllerAttached');
              this.webAttached = true;
              // 第三方 Cookie 放开（auth.openai.com 登录态依赖）——必须在 loadUrl 之前
              try {
                webview.WebCookieManager.putAcceptThirdPartyCookieEnabled(true);
              } catch (error) {
                console.error('开启第三方Cookie异常:', JSON.stringify(error));
              }
              // BFCache 容量：enableBackForwardCache 已在 MyAbilityStage 里打开了 BFCache，
              // 但**只开开关不改配置时容量默认是 1**（SDK：Default is 1, max is 50），
              // 也就是说前进/后退栈里只有最近一页能被整个实例缓存住，再往前的页面就得重新走
              // 完整加载（网络 + 解析 + JS 执行）——表现出来就是"点返回要等好几秒、还丢滚动位置"。
              // 这里把容量调到 3：覆盖"主页 → 会话 A → 会话 B 再返回"这种最常见的两跳场景，
              // 又不至于把整棵页面树留太多份（每份都是真实内存占用）。
              this.applyBackForwardCacheOptions();

              // UA → loadUrl：一次到位。原先 setCustomUserAgent 后延迟 300ms refresh()
              // 会让 chatgpt.com 整页加载两遍（基线 hilog 已证实），是冷启动最大的浪费。
              if (this.proxyStartupReady && !this.initialNavigationStarted) {
                this.initialNavigationStarted = true;
                this.applyUaAndLoad();
              }
              // 【下载委托不在这里同步创建】之前这里紧接着调用 ensureDownloadDelegate()，
              // 它要 lazy import 求值 delegate 模块 + 一次跨进程 setDownloadDelegate IPC + 注册 4 个回调，
              // 全部发生在主线程、且刚好卡在"loadUrl 已发出、网络正在等待"的那段时间里。
              // 下载功能只有用户真的点下载时才用得到，没必要占用冷启动。改为延后到 onPageEnd 之后再创建。
            })
            .onPageBegin((event) => {
              if (/^https?:\/\//i.test(event.url)) { this.currentUrl = event.url; }
              this.perfMark('pageBegin', event.url);
            })
            .onPageEnd((event) => {
              this.perfMark('pageEnd', event.url);
              // 页面成功加载完成 = 渲染进程已恢复正常，把崩溃重载计数清零。
              // 不清零的话计数只增不减，用久了到达上限后就再也不会自动恢复（永久白屏）。
              if (this.renderReloadCountForCrashed !== 0) {
                this.renderReloadCountForCrashed = 0;
              }
              if (this.renderReloadCountForOthers !== 0) {
                this.renderReloadCountForOthers = 0;
              }
              // 下载委托延后到首屏加载完成后再装配：此时用户已经看到内容，
              // 模块求值 + setDownloadDelegate IPC 赶不上也不影响体验。
              // 【为什么这里不担心"下载丢失"】委托只在 onPageEnd 才注册，理论上存在窗口：
              // 若网页在 onPageEnd 之前就自动触发下载（如 PDF 直链），请求会没有接收方。
              // 但 onPageEnd 的语义是"主框架加载完成"，而下载由用户点击 / 页面脚本触发，
              // 正常浏览路径上必然晚于 onPageEnd；且下面 FirstContentfulPaint 里还会再做一次
              // 幂等装配（见该回调注释），两条路径谁先到谁生效。
              this.ensureDownloadDelegate();
              // 为"未来才打开的页面"预取：首屏已结束，此时预取的网络开销不占关键路径，
              // 而用户点 SSO 登录时能直接命中缓存（见 prefetchNextPage 的实测依据）。
              this.prefetchNextPage();
            })
            .onFirstContentfulPaint((event) => {
              this.perfMark('FCP', 'fcp=' + event.firstContentfulPaintMs + 'ms navTick=' + event.navigationStartTick);
              // FCP 兜底装配下载委托：它一定早于任何用户交互，也覆盖了"主框架 onPageEnd 未触发"
              // （例如页面一直有资源在加载）这一边界。与 onPageEnd 那条路径互为补充，
              // ensureDownloadDelegate 幂等，重复调用不会重复注册回调。
              this.ensureDownloadDelegate();
            })
            .onPermissionRequest((event) => {
              if (event) {
                console.info('收到权限请求:', event.request.getOrigin());
                const resources = event.request.getAccessibleResource();
                console.info('请求的资源:', JSON.stringify(resources));

                if (this.permissionsGranted) {
                  event.request.grant(resources);
                  console.info('自动授予权限');
                  return;
                }
                this.grantIfSystemAllowed(event, resources);
              }
            })
            .backgroundColor(this.webBg)
            .darkMode(WebDarkMode.Auto)
            .domStorageAccess(true)
            .onlineImageAccess(true)
            .imageAccess(true)
            .fileAccess(true)
            .javaScriptAccess(true)
            // 已移除 databaseAccess(true)：它是 Web SQL Database 的开关，
            // 而 SDK 文档明确写"ArkWeb 内核升级到 M132 后该 API 对 Web SQL 的控制已失效（内核已移除 Web SQL）"。
            // 也就是说这一行在新内核上是个空操作，留着只会让人误以为它在生效。
            // 注意：真正被 chatgpt.com 依赖的存储是 localStorage / IndexedDB —— 前者由上面的
            // domStorageAccess(true) 负责（默认关闭，必须显式打开），后者默认可用，都不受这行影响。
            .copyOptions(CopyOptions.LocalDevice)
            .mixedMode(MixedMode.All)
            .horizontalScrollBarAccess(false)
            .verticalScrollBarAccess(false)
            // 过滚回弹：显式钉死为 NEVER（关闭）。
            // 注意：SDK 文档写明该属性**默认值就是 NEVER**，所以这一行本身不产生新的性能收益，
            // 它的价值是把"边界回弹动画 + 边缘光效会额外出帧"这个坑钉住，避免以后有人为了手感
            // 改成 ALWAYS 却不知道代价（滑到头会多一层回弹动画，观感上像卡一下）。
            .overScrollMode(OverScrollMode.NEVER)
            // JS 桥：网页通过 window.ohosBridge 调用原生。
            // 传的是成员字段（创建一次），不是内联字面量 —— 见 jsProxyConfig 的注释。
            .javaScriptProxy(this.jsProxyConfig)
            // documentStart：主题上报
            // 用 runJavaScriptOnDocumentStart（API 15+）而不是 javaScriptOnDocumentStart：
            // 后者按字典序执行脚本，前者严格按数组顺序，注入顺序才是确定可控的。
            .runJavaScriptOnDocumentStart(DOC_START_SCRIPTS)
            // documentEnd：视口补丁 + 隐藏横幅 + 长会话渲染减负
            .runJavaScriptOnDocumentEnd(DOC_END_SCRIPTS)
            // 多窗口：OAuth 登录弹窗承载 window.open
            .multiWindowAccess(true)
            .allowWindowOpenMethod(true)
            .onWindowNew((event) => {
              if (!event) {
                return;
              }
              if (this.oauthVisible) { event.handler.setWebController(null); return; }
              this.previewController = new webview.WebviewController();
              // 必须在 onWindowNew 内立即关联尚未挂载的 controller。
              // 等到 onControllerAttached 才关联会卡住新窗口，连带阻塞网页弹窗。
              event.handler.setWebController(this.previewController);
              this.oauthUrl = event.targetUrl;
              this.oauthVisible = true;
            })
            // 文件/图片/拍照选择器
            .onShowFileSelector((event) => {
              if (!event) {
                return false;
              }
              try {
                const acceptTypes: Array<string> = event.fileSelector.getAcceptType();
                let hasImage: boolean = false;
                let hasVideo: boolean = false;
                let hasOther: boolean = false;
                for (let i = 0; i < acceptTypes.length; i++) {
                  const t: string = acceptTypes[i].toLowerCase();
                  if (t.indexOf('image/') === 0 || t === 'image/*') {
                    hasImage = true;
                  } else if (t.indexOf('video/') === 0) {
                    hasVideo = true;
                  } else if (t.length > 1 && t.charAt(0) === '.') {
                    const ext: string = t.substring(1);
                    // Set.has 是 O(1)：原先 Array.indexOf 在 accept 有两三百项时会退化成 O(n²)
                    if (IMAGE_EXTS.has(ext)) {
                      hasImage = true;
                    } else if (VIDEO_EXTS.has(ext)) {
                      hasVideo = true;
                    } else {
                      hasOther = true;
                    }
                  } else {
                    hasOther = true;
                  }
                }
                const isCapture: boolean = event.fileSelector.isCapture();
                console.info('onShowFileSelector accept=' + JSON.stringify(acceptTypes) + ' capture=' + isCapture + ' image=' + hasImage + ' video=' + hasVideo + ' other=' + hasOther);
                if (isCapture) {
                  // 网页带 capture 属性：直接拉起系统相机拍照（无需相机权限，安全控件机制）
                  const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
                  const profile: cameraPicker.PickerProfile = new cameraPicker.PickerProfile();
                  cameraPicker.pick(context, [cameraPicker.PickerMediaType.PHOTO], profile).then((result: cameraPicker.PickerResult) => {
                    try {
                      if (result.resultCode === 0 && result.resultUri && result.resultUri.length > 0) {
                        event.result.handleFileList([result.resultUri]);
                      }
                    } catch (err) {
                      console.error('相机结果回填异常:', JSON.stringify(err));
                    }
                  }).catch((err: BusinessError) => {
                    console.error('相机拍照失败: ' + err.code + ', ' + err.message);
                    // 拍照异常必须回填空列表：否则网页的 <input type=file> 会一直处于"等待选择"状态，
                    // 后续点击再无反应（观感就是"点上传没反应/卡死"）
                    this.notifyFileSelectorAbort(event);
                  });
                } else if (hasImage || hasVideo) {
                  // 图片/视频选择：PhotoViewPicker（系统相册，含图片+视频混合列表）
                  const photoPicker = new photoAccessHelper.PhotoViewPicker();
                  const photoOptions = new photoAccessHelper.PhotoSelectOptions();
                  photoOptions.MIMEType = hasVideo
                    ? photoAccessHelper.PhotoViewMIMETypes.IMAGE_VIDEO_TYPE
                    : photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
                  photoOptions.maxSelectNumber = 9;
                  photoPicker.select(photoOptions).then((result: photoAccessHelper.PhotoSelectResult) => {
                    try {
                      event.result.handleFileList(result.photoUris);
                    } catch (e) {
                      console.error('handleFileList异常:', JSON.stringify(e));
                    }
                  }).catch((err: BusinessError) => {
                    console.error('图片选择失败: ' + err.code + ', ' + err.message);
                    this.notifyFileSelectorAbort(event);
                  });
                } else {
                  // 文档选择：DocumentViewPicker
                  const docPicker = new picker.DocumentViewPicker();
                  const docOptions = new picker.DocumentSelectOptions();
                  docOptions.maxSelectNumber = 9;
                  docPicker.select(docOptions).then((uris: Array<string>) => {
                    try {
                      event.result.handleFileList(uris);
                    } catch (e) {
                      console.error('handleFileList异常:', JSON.stringify(e));
                    }
                  }).catch((err: BusinessError) => {
                    console.error('文档选择失败: ' + err.code + ', ' + err.message);
                    this.notifyFileSelectorAbort(event);
                  });
                }
              } catch (error) {
                console.error('文件选择器异常:', JSON.stringify(error));
                return false;
              }
              return true;  // 同步返回 true，异步回填选择结果
            })
            .onVisibleAreaChange([0, 1.0], (isVisible: boolean) => {
              this.webIsVisible = isVisible;
              // 可见性变化回调里不能保证 controller 已绑定：未绑定就 loadUrl 会抛 17100001
              if (isVisible && this.needReloadWhenVisible && this.webAttached) {
                this.needReloadWhenVisible = false;
                this.reloadAfterRenderExit();
              }
            })
            .onRenderExited((event) => {
              if (!event) {
                return;
              }
              try {
                // 崩溃/被杀后的重载上限，防止渲染进程持续崩溃时无限重载把应用拖死。
                // 关键点：计数必须在校验通过后、真正重载前推进，并且用户手动导航成功后清零，
                // 否则计数只增不减，用久了就再也无法从渲染进程退出中恢复（表现为页面永久白屏）。
                if (event.renderExitReason === RenderExitReason.ProcessCrashed) {
                  if (this.renderReloadCountForCrashed >= this.renderReloadMaxForCrashed) {
                    console.error('渲染进程崩溃重载次数已达上限: ' + this.renderReloadCountForCrashed);
                    return;
                  }
                  this.renderReloadCountForCrashed++;
                  // 崩溃重载是低频事件，这条日志对排查"页面白屏后是否恢复过"很有用，保留；
                  // 统一用 warn 级别（与相邻的 error 一致），不再用 console.log。
                  console.warn('渲染进程崩溃重载次数: ' + this.renderReloadCountForCrashed);
                } else {
                  if (this.renderReloadCountForOthers >= this.renderReloadMaxForOthers) {
                    console.error('渲染进程退出重载次数已达上限: ' + this.renderReloadCountForOthers);
                    return;
                  }
                  this.renderReloadCountForOthers++;
                  console.warn('渲染进程退出重载次数: ' + this.renderReloadCountForOthers);
                }
                // 页面不可见时 loadUrl 会被内核丢弃：先记账，回到可见再补，避免"回来一片空白"
                if (!this.webIsVisible) {
                  this.needReloadWhenVisible = true;
                  return;
                }
                this.reloadAfterRenderExit();
              } catch (err) {
                console.error('onRenderExited异常:', JSON.stringify(err));
              }
            })
            // 主框架 HTTP 5xx 错误 → 本地错误页
            .onHttpErrorReceive((event) => {
              if (!event) {
                return;
              }
              try {
                if (event.request.isMainFrame() && event.response.getResponseCode() >= 500) {
                  this.loadErrorPage(event.request.getRequestUrl(), event.response.getResponseCode());
                }
              } catch (error) {
                console.error('onHttpErrorReceive异常:', JSON.stringify(error));
              }
            })
            // 主框架加载错误 → 本地错误页
            .onErrorReceive((event) => {
              if (!event) {
                return;
              }
              try {
                // 子资源请求失败也会回调这里：原先无条件 JSON.stringify(event) 发生在主线程，
                // 重载页面（长会话）时失败请求很多，会直接放大卡顿。改为主框架才处理。
                if (event.request.isMainFrame()) {
                  const code: number = event.error.getErrorCode();
                  const failUrl: string = event.request.getRequestUrl();
                  console.error('onErrorReceive mainFrame code=' + code + ' url=' + failUrl);
                  this.loadErrorPage(failUrl, code);
                }
              } catch (error) {
                console.error('onErrorReceive处理异常:', JSON.stringify(error));
              }
            })
            // 【注意】OAuth 半模态的 bindSheet 也已移到外层 Column（见 build 末尾）。
            // 与 bindPopup 同理：挂在 Web 上时，oauthVisible 每次变化都会让 build() 重跑，
            // 把 Web 上 19 个事件回调全部重建并重新下发。而 OAuth 的 open/close
            // 恰好发生在"点击登录按钮 -> 等待弹窗"这个最敏感的交互上，代价更高。
      }
      // 容器布局：占满整屏；顶部显式让出系统状态栏高度。
      //
      // 【历史坑，勿重蹈】
      // 1) 曾用 .padding({ bottom: '100%' })：百分比基准是**父容器宽度**（1256px），
      //    与 height('100%') 叠加后容器高达 1.45 屏 —— "下半部分空白"就是这么来的，已删除。
      // 2) 曾以为"父容器默认会避开安全区"就够了：真机实测**不成立** ——
      //    UI 树里 Web 的 bounds 确实是 [0,133][…]（布局正确），但截图里网页顶栏「聊天」
      //    却画在 y≈70，即【布局坐标对、渲染内容上移约 63px】，直接压到状态栏时间/电量上。
      //    根因是 ArkWeb 的视口高度按"整屏"计算，容器没有真正内缩它。
      // 3) 现在的做法：读取状态栏高度（EntryAbility 已写入 AppStorage 'insets.top'，单位 px），
      //    换算成 vp 后作为容器顶部内边距。这是唯一能同时约束【布局】和【Web 视口尺寸】的方式，
      //    网页拿到的是"整屏减去状态栏"的正确高度，顶栏自然落在状态栏下方。
      .padding({ top: this.statusBarTopVp() })
      .width('100%')
      .height('100%')
      .backgroundColor(this.webBg)
      // 上下文菜单挂在外层容器上（不再挂在 Web 上）。
      // 位置用 @State 承载（menuOffsetX/Y），只有它变化时才重建这里，Web 子树完全不受影响。
      .bindPopup(this.showMenu,
        {
          builder: this.MenuBuilder(),
          enableArrow: false,
          placement: Placement.RightBottom,
          offset: { x: this.menuOffsetX, y: this.menuOffsetY },
          mask: false,
          onStateChange: (e) => {
            if (!e.isVisible) {
              this.hideMenu();
              // 原实现用 this.result! 非空断言：result 尚未赋值时（极端时序）会直接崩。
              // 这里判空后关闭，并把引用置空，避免握住已经失效的结果对象。
              const r: WebContextMenuResult | undefined = this.result;
              this.result = undefined;
              if (r !== undefined) {
                try {
                  r.closeContextMenu();
                } catch (err) {
                  console.error('closeContextMenu异常:', JSON.stringify(err));
                }
              }
            }
          }
        })
      // OAuth 半模态也挂在外层容器上（同样不再挂在 Web 上）。
      // oauthVisible 变化只会影响这里的 sheet，不会牵动 Web 及其 19 个回调。
      .bindSheet($$this.oauthVisible, this.OAuthSheetBuilder(), {
        height: SheetSize.MEDIUM,
        detents: [SheetSize.MEDIUM, SheetSize.LARGE],
        dragBar: true,
        showClose: true,
        backgroundColor: this.sysIsDark ? '#171717' : '#FFFFFF',
        onDisappear: () => {
          this.popupController = undefined;
        }
      })

      // ===== 代理浮窗（叠在 Web 之上，贴右边缘）=====
      // 三段式交互：贴边只露一个角 -> 点击展开 -> 再点击进设置页。
      // 组件内部自己持有展开状态，展开/收起只重建浮窗自身，不影响 Web 子树。
      ProxyFab({
        proxyState: this.proxyState,
        isDark: this.sysIsDark,
        onOpenSettings: () => {
          this.proxyPanelVisible = true;
        }
      })
      // 【点击命中说明（踩过坑）】
      // 曾写 .hitTestBehavior(HitTestMode.Transparent) 想让事件穿透到 Web，
      // 结果浮窗自己也收不到点击 —— Transparent 表示"本节点不参与命中测试，
      // 事件直接交给下层"，于是 onClick 永远不触发。
      // 现在用默认的 HitTestMode.Default：浮窗区域自己处理，其余区域正常落到 Web。
      // 浮窗宽度只有几十 vp，对网页遮挡极小，不需要事件穿透。
    }
    // 【重要】关闭裁剪：浮窗贴在最右边缘，边框与阴影会有 1~6vp 的视觉外扩。
    // Stack 默认 clip(true) 会把超出边界的部分裁掉，之前"浮窗右半看不见"就是这个原因。
    // 关掉裁剪后，浮窗完整可见、点击区域也正确。
    .clip(false)
    // 代理设置面板：做成半模态，不打断网页状态（返回后 Web 仍在原位置）
    // 代理设置面板：官方 bindSheet（从下往上弹出）
    // 配置要点：
    //   · SheetSize.LARGE：占大部分屏幕，便于浏览上百个节点
    //   · dragBar: true：顶部拖动条，可下滑关闭
    //   · showClose: true：使用系统自带的沉浸式关闭按钮（不用自绘 ✕，避免重复）
    //   · 背景色跟随主题：深色下用黑底，浅色下用浅灰底，与面板内部配色一致
    .bindSheet($$this.proxyPanelVisible, this.ProxyPanelBuilder(), {
      height: SheetSize.LARGE,
      dragBar: true,
      // showClose 关掉：系统会把关闭按钮浮在内容右上角、压住"启用代理"卡片。
      // 面板内部标题栏已自带右对齐关闭按钮，布局更干净。
      showClose: false,
      backgroundColor: this.sysIsDark ? '#000000' : '#F2F2F7',
      blurStyle: BlurStyle.NONE,
      preferType: SheetType.BOTTOM,
      onDisappear: () => {
        if (this.pageDisposed) { return; }
        // 关闭后同步一次浮窗颜色与实际代理状态
        this.proxyState = ProxyManager.getState();
        // 面板里改的开关要立刻生效：bindSheet 的关闭不会触发 onPageShow，
        // 不在这里重读的话，用户关掉"后台保持连接"后要等下次前后台切换才生效。
        this.loadProxySettings().then(() => {
          if (this.pageDisposed) { return; }
          this.startLinkHealth();
          // 不做 isActive() 判断：队列里可能有一次还没跑完的 acquire，
          // 此刻 isActive() 仍是 false，跳过就会留下一条前台不需要的常驻任务。
          if (!this.proxySettings.keepAliveInBackground) {
            BackgroundKeeper.release(this.context).catch(() => {});
          }
        }).catch(() => {});
      }
    })
  }

  /** 代理设置面板的构建器。 */
  @Builder
  ProxyPanelBuilder() {
    ProxySettingsPanel({
      isDark: this.sysIsDark,
      onClose: () => {
        this.proxyPanelVisible = false;
      },
      onStateChanged: (s: ProxyState) => {
        // 面板的生命周期可能比页面长一截（销毁时 onDisappear 会晚一拍），
        // 这期间写 @State 会落到已销毁的页面上。
        if (this.pageDisposed) { return; }
        this.proxyState = s;
      }
    })
  }
}
