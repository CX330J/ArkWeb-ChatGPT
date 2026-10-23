# Bowen_ArkWeb框架 正式版v1.2

## 摘要

**这是一个基于ArkWeb深度开发的html嵌入式鸿蒙软件框架，即使你没有学过编程，你也可以零基础零编程构建自己的鸿蒙应用**

目前，Bowen_ArkWeb框架已经实现的功能有：

* 网页web/本地web自由嵌入；
* 底部安全区（小横条附近）沉浸式效果适配；
* 鸿蒙安全访问文件控件；鸿蒙安全访问相机控件；鸿蒙安全保存控件；
* 扩展右键菜单，包括图片右键下载菜单、复制链接等
* 下载监听和下载框适配，支持安全保存文件
* 支持自由而简单地添加url schame协议，已经demo包含的有maito邮箱、tel电话、sms短信、weixin微信、xhsdiscover小红书、jaccount上交大交我办应用跳转。
* 支持跳转应用对应的系统权限页；
* 系统相机和麦克风权限申请，网页获取系统相机和麦克风权限，采用二次权限申请以保护安全；
* 获取系统网络状态，并反馈给网页；
* 深色、浅色模式获取，并反馈给网页；
* 依据设备型号自动精确向网页申请与设备匹配的UA。
* 内置demo链接（网页和rawfile的本地引用示例）和许多软件图标
* 内置demo权限共5个，设置了ohos.permission.CAMERA（允许应用使用相机），ohos.permission.GET_NETWORK_INFO（允许应用获取数据网络信息），ohos.permission.INTERNET（允许使用Internet网络），ohos.permission.MICROPHONE（允许应用使用麦克风），ohos.permission.PRINT（允许应用获取打印框架的能力）
* 拦截强制跳转的app linking，正常加载网页（具体实现见后）



## 目录

* 部署项目

* 网页元素避让安全区适配

* 关于不支持深色模式的web页面顶部状态栏适配（临时方案，最佳状态栏背景实现应该使用外套column的动态背景色）

* 关于web组件的自定义协议跳转（url scheme）

* 关于UA（use-agent）的适配

* 关于拦截APP Linking强制跳转

* 致谢



## 部署项目：

* 使用DevEco studio导入项目，选择打开文件夹整体导入
* entry/src/main/ets/pages/Index.ets: 顶部代码修改指向的链接
* 其中如果是本地化html可把链接改为引用，如$rawfile('index.html')，html文件请存储在rawfile文件夹中
* app.json5处修改包名bundlename，修改版本号versionname和versioncode
* module.json5修改权限使用，修改应用启动页图标，"startWindowIcon": "$media:name"，其中name为resources/base/media文件夹的png图标文件名
* entry\src\main\resources\base\element\string.json处修改软件名EntryAbility_label，也可修改权限说明的描述
* layered_image.json修改软件图标，存储位置依然在media文件夹
* AppScope\resources\base\element\string.json处修改软件名app_name，注意两处都要修改
* 左上角横条-项目结构-signing configs处勾选自动签名，生成临时调试签名
* 右上角靶标图标可切换build mode为debug和release，锤子图标可编译hap和app，存放于build或entry\build里面的相关文件夹
* devices选择处可选择打开了开发者选项和有线调试的USB调试设备，也可在设备管理器内选择镜像下载启动
* 右上角甲虫或开始符号点击构建或运行

**没学过编程的零基础小白可以这样开发鸿蒙应用：**
使用AI生成html文件，保存到上方rawfile文件夹，并按上述步骤部署

## 网页元素避让安全区适配

* Web组件启用沉浸式效果时，渲染内容可能与非安全区域重叠，影响用户的阅读和交互。非安全区域包括顶部状态栏、屏幕挖孔区和底部导航条。在沉浸式效果下，网页的标题栏被屏幕挖孔区遮挡，底部的Tab区域与导航条发生重叠。

* 网页开发者可利用env(safe-area-inset-*)定义CSS样式，确保文字、图片和交互组件避让非安全区域。在以下示例中，通过env(safe-area-inset-*)更新了index.html的CSS样式，使网页主要内容避让非安全区域：

* `.title-bar {`

      align-items: center;
      justify-content: center;
      top: 0;
      height: 40px;
      padding-top: env(safe-area-inset-top); /* 设置padding-top避让上方非安全区域 */

  `}
  .content {`

      margin: 8px;
      padding-top: calc(env(safe-area-inset-top) + 40px); /* 同步title-bar增加padding-top高度 */

  `}
  .tabs {`

      justify-content: space-around;
      bottom: 0;
      height: calc(env(safe-area-inset-bottom) + 40px); /* 增加tab区域高度以避让下方非安全区域 */

  `}`

* 具体内容见开发文档：[文档中心](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/web-safe-area-insets)

## 关于不支持深色模式的web页面顶部状态栏适配

目前顶部状态栏安全区背景延伸适配的工作尚未完成。如果你的web不支持深色模式，在开启深色模式状态下顶部状态栏会呈现黑色，影响视觉观感。这时，你只需要在index.ets文件的最后几行代码：

`.width('100%')`

`.height('100%')`

后添加一行：

`.background('#F0F4F8')`

即可

## 关于web组件自定义协议跳转（url scheme）

本方案优于官方文档所提供的方案，具有可复用性、易移植性，无需额外的申请开通app linking，或者在module.json中输入值，只需要有url scheme 的前缀和对应app的包名即可。

相关内容在index.ets中搜索

【官方提供的方案】

鸿蒙系统web组件原生采用了APP linking的跳转方式，如豆包，无需做任何适配就可以自动跳转至应用。

对于绝大多数跳转链接，很有可能打开后为白屏或黑屏，这是因为该跳转协议未适配app linking。

官方的app linking方式，需要注册能力、添加关联名单等一系列操作，适配极为不方便。

官方还提供了deep linking的方案，但是给出的示例使用了特殊的单一值示例，不具备普遍可复用性，需要修改完善。

【我们提供的方案】

由于绝大多数应用都支持浏览器所采用的通用url scheme的跳转方式，因此深度适配此方案将会使得跳转极为简便。

官方文档有基于url scheme的方案。本处给出的方案相比官方示例代码可复用性更强。

在源代码中，已经开发了处理 maito 邮箱、tel 电话、sms 短信、weixin 微信、xhsdiscover 小红书、jaccount 上交大交我办APP 及QQ登录 链接的部分。

【适配步骤】

1.获取url scheme的前缀

这里，以上海交通大学交我办的`jaccount://login?uuid=xxx` 自定义协议拉起为例，

用开发者工具-请求手机端 分析移动端网站跳转交我办的代码（可右键直接读取网页源代码，再上传给AI分析），可以发现其网页采用URL Scheme

`function appLogin() {
    showTryAppLogin(5000);  // 显示等待界面，5秒超时
    if (firefox) {
        // Firefox 特殊兼容：通过隐藏 iframe + a 标签触发
        document.getElementById("firefox_link").click();
    } else {
        // 主流浏览器：直接跳转 URL Scheme
        window.location.href = 'jaccount://login?uuid=EXAMPLE_LOGIN_ID';
    }
    return false;
}`

其前缀为 jaccount:  。

下面是鸿蒙web框架的对应实现方式，代码已经给出demo，可以采用搜索工具查找位置，来更改demo代码

在Index.ets中，在处理链接拦截的部分添加

`// 处理 jaccount: 链接 - 拉起交我办APP

`if (requestUrl.indexOf('jaccount:') === 0) {`                //这里填入前缀

`let context = this.getUIContext().getHostContext() as common.UIAbilityContext;`

`let want: Want = {`

`bundleName: 'edu.sjtu.jwb',`            //这里是应用包名，可以用开发者相关工具获取，获取包名的方法网上可以查询到

`action: 'ohos.want.action.viewData',`

`uri: requestUrl`

`};`

`context.startAbility(want).then((data) => {`

`console.info(拉起交我办APP成功: ${JSON.stringify(data)});`

`}).catch((err: BusinessError) => {`

`console.error(拉起交我办APP失败: ${err.code}, ${err.message});`

`promptAction.showToast({ message: '未安装交我办APP，请先安装' });`

`});`

`return true;`

`}`

方案2：拉起浏览器跳转解决“暂无可用打开方式”的问题

对于QQ登录等部分情况，采用常规的指定报名会显示暂无可用打开方式。此时可以不指定包名采用浏览器跳转：

区别在于不指定包名，而是加上：
entities: ['entity.system.browsable']
此时所有注册了scheme的都可以自动识别并拉起浏览器跳转

> //` 处理 QQ登录链接 - 拉起QQ打开`
>
> `if (requestUrl.indexOf('https://xui.ptlogin2.qq.com/') === 0) {`
>
> `let context = this.getUIContext().getHostContext() as common.UIAbilityContext;`
>
> `let want: Want = {`
>
> `action: 'ohos.want.action.viewData',`
>
> `entities: ['entity.system.browsable'],`
>
> `uri: requestUrl`
>
> `};`
>
> `context.startAbility(want).then((data) => {`
>
> `console.info(拉起QQ成功: ${JSON.stringify(data)});`
>
> `}).catch((err: BusinessError) => {`
>
> `console.error(拉起QQ失败: ${err.code} - ${err.message});`
>
> `promptAction.showToast({ message: '未安装QQ，请先安装' });`
>
> `});`
>
> `return true;`
>
> `}`

官方文档的方案比本处复杂，不过也可以参考。

[H5通过url scheme拉起应用-关键场景示例-公共关键技术方案 - 华为HarmonyOS开发者](https://developer.huawei.com/consumer/cn/doc/architecture-guides/app_pull_up-0000002353615821)

## 关于UA（user agent）的适配

只需要更改适配逻辑即可，如下方，平板和大屏UA统一，如果想让平板显示为移动端，按下方添加即可。

详见index.ets

> `// UA设置逻辑：`
>
> `// 1. 强制移动模式 → 移动端UA`
>
> `// 2. 手机/可穿戴设备 → 移动端UA（无论屏幕方向）`
>
> `// 3. 小屏竖屏设备 → 移动端UA`
>
> `// 4. 其他情况（平板/2in1横屏或大屏） → PC端UA`
>
> `// 注：如果想让平板端显示移动端，那么在下方一行增加 || isTabletDevice 即可`
>
> `if (forceMobileUA || isMobileDevice || isSmallScreen) {`
>
> `this.controller.setCustomUserAgent(mobileUserAgent );`
>
> `this.controller.setCustomUserAgent(mobileUserAgent + " QwenApp/1.5");`
>
> `console.info('使用移动端UA');`
>
> `} else {`
>
> `this.controller.setCustomUserAgent(pcUserAgent);`
>
> `console.info('使用PC端UA');`
>
> `}`

注意：这里的设备请求没有添加Harmony OS设备，如果需要用到鸿蒙版应用商店和特有UA功能，请按照开发者联盟官网文档在开头的：

> // UA设置（修改为更精准的移动端标识）
>
> const forceMobileUA = false; // 强制手机UA开关设置为true
>
> const mobileUserAgent = "Mozilla/5.0 (Linux; Android 13; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Mobile Safari/537.36"; // 增强移动端标识
>
> const pcUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"; // 更新PC UA版本

处添加openharmony相关内容

## 关于拦截app linking 强制跳转

> ArkWeb内核已完成对App Linking的自动适配，集成了ArkWeb内核的应用，在ArkWeb中访问目标应用的App Linking地址时，系统将在应用已安装时自动拉端，未安装时跳转到对应网页，ArkWeb的宿主应用无需特殊处理

但是很有可能我们并不希望跳转应用，而app linking 又是深度集成的。官方文档给出以下解释

> 若开发者不希望触发App Linking应用跳转逻辑，而是在应用内以ArkWeb继续浏览，可以在onLoadIntercept()回调中拦截对应的App Linking地址，并手动通过loadUrl()的方式加载网页内容，需注意获取到的链接地址末尾会被自动添加“/”。

代码实现在下面几个地方（以豆包为例）

```
private isProcessingDoubao: boolean = false; // 新增：豆包链接处理状态
```

> `// 拦截豆包App Linking跳转（添加递归保护）`
>
> `if (requestUrl.indexOf('https://www.doubao.com') === 0) {`
>
> `// 检查是否已在加载此URL，避免递归`
>
> `if (!this.isProcessingDoubao) {`
>
> `this.isProcessingDoubao = true;`
>
> `console.info(拦截到豆包链接，在应用内加载: ${requestUrl});`
>
> `this.controller.loadUrl(requestUrl);`
>
> `// 设置超时重置状态，防止永久锁定`
>
> `setTimeout(() => {`
>
> `this.isProcessingDoubao = false;`
>
> `}, 3000);`
>
> `return true;`
>
> `} else {`
>
> `console.warn('已跳过递归加载豆包链接');`
>
> `}`
>
> `}`

## 致谢


本项目参考了以下项目的设计思路
* [零炻littlestone] -开源仓库 https://github.com/littlestone0806/WebApp-ohos
