# Codex 重连修复工具

## 用途

本项目提供 Windows 用户代理环境变量的检查、修复和回滚脚本，用于处理 Codex 反复重新连接或请求超时的问题。

## 当前状态

脚本可自动检测常见本地代理端口，等待代理稳定后测试 OpenAI 接口连通性，写入当前用户代理变量，并重启 VS Code 与 Microsoft Store 版 Codex，使两者重新继承代理配置。连接测试最多尝试 3 次，每次失败后等待 2 秒。

## 要求

- Windows 10 或 Windows 11
- Windows PowerShell 5.1 或更高版本
- 本地代理程序正在运行
- `curl.exe` 用于完整连通性测试；缺失时只检查代理端口

## 使用方法

先保存 VS Code 中所有文件，然后双击 `outputs/一键修复Codex重连.bat`。确认提示后，脚本会执行修复并重启 VS Code 与 Codex。

命令行检查状态：

```powershell
& '.\outputs\一键修复Codex重连.bat' status
```

回滚到首次修复前的用户环境变量：

```powershell
& '.\outputs\一键修复Codex重连.bat' remove
```

## 验证命令

```powershell
& '.\outputs\一键修复Codex重连.bat' status
```

## 项目结构

- `outputs/一键修复Codex重连.bat`：双击入口及状态、回滚命令，重启前会提示保存文件。
- `outputs/修复Codex重连.ps1`：代理检测、测试、环境变量备份与恢复、VS Code 与 Codex 重启逻辑。
- `work/`：临时测试产物目录。

## 配置

默认检测端口包括 `10808`、`7890`、`7897`、`10809`、`1080`、`8080` 和 `8888`。备份保存在 `%LOCALAPPDATA%\CodexProxyFix\environment-backup.json`。

连接测试开始前等待 2 秒；失败时最多重试 2 次，每次间隔 2 秒。连续 3 次失败后才中止修复。

## 已知限制

- 本地代理必须在运行，并允许 Codex 访问外部网络。
- 脚本修复的是当前 Windows 用户环境变量，不负责阻止其他软件再次清除这些变量。
- 修复和回滚会关闭 VS Code；必须先保存尚未保存的编辑内容。
