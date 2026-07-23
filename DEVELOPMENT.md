# SMS Success Monitor — 开发与维护真源

本文是 SMS Success Monitor 的开发、维护、跨窗口接手和技术决策真源。`README.md` 面向使用者，本文面向主管、开发者和后续 Codex 窗口。

当本文与代码冲突时，以当前代码和测试为运行事实；修复代码后必须同步本文。历史聊天、截图、旧安装包和交接摘要不能覆盖当前 Git、代码、测试与发布证据。

## 1. 项目定位与边界

- 产品：独立短信发送成功率监控客户端。
- 支持平台：macOS、Windows、Android。
- 固定监控后台：`BIllS02-OTP`、`BIllS`、`BIllS3`、`BIllS4`、`cg01`、`cg02`、`cg03（nine01）`、`cg04`、`bs01`。
- 客户端直接复用各后台的本机登录会话，读取后台自身域名的短信记录接口。
- 本项目不依赖 AI Automation 的数据库、任务表、调度器或生产服务；不要为了客户端需求修改这些系统。
- 各设备的登录态、自动登录资料、自定义页面和样本条数互不同步。
- 不保存手机号、短信验证码、Message ID 或短信正文；验证码识别只在设备本地执行。

禁止把本项目描述为短信发送器。它只读取短信记录并报警，不应触发真实短信、修改平台数据或写入 AI Automation 生产环境。

## 2. 真源优先级

| 问题 | 真源 |
| --- | --- |
| 监控算法、固定后台、macOS 状态模型 | `Sources/SMSMonitorCore/MonitorModels.swift` |
| macOS 扫描接口契约 | `Sources/SMSMonitorApp/ScanScript.swift` |
| macOS 调度、恢复、自动登录、聚合 | `Sources/SMSMonitorApp/MonitorController.swift` |
| macOS 工作台、自定义页面 | `Sources/SMSMonitorApp/PlatformWorkspaceController.swift` |
| macOS 本机凭据 | `Sources/SMSMonitorApp/LocalCredentialStore.swift` |
| Windows/Android 共用后台清单 | `clients/shared/modules.json` |
| Windows/Android 共用监控算法 | `clients/shared/monitor-core.mjs`、`clients/shared/scan.js` |
| 共用登录页自动化 | `clients/shared/auto-login/login-page.js` |
| Windows 主进程与生命周期 | `clients/windows-electron/src/main.mjs` |
| Windows UI | `clients/windows-electron/src/ui/` |
| Android 页面与监控服务 | `clients/android/app/src/main/java/com/local/smssuccessmonitor/` |
| 构建、验证、打包 | `scripts/` |
| 用户安装与使用说明 | `README.md` |
| 当前发布版本 | 三端版本文件、目标 Git commit、Release 附件及校验值共同证明 |

高漂移事实必须现场核验：当前分支、HEAD、dirty 状态、远端引用、GitHub Release、产物校验值和设备实测状态。无法取得当前证据时写“无法确认”，不要用旧聊天或旧包代替。

## 3. 稳定监控契约

除非用户明确批准产品口径变化，否则以下规则视为稳定契约：

1. 数据源为当前后台 origin 下的 `POST /api/sms_record/page`。
2. 默认样本数为 200，允许范围为 10–500。
3. 只有去除首尾空白并忽略大小写后等于 `SUCCESS` 的状态计为成功；`SENT`、`PENDING`、`FAILED` 等均不算成功。
4. 成功率为 `成功数 / 实际取得的去重样本数`。
5. 成功率严格小于 50% 才报警；正好 50% 不报警；空样本不得误报为低成功率。
6. 正常扫描周期为 60 秒；扫描耗时从下一次等待中扣除，避免周期持续漂移。
7. 同一后台连续两次扫描失败后重载该后台页面并重试，不清除登录态。
8. 结果超过四分钟未刷新视为过期，不能继续显示为健康结果。
9. 聚合只使用已取得有效指标的后台。存在多个报警时聚焦成功率最低者；无报警时聚焦最低健康值。
10. 登录失效、接口异常和业务低成功率是三种不同状态，不得互相替代。
11. 固定后台必须使用互相隔离的持久化会话；自定义页面加入同一监控聚合，但不能删除固定后台。
12. 图片验证码和 Google 验证码使用独立计数器：图片验证码最多连续尝试 10 次，Google 验证码最多尝试 5 次；分别达到上限后才暂停自动登录并提示人工处理。

扫描脚本会从页面本地存储读取 Token、国家、语言和可选 `Tkk`，在接口限制单页条数时自动翻页，并优先按记录 ID 去重。调整请求字段、鉴权头、状态映射或去重键属于跨平台协议变更，必须三端同步验证。

## 4. 架构与目录

```text
SMS Success Monitor
├── Sources/
│   ├── SMSMonitorCore/          # Swift 纯规则与配置
│   ├── SMSMonitorApp/           # macOS AppKit/WebKit 客户端
│   └── SMSMonitorCoreChecks/    # Swift 可执行规则检查
├── clients/
│   ├── shared/                  # Windows/Android 共用模块、扫描和登录逻辑
│   ├── windows-electron/        # Windows Electron 客户端
│   └── android/                 # Android 原生客户端
├── Resources/                   # macOS Info.plist 与资源
├── scripts/                     # 测试、构建、打包脚本
├── dist/                        # 本地生成的发布产物
└── release-seed/                # 仓库内的种子产物，不代表当前正式 Release
```

### macOS

- `AppDelegate` 组装通知、监控器和常驻浮窗。
- 每个后台由一个 `ModuleMonitorController` 管理独立 `WKWebView`、扫描调度、恢复和自动登录。
- `MonitorController` 汇总状态、处理过期结果、管理工作台和自定义页面。
- `LocalCredentialStore` 使用应用专用 AES-GCM 加密文件；不得恢复旧 Keychain 依赖。

### Windows

- Electron 主进程维护后台会话、扫描、自动登录、通知和窗口生命周期。
- 九个固定后台使用独立持久化 Session。
- 敏感配置必须留在主进程，并使用 Windows DPAPI `safeStorage`；渲染进程不得读取密码、Token 或 TOTP 密钥。

### Android

- `MainActivity` 提供工作台和设置，`MonitorService` 以前台服务维持每分钟扫描。
- 登录态和设置保存在应用私有目录，敏感配置使用 Android Keystore AES-GCM。
- 后台监控依赖通知权限；悬浮窗依赖用户单独授予“显示在其他应用上层”权限。

## 5. 跨平台一致性规则

当前 macOS 的固定后台配置在 Swift 中维护，Windows/Android 的配置在 `clients/shared/modules.json` 中维护。因此变更以下内容时必须双向同步：

- 后台 ID、显示名、URL、顺序；
- 默认样本数、允许范围、扫描间隔、报警阈值；
- `SUCCESS` 判定、聚合选择、空样本处理；
- 接口路径、请求体、鉴权头、分页、超时、去重和认证错误识别；
- 自动登录字段识别、验证码/TOTP 行为和失败冷却；
- 用户可见状态文案中代表业务语义的部分。

只改一端通常视为缺陷。平台特有 UI、权限、系统通知、窗口行为和安全存储实现可以不同，但产品语义必须一致。

## 6. 安全与隐私门禁

- 禁止提交真实账号、密码、Token、Cookie、TOTP 密钥、私钥或用户数据。
- 禁止在日志、截图、测试 fixture、交接文档或错误信息中输出敏感值。
- 自动登录资料只能保存在设备本机加密存储，不能上传数据库或远端服务。
- 扫描必须是只读接口调用；任何平台写请求、真实短信或账号配置写入都需要重新评估产品边界并取得用户明确授权。
- 不要把后台网页内容整体持久化，不要新增短信正文、手机号或验证码采集。
- 修改 WebView/Electron 安全边界时必须复核渲染进程权限、导航白名单、IPC 暴露和凭据可见性。
- 第三方 OCR 模型与依赖的许可证归档在 `clients/shared/auto-login/THIRD_PARTY_NOTICES.md`，升级时同步核验。

## 7. 标准开发流程

### 7.1 接手前

```bash
git rev-parse --show-toplevel
git status --short --branch
git log -1 --oneline
```

确认实际仓库根目录、分支、当前修改和用户最新指令。不要覆盖其他窗口的未提交改动。

阅读顺序：

1. `README.md`；
2. 本文；
3. 与任务直接相关的源码；
4. 对应测试和打包脚本；
5. 若项目仍位于 AI Automation 仓库内，再遵守仓库根目录的 `AGENTS.md`、`COLLAB.md`、`HANDOFF.md` 和 `cursorrules.md`。

### 7.2 实现

- 先写清目标、非目标、风险等级和验收标准。
- 优先修改最小边界，不顺手重构无关代码。
- 涉及稳定监控契约时先补或更新测试，再同步三端实现。
- 版本号只有在准备新发布时调整，不为普通开发提交随意递增。
- 不直接编辑生成目录、`node_modules`、Gradle build 输出或已打包二进制。

### 7.3 验证

所有代码改动至少运行：

```bash
./scripts/test.sh
```

它覆盖 macOS 无旧 Keychain 检查、Swift 核心规则、扫描脚本、登录页自动化、跨平台共用规则和 Windows 包结构。注意：未安装 Windows 依赖时，脚本会跳过 Windows npm 测试；交接时必须明确说明是否实际执行。

按影响面追加：

```bash
./scripts/package-macos.sh
./scripts/package-windows.sh
./scripts/package-android.sh
```

- macOS 改动需运行本地 OCR、TOTP 和页面查找自检，并在 Apple Silicon/Intel 兼容性相关变更后验证 Universal 2 包。
- Windows 改动需做 Windows 10/11 实机验证；macOS 上交叉打包成功不能代替 Windows 实测。
- Android 改动需通过 Lint、APK 构建，并在 Android 8.0+ 实机验证通知、前台服务、进程恢复与悬浮窗权限。
- 自动登录、后台接口或页面 DOM 变更需至少用无敏感信息的本地 fixture/模拟响应验证；未经授权不要在真实账号上做破坏性试验。

### 7.4 完成标准

- 代码、测试和本文没有契约漂移。
- `git diff --check` 通过。
- 相关验证已运行并记录结果；未验证项明确写出。
- 没有新增敏感信息或用户隐私持久化。
- 没有把安装包存在当作源码和测试正确的证明。

## 8. 版本与发布

当前版本号分别来自：

- macOS：`Resources/Info.plist`；
- Windows：`clients/windows-electron/package.json`；
- Android：`clients/android/app/build.gradle` 的 `versionName` / `versionCode`。

发布前必须确保三端面向同一功能版本；Android `versionCode` 必须递增。标准打包入口：

```bash
./scripts/package-all.sh
```

预期产物：

```text
dist/macos/SMS-Success-Monitor-macOS-universal.zip
dist/windows/SMS-Success-Monitor-Windows-x64.zip
dist/android/SMS-Success-Monitor-Android.apk
```

发布门禁：

1. 用户明确授权发布；普通开发或“打包看看”不等于允许上传 Release。
2. 记录目标 commit，确认工作树范围和发布分支。
3. 运行全量测试与三端打包，计算并记录 SHA-256。
4. 做对应平台实机冒烟：启动、九后台隔离登录、扫描、手动重扫、低于/等于 50% 边界、通知/浮窗、退出重启、自动登录失败冷却。
5. 核对 GitHub Release 附件来自目标 commit，文件名和校验值匹配。
6. 保留回滚到上一 Release 的路径。

当前 macOS 临时签名、Windows 未正式代码签名、Android 使用调试证书属于已知发布限制。配置正式签名之前，不得宣称已消除系统来源警告。

## 9. 常见变更的影响面

| 变更 | 至少检查 |
| --- | --- |
| 新增/删除/改名后台 | Swift 配置、`modules.json`、会话 ID、UI 顺序、共享测试、README |
| 后台 URL/域名变化 | 两套配置、origin 校验、登录页识别、持久化会话是否保留 |
| 短信接口变化 | Swift/共享扫描脚本、分页、鉴权、错误映射、模拟测试、三端实测 |
| 阈值/样本/周期变化 | Swift core、共享 core、设置 UI、状态文案、测试、README |
| 登录页 DOM 变化 | 共用登录脚本、macOS 桥接、Windows/Android runtime、验证码/TOTP 测试 |
| 本机凭据变化 | 三端安全存储、迁移/回读、删除行为、渲染进程隔离、安全测试 |
| 浮窗/通知变化 | 三端各自 UI、静音语义、前后台/重启行为、系统权限 |
| 发布版本变化 | 三端版本文件、测试、包、校验值、Release 附件、README |

## 10. 主管维护规则

- 用户与主管确认需求、优先级和产品口径；主管负责影响面、风险、拆分、验收和交接。
- 文档/只读/小改可直接处理。跨平台协议、安全存储、自动登录或发布相关改动应拆成影响面检查、实现、测试和审查阶段。
- 发布、上传附件、替换公开下载、正式签名证书操作必须取得用户明确授权。
- 真实后台只读检查不得泄露账号或业务明细；会产生平台写动作的验证必须单独授权。
- 每次交付必须报告：改动文件、行为变化、验证结果、未验证项、残余风险、是否需要发布。

## 11. 跨窗口交接

上下文变长、任务未完成、存在未提交 diff、即将发布或主管需要换窗口时，生成以下交接包。交接包不得包含任何凭据或用户隐私。

```text
【SMS Success Monitor 主管交接包】

用户最新指令：
当前目标：
非目标：
风险等级：
当前阶段：影响面 / 实现 / 测试 / 审查 / 待发布

项目路径：
分支与 HEAD：
Git 状态：
目标发布版本（如适用）：

已完成：
正在做：
下一步：

已改文件：
diff 摘要：
当前文件锁/其他窗口：

稳定契约是否变化：
跨平台同步状态：macOS / Windows / Android
安全与隐私检查：

已运行验证：
验证结果：
未验证项：
实机验证：macOS / Windows / Android

发布状态：未授权 / 已授权未发布 / 已发布
发布 commit、附件和 SHA-256（如适用）：
禁止动作：
残余风险：

新窗口接手：先读 README.md、DEVELOPMENT.md、当前 diff 和相关测试；重新执行 git status，核对用户最新指令后继续。不要凭交接包直接发布。
```

新窗口必须重新核对 Git 当前事实，不能假设交接包仍然最新。如果代码、测试、本文或用户最新指令互相冲突，暂停扩大修改，先报告冲突并由主管裁决。

## 12. 文档维护

以下变化必须同步本文：

- 产品边界或稳定监控契约变化；
- 目录、入口、构建工具或支持平台变化；
- 安全存储、隐私范围或登录自动化变化；
- 测试和发布门禁变化；
- 真源文件迁移；
- 主管维护和跨窗口交接规则变化。

不要在本文记录实时成功率、当前登录状态、临时 bug 清单或某次发布进度。需求与待办应进入任务/Issue，当前状态应通过 Git、测试、设备和 Release 证据即时确认。
