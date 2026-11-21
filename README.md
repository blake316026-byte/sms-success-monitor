# SMS Platform Workbench

**公开精简版 v0.3.87**（macOS / Windows）。Windows 为未签名版。

## 下载

- [macOS（Apple Silicon / Intel）](https://github.com/blake316026-byte/sms-success-monitor/releases/latest/download/SMS-Success-Monitor-macOS-universal.zip)
- [Windows x64](https://github.com/blake316026-byte/sms-success-monitor/releases/latest/download/SMS-Success-Monitor-Windows-x64.zip)
- [Android（保持 v0.3.85）](https://github.com/blake316026-byte/sms-success-monitor/releases/download/v0.3.85/SMS-Success-Monitor-Android.apk)

## 本次更新

更新 macOS / Windows，保持原精简版功能范围：

- 展示订单创建时间（北京时间）和等待时长。
- 新增等待时长筛选：输入 5 显示等待 5 分钟及以上的订单，留空或 0 显示全部；可与平台、订单搜索组合。
- 仍未处理且等待时间超过 20 分钟的订单以浅红底、红字高亮，并显示超时数量。
- 时间缺失、异常或查询尚未重新确认的旧结果不作为超时告警。
- 提现挂单 TG 报警：默认关闭，可设置超时时间（默认 20 分钟）并勾选发送平台。同一平台同一订单北京时间每天最多提醒一次，发送不明不自动重发，记录保留 24 小时。
- 已有 TG 设置升级时保留现有平台勾选；新增平台默认不勾选。新用户需自行填写 Token、群 ID 并选择平台。
- 修复 macOS 网页“汇入／上传”点击无反应，恢复系统文件选择框；不会自动选择或上传文件。

其他功能范围不变，不附带真实后台、账号或个人配置，仅保留原有示例占位页面。原公开版用户升级后沿用原有本地数据；请替换程序，不要删除用户数据目录。Android 尚无此页面，本次不更新。

## Windows 智能应用控制拦截

本包未使用商业代码签名，测试通过不代表 Windows 信任发布者。若显示“智能应用控制已阻止可能不安全的应用”，先确认来源并核对 Release 中的 SHA-256。

仅在信任本包、理解风险且有设备管理权限时，可手动进入：
**Windows 安全中心 → 应用和浏览器控制 → 智能应用控制设置 → 关闭**，确认提示后重开客户端。

这会影响整台电脑，不是只放行本应用，目前没有单应用例外。不要关闭 Defender 实时保护或防火墙。能否重新开启以本机提示为准，旧系统可能需要重置；不愿降低防护时请保留开启，不运行未签名包。组织设备请联系管理员。

[完整步骤与微软官方说明](WINDOWS.md)。客户端不会自动修改系统保护；SmartScreen 或病毒检测等其他提示需分别判断。

## 安装与升级

Windows 完整解压后运行“SMS Success Monitor.exe”，无需 Node.js，不要只取出 EXE。退出旧程序及托盘后替换程序，保留原有 AppData 用户数据。
macOS 退出旧程序后替换“SMS Platform Workbench.app”，保留原应用标识和用户数据；安装包为临时签名、未经 Apple 公证。
升级保留账号、密码、密钥、TG 设置、当天发送记录和持久登录数据。网站已撤销或过期的登录仍需重新认证。不要分发使用后的用户数据目录。

## 功能范围

| 功能 | macOS | Windows | Android |
| --- | --- | --- | --- |
| 后台工作台、本地登录配置、网页高亮 | 支持 | 支持 | 支持 |
| 全平台待处理订单 | 支持 | 支持 | 尚未移植 |
| 提现审核人员查询 | 支持 | 支持 | 尚未移植 |

历史 Release 仍保留原功能，不属于本次精简版。请下载 **v0.3.83 或后续明确标注的公开精简版**。

