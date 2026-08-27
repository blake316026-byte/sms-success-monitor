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

当前版本：**v0.3.52**（macOS build 59、Windows v0.3.52、Android versionCode 52）。三端修复账号 Token 混用，并在已加载的 NPG 权限清单明确缺少短信或报表授权时停止对应查询；支付汇总权限不等于报表看板权限。macOS 修复退出后的旧 Token 复用，以及同名已保存账号重新登录时验证码流程被暂停的问题。详见[本版更新说明](releases/v0.3.52.md)。
