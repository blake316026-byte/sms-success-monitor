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

当前正式版本：**v0.3.40**（macOS build 44、Android versionCode 44）。本版为 Windows 增加今日充值、提现、充提差和占比展示，并增加短信与财务接口的独立权限熔断：账号明确无权限后停止对应接口的定时请求，手动扫描或重新登录可重试。
