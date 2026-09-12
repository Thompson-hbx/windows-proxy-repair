# Windows 代理环境修复工具

本仓库从原来的 **Codex 重连修复工具**扩展为通用的 Windows 用户级代理环境诊断与修复工具，同时保留原 Codex 入口和回滚兼容性。

它针对一类常见但容易误判的问题：**浏览器、Electron 或 Windows 系统代理工作正常，但 CLI、Go 后端、language server 等子进程没有继承 `HTTP_PROXY` / `HTTPS_PROXY`，因此仍然直连外网并超时。**

典型表现包括：

- Codex / CLI 反复重连、请求超时或 OAuth token exchange 失败；
- Antigravity 主窗口可以启动，但 `language_server` 直连 Google 超时，最终本地 UI bootstrap 超时白屏；
- Windows Internet Settings 已配置本地代理，但 env-aware 程序仍不走代理。

## 设计原则

工具按以下层次工作：

1. 读取 Windows 用户系统代理、用户环境变量和常见本地代理监听端口；
2. 比较直接访问与经代理访问的结果，识别 `PROCESS_PROXY_GAP`；
3. 在修改前保存用户环境变量回滚快照；
4. 写入用户级 `HTTP_PROXY`、`HTTPS_PROXY`、`ALL_PROXY`；
5. 合并而不是覆盖 `NO_PROXY`，强制保留 `localhost,127.0.0.1,::1`；
6. 广播 Windows `Environment` 变更通知；
7. 必要时重启正在运行的客户端，使其重新继承环境；
8. 支持完整回滚。

工具不会修改 sing-box / Clash 等代理程序配置，也不会关闭 TLS 校验、防火墙、Defender 或 Chromium sandbox。

## 主入口

### 通用入口

双击：

```text
outputs/一键修复代理环境.bat
```

默认会：

- 自动发现本地代理；
- 测试 OpenAI 和 Google 关键网络路径；
- 安装用户级代理环境；
- 广播环境变量变更；
- 重启可安全识别的正在运行客户端。

只诊断、不修改：

```powershell
& '.\outputs\一键修复代理环境.bat' diagnose
```

查看当前状态：

```powershell
& '.\outputs\一键修复代理环境.bat' status
```

仅测试代理出口：

```powershell
& '.\outputs\一键修复代理环境.bat' test
```

回滚：

```powershell
& '.\outputs\一键修复代理环境.bat' remove
```

### PowerShell 直接调用

```powershell
# 综合诊断
powershell -NoProfile -ExecutionPolicy Bypass -File '.\outputs\修复代理环境.ps1' `
    -Action Diagnose -Profile All

# 只测试 Antigravity / Google 路径
powershell -NoProfile -ExecutionPolicy Bypass -File '.\outputs\修复代理环境.ps1' `
    -Action Test -Profile Antigravity

# 修复 Antigravity，并在完成后重启它
powershell -NoProfile -ExecutionPolicy Bypass -File '.\outputs\修复代理环境.ps1' `
    -Action Install -Profile Antigravity -RestartAntigravity

# 修复 Codex，并重启 Codex + VS Code
powershell -NoProfile -ExecutionPolicy Bypass -File '.\outputs\修复代理环境.ps1' `
    -Action Install -Profile Codex -RestartCodex -RestartVSCode

# 显式指定代理
powershell -NoProfile -ExecutionPolicy Bypass -File '.\outputs\修复代理环境.ps1' `
    -Action Install -Profile All -Proxy 'http://127.0.0.1:10808'
```

支持的 Profile：

- `All`：OpenAI + Google；
- `Codex`：OpenAI API；
- `Antigravity`：Google generate_204、OAuth、Cloud Code；
- `Generic`：通用 OpenAI + Google 连通性验证。

## 诊断结果

`Diagnose` 可能给出：

- `PROCESS_PROXY_GAP`：直连失败、代理成功，但用户级 `HTTP_PROXY` / `HTTPS_PROXY` 未指向工作代理。最符合 Go/CLI / language server 不读取 Windows 系统代理的故障模式；
- `ENV_PROXY_MISMATCH`：代理可用，但环境变量与工作代理不一致；
- `ENV_PROXY_OK`：环境变量已正确，优先重启受影响进程并继续检查应用自身问题；
- `PROXY_PATH_FAILURE`：代理自身无法访问目标；
- `PROXY_LISTENER_UNREACHABLE`：代理端口不可达；
- `NO_PROXY_CANDIDATE`：未发现可用代理候选。

## 代理发现顺序

未显式传入 `-Proxy` 时，会综合检查：

1. Windows 用户系统代理（仅 `ProxyEnable=1` 时）；
2. 用户级 `HTTPS_PROXY` / `HTTP_PROXY` / `ALL_PROXY`；
3. 常见本地监听端口：`10808`、`7890`、`7897`、`10809`、`1080`、`8080`、`8888`。

如果系统代理使用 `http=...;https=...` 形式，会优先提取 HTTPS / HTTP 代理。

## NO_PROXY

修复时不会直接覆盖现有 `NO_PROXY`，而是将以下 loopback 项合并进去：

```text
localhost,127.0.0.1,::1
```

这用于避免 Antigravity 等应用的本地 UI / backend loopback 被错误送入外部代理。

Windows 环境变量名称在系统层面不区分大小写，因此脚本使用规范化的大写变量名；对通常读取小写 `http_proxy` / `https_proxy` 的 Windows 程序仍会得到同一环境变量。

## 回滚

通用工具的备份位于：

```text
%LOCALAPPDATA%\ProxyEnvironmentFix\environment-backup.json
```

如果检测到旧版 Codex 工具已有：

```text
%LOCALAPPDATA%\CodexProxyFix\environment-backup.json
```

通用工具会优先导入它作为原始回滚基线，避免把“已经修复后的代理值”误当作初始状态。

原 Codex 入口仍使用旧备份路径和旧格式，因此原有 `remove` 行为保持兼容。

## Codex 兼容入口

以下旧入口保留：

```text
outputs/一键修复Codex重连.bat
outputs/修复Codex重连.ps1
```

它们现在作为兼容层调用统一核心，同时保留：

- 原 `Install / Status / Remove` 参数；
- `%LOCALAPPDATA%\CodexProxyFix\environment-backup.json`；
- Codex + VS Code 重启行为；
- 旧版 `NO_PROXY` 中的 `172.31.0.0/16` 兼容项。

旧 batch 已改为显式调用 `修复Codex重连.ps1`，不再通过 `*.ps1` 通配符寻找脚本，因此新增通用 PowerShell 文件后不会误调用错误入口。

## 文件结构

```text
outputs/
├─ 一键修复代理环境.bat      # 通用用户入口
├─ 修复代理环境.ps1          # 统一核心：诊断 / 测试 / 修复 / 回滚
├─ 一键修复Codex重连.bat    # 旧 Codex 兼容入口
└─ 修复Codex重连.ps1        # 旧参数兼容层
```

## 安全边界

脚本不会：

- 删除应用 profile / AppData；
- 修改 sing-box / Clash 路由；
- 设置 `--no-sandbox`；
- 设置 `--ignore-certificate-errors`；
- 关闭 Defender 或防火墙；
- 保存账号、Token、Cookie、OAuth 凭据。

用户级 `HTTP_PROXY` / `HTTPS_PROXY` 会影响所有读取这些变量的新进程，这是该修复的预期作用范围。若不希望继续使用，可执行 `remove` 恢复原值。

## 要求

- Windows 10 / Windows 11；
- Windows PowerShell 5.1 或更高版本；
- 本地代理程序正在运行；
- 推荐存在 `curl.exe`。如果缺少 curl，只能验证代理端口，无法完成外部路由对照测试。

## 验证建议

修改代码后至少验证：

```powershell
# PowerShell 语法解析
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path '.\outputs\修复代理环境.ps1'),
    [ref]$null,
    [ref]$errors
)
$errors

# 无副作用状态检查
& '.\outputs\一键修复代理环境.bat' status

# 无副作用诊断
& '.\outputs\一键修复代理环境.bat' diagnose

# 旧入口仍可用
& '.\outputs\一键修复Codex重连.bat' status
```
