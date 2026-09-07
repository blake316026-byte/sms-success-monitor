# SMS Success Monitor

独立的短信成功率监控客户端，支持 macOS、Windows 和 Android。

开发、维护、技术决策与跨窗口交接统一以 [`DEVELOPMENT.md`](DEVELOPMENT.md) 为真源。

## 立即下载

<p align="center">
  <a href="https://github.com/blake316026-byte/sms-success-monitor/releases/latest/download/SMS-Success-Monitor-macOS-universal.zip"><strong>下载 macOS 版</strong></a>
  &nbsp;&nbsp;&nbsp;
  <a href="https://github.com/blake316026-byte/sms-success-monitor/releases/latest/download/SMS-Success-Monitor-Windows-x64.zip"><strong>下载 Windows 版</strong></a>
  &nbsp;&nbsp;&nbsp;
  <a href="https://github.com/blake316026-byte/sms-success-monitor/releases/latest/download/SMS-Success-Monitor-Android.apk"><strong>下载 Android 版</strong></a>
</p>

macOS 包同时支持 Apple Silicon 和 Intel Mac。Windows 包支持 64 位 Windows 10/11。Android 包支持 Android 8.0 及以上版本。

### macOS 首次打开

当前 macOS 包使用内部临时签名，尚未使用 Apple Developer ID 签名和公证。从 GitHub 下载后若提示“Apple 无法验证”，请确认下载来源为本仓库，然后：

1. 将应用放入“应用程序”文件夹并尝试打开一次，在提示中点击“完成”。
2. 打开“系统设置”→“隐私与安全性”，向下滚动到“安全性”。
3. 在 SMS Success Monitor 提示旁点击“仍要打开”，输入本机登录密码后再次确认“打开”。

该例外保存后，以后可以正常双击启动。正式消除此提示需要使用 Apple Developer ID 签名并通过 Apple 公证。

本版：**macOS v0.3.64 build 71、Windows v0.3.64**；Android 下载继续使用已验证的 v0.3.61。macOS 和 Windows 新增持久关键词高亮：用户可保存关键词、颜色和完整词匹配设置，刷新、切换后台及网页动态更新后会继续高亮。GitHub 下载以已发布 Release 为准。详见[本版更新说明](releases/v0.3.64.md)。
