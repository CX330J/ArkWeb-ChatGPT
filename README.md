# ArkWeb ChatGPT

本项目基于 **[Bowen_ArkWeb_framework](https://github.com/zhubowen-bot/Bowen_ArkWeb_framework)** 开发，保留原项目的 Apache-2.0 许可证与来源说明，感谢原作者。

这是一个通过 ArkWeb 访问 ChatGPT 的 HarmonyOS 应用，提供登录弹窗、文件下载和应用内代理支持。

当前版本：**8.4.3**。这是独立开发的第三方客户端。

## 功能

- ChatGPT 网页、OAuth 登录弹窗、拍照和文件上传。
- 文件下载与系统保存选择器。
- 深浅色、安全区和手机、平板布局适配。
- 内置 arm64 Mihomo 内核，通过订阅配置应用内代理。
- 代理配置解析和启动在后台线程执行，连接期间界面可继续响应。

## 构建

1. 使用 DevEco Studio 打开项目并安装依赖。
2. 工程配置使用 HarmonyOS SDK `6.1.0(23)`，当前原生库支持 `arm64-v8a`。
3. 在 **Project Structure → Signing Configs** 中配置自己的调试签名。
4. 选择 Debug 模式并构建 HAP，安装到已开启调试的设备。

仓库提供未签名的构建配置。签名证书、密钥、密码、个人订阅和设备日志应保存在本机，提交前检查 `build-profile.json5` 是否被 IDE 写入本机签名信息。

## 目录

| 路径 | 内容 |
| --- | --- |
| `AppScope/` | 应用标识、版本和图标 |
| `entry/src/main/ets/` | ArkTS 页面、组件和代理管理 |
| `entry/src/main/cpp/` | Mihomo 的原生异步桥接层 |
| `entry/libs/arm64-v8a/` | 已编译的代理内核 |
| `entry/src/main/resources/` | 界面资源和本地错误页 |
| `entry/src/ohosTest/` | 真机回归测试 |
| `tools/mihomo/` | 内核入口源码、构建和验证工具 |
| `docs/` | 框架说明 |

## 验证代理首次启动

真机测试使用合成规则，规则响应延迟 8 秒，用来检查启动过程是否阻塞事件循环。

1. 在电脑执行 `python tools/mihomo/slow-rule-server.py`。
2. 执行 `hdc -t <device> rport tcp:18080 tcp:18080`。
3. 构建并安装应用 HAP 和 `ohosTest` HAP。
4. 执行下面的测试命令：

```shell
hdc -t <device> shell aa test -b com.bowen.chatgpt -m entry_test -s unittest OpenHarmonyTestRunner -s class ProxyStartup -s timeout 60000 -w 120
```

测试覆盖慢速规则初始化、缺失配置、启动取消和重复启动。运行结束后移除测试模块和端口转发。

其他本地验证：安装 Node.js、TypeScript、Python 和 PyYAML，然后运行 `node tools/mihomo/verify-config.cjs` 与 `node tools/mihomo/verify-interaction.cjs`。也可用 `TYPESCRIPT_MODULE` 指定本机 TypeScript 模块位置。网页性能验证另需 Playwright 与 Chrome。

## 文档与来源

- [ChatGPT 适配说明](README_CHATGPT.md)
- [原 ArkWeb 框架说明](docs/arkweb-framework.md)
- [Bowen_ArkWeb_framework 原项目](https://github.com/zhubowen-bot/Bowen_ArkWeb_framework)
- [Mihomo](https://github.com/MetaCubeX/mihomo)

原框架保留 Apache-2.0 许可证。第三方库和资源遵循各自许可证；GPT 图标相关权利归 OpenAI 所有。
