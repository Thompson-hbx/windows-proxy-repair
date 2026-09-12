[CmdletBinding()]
param(
    [ValidateSet('Install', 'Status', 'Remove')]
    [string]$Action = 'Install',

    [string]$Proxy,

    [switch]$RestartCodex,

    [switch]$RestartVSCode,

    [switch]$SkipConnectionTest
)

$ErrorActionPreference = 'Stop'
$coreScript = Join-Path $PSScriptRoot '修复代理环境.ps1'

if (-not (Test-Path -LiteralPath $coreScript)) {
    throw "Unified proxy repair script was not found: $coreScript"
}

$arguments = @{
    Action = $Action
    Profile = 'Codex'
    LegacyBackup = $true
    LegacyCodexBehavior = $true
}

if ($Proxy) {
    $arguments.Proxy = $Proxy
}
if ($RestartCodex) {
    $arguments.RestartCodex = $true
}
if ($RestartVSCode) {
    $arguments.RestartVSCode = $true
}
if ($SkipConnectionTest) {
    $arguments.SkipConnectionTest = $true
}

& $coreScript @arguments
