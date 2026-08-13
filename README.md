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

当前正式版本：**v0.3.42**（macOS build 46、Android versionCode 46）。本版修复 Windows 刷新成功路径：按钮每次刷新后都会恢复可用，主进程等待真实页面加载事件，未触发时强制重新加载当前网址。
