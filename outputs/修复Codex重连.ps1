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

$EnvironmentNames = @(
    'HTTP_PROXY',
    'HTTPS_PROXY',
    'ALL_PROXY',
    'WS_PROXY',
    'WSS_PROXY',
    'NO_PROXY'
)

$BackupDirectory = Join-Path $env:LOCALAPPDATA 'CodexProxyFix'
$BackupPath = Join-Path $BackupDirectory 'environment-backup.json'
$DefaultNoProxy = 'localhost,127.0.0.1,::1,172.31.0.0/16'

function Get-UserEnvironmentValue {
    param([Parameter(Mandatory)][string]$Name)

    return [Environment]::GetEnvironmentVariable($Name, 'User')
}

function Set-UserEnvironmentValue {
    param(
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()][string]$Value
    )

    [Environment]::SetEnvironmentVariable($Name, $Value, 'User')
    Set-Item -Path "Env:$Name" -Value $(if ($null -eq $Value) { '' } else { $Value })
}

function Get-ListeningProxy {
    $candidatePorts = @(10808, 7890, 7897, 10809, 1080, 8080, 8888)
    $listeners = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
        Where-Object {
            $_.LocalPort -in $candidatePorts -and
            $_.LocalAddress -in @('127.0.0.1', '0.0.0.0', '::', '::1')
        }

    foreach ($port in $candidatePorts) {
        if ($listeners.LocalPort -contains $port) {
            return "http://127.0.0.1:$port"
        }
    }

    return $null
}

function Resolve-Proxy {
    if ($Proxy) {
        $candidate = $Proxy
    }
    else {
        $systemProxy = (Get-ItemProperty `
                -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' `
                -ErrorAction SilentlyContinue).ProxyServer

        if ($systemProxy) {
            if ($systemProxy -match '^(https?://|socks5h?://)') {
                $candidate = $systemProxy
            }
            elseif ($systemProxy -notmatch '=') {
                $candidate = "http://$systemProxy"
            }
        }

        if (-not $candidate) {
            $candidate = Get-ListeningProxy
        }
    }

    if (-not $candidate) {
        throw 'No local proxy was detected. Run again with -Proxy http://127.0.0.1:PORT.'
    }

    $uri = $null
    if (-not [Uri]::TryCreate($candidate, [UriKind]::Absolute, [ref]$uri)) {
        throw "Invalid proxy URL: $candidate"
    }

    if ($uri.Scheme -notin @('http', 'https', 'socks5', 'socks5h')) {
        throw "Unsupported proxy scheme: $($uri.Scheme)"
    }

    return $uri.AbsoluteUri.TrimEnd('/')
}

function Test-ProxyConnection {
    param([Parameter(Mandatory)][string]$ProxyUrl)

    $uri = [Uri]$ProxyUrl
    $tcp = [Net.Sockets.TcpClient]::new()

    try {
        $connectTask = $tcp.ConnectAsync($uri.Host, $uri.Port)
        if (-not $connectTask.Wait(3000) -or -not $tcp.Connected) {
            throw "Proxy is not listening at $($uri.Host):$($uri.Port)."
        }
    }
    finally {
        $tcp.Dispose()
    }

    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if (-not $curl) {
        Write-Warning 'curl.exe was not found. The local proxy port is open, but the OpenAI endpoint was not tested.'
        return
    }

    $status = & $curl.Source `
        --silent `
        --show-error `
        --output NUL `
        --write-out '%{http_code}' `
        --connect-timeout 8 `
        --max-time 20 `
        --proxy $ProxyUrl `
        'https://api.openai.com/v1/models'

    if ($LASTEXITCODE -ne 0) {
        throw "The proxy cannot reach OpenAI. curl.exe exited with code $LASTEXITCODE."
    }

    if ($status -notin @('200', '401')) {
        throw "The proxy reached OpenAI but returned unexpected HTTP status $status."
    }

    Write-Host "OpenAI connection test passed (HTTP $status)."
}

function Save-EnvironmentBackup {
    if (Test-Path -LiteralPath $BackupPath) {
        return
    }

    New-Item -ItemType Directory -Path $BackupDirectory -Force | Out-Null
    $backup = [ordered]@{}

    foreach ($name in $EnvironmentNames) {
        $value = Get-UserEnvironmentValue -Name $name
        $backup[$name] = [ordered]@{
            Exists = $null -ne $value
            Value  = $value
        }
    }

    $backup | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $BackupPath -Encoding UTF8
}

function Restart-CodexApplication {
    $package = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending |
        Select-Object -First 1

    if ($package) {
        $appId = "$($package.PackageFamilyName)!App"
    }
    else {
        $app = Get-StartApps |
            Where-Object { $_.Name -in @('Codex', 'ChatGPT') -or $_.AppID -like '*OpenAI.Codex*' } |
            Select-Object -First 1
        $appId = $app.AppID
    }

    if (-not $appId) {
        Write-Warning 'The Codex application registration was not found. Restart Codex manually.'
    }

    $codePath = $null
    if ($RestartVSCode) {
        $codePath = Get-Process -Name 'Code' -ErrorAction SilentlyContinue |
            Where-Object Path |
            Select-Object -First 1 -ExpandProperty Path

        if (-not $codePath) {
            $codeCommand = Get-Command 'code.cmd' -ErrorAction SilentlyContinue
            if ($codeCommand) {
                $codePath = $codeCommand.Source
            }
        }
    }

    $restartVSCodeCommands = ''
    if ($RestartVSCode) {
        if ($codePath) {
            $escapedCodePath = $codePath.Replace("'", "''")
            $restartVSCodeCommands = @"
Get-Process -Name 'Code' -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2
Start-Process -FilePath '$escapedCodePath'
"@
        }
        else {
            Write-Warning 'VS Code executable was not found. Restart VS Code manually.'
        }
    }

    $restartCodexCommand = ''
    if ($appId) {
        $restartCodexCommand = "Start-Process 'explorer.exe' 'shell:AppsFolder\$appId'"
    }

    $helperPath = Join-Path $env:TEMP 'restart-codex-after-proxy-fix.ps1'
    $helper = @"
Start-Sleep -Seconds 3
Get-Process -Name 'ChatGPT','Codex','codex' -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2
$restartVSCodeCommands
$restartCodexCommand
Remove-Item -LiteralPath `$PSCommandPath -Force -ErrorAction SilentlyContinue
"@

    Set-Content -LiteralPath $helperPath -Value $helper -Encoding UTF8
    Start-Process powershell.exe `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $helperPath) `
        -WindowStyle Hidden

    Write-Host 'Codex client restart scheduled. Application windows may close shortly.'
}

function Show-Status {
    Write-Host 'Codex proxy environment:'
    foreach ($name in $EnvironmentNames) {
        $value = Get-UserEnvironmentValue -Name $name
        if ($null -eq $value) {
            $value = '<not set>'
        }
        Write-Host ("  {0}={1}" -f $name, $value)
    }

    Write-Host ("Backup: {0}" -f $(if (Test-Path -LiteralPath $BackupPath) { $BackupPath } else { '<not found>' }))
}

switch ($Action) {
    'Status' {
        Show-Status
    }

    'Install' {
        $proxyUrl = Resolve-Proxy
        Write-Host "Using proxy: $proxyUrl"

        if (-not $SkipConnectionTest) {
            Test-ProxyConnection -ProxyUrl $proxyUrl
        }

        Save-EnvironmentBackup

        foreach ($name in @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY')) {
            Set-UserEnvironmentValue -Name $name -Value $proxyUrl
        }
        foreach ($name in @('WS_PROXY', 'WSS_PROXY')) {
            Set-UserEnvironmentValue -Name $name -Value $null
        }
        Set-UserEnvironmentValue -Name 'NO_PROXY' -Value $DefaultNoProxy

        Write-Host 'Proxy variables installed for the current Windows user.'
        Write-Host 'Restart Codex so its background processes inherit the new environment.'

        if ($RestartCodex) {
            Restart-CodexApplication
        }
    }

    'Remove' {
        if (-not (Test-Path -LiteralPath $BackupPath)) {
            throw "Backup not found: $BackupPath"
        }

        $backup = Get-Content -LiteralPath $BackupPath -Raw | ConvertFrom-Json
        foreach ($name in $EnvironmentNames) {
            $item = $backup.$name
            if ($item.Exists) {
                Set-UserEnvironmentValue -Name $name -Value ([string]$item.Value)
            }
            else {
                Set-UserEnvironmentValue -Name $name -Value $null
            }
        }

        Remove-Item -LiteralPath $BackupPath -Force
        Write-Host 'Previous proxy environment restored for the current Windows user.'
        Write-Host 'Restart Codex to apply the restored environment.'

        if ($RestartCodex) {
            Restart-CodexApplication
        }
    }
}
