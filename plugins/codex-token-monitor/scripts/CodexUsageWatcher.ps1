[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [int]$ParentProcessId,

    [Parameter(Mandatory = $true)]
    [string]$TargetPathFile,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath,

    [ValidateRange(250, 10000)]
    [int]$PollIntervalMs = 500
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'TokenUsage.Core.psm1') -Force

$lastTargetPath = ''
$lastWriteTimeUtc = [DateTime]::MinValue
$temporaryPath = $OutputPath + '.tmp.' + $PID
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

try {
    while ($null -ne (Get-Process -Id $ParentProcessId -ErrorAction SilentlyContinue)) {
        $targetPath = ''
        try {
            if (Test-Path -LiteralPath $TargetPathFile -PathType Leaf) {
                $targetPath = [System.IO.File]::ReadAllText($TargetPathFile).Trim()
            }
        }
        catch {
            $targetPath = ''
        }

        if (-not [string]::IsNullOrWhiteSpace($targetPath) -and (Test-Path -LiteralPath $targetPath -PathType Leaf)) {
            $writeTimeUtc = [System.IO.File]::GetLastWriteTimeUtc($targetPath)
            if ($targetPath -ne $lastTargetPath -or $writeTimeUtc -ne $lastWriteTimeUtc) {
                $published = $false
                $backupPath = $null
                try {
                    $snapshot = Get-CodexUsageSnapshot -SessionPath $targetPath
                    if ($null -ne $snapshot) {
                        $json = $snapshot | ConvertTo-Json -Compress -Depth 5
                        [System.IO.File]::WriteAllText($temporaryPath, $json, $utf8NoBom)
                        if (Test-Path -LiteralPath $OutputPath -PathType Leaf) {
                            $backupPath = $temporaryPath + '.backup.' + [Guid]::NewGuid().ToString('N')
                            [System.IO.File]::Replace($temporaryPath, $OutputPath, $backupPath)
                            Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
                        }
                        else {
                            [System.IO.File]::Move($temporaryPath, $OutputPath)
                        }
                        $published = $true
                    }
                    elseif ($targetPath -ne $lastTargetPath) {
                        if (Test-Path -LiteralPath $OutputPath -PathType Leaf) {
                            Remove-Item -LiteralPath $OutputPath -Force -ErrorAction Stop
                        }
                        $published = -not (Test-Path -LiteralPath $OutputPath -PathType Leaf)
                    }
                    else {
                        $published = $true
                    }
                }
                catch {
                    Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
                    if ($null -ne $backupPath) {
                        Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
                    }
                }

                if ($published) {
                    $lastTargetPath = $targetPath
                    $lastWriteTimeUtc = $writeTimeUtc
                }
            }
        }

        Start-Sleep -Milliseconds $PollIntervalMs
    }
}
finally {
    Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
}
