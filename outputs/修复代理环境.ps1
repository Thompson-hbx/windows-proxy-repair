[CmdletBinding()]
param(
    [ValidateSet('Diagnose', 'Install', 'Status', 'Remove', 'Test')]
    [string]$Action = 'Diagnose',

    [ValidateSet('All', 'Codex', 'Antigravity', 'Generic')]
    [string]$Profile = 'All',

    [string]$Proxy,

    [switch]$RestartCodex,

    [switch]$RestartVSCode,

    [switch]$RestartAntigravity,

    [switch]$RestartRunningApps,

    [switch]$SkipConnectionTest,

    [switch]$LegacyBackup,

    [switch]$LegacyCodexBehavior
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

$LegacyBackupDirectory = Join-Path $env:LOCALAPPDATA 'CodexProxyFix'
$LegacyBackupPath = Join-Path $LegacyBackupDirectory 'environment-backup.json'
$BackupDirectory = Join-Path $env:LOCALAPPDATA 'ProxyEnvironmentFix'
$GeneralBackupPath = Join-Path $BackupDirectory 'environment-backup.json'
$BackupPath = if ($LegacyBackup) { $LegacyBackupPath } else { $GeneralBackupPath }
$ConnectionTestMaxAttempts = 3
$ConnectionTestInitialDelaySeconds = 2
$ConnectionTestRetryDelaySeconds = 2
$RequiredNoProxyEntries = @('localhost', '127.0.0.1', '::1')
$CommonProxyPorts = @(10808, 7890, 7897, 10809, 1080, 8080, 8888)

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

    if ($null -eq $Value) {
        Remove-Item -Path "Env:$Name" -ErrorAction SilentlyContinue
    }
    else {
        Set-Item -Path "Env:$Name" -Value $Value
    }
}

function Normalize-ProxyUrl {
    param([Parameter(Mandatory)][string]$Candidate)

    $value = $Candidate.Trim()
    if (-not $value) {
        return $null
    }

    if ($value -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') {
        $value = "http://$value"
    }

    $uri = $null
    if (-not [Uri]::TryCreate($value, [UriKind]::Absolute, [ref]$uri)) {
        return $null
    }

    if ($uri.Scheme -notin @('http', 'https', 'socks5', 'socks5h')) {
        return $null
    }

    if (-not $uri.Host -or $uri.Port -le 0) {
        return $null
    }

    return $uri.AbsoluteUri.TrimEnd('/')
}

function Get-SystemProxyCandidate {
    $settings = Get-ItemProperty `
        -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' `
        -ErrorAction SilentlyContinue

    if (-not $settings -or $settings.ProxyEnable -ne 1 -or -not $settings.ProxyServer) {
        return $null
    }

    $raw = [string]$settings.ProxyServer
    if ($raw -notmatch '=') {
        return (Normalize-ProxyUrl -Candidate $raw)
    }

    $map = @{}
    foreach ($part in ($raw -split ';')) {
        $pair = $part -split '=', 2
        if ($pair.Count -eq 2) {
            $map[$pair[0].Trim().ToLowerInvariant()] = $pair[1].Trim()
        }
    }

    foreach ($key in @('https', 'http', 'socks')) {
        if ($map.ContainsKey($key)) {
            $candidate = $map[$key]
            if ($key -eq 'socks' -and $candidate -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') {
                $candidate = "socks5://$candidate"
            }

            $normalized = Normalize-ProxyUrl -Candidate $candidate
            if ($normalized) {
                return $normalized
            }
        }
    }

    return $null
}

function Test-TcpEndpoint {
    param(
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][int]$Port,
        [int]$TimeoutMilliseconds = 2500
    )

    $client = [Net.Sockets.TcpClient]::new()
    try {
        $task = $client.ConnectAsync($HostName, $Port)
        return ($task.Wait($TimeoutMilliseconds) -and $client.Connected)
    }
    catch {
        return $false
    }
    finally {
        $client.Dispose()
    }
}

function Test-ProxyListener {
    param([Parameter(Mandatory)][string]$ProxyUrl)

    $uri = [Uri]$ProxyUrl
    return (Test-TcpEndpoint -HostName $uri.Host -Port $uri.Port)
}

function Get-ListeningProxyCandidates {
    $results = New-Object System.Collections.Generic.List[string]
    $getNetTcp = Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue

    if ($getNetTcp) {
        $listeners = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
            Where-Object {
                $_.LocalPort -in $CommonProxyPorts -and
                $_.LocalAddress -in @('127.0.0.1', '0.0.0.0', '::', '::1')
            }

        foreach ($port in $CommonProxyPorts) {
            if ($listeners.LocalPort -contains $port) {
                [void]$results.Add("http://127.0.0.1:$port")
            }
        }
    }
    else {
        foreach ($port in $CommonProxyPorts) {
            if (Test-TcpEndpoint -HostName '127.0.0.1' -Port $port -TimeoutMilliseconds 500) {
                [void]$results.Add("http://127.0.0.1:$port")
            }
        }
    }

    return $results.ToArray()
}

function Get-ProxyCandidates {
    $candidates = New-Object System.Collections.Generic.List[string]

    if ($Proxy) {
        $normalized = Normalize-ProxyUrl -Candidate $Proxy
        if (-not $normalized) {
            throw "Invalid proxy URL: $Proxy"
        }
        [void]$candidates.Add($normalized)
        return $candidates.ToArray()
    }

    $systemProxy = Get-SystemProxyCandidate
    if ($systemProxy) {
        [void]$candidates.Add($systemProxy)
    }

    foreach ($name in @('HTTPS_PROXY', 'HTTP_PROXY', 'ALL_PROXY')) {
        $value = Get-UserEnvironmentValue -Name $name
        if ($value) {
            $normalized = Normalize-ProxyUrl -Candidate $value
            if ($normalized) {
                [void]$candidates.Add($normalized)
            }
        }
    }

    foreach ($candidate in (Get-ListeningProxyCandidates)) {
        [void]$candidates.Add($candidate)
    }

    $seen = @{}
    $unique = New-Object System.Collections.Generic.List[string]
    foreach ($candidate in $candidates) {
        $key = $candidate.ToLowerInvariant()
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            [void]$unique.Add($candidate)
        }
    }

    return $unique.ToArray()
}

function Resolve-Proxy {
    $candidates = Get-ProxyCandidates
    if (-not $candidates -or $candidates.Count -eq 0) {
        throw 'No proxy candidate was detected. Run again with -Proxy http://127.0.0.1:PORT.'
    }

    if ($Proxy) {
        return $candidates[0]
    }

    foreach ($candidate in $candidates) {
        if (Test-ProxyListener -ProxyUrl $candidate) {
            return $candidate
        }
    }

    return $candidates[0]
}

function Get-ConnectivityTargets {
    param([Parameter(Mandatory)][string]$SelectedProfile)

    $targets = New-Object System.Collections.Generic.List[object]

    if ($SelectedProfile -in @('All', 'Codex', 'Generic')) {
        [void]$targets.Add([pscustomobject]@{
            Name = 'OpenAI API'
            Url = 'https://api.openai.com/v1/models'
            ExpectedCodes = @(200, 401)
            AnyHttp = $false
        })
    }

    if ($SelectedProfile -in @('All', 'Antigravity', 'Generic')) {
        [void]$targets.Add([pscustomobject]@{
            Name = 'Google generate_204'
            Url = 'https://www.googleapis.com/generate_204'
            ExpectedCodes = @(204)
            AnyHttp = $false
        })
        [void]$targets.Add([pscustomobject]@{
            Name = 'Google OAuth'
            Url = 'https://oauth2.googleapis.com/'
            ExpectedCodes = @()
            AnyHttp = $true
        })
        [void]$targets.Add([pscustomobject]@{
            Name = 'Google Cloud Code'
            Url = 'https://daily-cloudcode-pa.googleapis.com/'
            ExpectedCodes = @()
            AnyHttp = $true
        })
    }

    return $targets.ToArray()
}

function Invoke-CurlConnectivityTest {
    param(
        [Parameter(Mandatory)]$Target,
        [string]$ProxyUrl,
        [switch]$Direct,
        [int]$ConnectTimeoutSeconds = 6,
        [int]$MaxTimeSeconds = 12
    )

    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if (-not $curl) {
        return [pscustomobject]@{
            Name = $Target.Name
            Url = $Target.Url
            Passed = $null
            HttpStatus = $null
            ExitCode = $null
            Mode = if ($Direct) { 'direct' } else { 'proxy' }
            Message = 'curl.exe not found'
        }
    }

    $arguments = @(
        '--silent',
        '--show-error',
        '--output', 'NUL',
        '--write-out', '%{http_code}',
        '--connect-timeout', [string]$ConnectTimeoutSeconds,
        '--max-time', [string]$MaxTimeSeconds
    )

    if ($Direct) {
        $arguments += @('--noproxy', '*')
    }
    elseif ($ProxyUrl) {
        $arguments += @('--proxy', $ProxyUrl)
    }

    $arguments += $Target.Url

    $statusText = & $curl.Source @arguments 2>$null
    $exitCode = $LASTEXITCODE
    $status = 0
    [void][int]::TryParse(([string]$statusText).Trim(), [ref]$status)

    $passed = $false
    if ($exitCode -eq 0 -and $status -gt 0) {
        if ($Target.AnyHttp) {
            $passed = ($status -ge 200 -and $status -lt 500)
        }
        else {
            $passed = ($Target.ExpectedCodes -contains $status)
        }
    }

    $message = if ($passed) {
        "HTTP $status"
    }
    elseif ($exitCode -ne 0) {
        "curl exit $exitCode"
    }
    else {
        "HTTP $status"
    }

    return [pscustomobject]@{
        Name = $Target.Name
        Url = $Target.Url
        Passed = $passed
        HttpStatus = $status
        ExitCode = $exitCode
        Mode = if ($Direct) { 'direct' } else { 'proxy' }
        Message = $message
    }
}

function Test-ProfileConnectivity {
    param(
        [Parameter(Mandatory)][string]$SelectedProfile,
        [string]$ProxyUrl,
        [switch]$Direct,
        [switch]$ThrowOnFailure
    )

    $targets = Get-ConnectivityTargets -SelectedProfile $SelectedProfile
    $results = New-Object System.Collections.Generic.List[object]

    foreach ($target in $targets) {
        $result = Invoke-CurlConnectivityTest -Target $target -ProxyUrl $ProxyUrl -Direct:$Direct
        [void]$results.Add($result)

        $state = if ($null -eq $result.Passed) { 'SKIP' } elseif ($result.Passed) { 'PASS' } else { 'FAIL' }
        Write-Host ("[{0}] {1} ({2}) - {3}" -f $state, $result.Name, $result.Mode, $result.Message)
    }

    if ($ThrowOnFailure) {
        $knownResults = @($results | Where-Object { $null -ne $_.Passed })
        if ($knownResults.Count -eq 0) {
            throw 'curl.exe was not found, so external connectivity could not be verified.'
        }

        $failed = @($knownResults | Where-Object { -not $_.Passed })
        if ($failed.Count -gt 0) {
            throw ("Connectivity test failed for: {0}" -f (($failed | ForEach-Object Name) -join ', '))
        }
    }

    return $results.ToArray()
}

function Test-ProxyConnectionWithRetry {
    param(
        [Parameter(Mandatory)][string]$ProxyUrl,
        [Parameter(Mandatory)][string]$SelectedProfile
    )

    if (-not (Test-ProxyListener -ProxyUrl $ProxyUrl)) {
        $uri = [Uri]$ProxyUrl
        throw "Proxy is not listening at $($uri.Host):$($uri.Port)."
    }

    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if (-not $curl) {
        Write-Warning 'curl.exe was not found. Only the proxy listener was verified.'
        return
    }

    Write-Host "Waiting $ConnectionTestInitialDelaySeconds seconds for the proxy to stabilize..."
    Start-Sleep -Seconds $ConnectionTestInitialDelaySeconds

    $lastFailure = $null
    for ($attempt = 1; $attempt -le $ConnectionTestMaxAttempts; $attempt++) {
        try {
            Write-Host "Connectivity test attempt $attempt/$ConnectionTestMaxAttempts..."
            [void](Test-ProfileConnectivity -SelectedProfile $SelectedProfile -ProxyUrl $ProxyUrl -ThrowOnFailure)
            return
        }
        catch {
            $lastFailure = $_.Exception.GetBaseException().Message
        }

        if ($attempt -lt $ConnectionTestMaxAttempts) {
            Write-Warning "$lastFailure Retrying in $ConnectionTestRetryDelaySeconds seconds..."
            Start-Sleep -Seconds $ConnectionTestRetryDelaySeconds
        }
    }

    throw "$lastFailure Failed after $ConnectionTestMaxAttempts attempts."
}

function Merge-NoProxyValue {
    param(
        [AllowNull()][string]$CurrentValue,
        [string[]]$RequiredEntries = $RequiredNoProxyEntries
    )

    $ordered = New-Object System.Collections.Generic.List[string]
    $seen = @{}

    $allEntries = @()
    if ($CurrentValue) {
        $allEntries += ($CurrentValue -split ',')
    }
    $allEntries += $RequiredEntries

    foreach ($entry in $allEntries) {
        $trimmed = ([string]$entry).Trim()
        if (-not $trimmed) {
            continue
        }

        $key = $trimmed.ToLowerInvariant()
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            [void]$ordered.Add($trimmed)
        }
    }

    return ($ordered -join ',')
}

function Save-EnvironmentBackup {
    if (Test-Path -LiteralPath $BackupPath) {
        return
    }

    $targetDirectory = Split-Path -Parent $BackupPath
    New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null

    if (-not $LegacyBackup -and (Test-Path -LiteralPath $LegacyBackupPath)) {
        try {
            $legacy = Get-Content -LiteralPath $LegacyBackupPath -Raw | ConvertFrom-Json
            $migrated = [ordered]@{}
            foreach ($name in $EnvironmentNames) {
                $item = $legacy.$name
                if ($null -ne $item) {
                    $migrated[$name] = [ordered]@{
                        Exists = [bool]$item.Exists
                        Value = $item.Value
                    }
                }
                else {
                    $value = Get-UserEnvironmentValue -Name $name
                    $migrated[$name] = [ordered]@{
                        Exists = $null -ne $value
                        Value = $value
                    }
                }
            }

            $migrated | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $BackupPath -Encoding UTF8
            Write-Host "Imported rollback baseline from legacy Codex backup: $LegacyBackupPath"
            return
        }
        catch {
            Write-Warning "Legacy backup could not be imported: $($_.Exception.Message)"
        }
    }

    $backup = [ordered]@{}
    foreach ($name in $EnvironmentNames) {
        $value = Get-UserEnvironmentValue -Name $name
        $backup[$name] = [ordered]@{
            Exists = $null -ne $value
            Value = $value
        }
    }

    $backup | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $BackupPath -Encoding UTF8
    Write-Host "Rollback baseline saved: $BackupPath"
}

function Restore-EnvironmentBackup {
    if (-not (Test-Path -LiteralPath $BackupPath)) {
        throw "Backup not found: $BackupPath"
    }

    $backup = Get-Content -LiteralPath $BackupPath -Raw | ConvertFrom-Json
    foreach ($name in $EnvironmentNames) {
        $item = $backup.$name
        if ($null -eq $item) {
            continue
        }

        if ($item.Exists) {
            Set-UserEnvironmentValue -Name $name -Value ([string]$item.Value)
        }
        else {
            Set-UserEnvironmentValue -Name $name -Value $null
        }
    }

    Remove-Item -LiteralPath $BackupPath -Force
}

function Broadcast-EnvironmentChange {
    try {
        if (-not ('ProxyEnvironmentFix.NativeMethods' -as [type])) {
            Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
namespace ProxyEnvironmentFix {
    public static class NativeMethods {
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr SendMessageTimeout(
            IntPtr hWnd,
            uint Msg,
            UIntPtr wParam,
            string lParam,
            uint fuFlags,
            uint uTimeout,
            out UIntPtr lpdwResult);
    }
}
"@
        }

        $result = [UIntPtr]::Zero
        [void][ProxyEnvironmentFix.NativeMethods]::SendMessageTimeout(
            [IntPtr]0xffff,
            0x001A,
            [UIntPtr]::Zero,
            'Environment',
            0x0002,
            5000,
            [ref]$result
        )
        Write-Host 'Broadcasted Windows environment change notification.'
    }
    catch {
        Write-Warning "Could not broadcast environment change: $($_.Exception.Message)"
    }
}

function Get-CodexAppId {
    $package = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending |
        Select-Object -First 1

    if ($package) {
        return "$($package.PackageFamilyName)!App"
    }

    $app = Get-StartApps -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq 'Codex' -or $_.AppID -like '*OpenAI.Codex*' } |
        Select-Object -First 1

    if ($app) {
        return $app.AppID
    }

    return $null
}

function Get-AntigravityLaunchInfo {
    $running = Get-Process -Name 'Antigravity' -ErrorAction SilentlyContinue |
        Where-Object Path |
        Select-Object -First 1

    if ($running) {
        return [pscustomobject]@{ Type = 'Path'; Value = $running.Path }
    }

    $commonPaths = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Antigravity\Antigravity.exe'),
        (Join-Path $env:LOCALAPPDATA 'Antigravity\Antigravity.exe')
    )

    foreach ($path in $commonPaths) {
        if (Test-Path -LiteralPath $path) {
            return [pscustomobject]@{ Type = 'Path'; Value = $path }
        }
    }

    $app = Get-StartApps -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like '*Antigravity*' } |
        Select-Object -First 1

    if ($app) {
        return [pscustomobject]@{ Type = 'AppId'; Value = $app.AppID }
    }

    return $null
}

function Schedule-ApplicationRestarts {
    param(
        [switch]$DoRestartCodex,
        [switch]$DoRestartVSCode,
        [switch]$DoRestartAntigravity,
        [switch]$OnlyIfRunning
    )

    $restartCode = $DoRestartVSCode
    $restartAg = $DoRestartAntigravity
    $restartCx = $DoRestartCodex

    if ($OnlyIfRunning) {
        $restartCode = $restartCode -and [bool](Get-Process -Name 'Code' -ErrorAction SilentlyContinue)
        $restartAg = $restartAg -and [bool](Get-Process -Name 'Antigravity' -ErrorAction SilentlyContinue)
        $restartCx = $restartCx -and [bool](Get-Process -Name 'Codex' -ErrorAction SilentlyContinue)
    }

    if (-not ($restartCode -or $restartAg -or $restartCx)) {
        return
    }

    $commands = New-Object System.Collections.Generic.List[string]
    [void]$commands.Add('Start-Sleep -Seconds 2')

    if ($restartCode) {
        $codePath = Get-Process -Name 'Code' -ErrorAction SilentlyContinue |
            Where-Object Path |
            Select-Object -First 1 -ExpandProperty Path
        if (-not $codePath) {
            $codeCommand = Get-Command 'code.cmd' -ErrorAction SilentlyContinue
            if ($codeCommand) {
                $codePath = $codeCommand.Source
            }
        }

        [void]$commands.Add("Get-Process -Name 'Code' -ErrorAction SilentlyContinue | Stop-Process -Force")
        [void]$commands.Add('Start-Sleep -Seconds 2')
        if ($codePath) {
            $escaped = $codePath.Replace("'", "''")
            [void]$commands.Add("Start-Process -FilePath '$escaped'")
        }
        else {
            Write-Warning 'VS Code executable was not found. Restart VS Code manually.'
        }
    }

    if ($restartAg) {
        $launch = Get-AntigravityLaunchInfo
        [void]$commands.Add("Get-Process -Name 'Antigravity','language_server' -ErrorAction SilentlyContinue | Stop-Process -Force")
        [void]$commands.Add('Start-Sleep -Seconds 2')
        if ($launch) {
            $escaped = ([string]$launch.Value).Replace("'", "''")
            if ($launch.Type -eq 'Path') {
                [void]$commands.Add("Start-Process -FilePath '$escaped'")
            }
            else {
                [void]$commands.Add("Start-Process 'explorer.exe' 'shell:AppsFolder\$escaped'")
            }
        }
        else {
            Write-Warning 'Antigravity launch target was not found. Restart Antigravity manually.'
        }
    }

    if ($restartCx) {
        $appId = Get-CodexAppId
        if ($LegacyCodexBehavior) {
            [void]$commands.Add("Get-Process -Name 'ChatGPT','Codex','codex' -ErrorAction SilentlyContinue | Stop-Process -Force")
        }
        else {
            [void]$commands.Add("Get-Process -Name 'Codex','codex' -ErrorAction SilentlyContinue | Stop-Process -Force")
        }
        [void]$commands.Add('Start-Sleep -Seconds 2')
        if ($appId) {
            $escaped = $appId.Replace("'", "''")
            [void]$commands.Add("Start-Process 'explorer.exe' 'shell:AppsFolder\$escaped'")
        }
        else {
            Write-Warning 'Codex application registration was not found. Restart Codex manually.'
        }
    }

    $helperPath = Join-Path $env:TEMP ("restart-proxy-clients-{0}.ps1" -f ([Guid]::NewGuid().ToString('N')))
    [void]$commands.Add("Remove-Item -LiteralPath `$PSCommandPath -Force -ErrorAction SilentlyContinue")
    Set-Content -LiteralPath $helperPath -Value ($commands -join [Environment]::NewLine) -Encoding UTF8

    Start-Process powershell.exe `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $helperPath) `
        -WindowStyle Hidden

    Write-Host 'Application restart has been scheduled.'
}

function Get-SystemProxyStatus {
    $settings = Get-ItemProperty `
        -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' `
        -ErrorAction SilentlyContinue

    return [pscustomobject]@{
        ProxyEnable = if ($settings) { $settings.ProxyEnable } else { $null }
        ProxyServer = if ($settings) { $settings.ProxyServer } else { $null }
        ProxyOverride = if ($settings) { $settings.ProxyOverride } else { $null }
        AutoConfigURL = if ($settings) { $settings.AutoConfigURL } else { $null }
    }
}

function Show-Status {
    Write-Host '=== User proxy environment ==='
    foreach ($name in $EnvironmentNames) {
        $value = Get-UserEnvironmentValue -Name $name
        if ($null -eq $value) {
            $value = '<not set>'
        }
        Write-Host ("  {0}={1}" -f $name, $value)
    }

    Write-Host ''
    Write-Host '=== Windows Internet Settings ==='
    $system = Get-SystemProxyStatus
    Write-Host ("  ProxyEnable={0}" -f $system.ProxyEnable)
    Write-Host ("  ProxyServer={0}" -f $(if ($system.ProxyServer) { $system.ProxyServer } else { '<not set>' }))
    Write-Host ("  ProxyOverride={0}" -f $(if ($system.ProxyOverride) { $system.ProxyOverride } else { '<not set>' }))
    Write-Host ("  AutoConfigURL={0}" -f $(if ($system.AutoConfigURL) { $system.AutoConfigURL } else { '<not set>' }))

    Write-Host ''
    Write-Host '=== WinHTTP ==='
    try {
        & netsh winhttp show proxy
    }
    catch {
        Write-Warning "Could not query WinHTTP proxy: $($_.Exception.Message)"
    }

    Write-Host ''
    Write-Host '=== Detected proxy candidates ==='
    $candidates = @(Get-ProxyCandidates)
    if ($candidates.Count -eq 0) {
        Write-Host '  <none>'
    }
    else {
        foreach ($candidate in $candidates) {
            $listening = Test-ProxyListener -ProxyUrl $candidate
            Write-Host ("  {0}  listener={1}" -f $candidate, $listening)
        }
    }

    Write-Host ''
    Write-Host '=== Backups ==='
    Write-Host ("  General: {0}" -f $(if (Test-Path -LiteralPath $GeneralBackupPath) { $GeneralBackupPath } else { '<not found>' }))
    Write-Host ("  Legacy Codex: {0}" -f $(if (Test-Path -LiteralPath $LegacyBackupPath) { $LegacyBackupPath } else { '<not found>' }))
}

function Invoke-Diagnosis {
    Show-Status

    Write-Host ''
    Write-Host '=== Diagnosis ==='

    $proxyUrl = $null
    try {
        $proxyUrl = Resolve-Proxy
        Write-Host "Selected proxy: $proxyUrl"
    }
    catch {
        Write-Host 'Diagnosis: NO_PROXY_CANDIDATE'
        Write-Host $_.Exception.Message
        return
    }

    if (-not (Test-ProxyListener -ProxyUrl $proxyUrl)) {
        Write-Host 'Diagnosis: PROXY_LISTENER_UNREACHABLE'
        Write-Host "Proxy endpoint is not reachable: $proxyUrl"
        return
    }

    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if (-not $curl) {
        Write-Host 'Diagnosis: LISTENER_ONLY'
        Write-Host 'Proxy is listening, but curl.exe is unavailable for route comparison.'
        return
    }

    Write-Host ''
    Write-Host 'Proxy path:'
    $proxyResults = @(Test-ProfileConnectivity -SelectedProfile $Profile -ProxyUrl $proxyUrl)

    Write-Host ''
    Write-Host 'Direct path:'
    $directTargets = @(Get-ConnectivityTargets -SelectedProfile $Profile | Select-Object -First 2)
    $directResults = New-Object System.Collections.Generic.List[object]
    foreach ($target in $directTargets) {
        $result = Invoke-CurlConnectivityTest -Target $target -Direct -ConnectTimeoutSeconds 4 -MaxTimeSeconds 7
        [void]$directResults.Add($result)
        $state = if ($result.Passed) { 'PASS' } else { 'FAIL' }
        Write-Host ("[{0}] {1} (direct) - {2}" -f $state, $result.Name, $result.Message)
    }

    $proxyKnown = @($proxyResults | Where-Object { $null -ne $_.Passed })
    $proxyPass = ($proxyKnown.Count -gt 0 -and @($proxyKnown | Where-Object { -not $_.Passed }).Count -eq 0)
    $directFailed = @($directResults | Where-Object { $null -ne $_.Passed -and -not $_.Passed }).Count -gt 0

    $httpProxy = Get-UserEnvironmentValue -Name 'HTTP_PROXY'
    $httpsProxy = Get-UserEnvironmentValue -Name 'HTTPS_PROXY'
    $envMatches = ($httpProxy -eq $proxyUrl -and $httpsProxy -eq $proxyUrl)

    Write-Host ''
    if ($proxyPass -and $directFailed -and -not $envMatches) {
        Write-Host 'Diagnosis: PROCESS_PROXY_GAP'
        Write-Host 'Direct access fails, the local proxy works, but HTTP_PROXY/HTTPS_PROXY do not match the working proxy.'
        Write-Host 'This matches the failure class seen in Go/CLI processes and Antigravity language_server.'
    }
    elseif ($proxyPass -and -not $envMatches) {
        Write-Host 'Diagnosis: ENV_PROXY_MISMATCH'
        Write-Host 'The proxy works, but user-level HTTP_PROXY/HTTPS_PROXY do not match it.'
    }
    elseif ($proxyPass -and $envMatches) {
        Write-Host 'Diagnosis: ENV_PROXY_OK'
        Write-Host 'User-level proxy variables already match the working proxy. Restart affected processes before looking elsewhere.'
    }
    else {
        Write-Host 'Diagnosis: PROXY_PATH_FAILURE'
        Write-Host 'The selected proxy cannot reach one or more required endpoints.'
    }
}

function Install-ProxyEnvironment {
    $proxyUrl = Resolve-Proxy
    Write-Host "Using proxy: $proxyUrl"

    if (-not $SkipConnectionTest) {
        Test-ProxyConnectionWithRetry -ProxyUrl $proxyUrl -SelectedProfile $Profile
    }

    Save-EnvironmentBackup

    foreach ($name in @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY')) {
        Set-UserEnvironmentValue -Name $name -Value $proxyUrl
    }

    if ($LegacyCodexBehavior) {
        foreach ($name in @('WS_PROXY', 'WSS_PROXY')) {
            Set-UserEnvironmentValue -Name $name -Value $null
        }
    }

    $required = @($RequiredNoProxyEntries)
    if ($LegacyCodexBehavior) {
        $required += '172.31.0.0/16'
    }

    $currentNoProxy = Get-UserEnvironmentValue -Name 'NO_PROXY'
    $mergedNoProxy = Merge-NoProxyValue -CurrentValue $currentNoProxy -RequiredEntries $required
    Set-UserEnvironmentValue -Name 'NO_PROXY' -Value $mergedNoProxy

    Broadcast-EnvironmentChange

    Write-Host 'User-level proxy environment installed.'
    Write-Host "  HTTP_PROXY=$proxyUrl"
    Write-Host "  HTTPS_PROXY=$proxyUrl"
    Write-Host "  ALL_PROXY=$proxyUrl"
    Write-Host "  NO_PROXY=$mergedNoProxy"
    Write-Host 'Existing applications must restart to inherit the new environment.'

    if ($RestartRunningApps) {
        Schedule-ApplicationRestarts `
            -DoRestartCodex `
            -DoRestartVSCode `
            -DoRestartAntigravity `
            -OnlyIfRunning
    }
    elseif ($RestartCodex -or $RestartVSCode -or $RestartAntigravity) {
        Schedule-ApplicationRestarts `
            -DoRestartCodex:$RestartCodex `
            -DoRestartVSCode:$RestartVSCode `
            -DoRestartAntigravity:$RestartAntigravity
    }
}

function Remove-ProxyEnvironment {
    Restore-EnvironmentBackup
    Broadcast-EnvironmentChange
    Write-Host 'Previous user proxy environment restored.'
    Write-Host 'Existing applications must restart to inherit the restored environment.'

    if ($RestartRunningApps) {
        Schedule-ApplicationRestarts `
            -DoRestartCodex `
            -DoRestartVSCode `
            -DoRestartAntigravity `
            -OnlyIfRunning
    }
    elseif ($RestartCodex -or $RestartVSCode -or $RestartAntigravity) {
        Schedule-ApplicationRestarts `
            -DoRestartCodex:$RestartCodex `
            -DoRestartVSCode:$RestartVSCode `
            -DoRestartAntigravity:$RestartAntigravity
    }
}

switch ($Action) {
    'Status' {
        Show-Status
    }

    'Diagnose' {
        Invoke-Diagnosis
    }

    'Test' {
        $proxyUrl = Resolve-Proxy
        Write-Host "Using proxy: $proxyUrl"
        Test-ProxyConnectionWithRetry -ProxyUrl $proxyUrl -SelectedProfile $Profile
    }

    'Install' {
        Install-ProxyEnvironment
    }

    'Remove' {
        Remove-ProxyEnvironment
    }
}
