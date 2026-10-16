# 南京信息工程大学电费查询桌面工具（NUIST Electricity Query）

一个面向 Windows 的宿舍剩余电量桌面小工具，用于交流南京信息工程大学电费查询页面的个人使用方法。支持定时查询、本地历史曲线、日 / 周 / 月统计，以及可折叠的玻璃风格窗口。

本项目是非官方个人开源项目，与南京信息工程大学及相关服务运营方没有隶属或合作关系。它不附带有效登录凭据、个人房间配置或真实历史记录，不提供支付、充值或绕过登录的功能。学校页面和接口可能调整，当前方法不保证长期可用。

## 下载与启动

系统要求：Windows 10 / 11，系统自带的 Windows PowerShell 5.1 和 WPF。无需安装 Python、Node.js 或 GitHub 命令行工具。

1. 前往 [Releases](https://github.com/YONGZHEHAO/nuist-electricity-query/releases)，下载最新版本的便携 ZIP 并完整解压。
2. 双击 `NUIST-Electricity.exe`。这是无控制台启动器，请保留解压目录中的其他文件。
3. 点击工具中的“设置”，填写自己的房间显示名、查询参数和本人授权信息。首次使用请先阅读[配置与查询方法](docs/METHOD.md)。
4. 保存配置后刷新。授权有效、查询成功时，工具开始记录本机观测到的剩余电量。

只想体验界面，可在源码目录运行演示模式。演示数据完全虚构，不读取真实凭据、真实历史记录，也不发起网络请求：

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\src\PowerBalance.ps1 -Demo
```

## 功能与使用边界

- 默认每 60 秒查询一次；需要电脑开机、工具运行、网络正常且授权有效。
- 剩余电量曲线、本地历史记录、今日 / 本周 / 本月 / 全部区间，以及分钟 / 小时视图。
- 区间用电、正向电量变化、日均用电、预计可用时间和观测到的高耗电时段等参考统计。
- 窗口可拖动、从边缘及四角缩放；缩放时使用预览，结束后重新排布。
- 可折叠的桌面窗口和动态玻璃高光，展开时恢复原来的窗口尺寸。

历史记录从成功查询后开始积累，无法补回工具未运行期间的逐分钟数据。学校数据自身也可能有延迟，60 秒查询不等于每分钟都有新的电表读数。

统计根据相邻观测值推算，长时间断档、充值和校方数据修正都会影响结果。正向电量变化不是支付成功凭证，也不代表人民币充值金额；预计可用时间和高耗电时段不是电表账单或结算依据。

授权过期时，请在学校官方页面重新完成本人登录，再通过设置更新授权。工具不会从微信目录、浏览器配置或其他应用中自动搜集登录信息。

## 隐私与数据

所有个人配置和历史记录均保存在当前 Windows 用户的 `%LOCALAPPDATA%\NuistElectricityQuery\` 下：

- `config.json`：房间显示名及查询参数，不包含明文授权请求头。房间标识仍属于个人信息，请不要公开。
- `credentials.dat`：使用 Windows DPAPI 加密保存授权请求头，绑定当前 Windows 用户。不要分享该文件，也不要将其作为跨电脑备份使用。
- 历史记录：按房间查询配置的哈希分别保存 `history.csv`，不同配置不会混入同一份记录。

工具通过当前学校查询接口发送所配置的授权与房间参数，不设置项目维护者的遥测、数据上传或账号同步服务。开源代码、发行包和演示模式不包含你的个人运行数据。

DPAPI 保护的是磁盘上的凭据文件；运行时请求必须使用解密后的授权信息。同一 Windows 用户下运行的恶意程序仍可能访问个人数据。详见[隐私说明](docs/PRIVACY.md)。

## 从源码构建

在 Windows PowerShell 中进入项目目录：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Build.ps1
```

也可以直接运行桌面脚本：

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\src\PowerBalance.ps1
```

已完成本人配置时，可使用 `-Once` 做单次查询检查：

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\src\PowerBalance.ps1 -Once
```

主要文件：

```text
src/PowerBalance.ps1       桌面界面、查询和本地历史
src/PowerBalance.Motion.cs 窗口动画和运动辅助
scripts/Build.ps1          Windows 便携版构建入口
docs/METHOD.md            本人授权信息的手动配置方法
docs/PRIVACY.md           本地存储和公开发布边界
SECURITY.md               安全问题报告说明
```

## 反馈与贡献

欢迎提交兼容性修复、界面改进和不含个人数据的复现步骤。提交 Issue、截图或 Pull Request 前，请移除姓名、学号、房间信息、完整请求地址中的个人参数、Cookie、授权请求头及本地用户名。

请勿提交原始 HAR 文件、登录响应、真实历史 CSV、个人配置、日志或未脱敏的屏幕截图。可以使用 `-Demo` 生成演示界面。安全问题请参阅 [SECURITY.md](SECURITY.md)。

版本：`v0.1.0`。代码按 [MIT License](LICENSE) 发布；许可不代表授予任何学校账号或服务接口的访问权限。
