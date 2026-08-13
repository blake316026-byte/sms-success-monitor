# SMS Success Monitor

独立短信成功率监控客户端，提供 macOS、Windows 和 Android 三个版本。项目与 AI Automation 的任务、数据库、调度器和生产发布流程完全分离。

开发、维护、技术决策与跨窗口交接统一以 [`DEVELOPMENT.md`](DEVELOPMENT.md) 为真源。

## 立即下载

<p align="center">
  <a href="https://github.com/blake316026-byte/sms-success-monitor/releases/latest/download/SMS-Success-Monitor-macOS-universal.zip"><img alt="下载 macOS 客户端" src="https://img.shields.io/badge/下载-macOS-171A21?style=for-the-badge&amp;logo=apple&amp;logoColor=white"></a>
  <a href="https://github.com/blake316026-byte/sms-success-monitor/releases/latest/download/SMS-Success-Monitor-Windows-x64.zip"><img alt="下载 Windows 客户端" src="https://img.shields.io/badge/下载-Windows-1976D2?style=for-the-badge&amp;logo=windows11&amp;logoColor=white"></a>
  <a href="https://github.com/blake316026-byte/sms-success-monitor/releases/latest/download/SMS-Success-Monitor-Android.apk"><img alt="下载 Android 客户端" src="https://img.shields.io/badge/下载-Android-00A66C?style=for-the-badge&amp;logo=android&amp;logoColor=white"></a>
</p>

macOS 包同时支持 Apple Silicon 和 Intel Mac。Windows 包支持 64 位 Windows 10/11。Android 包支持 Android 8.0 及以上版本。

当前正式版本：**v0.3.36**（macOS build 40、Android versionCode 40）。本版将短信扫描与财务刷新彻底分离：短信只读取有界分页样本，财务按平台调用
