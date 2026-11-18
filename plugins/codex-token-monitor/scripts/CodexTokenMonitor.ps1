[CmdletBinding()]
param(
    [switch]$Headless,
    [switch]$FollowActive,
    [string]$InitialSessionPath,
    [ValidateRange(0, 3600)]
    [int]$RunSeconds = 0,
    [string]$SessionsRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'TokenUsage.Core.psm1') -Force

if ([string]::IsNullOrWhiteSpace($SessionsRoot)) {
    $SessionsRoot = Join-Path (Get-CodexDataRoot) 'sessions'
}

if ($Headless) {
    $paths = Get-CodexSessionFiles -SessionsRoot $SessionsRoot
    $latest = Get-MostRecentCodexSession -SessionPaths $paths
    if ($null -eq $latest) {
        @{ status = 'waiting'; reason = 'No Codex session files were found.' } | ConvertTo-Json -Compress
        exit 1
    }
    $snapshot = Get-CodexUsageSnapshot -SessionPath $latest
    if ($null -eq $snapshot) {
        @{ status = 'waiting'; reason = 'No token_count event was found in the active session.' } | ConvertTo-Json -Compress
        exit 1
    }
    $snapshot | Select-Object SessionId, EventTimestamp, LastInputTokens, LastCachedInputTokens, LastOutputTokens, LastReasoningTokens, LastTotalTokens, TotalTokens, ModelContextWindow, ContextPercent | ConvertTo-Json -Compress
    exit 0
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$stateRoot = Join-Path $env:LOCALAPPDATA 'CodexTokenMonitor'
$pidPath = Join-Path $stateRoot 'monitor.pid'
$targetPathFile = Join-Path $stateRoot 'target-session.txt'
$selectedTaskPath = Join-Path $stateRoot 'selected-task.txt'
$usageTargetPath = Join-Path $stateRoot 'usage-target-session.txt'
$usageSnapshotPath = Join-Path $stateRoot 'usage-snapshot.json'
$selectionWatcherScript = Join-Path $PSScriptRoot 'CodexSelectionWatcher.ps1'
$usageWatcherScript = Join-Path $PSScriptRoot 'CodexUsageWatcher.ps1'
if (-not (Test-Path -LiteralPath $stateRoot -PathType Container)) {
    New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
}

$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\CodexTokenMonitor.Singleton', [ref]$createdNew)
$showEvent = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, 'Local\CodexTokenMonitor.Show')
if (-not $createdNew) {
    [void]$showEvent.Set()
    $showEvent.Dispose()
    $mutex.Dispose()
    exit 0
}

[System.IO.File]::WriteAllText($pidPath, [string]$PID)

$colorBackground = [System.Drawing.ColorTranslator]::FromHtml('#17191D')
$colorPanel = [System.Drawing.ColorTranslator]::FromHtml('#23262C')
$colorText = [System.Drawing.ColorTranslator]::FromHtml('#F4F6F8')
$colorMuted = [System.Drawing.ColorTranslator]::FromHtml('#98A1AE')
$colorAccent = [System.Drawing.ColorTranslator]::FromHtml('#39C98A')
$colorWarning = [System.Drawing.ColorTranslator]::FromHtml('#E8AD4A')
$colorTrack = [System.Drawing.ColorTranslator]::FromHtml('#343840')

function New-Label {
    param(
        [string]$Text,
        [int]$X,
        [int]$Y,
        [int]$Width,
        [int]$Height,
        [float]$Size = 9.0,
        [System.Drawing.Color]$Color = $colorText,
        [System.Drawing.FontStyle]$Style = [System.Drawing.FontStyle]::Regular,
        [System.Drawing.ContentAlignment]$Align = [System.Drawing.ContentAlignment]::MiddleLeft
    )

    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Location = New-Object System.Drawing.Point($X, $Y)
    $label.Size = New-Object System.Drawing.Size($Width, $Height)
    $label.ForeColor = $Color
    $label.BackColor = [System.Drawing.Color]::Transparent
    $label.Font = New-Object System.Drawing.Font('Segoe UI', $Size, $Style)
    $label.TextAlign = $Align
    return $label
}

function Format-Age {
    param([DateTime]$Timestamp)
    if ($Timestamp -eq [DateTime]::MinValue) { return 'unknown' }
    $age = [DateTime]::UtcNow - $Timestamp.ToUniversalTime()
    if ($age.TotalSeconds -lt 2) { return 'now' }
    if ($age.TotalMinutes -lt 1) { return ('{0}s ago' -f [Math]::Floor($age.TotalSeconds)) }
    if ($age.TotalHours -lt 1) { return ('{0}m ago' -f [Math]::Floor($age.TotalMinutes)) }
    return ('{0}h ago' -f [Math]::Floor($age.TotalHours))
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Codex Token Monitor'
$form.ClientSize = New-Object System.Drawing.Size(420, 460)
$form.MinimumSize = New-Object System.Drawing.Size(436, 499)
$form.MaximumSize = New-Object System.Drawing.Size(436, 499)
$form.BackColor = $colorBackground
$form.ForeColor = $colorText
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
$form.MaximizeBox = $false
$form.TopMost = $true
$form.ShowInTaskbar = $true
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$workingArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.Location = New-Object System.Drawing.Point(($workingArea.Right - $form.Width - 20), ($workingArea.Top + 20))

$titleLabel = New-Label -Text 'Codex Token Monitor' -X 20 -Y 14 -Width 225 -Height 32 -Size 16 -Style ([System.Drawing.FontStyle]::Bold)
$historyButton = New-Object System.Windows.Forms.Button
$historyButton.Text = 'History'
$historyButton.Location = New-Object System.Drawing.Point(252, 18)
$historyButton.Size = New-Object System.Drawing.Size(70, 25)
$historyButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$historyButton.FlatAppearance.BorderColor = $colorTrack
$historyButton.BackColor = $colorPanel
$historyButton.ForeColor = $colorText
$historyButton.Font = New-Object System.Drawing.Font('Segoe UI', 8)
$historyButton.TabStop = $false
$statusDot = New-Object System.Windows.Forms.Panel
$statusDot.Location = New-Object System.Drawing.Point(335, 27)
$statusDot.Size = New-Object System.Drawing.Size(8, 8)
$statusDot.BackColor = $colorWarning
$statusLabel = New-Label -Text 'Waiting' -X 350 -Y 18 -Width 54 -Height 26 -Size 8 -Color $colorMuted -Align ([System.Drawing.ContentAlignment]::MiddleRight)

$taskNameTitle = New-Label -Text 'TASK' -X 20 -Y 52 -Width 80 -Height 18 -Size 8 -Color $colorMuted -Style ([System.Drawing.FontStyle]::Bold)
$taskNameLabel = New-Label -Text '--' -X 20 -Y 69 -Width 380 -Height 24 -Size 10 -Style ([System.Drawing.FontStyle]::Bold)
$taskNameLabel.AutoEllipsis = $true
$questionTitle = New-Label -Text 'ROUND -- USER QUESTION' -X 20 -Y 98 -Width 250 -Height 18 -Size 8 -Color $colorMuted -Style ([System.Drawing.FontStyle]::Bold)
$questionLabel = New-Label -Text '--' -X 20 -Y 114 -Width 380 -Height 38 -Size 9 -Color $colorText
$questionLabel.AutoEllipsis = $true

$contextTitle = New-Label -Text 'CONTEXT WINDOW' -X 20 -Y 160 -Width 180 -Height 20 -Size 8 -Color $colorMuted -Style ([System.Drawing.FontStyle]::Bold)
$contextValue = New-Label -Text '-- / --' -X 190 -Y 158 -Width 210 -Height 24 -Size 9 -Color $colorText -Align ([System.Drawing.ContentAlignment]::MiddleRight)
$contextTrack = New-Object System.Windows.Forms.Panel
$contextTrack.Location = New-Object System.Drawing.Point(20, 186)
$contextTrack.Size = New-Object System.Drawing.Size(380, 7)
$contextTrack.BackColor = $colorTrack
$contextFill = New-Object System.Windows.Forms.Panel
$contextFill.Location = New-Object System.Drawing.Point(0, 0)
$contextFill.Size = New-Object System.Drawing.Size(0, 7)
$contextFill.BackColor = $colorAccent
$contextTrack.Controls.Add($contextFill)

$divider = New-Object System.Windows.Forms.Panel
$divider.Location = New-Object System.Drawing.Point(20, 209)
$divider.Size = New-Object System.Drawing.Size(380, 1)
$divider.BackColor = $colorPanel

$lastTitle = New-Label -Text 'CURRENT TURN' -X 20 -Y 221 -Width 180 -Height 20 -Size 8 -Color $colorMuted -Style ([System.Drawing.FontStyle]::Bold)
$metricNames = @('Input', 'Output', 'Reasoning', 'Cached')
$metricLabels = @()
$metricValues = @()
for ($index = 0; $index -lt $metricNames.Count; $index++) {
    $x = 20 + ($index * 96)
    $metricLabels += New-Label -Text $metricNames[$index] -X $x -Y 247 -Width 88 -Height 18 -Size 8 -Color $colorMuted
    $metricValues += New-Label -Text '--' -X $x -Y 266 -Width 88 -Height 34 -Size 15 -Style ([System.Drawing.FontStyle]::Bold)
}

$turnSummary = New-Label -Text 'TOTAL --' -X 20 -Y 303 -Width 380 -Height 20 -Size 8 -Color $colorMuted
$sessionTitle = New-Label -Text 'SESSION PROCESSED' -X 20 -Y 327 -Width 190 -Height 20 -Size 8 -Color $colorMuted -Style ([System.Drawing.FontStyle]::Bold)
$sessionTotal = New-Label -Text '--' -X 20 -Y 348 -Width 210 -Height 42 -Size 23 -Style ([System.Drawing.FontStyle]::Bold)
$sessionUnit = New-Label -Text 'tokens' -X 231 -Y 360 -Width 60 -Height 24 -Size 9 -Color $colorMuted

$taskLabel = New-Label -Text 'Task --' -X 20 -Y 397 -Width 190 -Height 22 -Size 8 -Color $colorMuted
$updatedLabel = New-Label -Text 'Waiting for usage data' -X 210 -Y 397 -Width 190 -Height 22 -Size 8 -Color $colorMuted -Align ([System.Drawing.ContentAlignment]::MiddleRight)

$followCheck = New-Object System.Windows.Forms.CheckBox
$followCheck.Text = 'Follow Codex selection'
$followCheck.Location = New-Object System.Drawing.Point(20, 427)
$followCheck.Size = New-Object System.Drawing.Size(155, 24)
$followCheck.ForeColor = $colorText
$followCheck.BackColor = $colorBackground
$followCheck.Checked = $true

$topmostCheck = New-Object System.Windows.Forms.CheckBox
$topmostCheck.Text = 'Always on top'
$topmostCheck.Location = New-Object System.Drawing.Point(276, 427)
$topmostCheck.Size = New-Object System.Drawing.Size(124, 24)
$topmostCheck.ForeColor = $colorText
$topmostCheck.BackColor = $colorBackground
$topmostCheck.Checked = $true
$topmostCheck.Add_CheckedChanged({ $form.TopMost = $topmostCheck.Checked })

$controls = @($titleLabel, $historyButton, $statusDot, $statusLabel, $taskNameTitle, $taskNameLabel, $questionTitle, $questionLabel, $contextTitle, $contextValue, $contextTrack, $divider, $lastTitle, $turnSummary, $sessionTitle, $sessionTotal, $sessionUnit, $taskLabel, $updatedLabel, $followCheck, $topmostCheck) + $metricLabels + $metricValues
$form.Controls.AddRange([System.Windows.Forms.Control[]]$controls)

$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$showMenuItem = $trayMenu.Items.Add('Show monitor')
$topMenuItem = $trayMenu.Items.Add('Always on top')
$topMenuItem.Checked = $true
[void]$trayMenu.Items.Add('-')
$exitMenuItem = $trayMenu.Items.Add('Exit')
$trayIcon = New-Object System.Windows.Forms.NotifyIcon
$trayIcon.Text = 'Codex Token Monitor'
$trayIcon.Icon = [System.Drawing.SystemIcons]::Information
$trayIcon.ContextMenuStrip = $trayMenu
$trayIcon.Visible = $true

$script:Exiting = $false
$script:NeedRescan = $true
$script:SessionPaths = @()
$script:CurrentPath = $null
$script:PinnedPath = $null
$script:SelectedPath = $null
$script:LastSelectedTaskName = ''
$script:TaskPathsByName = @{}
$script:UnindexedSessionPaths = @()
$script:NeedFallbackTaskIndex = $true
$script:NeedTaskIndex = $true
$script:LastSnapshot = $null
$script:LastWriteTime = [DateTime]::MinValue
$script:TickCount = 0
$script:HistoryForm = $null
$script:HistoryGrid = $null
$script:HistoryTitleLabel = $null
$script:HistoryStatusLabel = $null
$script:HistoryPath = $null
$script:HistoryRunspace = $null
$script:HistoryPowerShell = $null
$script:HistoryAsyncResult = $null
$script:HistoryActiveRequest = $null
$script:HistoryPendingRequest = $null
$script:HistoryRequestId = 0
$script:HistoryPollTimer = $null

function Get-RequestedSessionPath {
    if (-not (Test-Path -LiteralPath $targetPathFile -PathType Leaf)) {
        return $null
    }
    try {
        $requestedPath = (Get-Content -LiteralPath $targetPathFile -Raw).Trim()
        if (Test-Path -LiteralPath $requestedPath -PathType Leaf) {
            return $requestedPath
        }
    }
    catch {
        return $null
    }
    return $null
}

if (-not $FollowActive) {
    if (-not [string]::IsNullOrWhiteSpace($InitialSessionPath) -and (Test-Path -LiteralPath $InitialSessionPath -PathType Leaf)) {
        $script:SelectedPath = $InitialSessionPath
    }
    else {
        $script:SelectedPath = Get-RequestedSessionPath
    }
}

function Get-SessionIdFromPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $id = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    if ($id -match '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})(?:_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})?$') {
        return $Matches[1]
    }
    return $id
}

function Update-TaskPathIndex {
    $index = @{}
    $unindexedPaths = New-Object System.Collections.Generic.List[string]
    $indexedNames = Get-CodexIndexedTaskNames
    foreach ($path in $script:SessionPaths) {
        try {
            $sessionId = Get-SessionIdFromPath -Path $path
            if (-not $indexedNames.ContainsKey($sessionId)) {
                $unindexedPaths.Add($path)
                continue
            }
            $name = $indexedNames[$sessionId]
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            if (-not $index.ContainsKey($name)) {
                $index[$name] = @()
            }
            $index[$name] += $path
        }
        catch {
            continue
        }
    }
    $script:TaskPathsByName = $index
    $script:UnindexedSessionPaths = $unindexedPaths.ToArray()
    $script:NeedFallbackTaskIndex = $true
    $script:NeedTaskIndex = $false
}

function Update-FallbackTaskPathIndex {
    foreach ($path in $script:UnindexedSessionPaths) {
        try {
            $sessionId = Get-SessionIdFromPath -Path $path
            $name = Get-CodexTaskName -SessionId $sessionId -SessionPath $path -SkipIndex
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            if (-not $script:TaskPathsByName.ContainsKey($name)) {
                $script:TaskPathsByName[$name] = @()
            }
            $script:TaskPathsByName[$name] += $path
        }
        catch {
            continue
        }
    }
    $script:NeedFallbackTaskIndex = $false
}

function Get-SelectedCodexTaskName {
    try {
        if (-not (Test-Path -LiteralPath $selectedTaskPath -PathType Leaf)) { return '' }
        return (Get-Content -LiteralPath $selectedTaskPath -Raw -Encoding UTF8).Trim()
    }
    catch {
        return ''
    }
    return ''
}

function Resolve-SessionPathByTaskName {
    param([Parameter(Mandatory = $true)][string]$TaskName)

    if ($script:NeedTaskIndex) {
        Update-TaskPathIndex
    }
    if (-not $script:TaskPathsByName.ContainsKey($TaskName) -and $script:NeedFallbackTaskIndex) {
        Update-FallbackTaskPathIndex
    }
    if (-not $script:TaskPathsByName.ContainsKey($TaskName)) {
        return $null
    }

    $candidates = @($script:TaskPathsByName[$TaskName])
    if ($null -ne $script:CurrentPath -and $candidates -contains $script:CurrentPath) {
        return $script:CurrentPath
    }
    return $candidates |
        Sort-Object { [System.IO.File]::GetLastWriteTimeUtc($_) } -Descending |
        Select-Object -First 1
}

function Format-HistoryDuration {
    param([long]$Seconds)
    if ($Seconds -ge 3600) { return ('{0:0.0}h' -f ($Seconds / 3600.0)) }
    if ($Seconds -ge 60) { return ('{0}m {1}s' -f [Math]::Floor($Seconds / 60), ($Seconds % 60)) }
    return ('{0}s' -f $Seconds)
}

function New-HistoryWindow {
    $historyForm = New-Object System.Windows.Forms.Form
    $historyForm.Text = 'Codex Token History'
    $historyForm.ClientSize = New-Object System.Drawing.Size(920, 500)
    $historyForm.MinimumSize = New-Object System.Drawing.Size(760, 420)
    $historyForm.BackColor = $colorBackground
    $historyForm.ForeColor = $colorText
    $historyForm.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $historyForm.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $historyForm.ShowInTaskbar = $false

    $historyTitle = New-Label -Text 'Turn history' -X 20 -Y 14 -Width 690 -Height 28 -Size 14 -Style ([System.Drawing.FontStyle]::Bold)
    $historyTitle.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $historyStatus = New-Label -Text 'Loading...' -X 20 -Y 42 -Width 690 -Height 20 -Size 8 -Color $colorMuted
    $historyStatus.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right

    $refreshButton = New-Object System.Windows.Forms.Button
    $refreshButton.Text = 'Refresh'
    $refreshButton.Location = New-Object System.Drawing.Point(820, 20)
    $refreshButton.Size = New-Object System.Drawing.Size(80, 28)
    $refreshButton.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
    $refreshButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $refreshButton.FlatAppearance.BorderColor = $colorTrack
    $refreshButton.BackColor = $colorPanel
    $refreshButton.ForeColor = $colorText

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(20, 72)
    $grid.Size = New-Object System.Drawing.Size(880, 408)
    $grid.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $grid.BackgroundColor = $colorBackground
    $grid.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $grid.CellBorderStyle = [System.Windows.Forms.DataGridViewCellBorderStyle]::SingleHorizontal
    $grid.GridColor = $colorTrack
    $grid.EnableHeadersVisualStyles = $false
    $grid.ColumnHeadersDefaultCellStyle.BackColor = $colorPanel
    $grid.ColumnHeadersDefaultCellStyle.ForeColor = $colorText
    $grid.ColumnHeadersDefaultCellStyle.SelectionBackColor = $colorPanel
    $grid.ColumnHeadersHeight = 32
    $grid.RowsDefaultCellStyle.BackColor = $colorBackground
    $grid.RowsDefaultCellStyle.ForeColor = $colorText
    $grid.RowsDefaultCellStyle.SelectionBackColor = [System.Drawing.ColorTranslator]::FromHtml('#2D423B')
    $grid.RowsDefaultCellStyle.SelectionForeColor = $colorText
    $grid.AlternatingRowsDefaultCellStyle.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#1D2025')
    $grid.RowTemplate.Height = 30
    $grid.RowHeadersVisible = $false
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AllowUserToResizeRows = $false
    $grid.ReadOnly = $true
    $grid.MultiSelect = $false
    $grid.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
    $grid.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::Fill

    $columnSpecs = @(
        @('Round', 'Round', 55),
        @('Question', 'User question', 250),
        @('Total', 'Total', 72),
        @('Input', 'Input', 72),
        @('Output', 'Output', 65),
        @('Cached', 'Cached', 72),
        @('Reasoning', 'Reasoning', 70),
        @('Calls', 'Calls', 46),
        @('Status', 'Status', 65),
        @('Elapsed', 'Elapsed', 62)
    )
    foreach ($spec in $columnSpecs) {
        $column = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $column.Name = $spec[0]
        $column.HeaderText = $spec[1]
        $column.FillWeight = $spec[2]
        $column.MinimumWidth = if ($spec[0] -eq 'Question') { 170 } else { 48 }
        [void]$grid.Columns.Add($column)
    }

    $historyForm.Controls.AddRange([System.Windows.Forms.Control[]]@($historyTitle, $historyStatus, $refreshButton, $grid))
    $refreshButton.Add_Click({ Update-HistoryWindow })
    $historyForm.Add_FormClosed({
        $script:HistoryRequestId++
        $script:HistoryPendingRequest = $null
        $script:HistoryForm = $null
        $script:HistoryGrid = $null
        $script:HistoryTitleLabel = $null
        $script:HistoryStatusLabel = $null
        $script:HistoryPath = $null
    })

    $script:HistoryForm = $historyForm
    $script:HistoryGrid = $grid
    $script:HistoryTitleLabel = $historyTitle
    $script:HistoryStatusLabel = $historyStatus
}

function Initialize-HistoryRunspace {
    if ($null -ne $script:HistoryRunspace) { return }

    $initialState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $modulePath = Join-Path $PSScriptRoot 'TokenUsage.Core.psm1'
    $initialState.ImportPSModule([string[]]@($modulePath))
    $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($initialState)
    $runspace.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
    $runspace.Open()
    $script:HistoryRunspace = $runspace
}

function Start-HistoryLoad {
    if ($null -ne $script:HistoryAsyncResult -or $null -eq $script:HistoryPendingRequest) { return }

    $request = $script:HistoryPendingRequest
    $script:HistoryPendingRequest = $null
    try {
        Initialize-HistoryRunspace
        $sessionId = Get-SessionIdFromPath -Path $request.Path
        $pipeline = [System.Management.Automation.PowerShell]::Create()
        $pipeline.Runspace = $script:HistoryRunspace
        $script:HistoryPowerShell = $pipeline
        $script:HistoryActiveRequest = $request
        $script:HistoryAsyncResult = $pipeline.AddScript(
            '$path = [string]$args[0]; $sessionId = [string]$args[1]; $turns = @(Get-CodexTurnHistory -SessionPath $path -MaxTurns 100); $taskName = Get-CodexTaskName -SessionId $sessionId -SessionPath $path; [pscustomobject]@{ SessionPath = $path; Turns = $turns; TaskName = $taskName }'
        ).AddArgument($request.Path).AddArgument($sessionId).BeginInvoke()

        if ($null -eq $script:HistoryPollTimer) {
            $script:HistoryPollTimer = New-Object System.Windows.Forms.Timer
            $script:HistoryPollTimer.Interval = 100
            $script:HistoryPollTimer.Add_Tick({ Complete-HistoryLoad })
        }
        $script:HistoryPollTimer.Start()
    }
    catch {
        if (
            $request.RequestId -eq $script:HistoryRequestId -and
            $null -ne $script:HistoryForm -and
            -not $script:HistoryForm.IsDisposed
        ) {
            $script:HistoryStatusLabel.Text = 'Could not load turn history.'
        }
        if ($null -ne $script:HistoryPowerShell) {
            $script:HistoryPowerShell.Dispose()
            $script:HistoryPowerShell = $null
        }
        $script:HistoryAsyncResult = $null
        $script:HistoryActiveRequest = $null
        if ($null -ne $script:HistoryPendingRequest) { Start-HistoryLoad }
        elseif ($null -ne $script:HistoryPollTimer) { $script:HistoryPollTimer.Stop() }
    }
}

function Complete-HistoryLoad {
    if ($null -eq $script:HistoryAsyncResult -or -not $script:HistoryAsyncResult.IsCompleted) { return }

    $pipeline = $script:HistoryPowerShell
    $request = $script:HistoryActiveRequest
    $asyncResult = $script:HistoryAsyncResult
    $result = $null
    $loadError = $null
    try {
        $items = @($pipeline.EndInvoke($asyncResult))
        if ($pipeline.HadErrors -or $items.Count -eq 0) {
            $loadError = 'History parser returned an error.'
        }
        else {
            $result = $items[$items.Count - 1]
        }
    }
    catch {
        $loadError = $_.Exception.Message
    }
    finally {
        $pipeline.Dispose()
        $script:HistoryPowerShell = $null
        $script:HistoryAsyncResult = $null
        $script:HistoryActiveRequest = $null
    }

    $currentPath = if ($null -ne $script:CurrentPath) { $script:CurrentPath } else { $script:SelectedPath }
    $isCurrent =
        $null -ne $request -and
        $request.RequestId -eq $script:HistoryRequestId -and
        $request.Path -eq $currentPath -and
        $null -ne $script:HistoryForm -and
        -not $script:HistoryForm.IsDisposed

    if ($isCurrent) {
        if ($null -ne $loadError -or $null -eq $result -or $result.SessionPath -ne $request.Path) {
            $script:HistoryStatusLabel.Text = 'Could not load turn history.'
        }
        else {
            Set-HistoryWindowResult -Result $result
        }
    }

    if ($null -ne $script:HistoryPendingRequest) {
        Start-HistoryLoad
    }
    elseif ($null -ne $script:HistoryPollTimer) {
        $script:HistoryPollTimer.Stop()
    }
}

function Set-HistoryWindowResult {
    param([Parameter(Mandatory = $true)]$Result)

    if ($null -eq $script:HistoryForm -or $script:HistoryForm.IsDisposed) { return }
    $history = @($Result.Turns)
    $script:HistoryGrid.SuspendLayout()
    try {
        $script:HistoryGrid.Rows.Clear()
        for ($index = $history.Count - 1; $index -ge 0; $index--) {
            $turn = $history[$index]
            $rowIndex = $script:HistoryGrid.Rows.Add(
                ('#{0}' -f $turn.TurnNumber),
                $turn.Prompt,
                (Format-CompactTokenCount $turn.TotalTokens),
                (Format-CompactTokenCount $turn.InputTokens),
                (Format-CompactTokenCount $turn.OutputTokens),
                (Format-CompactTokenCount $turn.CachedInputTokens),
                (Format-CompactTokenCount $turn.ReasoningTokens),
                $turn.CallCount,
                $turn.Status,
                (Format-HistoryDuration $turn.ElapsedSeconds)
            )
            $row = $script:HistoryGrid.Rows[$rowIndex]
            $row.Cells['Question'].ToolTipText = $turn.Prompt
            if ($turn.Status -eq 'Running') {
                $row.Cells['Status'].Style.ForeColor = $colorAccent
            }
            elseif ($turn.Status -eq 'Aborted') {
                $row.Cells['Status'].Style.ForeColor = $colorWarning
            }
        }
    }
    finally {
        $script:HistoryGrid.ResumeLayout()
    }

    $script:HistoryTitleLabel.Text = $Result.TaskName
    $script:HistoryStatusLabel.Text = 'Showing {0} most recent rounds - newest first' -f $history.Count
    $script:HistoryPath = $Result.SessionPath
}

function Update-HistoryWindow {
    if ($null -eq $script:HistoryForm -or $script:HistoryForm.IsDisposed) { return }
    $path = if ($null -ne $script:CurrentPath) { $script:CurrentPath } else { $script:SelectedPath }
    if ($null -eq $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $script:HistoryRequestId++
        $script:HistoryPendingRequest = $null
        $script:HistoryStatusLabel.Text = 'No task selected.'
        $script:HistoryGrid.Rows.Clear()
        $script:HistoryPath = $null
        return
    }

    $script:HistoryRequestId++
    $script:HistoryPendingRequest = [pscustomobject]@{
        Path = $path
        RequestId = $script:HistoryRequestId
    }
    $script:HistoryStatusLabel.Text = 'Loading turn history...'
    $script:HistoryForm.Refresh()
    Start-HistoryLoad
}

function Stop-HistoryInfrastructure {
    $script:HistoryRequestId++
    $script:HistoryPendingRequest = $null

    if ($null -ne $script:HistoryPollTimer) {
        $script:HistoryPollTimer.Stop()
        $script:HistoryPollTimer.Dispose()
        $script:HistoryPollTimer = $null
    }

    $pipeline = $script:HistoryPowerShell
    if ($null -ne $pipeline) {
        try {
            if ($pipeline.InvocationStateInfo.State -eq [System.Management.Automation.PSInvocationState]::Running) {
                $pipeline.Stop()
            }
        }
        catch {
        }
        try {
            $pipeline.Dispose()
        }
        catch {
        }
    }

    $script:HistoryPowerShell = $null
    $script:HistoryAsyncResult = $null
    $script:HistoryActiveRequest = $null

    if ($null -ne $script:HistoryRunspace) {
        try {
            $script:HistoryRunspace.Close()
        }
        catch {
        }
        try {
            $script:HistoryRunspace.Dispose()
        }
        catch {
        }
        $script:HistoryRunspace = $null
    }
}

function Show-HistoryWindow {
    if ($null -eq $script:HistoryForm -or $script:HistoryForm.IsDisposed) {
        New-HistoryWindow
    }
    Update-HistoryWindow
    if (-not $script:HistoryForm.Visible) {
        $script:HistoryForm.Show($form)
    }
    $script:HistoryForm.Activate()
}

$historyButton.Add_Click({ Show-HistoryWindow })

$selectionWatcherProcess = $null
if (Test-Path -LiteralPath $selectionWatcherScript -PathType Leaf) {
    Remove-Item -LiteralPath $selectedTaskPath -Force -ErrorAction SilentlyContinue
    $selectionWatcherArguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-WindowStyle', 'Hidden',
        '-File', ('"{0}"' -f $selectionWatcherScript),
        '-ParentProcessId', $PID,
        '-OutputPath', ('"{0}"' -f $selectedTaskPath)
    )
    $selectionWatcherProcess = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $selectionWatcherArguments -WindowStyle Hidden -PassThru
}

$usageWatcherProcess = $null
if (Test-Path -LiteralPath $usageWatcherScript -PathType Leaf) {
    Remove-Item -LiteralPath $usageTargetPath, $usageSnapshotPath -Force -ErrorAction SilentlyContinue
    $usageWatcherArguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-WindowStyle', 'Hidden',
        '-File', ('"{0}"' -f $usageWatcherScript),
        '-ParentProcessId', $PID,
        '-TargetPathFile', ('"{0}"' -f $usageTargetPath),
        '-OutputPath', ('"{0}"' -f $usageSnapshotPath)
    )
    $usageWatcherProcess = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $usageWatcherArguments -WindowStyle Hidden -PassThru
}

$watcher = $null
if (Test-Path -LiteralPath $SessionsRoot -PathType Container) {
    $watcher = New-Object System.IO.FileSystemWatcher
    $watcher.Path = $SessionsRoot
    $watcher.Filter = '*.jsonl'
    $watcher.IncludeSubdirectories = $true
    $watcher.EnableRaisingEvents = $true
    Register-ObjectEvent -InputObject $watcher -EventName Created -Action { $script:NeedRescan = $true } | Out-Null
    Register-ObjectEvent -InputObject $watcher -EventName Renamed -Action { $script:NeedRescan = $true } | Out-Null
}

function Show-MonitorWindow {
    $form.Show()
    $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    $form.Activate()
}

$showMenuItem.Add_Click({ Show-MonitorWindow })
$trayIcon.Add_DoubleClick({ Show-MonitorWindow })
$topMenuItem.Add_Click({
    $topmostCheck.Checked = -not $topmostCheck.Checked
    $topMenuItem.Checked = $topmostCheck.Checked
})
$topmostCheck.Add_CheckedChanged({ $topMenuItem.Checked = $topmostCheck.Checked })
$exitMenuItem.Add_Click({
    $script:Exiting = $true
    $form.Close()
})
$form.Add_FormClosing({
    param($sender, $eventArgs)
    if (-not $script:Exiting -and $eventArgs.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) {
        $eventArgs.Cancel = $true
        $form.Hide()
    }
})

$followCheck.Add_CheckedChanged({
    if ($followCheck.Checked) {
        $script:PinnedPath = $null
    }
    else {
        $script:PinnedPath = $script:CurrentPath
    }
})

function Update-Display {
    param($Snapshot)

    if ($null -eq $Snapshot) {
        $statusDot.BackColor = $colorWarning
        $statusLabel.Text = 'Waiting'
        $taskNameLabel.Text = if ([string]::IsNullOrWhiteSpace($script:LastSelectedTaskName)) { '--' } else { $script:LastSelectedTaskName }
        $questionTitle.Text = 'CURRENT TURN USER QUESTION'
        $questionLabel.Text = 'Waiting for usage data'
        $contextValue.Text = '-- / --'
        $contextFill.Width = 0
        foreach ($metricValue in $metricValues) { $metricValue.Text = '--' }
        $turnSummary.Text = 'Waiting for usage data'
        $sessionTotal.Text = '--'
        $taskLabel.Text = 'Task --'
        $updatedLabel.Text = 'Waiting for usage data'
        return
    }

    $statusDot.BackColor = $colorAccent
    $statusLabel.Text = 'Live'
    $taskNameLabel.Text = $Snapshot.TaskName
    $contextValue.Text = '{0} / {1} ({2:0.0}%)' -f (Format-CompactTokenCount $Snapshot.LastInputTokens), (Format-CompactTokenCount $Snapshot.ModelContextWindow), $Snapshot.ContextPercent
    $fillWidth = [Math]::Max(0, [Math]::Min($contextTrack.Width, [int][Math]::Round($contextTrack.Width * $Snapshot.ContextPercent / 100.0)))
    $contextFill.Width = $fillWidth
    $contextFill.BackColor = if ($Snapshot.ContextPercent -ge 95) { [System.Drawing.Color]::FromArgb(229, 91, 91) } elseif ($Snapshot.ContextPercent -ge 85) { $colorWarning } else { $colorAccent }

    $turnDataProperty = $Snapshot.PSObject.Properties['TurnDataAvailable']
    $turnDataAvailable = if ($null -ne $turnDataProperty) {
        [bool]$turnDataProperty.Value
    }
    else {
        $null -ne $Snapshot.PSObject.Properties['TurnNumber']
    }
    if ($turnDataAvailable) {
        $questionTitle.Text = if ([int]$Snapshot.TurnNumber -gt 0) {
            'ROUND {0} USER QUESTION' -f $Snapshot.TurnNumber
        }
        else {
            'CURRENT TURN USER QUESTION'
        }
        $questionLabel.Text = $Snapshot.TurnPrompt
        $metricValues[0].Text = Format-CompactTokenCount $Snapshot.TurnInputTokens
        $metricValues[1].Text = Format-CompactTokenCount $Snapshot.TurnOutputTokens
        $metricValues[2].Text = Format-CompactTokenCount $Snapshot.TurnReasoningTokens
        $metricValues[3].Text = Format-CompactTokenCount $Snapshot.TurnCachedInputTokens
        $turnSummary.Text = 'TOTAL {0}   {1} model calls   {2}' -f (Format-CompactTokenCount $Snapshot.TurnTotalTokens), $Snapshot.TurnCallCount, $Snapshot.TurnStatus
    }
    else {
        $questionTitle.Text = 'CURRENT TURN USER QUESTION'
        $questionLabel.Text = 'Outside the recent scan window'
        foreach ($metricValue in $metricValues) { $metricValue.Text = '--' }
        $turnSummary.Text = 'CURRENT TURN DETAILS UNAVAILABLE'
    }
    $sessionTotal.Text = Format-CompactTokenCount $Snapshot.TotalTokens
    $taskLabel.Text = 'Task {0}' -f $Snapshot.SessionShortId
    $updatedLabel.Text = 'Updated {0}' -f (Format-Age $Snapshot.EventTimestampUtc)
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({
    $script:TickCount++
    if ($showEvent.WaitOne(0)) {
        $requestedPath = Get-RequestedSessionPath
        if ($null -ne $requestedPath) {
            if ($followCheck.Checked) {
                $script:SelectedPath = $requestedPath
            }
            else {
                $script:PinnedPath = $requestedPath
            }
            $script:CurrentPath = $null
            $script:LastWriteTime = [DateTime]::MinValue
        }
        Show-MonitorWindow
    }

    if ($script:NeedRescan -or $script:TickCount % 15 -eq 1) {
        $nextSessionPaths = @(Get-CodexSessionFiles -SessionsRoot $SessionsRoot)
        if ($nextSessionPaths.Count -ne $script:SessionPaths.Count) {
            $script:NeedTaskIndex = $true
        }
        $script:SessionPaths = $nextSessionPaths
        $script:NeedRescan = $false
    }

    $targetPath = if (-not $followCheck.Checked -and $null -ne $script:PinnedPath) {
        $script:PinnedPath
    }
    else {
        if ($script:TickCount % 2 -eq 1) {
            $selectedTaskName = Get-SelectedCodexTaskName
            if (-not [string]::IsNullOrWhiteSpace($selectedTaskName)) {
                $resolvedPath = Resolve-SessionPathByTaskName -TaskName $selectedTaskName
                if ($null -ne $resolvedPath) {
                    $script:LastSelectedTaskName = $selectedTaskName
                    $script:SelectedPath = $resolvedPath
                }
            }
        }
        if ($null -ne $script:SelectedPath) {
            $script:SelectedPath
        }
        else {
            Get-MostRecentCodexSession -SessionPaths $script:SessionPaths
        }
    }

    if ($null -eq $targetPath) {
        Update-Display $null
        return
    }

    $taskChanged = $targetPath -ne $script:CurrentPath
    if ($taskChanged) {
        $script:CurrentPath = $targetPath
        $script:LastSnapshot = $null
        $script:LastWriteTime = [DateTime]::MinValue
        [System.IO.File]::WriteAllText($usageTargetPath, $targetPath, [System.Text.Encoding]::UTF8)
    }

    if (Test-Path -LiteralPath $usageSnapshotPath -PathType Leaf) {
        $snapshotWriteTime = [System.IO.File]::GetLastWriteTimeUtc($usageSnapshotPath)
        if ($snapshotWriteTime -ne $script:LastWriteTime) {
            try {
                $snapshot = Get-Content -LiteralPath $usageSnapshotPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
                if ($snapshot.SessionPath -eq $targetPath) {
                    $script:LastSnapshot = $snapshot
                    $script:LastWriteTime = $snapshotWriteTime
                }
            }
            catch {
                # The watcher may be replacing the snapshot while this tick reads it.
            }
        }
    }

    Update-Display $script:LastSnapshot
    if (
        $taskChanged -and
        $null -ne $script:HistoryForm -and
        -not $script:HistoryForm.IsDisposed -and
        $script:HistoryForm.Visible
    ) {
        Update-HistoryWindow
    }
})
$timer.Start()

$shutdownTimer = $null
if ($RunSeconds -gt 0) {
    $shutdownTimer = New-Object System.Windows.Forms.Timer
    $shutdownTimer.Interval = $RunSeconds * 1000
    $shutdownTimer.Add_Tick({
        $shutdownTimer.Stop()
        $script:Exiting = $true
        $form.Close()
    })
    $shutdownTimer.Start()
}

try {
    [System.Windows.Forms.Application]::Run($form)
}
finally {
    Stop-HistoryInfrastructure
    $timer.Stop()
    if ($null -ne $shutdownTimer) { $shutdownTimer.Stop(); $shutdownTimer.Dispose() }
    if ($null -ne $watcher) { $watcher.Dispose() }
    if ($null -ne $selectionWatcherProcess -and -not $selectionWatcherProcess.HasExited) {
        Stop-Process -Id $selectionWatcherProcess.Id -Force -ErrorAction SilentlyContinue
    }
    if ($null -ne $usageWatcherProcess -and -not $usageWatcherProcess.HasExited) {
        Stop-Process -Id $usageWatcherProcess.Id -Force -ErrorAction SilentlyContinue
    }
    Get-EventSubscriber | Where-Object { $_.SourceObject -eq $watcher } | Unregister-Event -Force -ErrorAction SilentlyContinue
    $trayIcon.Visible = $false
    $trayIcon.Dispose()
    $showEvent.Dispose()
    if ($createdNew) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
    Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $selectedTaskPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $usageTargetPath, $usageSnapshotPath -Force -ErrorAction SilentlyContinue
}
