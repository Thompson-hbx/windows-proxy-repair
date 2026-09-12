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

$coreScript = Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File |
    Where-Object { $_.FullName -ne $PSCommandPath } |
    Where-Object {
        Select-String -LiteralPath $_.FullName `
            -Pattern "ValidateSet\('Diagnose', 'Install', 'Status', 'Remove', 'Test'\)" `
            -Quiet
    } |
    Select-Object -First 1 -ExpandProperty FullName

if (-not $coreScript) {
    throw 'Unified proxy repair core was not found beside the compatibility script.'
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
