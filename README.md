# Codex Recovery

针对 Windows AppX 版 Codex 特定更新故障的诊断与恢复脚本，提供只读检查、受条件保护的修复及重启后复查。

这是独立社区工具，与 OpenAI 无隶属或官方支持关系。它不是通用启动修复器，也不适用于所有 Codex 故障。

## 适用范围

- Windows 10/11，安装 AppX 版 Codex。
- 修复操作使用系统 Windows PowerShell 5.1，并需要当前用户的管理员权限。
- 仅在程序包处于 `Servicing`、服务登记属于不同版本且近期部署日志同时匹配 `windows.service` 和 `0x80070005` 时，进入服务注册清理。
- 不支持 macOS、Linux、WSL 或仅安装 npm CLI 的环境；跨设备兼容性尚未全面实测。

## 使用

下载或克隆仓库，将文件保存在当前用户可写的本地目录。建议首先执行只读检查：

```powershell
.\Check-Codex.cmd
```

| 入口 | 用途 |
| --- | --- |
| `Check-Codex.cmd` | 只读诊断，不删除、不重启、不启动客户端 |
| `Repair-Codex.cmd` | 符合条件后备份并清理目标服务注册项，提示重启 |
| `Resume-Codex.cmd` | 继续当前用户、当前电脑的重启后复查 |
| `Verify-Codex.cmd` | 检查当前状态并尝试启动客户端 |

修复会更改指定服务的注册表项并登记一次性登录后复查。执行前保存工作，阅读 [使用说明](使用说明.md)，并保持工具位置不变，直到复查完成。脚本不会自动解决网络、账号或组织设置问题，本地检查通过也不代表在线功能已恢复。

## 数据与隐私

备份、日志和状态默认保存在 `%LOCALAPPDATA%\CodexRecovery`，不在仓库目录中。注册表备份和旧日志可能含本机信息，不要上传到 GitHub 或 Issue；提交反馈前请人工检查内容。

仓库的 `.gitignore` 排除了常见恢复记录、注册表导出、日志、转储、凭据文件及快捷方式，但不能替代人工检查。

## 验证

在 Windows PowerShell 5.1 中运行现有保护条件测试：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-Guards.ps1
```

测试覆盖故障匹配条件、脚本语法、恢复状态身份校验和摘要输出隐私保护；还会读取本机状态，并在包正常时验证修复入口会跳过操作。它不执行真实故障修复或重启，不能替代目标环境恢复验证。

## 许可证

采用 [MIT License](LICENSE)。允许使用、修改和再分发，需保留版权及许可声明；软件按现状提供，不作保证。
