# Windows Proxy Repair (Windows 代理环境修复工具)

> A Windows proxy-environment diagnostics and repair tool for env-aware AI/CLI clients.

本工具用于诊断和修复 Windows 上一类常见的代理断层（process proxy gap）问题：浏览器或 Electron 等 GUI 客户端能读取 Windows 系统代理，但 CLI、Go 后端、language server 等进程只读取用户级环境变量 `HTTP_PROXY` / `HTTPS_PROXY`，从而仍直接尝试外网直连并导致连接超时或失败。

核心支持范围包括：

- **Codex**：解决反复重连、OAuth token exchange 或 API 请求超时；
- **Antigravity**：主程序启动但 `language_server` 直连 Google 超时导致本地 UI bootstrap 白屏；
- **Go CLI / Language Server**：开发工具链、终端 CLI 及其他读取 `HTTP_PROXY` / `HTTPS_PROXY` 的 Windows 原生进程。

## 目录结构

```text
scripts/
├─ proxy-repair.ps1              # 统一核心：诊断 / 测试 / 修复 / 回滚
├─ proxy-repair.cmd              # 通用双击 / 命令行入口
└─ compat/
   ├─ codex-proxy-fix.ps1        # Codex 旧参数兼容层
   └─ codex-proxy-fix.cmd        # Codex 兼容入口

.github/workflows/
└─ windows-smoke.yml             # Windows PowerShell 语法与 Status smoke test

tmp/                             # 临时测试产物，不提交
```

可执行路径统一采用 **ASCII + lowercase + kebab-case**。这是刻意的工程约束：Windows PowerShell 5.1、批处理和部分自动化工具对 UTF-8 非 ASCII 文件名存在兼容性风险。

## 工作模型

工具按以下流程工作：

1. 检查 Windows 用户系统代理、用户环境变量和常见本地代理端口；
2. 对比直连与代理访问结果；
3. 判断是否存在 process proxy gap；
4. 修改前保存环境变量回滚快照；
5. 写入用户级 `HTTP_PROXY`、`HTTPS_PROXY`、`ALL_PROXY`；
6. 保留并合并 `NO_PROXY`，确保 `localhost,127.0.0.1,::1` 绕过代理；
7. 广播 Windows `Environment` 变更；
8. 必要时重启相关客户端，使其重新继承环境；
9. 支持完整回滚。

工具不会删除应用 profile，也不会关闭 TLS 校验、Defender、防火墙或 Chromium sandbox；不会主动修改 sing-box / Clash 路由。

## 使用方法

### 通用入口

双击：

```text
scripts\proxy-repair.cmd
```

只诊断、不修改：

```powershell
.\scripts\proxy-repair.cmd diagnose
```

查看状态：

```powershell
.\scripts\proxy-repair.cmd status
```

测试代理出口：

```powershell
.\scripts\proxy-repair.cmd test
```

回滚：

```powershell
.\scripts\proxy-repair.cmd remove
```

### PowerShell 直接调用

```powershell
# 综合诊断
powershell -NoProfile -ExecutionPolicy Bypass -File '.\scripts\proxy-repair.ps1' `
    -Action Diagnose -Profile All

# 只测试 Antigravity / Google 路径
powershell -NoProfile -ExecutionPolicy Bypass -File '.\scripts\proxy-repair.ps1' `
    -Action Test -Profile Antigravity

# 修复 Antigravity，并在完成后重启它
powershell -NoProfile -ExecutionPolicy Bypass -File '.\scripts\proxy-repair.ps1' `
    -Action Install -Profile Antigravity -RestartAntigravity

# 修复 Codex，并重启 Codex + VS Code
powershell -NoProfile -ExecutionPolicy Bypass -File '.\scripts\proxy-repair.ps1' `
    -Action Install -Profile Codex -RestartCodex -RestartVSCode

# 显式指定代理
powershell -NoProfile -ExecutionPolicy Bypass -File '.\scripts\proxy-repair.ps1' `
    -Action Install -Profile All -Proxy 'http://127.0.0.1:10808'
```

支持的 Profile：

- `All`：OpenAI + Google；
- `Codex`：OpenAI API；
- `Antigravity`：Google generate_204、OAuth、Cloud Code；
- `Generic`：通用 OpenAI + Google 连通性验证。

## 诊断结果

`Diagnose` 可能输出：

- `PROCESS_PROXY_GAP`：直连失败、代理成功，但用户级 `HTTP_PROXY` / `HTTPS_PROXY` 未指向工作代理；
- `ENV_PROXY_MISMATCH`：代理可用，但环境变量与工作代理不一致；
- `ENV_PROXY_OK`：环境变量已正确，应优先重启进程并继续检查应用自身问题；
- `PROXY_PATH_FAILURE`：代理出口访问目标失败；
- `PROXY_LISTENER_UNREACHABLE`：代理端口不可达；
- `NO_PROXY_CANDIDATE`：没有发现可用代理候选。

## NO_PROXY

修复时不会覆盖原有 `NO_PROXY`，而是至少合并：

```text
localhost,127.0.0.1,::1
```

这用于保证 Antigravity 等应用的本地 UI / backend loopback 不被错误送入外部代理。

## 回滚

通用工具备份：

```text
%LOCALAPPDATA%\ProxyEnvironmentFix\environment-backup.json
```

Codex 兼容层继续支持：

```text
%LOCALAPPDATA%\CodexProxyFix\environment-backup.json
```

如果发现已有旧 Codex 备份，通用工具会优先将它视为原始回滚基线，避免把“已经修复后的代理值”错误记录成初始状态。

## Codex 兼容入口

原 Codex 功能迁移到：

```text
scripts\compat\codex-proxy-fix.cmd
scripts\compat\codex-proxy-fix.ps1
```

它们仍保留：

- `Install / Status / Remove` 参数；
- `%LOCALAPPDATA%\CodexProxyFix\environment-backup.json`；
- Codex + VS Code 重启行为；
- 原有 `172.31.0.0/16` NO_PROXY 兼容逻辑。

## 安全边界

脚本不会：

- 删除应用 profile / AppData；
- 修改 sing-box / Clash 路由；
- 设置 `--no-sandbox`；
- 设置 `--ignore-certificate-errors`；
- 关闭 Defender 或防火墙；
- 保存账号、Token、Cookie 或 OAuth 凭据。

用户级 `HTTP_PROXY` / `HTTPS_PROXY` 会影响所有读取这些变量的新进程，这是该工具的预期作用范围；如不需要，可执行 `remove` 恢复原值。

## 要求

- Windows 10 / Windows 11；
- Windows PowerShell 5.1 或更高版本；
- 本地代理程序正在运行；
- 推荐存在 `curl.exe`，用于完整外部路由测试。

## 验证

```powershell
# PowerShell 语法解析
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path '.\scripts\proxy-repair.ps1'),
    [ref]$null,
    [ref]$errors
)
$errors

# 无副作用状态检查
.\scripts\proxy-repair.cmd status

# 无副作用诊断
.\scripts\proxy-repair.cmd diagnose

# Codex 兼容入口
.\scripts\compat\codex-proxy-fix.cmd status
```
