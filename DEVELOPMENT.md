# SMS Success Monitor — 开发与维护真源

本文是 SMS Success Monitor 的开发、维护、跨窗口接手和技术决策真源。`README.md` 面向使用者，本文面向主管、开发者和后续 Codex 窗口。

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
