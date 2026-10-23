# Bowen_ArkWeb ChatGPT 套壳应用 适配说明

## 项目简介

本项目基于 **Bowen_ArkWeb_framework**（一个基于 ArkWeb 深度开发的 HTML 嵌入式鸿蒙软件框架）适配 **ChatGPT**（chatgpt.com）的鸿蒙套壳应用。无需官方原生客户端，即可在鸿蒙设备上获得接近原生 App 的 ChatGPT 使用体验。

* 目标站点：`https://chatgpt.com`（登录域 `https://auth.openai.com`）
* 应用包名 bundleName：`com.bowen.chatgpt`
* 支持设备：phone / tablet / 2in1 / wearable
* 已内置权限：INTERNET（网络）、GET_NETWORK_INFO（网络状态）、MICROPHONE（麦克风，语音模式）、CAMERA（相机，拍照上传）、PRINT（打印框架）

## 各页面适配清单

| 页面 / 场景 | 适配点 |
| --- | --- |
| 登录/注册（auth.openai.com，含 Google / Apple / Microsoft SSO） | 开启第三方 Cookie 支持，保证 SSO 登录态持久化；OAuth 授权弹窗由原生 `bindSheet` 半模态承载，避免弹窗丢失或白屏 |
| 主聊天页 | 沉浸式全屏窗口 + 安全区避让（`expandSafeArea`）；键盘采用 OFFSET 模式整体上移避让，避免输入框被二次避让顶到屏幕顶部；JS 注入隐藏页面顶部"下载 App"横幅 |
| 侧边栏 | 直接使用 ChatGPT 网页自带的会话侧边栏（原生侧栏方案已移除） |
| 语音模式 | 麦克风权限双授权：系统权限（`requestPermissionsFromUser`）+ 应用内 `onPermissionRequest` 二次授权，任一未授权均给出引导 |
| 附件上传/拍照 | `onShowFileSelector` 智能路由：带 `capture` 拉起系统相机拍照（cameraPicker）；图片走系统相册（PhotoViewPicker）；其余走文档选择器（DocumentViewPicker） |
| 生成内容下载 | 原框架下载委托（`onDownloadStart`）+ `DownloadConfirmDialog` 下载确认弹窗，安全保存导出的文件 |
| 分享页 / 历史会话 | 正常加载；返回键优先执行网页后退（`accessStep(-1)` / `backward`），不直接退出应用 |
| 外部链接 | 默认在应用内打开，保持浏览连续性；长按菜单提供「在系统浏览器打开」，mailto/tel/sms 等协议自动拉起对应系统应用 |
| 断网 / 5xx 错误页 | 自定义错误页 `web_error.html`，深浅色自适应，提供「重试」「返回首页」按钮 |
| 深浅色模式 | `WebDarkMode.Auto` 跟随系统；JS `matchMedia` 监听网页配色变化并上报，同步系统栏/窗口背景色，防止启动与切换时白闪 |
| 深链 Deep Link | 其他 App 打开 `chatgpt.com` / `auth.openai.com` 链接可直接拉起本应用，启动参数经 coldStartUrl 透传直达目标页面 |
| 应用图标 | 由官方 GPT logo 生成的鸿蒙分层图标（前景/背景双层，自适应圆角与深浅色） |

## 工程结构说明（关键文件）

* `entry/src/main/ets/pages/Index.ets` —— 主页面与 Web 组件核心。包含 URL 加载、UA 按设备类型自适应（手机移动端 UA / 平板与 2in1 PC 端 UA）、url scheme 拦截分发（mailto/tel/sms 等）、右键菜单（图片保存、复制链接）、权限双授权、深浅色与网络状态同步、渲染进程崩溃自动恢复等能力。


* `entry/src/main/ets/component/OAuthSheet.ets` —— OAuth 半模态承载组件。登录/注册流程中识别 SSO 授权弹窗，使用原生 `bindSheet` 半模态窗口承载，解决授权浮层在网页内被吞或无法交互的问题。

* `entry/src/main/resources/rawfile/web_error.html` —— 自定义错误页。断网、5xx 等加载失败时展示，深浅色自动适配，提供「重试」「返回首页」操作。

* `entry/src/main/ets/mihomo/` —— 内置代理（mihomo 内核）。`ProxyManager` 负责内核生命周期与 ArkWeb 代理下发；`AutoSelect` 负责启动测速选最优、链路劣化自动换路与健康探测；`BackgroundKeeper` 在切后台时申请 DATA_TRANSFER 长时任务并周期续期，避免回来后内核已被系统回收；`NetworkWatcher` 监听系统网络变化，换 Wi-Fi / 断网恢复时立即探活内核并重下发代理设置；`ProxySettings` 持久化四个开关（启动自动选路 / 劣化自动切换 / 换节点后刷新 / 后台保持连接）、探测间隔、「智能选路」卡片的展开状态以及测速结果缓存；`SubscriptionUpdater` 按订阅响应头 `profile-update-interval` 自动更新订阅（回前台触发，未声明按 24 小时）；面板状态卡展示内核累计上下行流量与活动连接数。`ProxyRegion` 识别节点国家并排序（日本 → 新加坡 → 美国 → 其它可用 → 未知 → 不可用），`ProxyStrategies` 生成应用内策略组（负载均衡 / 智能线路 / 各国家线路 / 故障转移），仅供 ChatGPT 可用地区参与选路。负载均衡按国家分组：节点数 ≥2 的国家各有一个 `应用 · 负载均衡 · JP 日本` 这样的组（代码 + 中文并列，组内 consistent-hashing，国**内**分摊不跨地区），单节点国家合并为 `应用 · 负载均衡 · 单节点国家`，`应用 · 负载均衡` 本身是 `select` 用来选国家（默认日本），并在面板里固定排最前。负载均衡只使用**当前使用的订阅**的节点（内核一次只加载一份订阅配置）。均衡组内的节点切换由内核按健康检查自动完成，**不会刷新网页、也不会打断软件内界面**；应用层的自动选路在识别到当前出口经过均衡组时会主动跳过。

* `entry/src/main/ets/component/WebPerformanceScripts.ets` —— 网页侧渲染减负脚本：按元素真实高度启用 `content-visibility` 跳过屏幕外内容（侧栏与长会话）、滚动期降级 scroll 监听、侧栏滚动链隔离。侧栏拖拽排序的触摸修正仍在 `Index.ets` 的 `SIDEBAR_TOUCH_CSS`，两者互不替代。

* `entry/src/main/ets/component/WebInteractionScripts.ets` —— 网页侧交互脚本：输入框只接受用户主动聚焦（拦截自动聚焦抢键盘）、触摸设备 hover 查询修正、**长距离下拉刷新**（顶部下拉 180px 触底刷新，带环形进度：外圈轨道 + 内圈进度随下拉距离增长，满环变绿，松手隐藏）。下拉刷新走 `touchstart/touchmove`（滚动中 pointer 会被 `pointercancel`），通过 `javaScriptProxy` 的 `onPullRefresh` 回到 ArkTS 调 `controller.refresh()`；与原生的 `onGestureRecognizerJudgeBegin` 手势屏蔽互不干扰，后者保持不变。

* `entry/src/main/ets/entryability/EntryAbility.ets` —— 应用入口 Ability。负责 Web 引擎预初始化（`initializeWebEngine`）与 BFCache 开启（返回浏览提速）、解析深链 Want（coldStartUrl 透传）、窗口全屏与标题栏设置（2in1 沉浸模式）。

* `entry/src/main/module.json5` —— 模块配置与深链声明。在 EntryAbility 的 `skills` 中注册了 `entity.system.browser` + `action.view`，并声明 `https` 协议下 `chatgpt.com` 与 `auth.openai.com` 两个 host，使系统在其它应用打开这两个域名的链接时可将本应用列为打开方式。

## 构建步骤

1. 使用 DevEco Studio 打开工程根目录整体导入。
2. 左上角菜单 **File > Project Structure > Signing Configs**，勾选自动签名（Automatically generate signature），生成临时调试签名。
3. **Build > Build Hap(s)/APP(s) > Build Hap(s)** 编译生成 HAP；首次编译请选择 **debug** 模式。
4. 也可使用命令行编译：

   ```
   hvigorw assembleHap --mode module -p product=default
   ```

5. 在设备选择处连接已开启开发者选项与 USB 调试的真机（或使用设备管理器镜像），点击运行即可安装体验。

## 已知限制

* 会话列表提取依赖 ChatGPT 前端 DOM 结构，官方改版后会失效，届时自动回退网页自带侧栏，不影响正常使用。
* 嵌套弹窗暂不支持（OAuth 授权弹窗内部再弹出新窗口的场景）。
* chatgpt.com 部分地区访问受限，请自备网络代理。
* 官方 GPT 图标版权归 OpenAI 所有，仅限个人本地使用，请勿用于商业分发。

## 鸣谢

* 本项目基于 [zhubowen-bot](https://github.com/zhubowen-bot) 的 Bowen_ArkWeb_framework 开发，原框架以 Apache-2.0 协议开源，感谢原作者的付出。
