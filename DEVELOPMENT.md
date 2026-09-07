# SMS Success Monitor — 开发与维护真源

本文是 SMS Success Monitor 的开发、维护、跨窗口接手和技术决策真源。`README.md` 面向使用者，本文面向主管、开发者和后续 Codex 窗口。

## 2026-09-07 持久关键词高亮

- 发布目标为 macOS v0.3.64 build 71、Windows v0.3.64；Android 源码已接入但当前环境未接受 Android SDK 许可、未完成 APK 编译，Release 继续提供已验证的 v0.3.61 APK，不能描述为 Android v0.3.64。
- 工具栏新增“自动高亮”，用户可保存启用状态、每行一个的关键词、颜色和完整词匹配；设置仅保存在本机并应用到全部后台页面。
- 共享高亮运行时使用 CSS Highlight API，不包装或改写业务 DOM；忽略输入框、脚本、隐藏和可编辑内容。MutationObserver 在 SPA 或表格动态更新后重新计算高亮，并限制为 200 个关键词、单项 100 字符和每页 10000 个匹配。
- macOS 打包自检在真实 WKWebView 中验证初始文字和动态新增文字；完整项目测试、Universal 构建和签名完整性检查通过。Windows x64 包完成 UI 构建、设置边界测试、包结构检查并确认携带共享高亮脚本，未在真实 Windows 主机运行验收。
- 同一版本包含可见后台优先启动登录修复：已保存账号的当前页面不再等待全部后台错峰启动后才进入自动登录。
- 发布完成必须同时核对公开 `v0.3.64` 标签、Release 三个附件、远端附件摘要和 `SHA256SUMS.txt`，不能以本机安装或本地压缩包代替 GitHub 发布证据。

## 2026-09-04 登录循环修复验证

- 本次发布目标为 macOS v0.3.61 build 68、Windows v0.3.61、Android v0.3.61 versionCode 61；发布结果以 GitHub v0.3.61 Release 和校验清单为准，不以本机安装成功作为发布证据。
- 旧版 v0.3.60 的 cg04 在主动注销后可复现循环：12:16:50 提交 TOTP，12:16:51 导航到 `/`，12:16:52 再回 `/login`；后续再次提交账号密码。
- 控制器缺陷：`credentialLoginPending` 置位后，`didFinish` 在加载首页提前清掉自动登录状态并取消结果确认，但未清掉认证恢复标记；后续扫描因此再次打开登录页。
- 新逻辑：加载首页和 `/ga-auth` 不等于认证完成；业务页面必须存在当前配置账号对应的 Token，统一完成确认时清掉恢复标记并更新 `authenticationEpoch`，防止旧回调修改新状态。加载超时暂停，不能继续提交账号密码。
- `scripts/check-login-completion.mjs` 抽取实际 Swift 方法编译执行，无真实凭据、网络或账户操作；覆盖加载首页、二次验证、缺少会话、恢复标记清除、旧回调、超时暂停。完整 `scripts/test.sh` 和 Universal 打包自检通过。
- 新版现场：12:18:15 cg04 记录 `login confirmed at /ck-dashboard; recovery flag cleared`，12:18:19、12:18:37、12:19:37 扫描返回；cg12 于 12:19:53 同样完成登录确认。
- 验证边界：上述为新版启动登录及短期连续扫描；新版主动注销后的恢复、刷新测试暂因桌面工具无法访问实际窗口而未完成，不能宣称长期或全平台彻底解决。

## 2026-09-05 macOS 网页查找高亮

- macOS v0.3.62 build 69 已完成本机验证并进入 GitHub 发布流程；最终发布状态以公开 `v0.3.62` 标签、Release 附件和 SHA256 校验清单为准。
- `PageFindScript` 使用浏览器 CSS Highlight API 标亮当前页面全部匹配字符；普通匹配为黄色，当前匹配为橙色并带下划线，不包装或改写业务页面 DOM。
- 查找栏显示“当前序号/总数”，输入新关键词从首项开始，上一个、下一个和 Shift-Enter 支持循环导航，Esc 或清空关键词会删除高亮。
- 若旧版 WebKit 不支持 CSS Highlight API，自动回退到 `WKWebView.find`，保留基本定位能力。
- macOS 打包自检会在真实 `WKWebView` 中核对大小写不敏感的三处高亮和第二项导航；Windows 继续使用 Chromium `findInPage` 的原生全部匹配高亮。
- GitHub v0.3.62 的 macOS 包经现场复核为 ad-hoc 内部签名（无 Team ID、无公证票据），Gatekeeper 对隔离下载包返回 `rejected`。在配置 Apple Developer ID 和公证凭据前，使用者需在“系统设置”→“隐私与安全性”中人工确认“仍要打开”；不要把本地 `codesign --verify` 通过描述为 Apple 公证通过。
