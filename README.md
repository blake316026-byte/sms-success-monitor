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

当前开发版本：**v0.3.52**（macOS build 56、Windows v0.3.52、Android versionCode 52）。本版修复账号 Token 混用：当前网页账号优先且不回退旧账号，权限拒绝立即停止对应查询，账号冲突或查询期间切换账号时不展示返回数据。更换自动登录用户名时清除旧 Token，页面 Token 仅写回同名账号配置。
