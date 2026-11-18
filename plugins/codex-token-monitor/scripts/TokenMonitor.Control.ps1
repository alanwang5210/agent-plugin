[CmdletBinding()]
param(
    [ValidateSet('Start', 'Show', 'Stop', 'Restart', 'Status', 'EnableAutostart', 'DisableAutostart')]
    [string]$Action = 'Status'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$appName = 'CodexTokenMonitor'
$stateRoot = Join-Path $env:LOCALAPPDATA $appName
$pidPath = Join-Path $stateRoot 'monitor.pid'
$targetPathFile = Join-Path $stateRoot 'target-session.txt'
$monitorScript = Join-Path $PSScriptRoot 'CodexTokenMonitor.ps1'
$powerShellPath = Join-Path $PSHOME 'powershell.exe'
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'

function Get-MonitorProcess {
    if (-not (Test-Path -LiteralPath $pidPath -PathType Leaf)) {
        return $null
    }

    $savedPid = 0
    if (-not [int]::TryParse((Get-Content -LiteralPath $pidPath -Raw).Trim(), [ref]$savedPid)) {
        Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue
        return $null
    }

    $process = Get-CimInstance Win32_Process -Filter "ProcessId = $savedPid" -ErrorAction SilentlyContinue
    if ($null -eq $process -or $process.Name -notmatch '^powershell(\.exe)?$' -or $process.CommandLine -notlike '*CodexTokenMonitor.ps1*') {
        Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue
        return $null
    }

    return $process
}

function Set-CurrentSessionTarget {
    $codexRoot = if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        [System.IO.Path]::GetFullPath($env:CODEX_HOME)
    }
    else {
        Join-Path $env:USERPROFILE '.codex'
    }
    $sessionsRoot = Join-Path $codexRoot 'sessions'
    if (-not (Test-Path -LiteralPath $sessionsRoot -PathType Container)) {
        return $null
    }

    $latestPath = $null
    $latestTime = [DateTime]::MinValue
    foreach ($path in [System.IO.Directory]::EnumerateFiles($sessionsRoot, 'rollout-*.jsonl', [System.IO.SearchOption]::AllDirectories)) {
        $writeTime = [System.IO.File]::GetLastWriteTimeUtc($path)
        if ($writeTime -gt $latestTime) {
            $latestTime = $writeTime
            $latestPath = $path
        }
    }

    if ($null -ne $latestPath) {
        [System.IO.File]::WriteAllText($targetPathFile, $latestPath)
    }
    return $latestPath
}

function Start-Monitor {
    param([switch]$RequestShow)

    $targetSessionPath = Set-CurrentSessionTarget
    $existing = Get-MonitorProcess
    if ($null -ne $existing -and -not $RequestShow) {
        return [pscustomobject]@{ status = 'running'; pid = [int]$existing.ProcessId; autostart = (Get-AutostartState) }
    }

    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-WindowStyle', 'Hidden',
        '-File', ('"{0}"' -f $monitorScript)
    )
    if ($null -ne $targetSessionPath) {
        $arguments += @('-InitialSessionPath', ('"{0}"' -f $targetSessionPath))
    }
    $started = Start-Process -FilePath $powerShellPath -ArgumentList $arguments -WindowStyle Hidden -PassThru

    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        Start-Sleep -Milliseconds 100
        $running = Get-MonitorProcess
        if ($null -ne $running) {
            return [pscustomobject]@{ status = 'running'; pid = [int]$running.ProcessId; autostart = (Get-AutostartState) }
        }
        if ($started.HasExited) {
            break
        }
    }

    throw 'The token monitor did not start successfully.'
}

function Stop-Monitor {
    $process = Get-MonitorProcess
    if ($null -eq $process) {
        return [pscustomobject]@{ status = 'stopped'; pid = $null; autostart = (Get-AutostartState) }
    }

    Stop-Process -Id ([int]$process.ProcessId) -Force
    Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue
    return [pscustomobject]@{ status = 'stopped'; pid = $null; autostart = (Get-AutostartState) }
}

function Get-AutostartState {
    try {
        $item = Get-ItemProperty -Path $runKey -ErrorAction Stop
        $property = $item.PSObject.Properties[$appName]
        return $null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)
    }
    catch {
        return $false
    }
}

function Set-Autostart {
    param([bool]$Enabled)

    if ($Enabled) {
        $command = '"{0}" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{1}" -FollowActive' -f $powerShellPath, $monitorScript
        New-Item -Path $runKey -Force | Out-Null
        Set-ItemProperty -Path $runKey -Name $appName -Value $command
    }
    else {
        Remove-ItemProperty -Path $runKey -Name $appName -ErrorAction SilentlyContinue
    }
}

if (-not (Test-Path -LiteralPath $stateRoot -PathType Container)) {
    New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
}

$result = switch ($Action) {
    'Start' { Start-Monitor }
    'Show' { Start-Monitor -RequestShow }
    'Stop' { Stop-Monitor }
    'Restart' {
        [void](Stop-Monitor)
        Start-Monitor
    }
    'Status' {
        $process = Get-MonitorProcess
        [pscustomobject]@{
            status = $(if ($null -ne $process) { 'running' } else { 'stopped' })
            pid = $(if ($null -ne $process) { [int]$process.ProcessId } else { $null })
            autostart = Get-AutostartState
        }
    }
    'EnableAutostart' {
        Set-Autostart -Enabled $true
        [pscustomobject]@{ status = 'configured'; pid = $null; autostart = $true }
    }
    'DisableAutostart' {
        Set-Autostart -Enabled $false
        [pscustomobject]@{ status = 'configured'; pid = $null; autostart = $false }
    }
}

$result | ConvertTo-Json -Compress
