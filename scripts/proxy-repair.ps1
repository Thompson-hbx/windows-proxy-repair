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
$EnvironmentNames = @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'WS_PROXY', 'WSS_PROXY', 'NO_PROXY')
$CommonProxyPorts = @(10808, 7890, 7897, 10809, 1080, 8080, 8888)
$LegacyBackupPath = Join-Path (Join-Path $env:LOCALAPPDATA 'CodexProxyFix') 'environment-backup.json'
$GeneralBackupPath = Join-Path (Join-Path $env:LOCALAPPDATA 'ProxyEnvironmentFix') 'environment-backup.json'
$BackupPath = if ($LegacyBackup) { $LegacyBackupPath } else { $GeneralBackupPath }

function Get-UserEnv([string]$Name) {
    [Environment]::GetEnvironmentVariable($Name, 'User')
}

function Set-UserEnv([string]$Name, [AllowNull()][string]$Value) {
    [Environment]::SetEnvironmentVariable($Name, $Value, 'User')
    if ($null -eq $Value) {
        Remove-Item -Path "Env:$Name" -ErrorAction SilentlyContinue
    }
    else {
        Set-Item -Path "Env:$Name" -Value $Value
    }
}

function Normalize-ProxyUrl([string]$Candidate) {
    if (-not $Candidate) { return $null }
    $value = $Candidate.Trim()
    if ($value -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') { $value = "http://$value" }

    $uri = $null
    if (-not [Uri]::TryCreate($value, [UriKind]::Absolute, [ref]$uri)) { return $null }
    if ($uri.Scheme -notin @('http', 'https', 'socks5', 'socks5h')) { return $null }
    if (-not $uri.Host -or $uri.Port -le 0 -or $uri.UserInfo) { return $null }
    $uri.AbsoluteUri.TrimEnd('/')
}

function Test-Tcp([string]$HostName, [int]$Port, [int]$TimeoutMs = 2500) {
    $client = [Net.Sockets.TcpClient]::new()
    try {
        $task = $client.ConnectAsync($HostName, $Port)
        return ($task.Wait($TimeoutMs) -and $client.Connected)
    }
    catch { return $false }
    finally { $client.Dispose() }
}

function Test-ProxyListener([string]$ProxyUrl) {
    $uri = [Uri]$ProxyUrl
    Test-Tcp -HostName $uri.Host -Port $uri.Port
}

function Get-SystemProxy {
    $settings = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
    if (-not $settings -or $settings.ProxyEnable -ne 1 -or -not $settings.ProxyServer) { return $null }

    $raw = [string]$settings.ProxyServer
    if ($raw -notmatch '=') { return (Normalize-ProxyUrl $raw) }

    $map = @{}
    foreach ($part in ($raw -split ';')) {
        $pair = $part -split '=', 2
        if ($pair.Count -eq 2) { $map[$pair[0].Trim().ToLowerInvariant()] = $pair[1].Trim() }
    }

    foreach ($key in @('https', 'http', 'socks')) {
        if (-not $map.ContainsKey($key)) { continue }
        $value = $map[$key]
        if ($key -eq 'socks' -and $value -notmatch '://') { $value = "socks5://$value" }
        $normalized = Normalize-ProxyUrl $value
        if ($normalized) { return $normalized }
    }
    $null
}

function Get-ProxyCandidates {
    if ($Proxy) {
        $normalized = Normalize-ProxyUrl $Proxy
        if (-not $normalized) { throw 'Invalid proxy URL. Credentials in proxy URLs are intentionally unsupported.' }
        return @($normalized)
    }

    $items = New-Object System.Collections.Generic.List[string]
    $systemProxy = Get-SystemProxy
    if ($systemProxy) { [void]$items.Add($systemProxy) }

    foreach ($name in @('HTTPS_PROXY', 'HTTP_PROXY', 'ALL_PROXY')) {
        $normalized = Normalize-ProxyUrl (Get-UserEnv $name)
        if ($normalized) { [void]$items.Add($normalized) }
    }

    if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
        $listeners = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
            Where-Object { $_.LocalPort -in $CommonProxyPorts -and $_.LocalAddress -in @('127.0.0.1', '0.0.0.0', '::', '::1') }
        foreach ($port in $CommonProxyPorts) {
            if ($listeners.LocalPort -contains $port) { [void]$items.Add("http://127.0.0.1:$port") }
        }
    }
    else {
        foreach ($port in $CommonProxyPorts) {
            if (Test-Tcp '127.0.0.1' $port 500) { [void]$items.Add("http://127.0.0.1:$port") }
        }
    }

    $seen = @{}
    $result = @()
    foreach ($item in $items) {
        $key = $item.ToLowerInvariant()
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $result += $item
        }
    }
    return $result
}

function Resolve-Proxy {
    $candidates = @(Get-ProxyCandidates)
    if ($candidates.Count -eq 0) { throw 'No proxy candidate detected. Use -Proxy http://127.0.0.1:PORT.' }
    if ($Proxy) { return $candidates[0] }
    foreach ($candidate in $candidates) {
        if (Test-ProxyListener $candidate) { return $candidate }
    }
    $candidates[0]
}

function Get-Targets([string]$SelectedProfile) {
    $targets = @()
    if ($SelectedProfile -in @('All', 'Codex', 'Generic')) {
        $targets += [pscustomobject]@{ Name='OpenAI API'; Url='https://api.openai.com/v1/models'; Codes=@(200,401); AnyHttp=$false }
    }
    if ($SelectedProfile -in @('All', 'Antigravity', 'Generic')) {
        $targets += [pscustomobject]@{ Name='Google generate_204'; Url='https://www.googleapis.com/generate_204'; Codes=@(204); AnyHttp=$false }
        $targets += [pscustomobject]@{ Name='Google OAuth'; Url='https://oauth2.googleapis.com/'; Codes=@(); AnyHttp=$true }
        $targets += [pscustomobject]@{ Name='Google Cloud Code'; Url='https://daily-cloudcode-pa.googleapis.com/'; Codes=@(); AnyHttp=$true }
    }
    $targets
}

function Invoke-CurlTest {
    param($Target, [string]$ProxyUrl, [switch]$Direct, [int]$ConnectTimeout = 6, [int]$MaxTime = 12)

    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if (-not $curl) {
        return [pscustomobject]@{ Name=$Target.Name; Passed=$null; Status=$null; ExitCode=$null; Message='curl.exe not found' }
    }

    $argsList = @('--silent','--show-error','--output','NUL','--write-out','%{http_code}','--connect-timeout',[string]$ConnectTimeout,'--max-time',[string]$MaxTime)
    if ($Direct) { $argsList += @('--noproxy','*') }
    elseif ($ProxyUrl) { $argsList += @('--proxy',$ProxyUrl) }
    $argsList += $Target.Url

    $previousPreference = $ErrorActionPreference
    $text = $null
    $exitCode = $null
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        $text = & $curl.Source @argsList 2>$null
        $exitCode = $LASTEXITCODE
    }
    catch {
        $exitCode = if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) { $LASTEXITCODE } else { 1 }
    }
    finally {
        $ErrorActionPreference = $previousPreference
        $global:LASTEXITCODE = 0
    }
    $status = 0
    [void][int]::TryParse(([string]$text).Trim(), [ref]$status)
    $passed = $false
    if ($exitCode -eq 0 -and $status -gt 0) {
        $passed = if ($Target.AnyHttp) { $status -ge 200 -and $status -lt 500 } else { $Target.Codes -contains $status }
    }
    $message = if ($exitCode -ne 0) { "curl exit $exitCode" } else { "HTTP $status" }
    [pscustomobject]@{ Name=$Target.Name; Passed=$passed; Status=$status; ExitCode=$exitCode; Message=$message }
}

function Test-Profile {
    param([string]$SelectedProfile, [string]$ProxyUrl, [switch]$Direct, [switch]$ThrowOnFailure)
    $results = @()
    foreach ($target in (Get-Targets $SelectedProfile)) {
        $r = Invoke-CurlTest -Target $target -ProxyUrl $ProxyUrl -Direct:$Direct
        $results += $r
        $state = if ($null -eq $r.Passed) { 'SKIP' } elseif ($r.Passed) { 'PASS' } else { 'FAIL' }
        Write-Host ("[{0}] {1} - {2}" -f $state, $r.Name, $r.Message)
    }
    if ($ThrowOnFailure) {
        $known = @($results | Where-Object { $null -ne $_.Passed })
        if ($known.Count -eq 0) { throw 'curl.exe is required for external route verification.' }
        $failed = @($known | Where-Object { -not $_.Passed })
        if ($failed.Count -gt 0) { throw ("Connectivity failed for: {0}" -f (($failed | ForEach-Object Name) -join ', ')) }
    }
    $results
}

function Test-ProxyRoute([string]$ProxyUrl, [string]$SelectedProfile) {
    if (-not (Test-ProxyListener $ProxyUrl)) {
        $uri = [Uri]$ProxyUrl
        throw "Proxy is not listening at $($uri.Host):$($uri.Port)."
    }
    if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
        Write-Warning 'curl.exe not found; only the proxy listener was verified.'
        return
    }

    Start-Sleep -Seconds 2
    $last = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Write-Host "Connectivity attempt $attempt/3..."
            [void](Test-Profile -SelectedProfile $SelectedProfile -ProxyUrl $ProxyUrl -ThrowOnFailure)
            return
        }
        catch { $last = $_.Exception.GetBaseException().Message }
        if ($attempt -lt 3) { Write-Warning "$last Retrying in 2 seconds..."; Start-Sleep -Seconds 2 }
    }
    throw "$last Failed after 3 attempts."
}

function Merge-NoProxy([string]$Current, [string[]]$Required) {
    $seen = @{}
    $result = @()
    $items = @()
    if ($Current) { $items += ($Current -split ',') }
    $items += $Required
    foreach ($item in $items) {
        $v = ([string]$item).Trim()
        if (-not $v) { continue }
        $key = $v.ToLowerInvariant()
        if (-not $seen.ContainsKey($key)) { $seen[$key] = $true; $result += $v }
    }
    $result -join ','
}

function Save-Backup {
    if (Test-Path $BackupPath) { return }
    New-Item -ItemType Directory -Path (Split-Path $BackupPath -Parent) -Force | Out-Null

    if (-not $LegacyBackup -and (Test-Path $LegacyBackupPath)) {
        try {
            $legacy = Get-Content $LegacyBackupPath -Raw | ConvertFrom-Json
            $copy = [ordered]@{}
            foreach ($name in $EnvironmentNames) {
                $item = $legacy.$name
                if ($null -ne $item) { $copy[$name] = [ordered]@{ Exists=[bool]$item.Exists; Value=$item.Value } }
                else {
                    $value = Get-UserEnv $name
                    $copy[$name] = [ordered]@{ Exists=$null -ne $value; Value=$value }
                }
            }
            $copy | ConvertTo-Json -Depth 3 | Set-Content $BackupPath -Encoding UTF8
            Write-Host "Imported legacy rollback baseline: $LegacyBackupPath"
            return
        }
        catch { Write-Warning "Legacy backup import failed: $($_.Exception.Message)" }
    }

    $backup = [ordered]@{}
    foreach ($name in $EnvironmentNames) {
        $value = Get-UserEnv $name
        $backup[$name] = [ordered]@{ Exists=$null -ne $value; Value=$value }
    }
    $backup | ConvertTo-Json -Depth 3 | Set-Content $BackupPath -Encoding UTF8
    Write-Host "Rollback baseline saved: $BackupPath"
}

function Restore-Backup {
    if (-not (Test-Path $BackupPath)) { throw "Backup not found: $BackupPath" }
    $backup = Get-Content $BackupPath -Raw | ConvertFrom-Json
    foreach ($name in $EnvironmentNames) {
        $item = $backup.$name
        if ($null -eq $item) { continue }
        if ($item.Exists) { Set-UserEnv $name ([string]$item.Value) } else { Set-UserEnv $name $null }
    }
    Remove-Item $BackupPath -Force
}

function Broadcast-EnvironmentChange {
    try {
        if (-not ('ProxyEnvironmentFix.NativeMethods' -as [type])) {
            Add-Type @"
using System;
using System.Runtime.InteropServices;
namespace ProxyEnvironmentFix {
  public static class NativeMethods {
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint flags, uint timeout, out UIntPtr result);
  }
}
"@
        }
        $result = [UIntPtr]::Zero
        [void][ProxyEnvironmentFix.NativeMethods]::SendMessageTimeout([IntPtr]0xffff,0x001A,[UIntPtr]::Zero,'Environment',0x0002,5000,[ref]$result)
        Write-Host 'Broadcasted Windows environment change notification.'
    }
    catch { Write-Warning "Environment broadcast failed: $($_.Exception.Message)" }
}

function Get-CodexAppId {
    $package = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1
    if ($package) { return "$($package.PackageFamilyName)!App" }
    $app = Get-StartApps -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -in @('Codex', 'ChatGPT') -or $_.AppID -like '*OpenAI.Codex*' } |
        Select-Object -First 1
    if ($app) { return $app.AppID }
    $null
}

function Get-AntigravityLaunch {
    $p = Get-Process Antigravity -ErrorAction SilentlyContinue | Where-Object Path | Select-Object -First 1
    if ($p) { return [pscustomobject]@{ Type='Path'; Value=$p.Path } }
    foreach ($path in @((Join-Path $env:LOCALAPPDATA 'Programs\Antigravity\Antigravity.exe'),(Join-Path $env:LOCALAPPDATA 'Antigravity\Antigravity.exe'))) {
        if (Test-Path $path) { return [pscustomobject]@{ Type='Path'; Value=$path } }
    }
    $app = Get-StartApps -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*Antigravity*' } | Select-Object -First 1
    if ($app) { return [pscustomobject]@{ Type='AppId'; Value=$app.AppID } }
    $null
}

function Schedule-Restarts {
    param([switch]$Codex, [switch]$VSCode, [switch]$Antigravity, [switch]$OnlyIfRunning)

    if ($OnlyIfRunning) {
        $VSCode = $VSCode -and [bool](Get-Process Code -ErrorAction SilentlyContinue)
        $Antigravity = $Antigravity -and [bool](Get-Process Antigravity -ErrorAction SilentlyContinue)
        $Codex = $Codex -and [bool](Get-Process -Name 'Codex','ChatGPT' -ErrorAction SilentlyContinue)
    }
    if (-not ($Codex -or $VSCode -or $Antigravity)) { return }

    $lines = @('Start-Sleep -Seconds 2')
    if ($VSCode) {
        $codePath = Get-Process Code -ErrorAction SilentlyContinue | Where-Object Path | Select-Object -First 1 -ExpandProperty Path
        if (-not $codePath) { $cmd = Get-Command code.cmd -ErrorAction SilentlyContinue; if ($cmd) { $codePath = $cmd.Source } }
        $lines += "Get-Process Code -ErrorAction SilentlyContinue | Stop-Process -Force"
        $lines += 'Start-Sleep -Seconds 2'
        if ($codePath) { $lines += "Start-Process -FilePath '$($codePath.Replace("'","''"))'" }
        else { Write-Warning 'VS Code executable not found; restart it manually.' }
    }
    if ($Antigravity) {
        $launch = Get-AntigravityLaunch
        $lines += "Get-Process Antigravity -ErrorAction SilentlyContinue | Stop-Process -Force"
        $lines += 'Start-Sleep -Seconds 2'
        if ($launch) {
            $value = ([string]$launch.Value).Replace("'","''")
            if ($launch.Type -eq 'Path') { $lines += "Start-Process -FilePath '$value'" }
            else { $lines += "Start-Process explorer.exe 'shell:AppsFolder\$value'" }
        }
        else { Write-Warning 'Antigravity launch target not found; restart it manually.' }
    }
    if ($Codex) {
        $appId = Get-CodexAppId
        $lines += "Get-Process -Name 'ChatGPT','Codex' -ErrorAction SilentlyContinue | Stop-Process -Force"
        $lines += 'Start-Sleep -Seconds 2'
        if ($appId) { $lines += "Start-Process explorer.exe 'shell:AppsFolder\$($appId.Replace("'","''"))'" }
        else { Write-Warning 'Codex registration not found; restart it manually.' }
    }

    $helper = Join-Path $env:TEMP ("restart-proxy-clients-{0}.ps1" -f [Guid]::NewGuid().ToString('N'))
    $lines += 'Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue'
    Set-Content $helper ($lines -join [Environment]::NewLine) -Encoding UTF8
    Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$helper) -WindowStyle Hidden
    Write-Host 'Application restart scheduled.'
}

function Show-Status {
    Write-Host '=== User proxy environment ==='
    foreach ($name in $EnvironmentNames) {
        $value = Get-UserEnv $name
        if ($null -eq $value) { $value = '<not set>' }
        Write-Host ("  {0}={1}" -f $name,$value)
    }

    $settings = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
    Write-Host "`n=== Windows Internet Settings ==="
    Write-Host ("  ProxyEnable={0}" -f $(if ($settings) { $settings.ProxyEnable } else { '<unknown>' }))
    Write-Host ("  ProxyServer={0}" -f $(if ($settings.ProxyServer) { $settings.ProxyServer } else { '<not set>' }))
    Write-Host ("  ProxyOverride={0}" -f $(if ($settings.ProxyOverride) { $settings.ProxyOverride } else { '<not set>' }))
    Write-Host ("  AutoConfigURL={0}" -f $(if ($settings.AutoConfigURL) { $settings.AutoConfigURL } else { '<not set>' }))

    Write-Host "`n=== WinHTTP ==="
    & netsh winhttp show proxy

    Write-Host "`n=== Proxy candidates ==="
    $candidates = @(Get-ProxyCandidates)
    if ($candidates.Count -eq 0) { Write-Host '  <none>' }
    foreach ($candidate in $candidates) { Write-Host ("  {0}  listener={1}" -f $candidate,(Test-ProxyListener $candidate)) }

    Write-Host "`n=== Backups ==="
    Write-Host ("  General: {0}" -f $(if (Test-Path $GeneralBackupPath) { $GeneralBackupPath } else { '<not found>' }))
    Write-Host ("  Legacy Codex: {0}" -f $(if (Test-Path $LegacyBackupPath) { $LegacyBackupPath } else { '<not found>' }))
}

function Diagnose {
    Show-Status
    Write-Host "`n=== Diagnosis ==="
    try { $proxyUrl = Resolve-Proxy }
    catch { Write-Host 'Diagnosis: NO_PROXY_CANDIDATE'; Write-Host $_.Exception.Message; return }
    Write-Host "Selected proxy: $proxyUrl"

    if (-not (Test-ProxyListener $proxyUrl)) {
        Write-Host 'Diagnosis: PROXY_LISTENER_UNREACHABLE'
        return
    }
    if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
        Write-Host 'Diagnosis: LISTENER_ONLY'
        return
    }

    Write-Host "`nProxy path:"
    $proxyResults = @(Test-Profile -SelectedProfile $Profile -ProxyUrl $proxyUrl)
    Write-Host "`nDirect path:"
    $directResults = @()
    foreach ($target in @(Get-Targets $Profile | Select-Object -First 2)) {
        $r = Invoke-CurlTest -Target $target -Direct -ConnectTimeout 4 -MaxTime 7
        $directResults += $r
        Write-Host ("[{0}] {1} - {2}" -f $(if ($r.Passed) { 'PASS' } else { 'FAIL' }),$r.Name,$r.Message)
    }

    $proxyPass = @($proxyResults | Where-Object { $null -ne $_.Passed -and -not $_.Passed }).Count -eq 0
    $directFailed = @($directResults | Where-Object { $null -ne $_.Passed -and -not $_.Passed }).Count -gt 0
    $http = Normalize-ProxyUrl (Get-UserEnv 'HTTP_PROXY')
    $https = Normalize-ProxyUrl (Get-UserEnv 'HTTPS_PROXY')
    $envMatches = ($http -eq $proxyUrl -and $https -eq $proxyUrl)

    Write-Host ''
    if ($proxyPass -and $directFailed -and -not $envMatches) {
        Write-Host 'Diagnosis: PROCESS_PROXY_GAP'
        Write-Host 'Direct access fails, the proxy works, but HTTP_PROXY/HTTPS_PROXY do not match it.'
    }
    elseif ($proxyPass -and -not $envMatches) { Write-Host 'Diagnosis: ENV_PROXY_MISMATCH' }
    elseif ($proxyPass -and $envMatches) { Write-Host 'Diagnosis: ENV_PROXY_OK' }
    else { Write-Host 'Diagnosis: PROXY_PATH_FAILURE' }
}

function Install-ProxyEnvironment {
    $proxyUrl = Resolve-Proxy
    Write-Host "Using proxy: $proxyUrl"
    if (-not $SkipConnectionTest) { Test-ProxyRoute -ProxyUrl $proxyUrl -SelectedProfile $Profile }
    Save-Backup

    foreach ($name in @('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY')) { Set-UserEnv $name $proxyUrl }
    if ($LegacyCodexBehavior -or $Profile -in @('All','Codex')) {
        foreach ($name in @('WS_PROXY','WSS_PROXY')) { Set-UserEnv $name $null }
    }

    $required = @('localhost','127.0.0.1','::1')
    if ($LegacyCodexBehavior) { $required += '172.31.0.0/16' }
    $noProxy = Merge-NoProxy (Get-UserEnv 'NO_PROXY') $required
    Set-UserEnv 'NO_PROXY' $noProxy
    Broadcast-EnvironmentChange

    Write-Host 'User-level proxy environment installed.'
    Write-Host "  HTTP_PROXY=$proxyUrl"
    Write-Host "  HTTPS_PROXY=$proxyUrl"
    Write-Host "  ALL_PROXY=$proxyUrl"
    Write-Host "  NO_PROXY=$noProxy"
    Write-Host 'Existing processes must restart to inherit it.'

    if ($RestartRunningApps) { Schedule-Restarts -Codex -VSCode -Antigravity -OnlyIfRunning }
    elseif ($RestartCodex -or $RestartVSCode -or $RestartAntigravity) {
        Schedule-Restarts -Codex:$RestartCodex -VSCode:$RestartVSCode -Antigravity:$RestartAntigravity
    }
}

function Remove-ProxyEnvironment {
    Restore-Backup
    Broadcast-EnvironmentChange
    Write-Host 'Previous user proxy environment restored.'
    if ($RestartRunningApps) { Schedule-Restarts -Codex -VSCode -Antigravity -OnlyIfRunning }
    elseif ($RestartCodex -or $RestartVSCode -or $RestartAntigravity) {
        Schedule-Restarts -Codex:$RestartCodex -VSCode:$RestartVSCode -Antigravity:$RestartAntigravity
    }
}

switch ($Action) {
    'Status' { Show-Status }
    'Diagnose' { Diagnose }
    'Test' { $p = Resolve-Proxy; Write-Host "Using proxy: $p"; Test-ProxyRoute $p $Profile }
    'Install' { Install-ProxyEnvironment }
    'Remove' { Remove-ProxyEnvironment }
}
