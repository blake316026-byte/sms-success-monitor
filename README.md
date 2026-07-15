# SMS Success Monitor

独立短信成功率监控客户端，提供 macOS、Windows 和 Android 三个版本。项目与 AI Automation 的任务、数据库、调度器和生产发布流程完全分离。

固定后台：`BIllS02-OTP`、`BIllS`、`BIllS3`、`BIllS4`、`cg01`、`cg02`、`cg03（nine01）`、`cg04`、`bs01`。

## 立即下载

<p align="center">
  <a href="https://github.com/blake316026-byte/sms-success-monitor/releases/latest/download/SMS-Success-Monitor-macOS-universal.zip"><img alt="下载 macOS 客户端" src="https://img.shields.io/badge/下载-macOS-171A21?style=for-the-badge&amp;logo=apple&amp;logoColor=white"></a>
  <a href="https://github.com/blake316026-byte/sms-success-monitor/releases/latest/download/SMS-Success-Monitor-Windows-x64.zip"><img alt="下载 Windows 客户端" src="https://img.shields.io/badge/下载-Windows-1976D2?style=for-the-badge&amp;logo=windows11&amp;logoColor=white"></a>
  <a href="https://github.com/blake316026-byte/sms-success-monitor/releases/latest/download/SMS-Success-Monitor-Android.apk"><img alt="下载 Android 客户端" src="https://img.shields.io/badge/下载-Android-00A66C?style=for-the-badge&amp;logo=android&amp;logoColor=white"></a>
</p>

macOS 包同时支持 Apple Silicon 和 Intel Mac。Windows 包支持 64 位 Windows 10/11。Android 包支持 Android 8.0 及以上版本。

## 监控口径

- 数据源：每个后台自身域名下的 `/api/sms_record/page`
- 样本：默认读取最新 200 条，可在客户端手动设置为 10–500 条；接口限制单页大小时自动翻页并去重
- 成功：只有原始状态 `SUCCESS` 计为成功
- 报警：`成功数 / 实际样本数 < 50%`
- 周期：每 60 秒扫描一次，也可以手动扫描当前后台或全部后台
- 自恢复：同一后台连续两次扫描异常时，只重载该后台连接并立即重试，不清除登录状态
- 自动登录：Token 失效后可使用本机保存的账号密码、本地图片验证码识别和可选 Google 动态码自动重新登录
- 聚合：只比较已经登录并取得统计值的后台；多个报警同时存在时展示成功率最低者，无报警时展示当前最低健康值
- 登录态：未登录后台只在总览中标记，不会覆盖已有监控值；仅当全部后台都没有有效值时才显示“需登录”
- 本地安全：macOS 使用应用专用 AES-GCM 加密文件、Windows 使用 DPAPI `safeStorage`、Android 使用 Keystore AES-GCM；账号、密码、Google 密钥和 Token 不上传数据库
- 隐私：客户端不保存手机号、短信验证码、Message ID 或短信正文；图片验证码只在设备本地识别

## 三端功能

### macOS

- 原生 Swift/AppKit + WebKit 客户端
- Universal 2 架构，同时支持 Apple Silicon 和 Intel Mac
- 9 个固定后台使用独立持久化资料库，可同时保持不同账号登录
- 支持额外独立页面、标准复制粘贴快捷键、`Command-F` 当前后台网页查找、总览表、常驻最上层浮窗和本机通知
- 固定后台和额外独立页面均可配置本地自动登录；敏感信息保存在应用专用加密文件并在保存后回读校验
- 工具栏样本按钮可统一设置全部后台的样本条数，设置保存在本机并立即重扫
- 红色报警时显示呼吸光、闪烁和抖动；右键浮窗可扫描、打开工作台、静音或退出

### Windows

- Electron 客户端，9 个后台分别使用独立的持久化 Session
- 工作台、独立标签、额外页面、复制粘贴、总览表、常驻最上层浮窗和 Windows 通知
- 固定后台和额外页面均支持自动登录；配置使用 Windows DPAPI 加密，网页渲染进程无法读取已保存的密码和 Token
- 地址栏旁可直接修改样本条数，设置保存在当前 Windows 用户目录并立即重扫
- 后台页面支持 50%–200% 缩放，可使用工具栏、`Ctrl +`、`Ctrl -`、`Ctrl 0` 或 `Ctrl + 鼠标滚轮`，比例保存在本机
- 工作台支持 `Ctrl-F` 查找当前后台网页内容，并可查看匹配数量及切换上一个、下一个结果
- 首次从固定目录运行后自动加入 Windows 登录启动项；移动客户端目录后需要重新运行一次
- 红色报警时浮窗持续脉冲，并在任务栏请求注意

### Android

- 原生 Java + Android WebView 客户端，9 个后台登录态保存在应用私有目录
- 前台监控服务每分钟扫描，切换到其他 App 后仍保留监控通知
- 自动登录配置使用 Android Keystore 加密，Activity 关闭后前台服务仍可完成 Token 恢复
- 导航栏样本按钮可修改样本条数，设置保存在应用私有目录并立即重扫
- 可拖动的系统悬浮窗、明显的红色报警呼吸动效、报警通知和模块总览
- 首次使用需要允许通知，并在系统页面手动授予一次“显示在其他应用上层”权限
- 长按网页输入框即可使用 Android 原生复制和粘贴

各设备的登录态互不同步，需要在每台设备分别登录。固定监控标签不可删除；自定义页面可配置自动登录，但不加入固定成功率统计。

样本条数也是每台设备独立保存，不会上传数据库。修改后旧统计会清空，客户端按新样本数完成扫描后再恢复正常或报警状态。

首次启用自动登录：选择对应后台，点击钥匙图标，输入账号、密码和可选 Google 密钥并保存。每个后台独立配置；连续 5 次自动登录失败后暂停 5 分钟，避免错误配置导致账号持续尝试。

## 已打包产物

```text
dist/macos/SMS-Success-Monitor-macOS-universal.zip
dist/windows/SMS-Success-Monitor-Windows-x64.zip
dist/android/SMS-Success-Monitor-Android.apk
```

三份下载均为已经打包、无需自行编译的可运行客户端。当前 macOS 包为本机临时签名，Windows 包未购买代码签名证书，Android 包使用本机调试证书签名；系统首次打开时可能显示来源确认。若要消除这些提示，需要后续配置 Apple Developer、Windows Authenticode 和长期 Android 发布证书。

## 安装

macOS：解压后把 `SMS Success Monitor.app` 放入“应用程序”。首次启动若被系统拦截，在 Finder 中右键应用并选择“打开”；以后可直接启动，重启电脑后也可在“应用程序”中再次打开。

Windows：把 ZIP 完整解压到固定目录，运行 `SMS Success Monitor.exe`。不要只把 EXE 单独拖出文件夹；首次出现 SmartScreen 时选择“更多信息”并确认运行。

Android：把 APK 发送到设备并安装；系统询问时允许该来源安装应用。打开后完成 9 个后台登录和悬浮窗授权。

## 本地构建

全部验证并打包：

```bash
git clone https://github.com/blake316026-byte/sms-success-monitor.git
cd sms-success-monitor
./scripts/package-all.sh
```

单独构建：

```bash
./scripts/package-macos.sh
./scripts/package-windows.sh
./scripts/package-android.sh
```

依赖：macOS 13+ 与 Swift 工具链、Node.js 24、JDK 17、Android SDK 35。Windows 包可在 macOS 交叉生成，但最终签名和 Windows 实机验证应在 Windows 上完成。

## 验证

```bash
./scripts/test.sh
```

该命令检查 Swift 核心规则、扫描脚本、共享模块配置和 Electron 工程结构。Android 打包脚本还会执行 Android Lint 和完整 APK 编译。
