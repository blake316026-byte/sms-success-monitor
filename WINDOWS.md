# Windows 未签名版与拦截提示

本客户端未使用商业代码签名证书。安装包测试通过不代表 Windows 会信任发布者，下载后仍可能被系统拦截；本次发布不承诺消除所有安全提示。

## 显示“智能应用控制已阻止可能不安全的应用”

先确认文件来自本仓库正式 Release，并核对 SHA-256。仅当你信任该文件、理解风险且有权管理这台电脑时，才自行选择以下操作：

1. 在开始菜单搜索并打开“Windows 安全中心”。
2. 进入“应用和浏览器控制”。
3. 打开“智能应用控制设置”。
4. 选择“关闭”，阅读并确认系统提示，然后重新打开客户端。

**这会关闭整台电脑的智能应用控制，不是只放行本客户端。** 目前该功能没有单个应用的放行选项。关闭后会降低对未知应用的防护；不愿降低防护时，请保留开启并不要运行该未签名包。

不要关闭 Microsoft Defender 实时保护、防火墙，也不要导入陌生根证书或运行修改安全策略的脚本。客户端及升级程序不会替你更改这些设置。组织管理的电脑若不允许修改，请联系管理员。

能否重新开启取决于 Windows 版本、更新和设备状态；微软已为近期更新提供重新开启能力，但较旧系统可能需要重置。**以本机提示为准，不要在没有确认恢复条件前关闭。**

“Windows 已保护你的电脑”（SmartScreen）和病毒检测提示是其他情况，不适用上述判断；请先核对具体提示，不要盲目关闭其他保护。

微软说明：[智能应用控制设置](https://support.microsoft.com/zh-cn/windows/security/windows-security/app-browser-control-in-the-windows-security-app)、[智能应用控制常见问题](https://support.microsoft.com/zh-cn/windows/security/threat-malware-protection/smart-app-control-frequently-asked-questions)。

## 安装和数据

完整解压 ZIP，不要只拿出 EXE，不需要安装 Node.js。
精简版升级请退出旧客户端及托盘后替换程序，保留原有用户数据目录；完整版按随包 README 使用 Upgrade.cmd。
不要删除 AppData 中的用户数据，不要把使用后的目录或备份重新分发。
账号与持久登录数据会沿用；网站主动过期或撤销的会话仍需重新认证。
