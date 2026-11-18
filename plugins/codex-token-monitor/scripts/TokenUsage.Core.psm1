Set-StrictMode -Version Latest

$script:TurnNumberCache = @{}
$script:TurnHistoryCache = @{}
$script:HistoryJsonSerializer = $null

function Get-CodexDataRoot {
    [CmdletBinding()]
    param()

    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        return [System.IO.Path]::GetFullPath($env:CODEX_HOME)
    }

    return Join-Path $env:USERPROFILE '.codex'
}

function Get-LongValue {
    param(
        [Parameter(Mandatory = $false)]
        $Value
    )

    if ($null -eq $Value) {
        return [long]0
    }

    return [long]$Value
}

function Get-ObjectPropertyValue {
    param(
        [Parameter(Mandatory = $false)]
        $Object,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }

    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.GetType().Name -eq 'Dictionary`2') {
            if ($Object.ContainsKey($Name)) { return $Object[$Name] }
            return $null
        }
        try { return ([System.Collections.IDictionary]$Object)[$Name] }
        catch { return $null }
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Get-LongProperty {
    param(
        [Parameter(Mandatory = $false)]
        $Object,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    return Get-LongValue (Get-ObjectPropertyValue -Object $Object -Name $Name)
}

function Get-CodexTailLines {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][int]$LineCount,
        [Parameter(Mandatory = $true)][int]$MaxBytes
    )

    $stream = $null
    try {
        $stream = New-Object System.IO.FileStream(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite
        )
        if ($stream.Length -eq 0) { return @() }

        $chunks = New-Object 'System.Collections.Generic.List[byte[]]'
        $position = $stream.Length
        $bytesRead = 0
        $newlineCount = 0
        $lastByte = -1
        $startsAtLineBoundary = $false
        $chunkSize = 65536

        while ($position -gt 0 -and $bytesRead -lt $MaxBytes) {
            $bytesToRead = [int][Math]::Min([long]$chunkSize, [Math]::Min([long]$position, [long]($MaxBytes - $bytesRead)))
            $chunkStart = $position - $bytesToRead
            [void]$stream.Seek($chunkStart, [System.IO.SeekOrigin]::Begin)
            $chunkBuffer = [System.Array]::CreateInstance([byte], $bytesToRead)
            $chunkLength = 0
            while ($chunkLength -lt $chunkBuffer.Length) {
                $read = $stream.Read($chunkBuffer, $chunkLength, $chunkBuffer.Length - $chunkLength)
                if ($read -le 0) { break }
                $chunkLength += $read
            }
            if ($chunkLength -eq 0) { break }

            if ($chunkLength -lt $chunkBuffer.Length) {
                $trimmedBuffer = [System.Array]::CreateInstance([byte], $chunkLength)
                [System.Array]::Copy($chunkBuffer, $trimmedBuffer, $chunkLength)
                $chunkBuffer = $trimmedBuffer
            }
            $chunks.Add($chunkBuffer)
            $position = $chunkStart
            $bytesRead += $chunkLength

            if ($lastByte -lt 0) { $lastByte = [int]$chunkBuffer[$chunkLength - 1] }
            foreach ($byte in $chunkBuffer) {
                if ($byte -eq 10) { $newlineCount++ }
            }

            $startsAtLineBoundary = $position -eq 0
            if ($position -gt 0) {
                [void]$stream.Seek($position - 1, [System.IO.SeekOrigin]::Begin)
                $startsAtLineBoundary = $stream.ReadByte() -eq 10
            }

            $completeLineCount = $newlineCount + [int]($lastByte -ne 10)
            if (-not $startsAtLineBoundary) { $completeLineCount-- }
            if ($completeLineCount -ge $LineCount) { break }

            if ($chunkLength -lt $bytesToRead) { break }
        }

        if ($bytesRead -eq 0) { return @() }
        $buffer = [System.Array]::CreateInstance([byte], $bytesRead)
        $bufferOffset = 0
        for ($index = $chunks.Count - 1; $index -ge 0; $index--) {
            $chunk = $chunks[$index]
            [System.Array]::Copy($chunk, 0, $buffer, $bufferOffset, $chunk.Length)
            $bufferOffset += $chunk.Length
        }

        $text = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $bytesRead)
        if ($position -eq 0 -and $text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) {
            $text = $text.Substring(1)
        }
        $lines = @($text -split '\r?\n')
        $firstIndex = if ($position -eq 0 -or $startsAtLineBoundary) { 0 } else { 1 }
        $lastIndex = $lines.Count - 1
        if ($lastIndex -ge $firstIndex -and $lines[$lastIndex].Length -eq 0) {
            $lastIndex--
        }
        if ($lastIndex -lt $firstIndex) { return @() }

        $firstIndex = [Math]::Max($firstIndex, $lastIndex - $LineCount + 1)
        return @($lines[$firstIndex..$lastIndex])
    }
    catch {
        return @()
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function ConvertFrom-CodexEventLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Line
    )

    if ([string]::IsNullOrWhiteSpace($Line)) {
        return $null
    }

    try {
        $event = ConvertFrom-Json -InputObject $Line -ErrorAction Stop
    }
    catch {
        return $null
    }

    $eventType = [string](Get-ObjectPropertyValue -Object $event -Name 'type')
    $payload = Get-ObjectPropertyValue -Object $event -Name 'payload'
    $payloadType = [string](Get-ObjectPropertyValue -Object $payload -Name 'type')

    return [pscustomobject]@{
        Event       = $event
        EventType   = $eventType
        Payload     = $payload
        PayloadType = $payloadType
    }
}

function ConvertFrom-CodexHistoryEventLine {
    param([Parameter(Mandatory = $true)][string]$Line)

    if ([string]::IsNullOrWhiteSpace($Line)) { return $null }
    try {
        if ($null -eq $script:HistoryJsonSerializer) {
            Add-Type -AssemblyName System.Web.Extensions -ErrorAction Stop
            $script:HistoryJsonSerializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
            $script:HistoryJsonSerializer.MaxJsonLength = [int]::MaxValue
        }
        $event = $script:HistoryJsonSerializer.DeserializeObject($Line)
    }
    catch { return $null }

    $payload = Get-ObjectPropertyValue -Object $event -Name 'payload'
    return [pscustomobject]@{
        Event       = $event
        EventType   = [string](Get-ObjectPropertyValue -Object $event -Name 'type')
        Payload     = $payload
        PayloadType = [string](Get-ObjectPropertyValue -Object $payload -Name 'type')
    }
}

function ConvertFrom-CodexTokenEventLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Line
    )

    if ($Line -notmatch '"type"\s*:\s*"token_count"') {
        return $null
    }

    $record = ConvertFrom-CodexEventLine -Line $Line
    if ($null -eq $record -or $record.EventType -ne 'event_msg' -or $record.PayloadType -ne 'token_count') {
        return $null
    }

    return ConvertFrom-CodexTokenEventRecord -Record $record
}

function ConvertFrom-CodexHistoryTokenEventLine {
    param([Parameter(Mandatory = $true)][string]$Line)

    if ($Line -notmatch '"type"\s*:\s*"token_count"') { return $null }
    $record = ConvertFrom-CodexHistoryEventLine -Line $Line
    if ($null -eq $record -or $record.EventType -ne 'event_msg' -or $record.PayloadType -ne 'token_count') { return $null }
    return ConvertFrom-CodexTokenEventRecord -Record $record
}

function ConvertFrom-CodexTokenEventRecord {
    param([Parameter(Mandatory = $true)]$Record)

    $info = Get-ObjectPropertyValue -Object $Record.Payload -Name 'info'
    $total = Get-ObjectPropertyValue -Object $info -Name 'total_token_usage'
    $last = Get-ObjectPropertyValue -Object $info -Name 'last_token_usage'
    if ($null -eq $info -or $null -eq $total -or $null -eq $last) {
        return $null
    }

    $contextWindow = Get-LongProperty -Object $info -Name 'model_context_window'
    $lastInput = Get-LongProperty -Object $last -Name 'input_tokens'
    $contextPercent = if ($contextWindow -gt 0) {
        [Math]::Round([Math]::Min(100.0, ($lastInput * 100.0) / $contextWindow), 1)
    }
    else {
        0.0
    }

    [pscustomobject]@{
        EventTimestamp              = [string](Get-ObjectPropertyValue -Object $record.Event -Name 'timestamp')
        TotalInputTokens            = Get-LongProperty -Object $total -Name 'input_tokens'
        TotalCachedInputTokens      = Get-LongProperty -Object $total -Name 'cached_input_tokens'
        TotalCacheWriteInputTokens  = Get-LongProperty -Object $total -Name 'cache_write_input_tokens'
        TotalOutputTokens           = Get-LongProperty -Object $total -Name 'output_tokens'
        TotalReasoningTokens        = Get-LongProperty -Object $total -Name 'reasoning_output_tokens'
        TotalTokens                 = Get-LongProperty -Object $total -Name 'total_tokens'
        LastInputTokens             = $lastInput
        LastCachedInputTokens       = Get-LongProperty -Object $last -Name 'cached_input_tokens'
        LastCacheWriteInputTokens   = Get-LongProperty -Object $last -Name 'cache_write_input_tokens'
        LastOutputTokens            = Get-LongProperty -Object $last -Name 'output_tokens'
        LastReasoningTokens         = Get-LongProperty -Object $last -Name 'reasoning_output_tokens'
        LastTotalTokens             = Get-LongProperty -Object $last -Name 'total_tokens'
        ModelContextWindow          = $contextWindow
        ContextPercent              = $contextPercent
    }
}

function Get-UsageDifference {
    param(
        [Parameter(Mandatory = $true)]$Current,
        $Baseline
    )

    $baselineValue = if ($null -eq $Baseline) { [long]0 } else { [long]$Baseline }
    return [Math]::Max([long]0, ([long]$Current - $baselineValue))
}

function ConvertTo-CodexDisplayText {
    param(
        [string]$Text,
        [ValidateRange(10, 500)]
        [int]$MaxLength = 120
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ''
    }

    $normalized = [regex]::Replace($Text, '\s+', ' ').Trim()
    if ($normalized.Length -le $MaxLength) {
        return $normalized
    }
    return $normalized.Substring(0, $MaxLength - 3).TrimEnd() + '...'
}

function ConvertTo-CodexUtcDateTime {
    param($Value)

    if ($null -eq $Value) {
        return [DateTime]::MinValue
    }
    if ($Value -is [DateTimeOffset]) {
        return $Value.UtcDateTime
    }
    if ($Value -is [DateTime]) {
        if ($Value.Kind -eq [DateTimeKind]::Utc) { return $Value }
        if ($Value.Kind -eq [DateTimeKind]::Local) { return $Value.ToUniversalTime() }
        return [DateTime]::SpecifyKind($Value, [DateTimeKind]::Utc)
    }

    $parsed = [DateTime]::MinValue
    $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
    if ([DateTime]::TryParse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) {
        return $parsed
    }
    return [DateTime]::MinValue
}

function ConvertTo-CodexUserMessageText {
    param($UserMessage)

    $parts = New-Object 'System.Collections.Generic.List[string]'
    $content = Get-ObjectPropertyValue -Object $UserMessage -Name 'content'
    foreach ($item in @($content)) {
        $type = [string](Get-ObjectPropertyValue -Object $item -Name 'type')
        if ($type -in @('text', 'input_text')) {
            $text = [string](Get-ObjectPropertyValue -Object $item -Name 'text')
            if (-not [string]::IsNullOrWhiteSpace($text)) { $parts.Add($text) }
        }
        elseif ($type -in @('image', 'input_image')) {
            $parts.Add('[Image attachment]')
        }
    }
    return ConvertTo-CodexDisplayText ([string]::Join(' | ', $parts.ToArray())) 500
}

function Get-CodexHistoryTurn {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$TurnId,
        [switch]$CreateIfMissing
    )

    if ([string]::IsNullOrWhiteSpace($TurnId)) { return $null }
    if (-not $State.ModernTurnMap.ContainsKey($TurnId)) {
        if ($State.ExpiredModernTurnIds.ContainsKey($TurnId)) { return $null }
        if (-not $CreateIfMissing) { return $null }
        $State.ModernTurnNumber++
        $turn = [pscustomobject]@{
            TurnId                = $TurnId
            TurnNumber            = $State.ModernTurnNumber
            Prompt                = ''
            PromptParts           = New-Object 'System.Collections.Generic.List[string]'
            MessageIds            = @{}
            Status                = 'Running'
            BaselineUsage         = $null
            LatestUsage           = $null
            CallCount             = 0
            ResponseIds           = @{}
            StartedAtUtc          = [DateTime]::MinValue
            CompletedAtUtc        = [DateTime]::MinValue
            ElapsedSecondsOverride = $null
        }
        $State.ModernTurnMap[$TurnId] = $turn
        [void]$State.ModernTurns.Add($turn)
        $State.HasModernTurns = $true
        while ($State.ModernTurns.Count -gt $State.MaxTurns) {
            $expired = $State.ModernTurns[0]
            $State.ExpiredModernTurnIds[$expired.TurnId] = $true
            $State.ExpiredModernTurnOrder.Add($expired.TurnId)
            while ($State.ExpiredModernTurnOrder.Count -gt $State.MaxTurns) {
                $oldestExpiredTurnId = $State.ExpiredModernTurnOrder[0]
                $State.ExpiredModernTurnOrder.RemoveAt(0)
                [void]$State.ExpiredModernTurnIds.Remove($oldestExpiredTurnId)
            }
            [void]$State.ModernTurnMap.Remove($expired.TurnId)
            $State.ModernTurns.RemoveAt(0)
        }
    }
    if (-not $State.ModernTurnMap.ContainsKey($TurnId)) { return $null }
    return $State.ModernTurnMap[$TurnId]
}

function ConvertFrom-CodexTurnUsageRecord {
    param($Record)

    $usage = Get-ObjectPropertyValue -Object $Record.Payload -Name 'turn_token_usage'
    if ($null -eq $usage) { return $null }

    return [pscustomobject]@{
        TotalInputTokens       = Get-LongProperty -Object $usage -Name 'input_tokens'
        TotalCachedInputTokens = Get-LongProperty -Object $usage -Name 'cached_input_tokens'
        TotalCacheWriteInputTokens = Get-LongProperty -Object $usage -Name 'cache_write_input_tokens'
        TotalOutputTokens      = Get-LongProperty -Object $usage -Name 'output_tokens'
        TotalReasoningTokens   = Get-LongProperty -Object $usage -Name 'reasoning_output_tokens'
        TotalTokens            = Get-LongProperty -Object $usage -Name 'total_tokens'
        EventTimestampUtc      = ConvertTo-CodexUtcDateTime (Get-ObjectPropertyValue -Object $Record.Event -Name 'timestamp')
    }
}

function New-CodexTurnHistoryState {
    param([Parameter(Mandatory = $true)][int]$MaxTurns)

    return [pscustomobject]@{
        MaxTurns             = $MaxTurns
        CompleteOffset       = [long]0
        FileLength           = [long]0
        LastWriteTimeUtc     = [DateTime]::MinValue
        CreationTimeUtc      = [DateTime]::MinValue
        PrefixHash           = ''
        CheckpointHash       = ''
        LinesProcessed       = [long]0
        LegacyTurns          = New-Object 'System.Collections.Generic.List[object]'
        CurrentLegacy        = $null
        PreviousUsage        = $null
        LegacyTurnNumber     = 0
        ModernTurnMap        = @{}
        ModernTurns          = New-Object 'System.Collections.Generic.List[object]'
        ExpiredModernTurnIds = @{}
        ExpiredModernTurnOrder = New-Object 'System.Collections.Generic.List[string]'
        ModernTurnNumber     = 0
        HasModernTurns       = $false
    }
}

function Add-CodexHistoryLines {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string[]]$Lines
    )

    foreach ($Line in $Lines) {
        $State.LinesProcessed++

        if ($Line -match '"type"\s*:\s*"token_usage_record"') {
            $record = ConvertFrom-CodexHistoryEventLine -Line $Line
            if ($null -eq $record -or $record.EventType -ne 'token_usage_record') { continue }

            $turnId = [string](Get-ObjectPropertyValue -Object $record.Payload -Name 'turn_id')
            $turn = Get-CodexHistoryTurn -State $State -TurnId $turnId
            $usage = ConvertFrom-CodexTurnUsageRecord -Record $record
            if ($null -ne $turn -and $null -ne $usage) {
                $responseId = [string](Get-ObjectPropertyValue -Object $record.Payload -Name 'response_id')
                if ([string]::IsNullOrWhiteSpace($responseId)) {
                    if ($null -eq $turn.LatestUsage -or $usage.TotalTokens -gt $turn.LatestUsage.TotalTokens) {
                        $turn.CallCount++
                    }
                }
                elseif (-not $turn.ResponseIds.ContainsKey($responseId)) {
                    $turn.ResponseIds[$responseId] = $true
                    $turn.CallCount++
                }
                $turn.LatestUsage = $usage
            }
            continue
        }

        if ($Line -notmatch '"type"\s*:\s*"event_msg"') { continue }
        $eventRecord = ConvertFrom-CodexHistoryEventLine -Line $Line
        if ($null -eq $eventRecord -or $eventRecord.EventType -ne 'event_msg') { continue }
        $eventPayload = $eventRecord.Payload

        if ($eventRecord.PayloadType -eq 'task_started') {
            $turnId = [string](Get-ObjectPropertyValue -Object $eventPayload -Name 'turn_id')
            $turn = Get-CodexHistoryTurn -State $State -TurnId $turnId -CreateIfMissing
            if ($null -ne $turn) {
                $turn.StartedAtUtc = ConvertTo-CodexUtcDateTime (Get-ObjectPropertyValue -Object $eventPayload -Name 'started_at')
                if ($turn.StartedAtUtc -eq [DateTime]::MinValue) {
                    $turn.StartedAtUtc = ConvertTo-CodexUtcDateTime (Get-ObjectPropertyValue -Object $eventRecord.Event -Name 'timestamp')
                }
            }
            continue
        }

        if ($eventRecord.PayloadType -eq 'item_completed') {
            $item = Get-ObjectPropertyValue -Object $eventPayload -Name 'item'
            if ([string](Get-ObjectPropertyValue -Object $item -Name 'type') -eq 'UserMessage') {
                $turnId = [string](Get-ObjectPropertyValue -Object $eventPayload -Name 'turn_id')
                $turn = Get-CodexHistoryTurn -State $State -TurnId $turnId
                if ($null -ne $turn) {
                    $messageId = [string](Get-ObjectPropertyValue -Object $item -Name 'id')
                    if ([string]::IsNullOrWhiteSpace($messageId) -or -not $turn.MessageIds.ContainsKey($messageId)) {
                        if (-not [string]::IsNullOrWhiteSpace($messageId)) { $turn.MessageIds[$messageId] = $true }
                        $prompt = ConvertTo-CodexUserMessageText -UserMessage $item
                        if (-not [string]::IsNullOrWhiteSpace($prompt)) { $turn.PromptParts.Add($prompt) }
                    }
                }
            }
            continue
        }

        if ($eventRecord.PayloadType -eq 'task_complete' -or $eventRecord.PayloadType -eq 'turn_aborted') {
            $turnId = [string](Get-ObjectPropertyValue -Object $eventPayload -Name 'turn_id')
            $turn = Get-CodexHistoryTurn -State $State -TurnId $turnId
            if ($null -ne $turn) {
                $eventError = Get-ObjectPropertyValue -Object $eventPayload -Name 'error'
                $turn.Status = if ($eventRecord.PayloadType -eq 'turn_aborted' -or -not [string]::IsNullOrWhiteSpace([string]$eventError)) { 'Aborted' } else { 'Complete' }
                $turn.CompletedAtUtc = ConvertTo-CodexUtcDateTime (Get-ObjectPropertyValue -Object $eventPayload -Name 'completed_at')
                if ($turn.CompletedAtUtc -eq [DateTime]::MinValue) {
                    $turn.CompletedAtUtc = ConvertTo-CodexUtcDateTime (Get-ObjectPropertyValue -Object $eventRecord.Event -Name 'timestamp')
                }
                $durationMs = Get-ObjectPropertyValue -Object $eventPayload -Name 'duration_ms'
                if ($null -ne $durationMs) { $turn.ElapsedSecondsOverride = [Math]::Max(0, [Math]::Round(([double]$durationMs) / 1000.0)) }
            }
        }

        if ($eventRecord.PayloadType -eq 'user_message') {
            if ($null -ne $State.CurrentLegacy) {
                if ($State.CurrentLegacy.Status -eq 'Running') { $State.CurrentLegacy.Status = 'Complete' }
                $State.LegacyTurns.Add((ConvertTo-CodexTurnSummary -Turn $State.CurrentLegacy))
                while ($State.LegacyTurns.Count -gt $State.MaxTurns) { $State.LegacyTurns.RemoveAt(0) }
            }

            $State.LegacyTurnNumber++
            $startedAt = ConvertTo-CodexUtcDateTime (Get-ObjectPropertyValue -Object $eventRecord.Event -Name 'timestamp')
            $State.CurrentLegacy = [pscustomobject]@{
                TurnNumber        = $State.LegacyTurnNumber
                Prompt            = ConvertTo-CodexDisplayText ([string](Get-ObjectPropertyValue -Object $eventPayload -Name 'message')) 200
                Status            = 'Running'
                BaselineUsage     = $State.PreviousUsage
                LatestUsage       = $null
                LastObservedTotal = if ($null -eq $State.PreviousUsage) { [long]0 } else { [long]$State.PreviousUsage.TotalTokens }
                CallCount         = 0
                StartedAtUtc      = $startedAt
                CompletedAtUtc    = [DateTime]::MinValue
            }
            continue
        }

        if ($eventRecord.PayloadType -eq 'token_count') {
            $usage = ConvertFrom-CodexTokenEventRecord -Record $eventRecord
            if ($null -eq $usage) { continue }
            $usage | Add-Member -NotePropertyName EventTimestampUtc -NotePropertyValue (ConvertTo-CodexUtcDateTime $usage.EventTimestamp)
            $State.PreviousUsage = $usage
            if ($null -ne $State.CurrentLegacy) {
                if ($usage.TotalTokens -gt $State.CurrentLegacy.LastObservedTotal) {
                    $State.CurrentLegacy.CallCount++
                    $State.CurrentLegacy.LastObservedTotal = $usage.TotalTokens
                }
                $State.CurrentLegacy.LatestUsage = $usage
            }
            continue
        }

        if ($null -ne $State.CurrentLegacy -and $eventRecord.PayloadType -in @('task_complete', 'turn_aborted')) {
            $State.CurrentLegacy.Status = if ($eventRecord.PayloadType -eq 'task_complete') { 'Complete' } else { 'Aborted' }
            $State.CurrentLegacy.CompletedAtUtc = ConvertTo-CodexUtcDateTime (Get-ObjectPropertyValue -Object $eventRecord.Event -Name 'timestamp')
        }
    }

    $legacyExcess = $State.LegacyTurns.Count - $State.MaxTurns
    if ($legacyExcess -gt 0) { $State.LegacyTurns.RemoveRange(0, $legacyExcess) }
    $modernExcess = $State.ModernTurns.Count - $State.MaxTurns
    if ($modernExcess -gt 0) {
        for ($index = 0; $index -lt $modernExcess; $index++) {
            [void]$State.ModernTurnMap.Remove($State.ModernTurns[$index].TurnId)
        }
        $State.ModernTurns.RemoveRange(0, $modernExcess)
    }
}

function Get-CodexHistoryRangeHash {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][long]$Offset,
        [Parameter(Mandatory = $true)][int]$Length
    )

    if ($Length -le 0) { return '' }
    $stream = $null
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        [void]$stream.Seek($Offset, [System.IO.SeekOrigin]::Begin)
        $bytes = [System.Array]::CreateInstance([byte], $Length)
        $readTotal = 0
        while ($readTotal -lt $Length) {
            $read = $stream.Read($bytes, $readTotal, $Length - $readTotal)
            if ($read -le 0) { break }
            $readTotal += $read
        }
        if ($readTotal -lt $Length) {
            $trimmed = [System.Array]::CreateInstance([byte], $readTotal)
            [System.Array]::Copy($bytes, $trimmed, $readTotal)
            $bytes = $trimmed
        }
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { return [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '') }
        finally { $sha.Dispose() }
    }
    catch { return '' }
    finally { if ($null -ne $stream) { $stream.Dispose() } }
}

function Get-CodexHistoryFileMarkers {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][long]$CompleteOffset)

    $file = Get-Item -LiteralPath $Path -ErrorAction Stop
    $prefixLength = [int][Math]::Min([long]256, [long]$file.Length)
    $checkpointLength = [int][Math]::Min([long]64, [long]$CompleteOffset)
    return [pscustomobject]@{
        FileLength       = [long]$file.Length
        LastWriteTimeUtc = $file.LastWriteTimeUtc
        CreationTimeUtc  = $file.CreationTimeUtc
        PrefixHash       = Get-CodexHistoryRangeHash -Path $Path -Offset 0 -Length $prefixLength
        CheckpointHash   = Get-CodexHistoryRangeHash -Path $Path -Offset ($CompleteOffset - $checkpointLength) -Length $checkpointLength
    }
}

function Get-CodexHistoryLineBatch {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][long]$Offset
    )

    $stream = $null
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $fileLength = [long]$stream.Length
        if ($Offset -gt $fileLength) {
            return [pscustomobject]@{ Lines = [string[]]@(); CompleteByteCount = [long]0; ReadLength = $fileLength }
        }
        $available = $fileLength - $Offset
        if ($available -gt [int]::MaxValue) { throw 'History append exceeds the supported in-memory batch size.' }

        $bytes = [System.Array]::CreateInstance([byte], [int]$available)
        [void]$stream.Seek($Offset, [System.IO.SeekOrigin]::Begin)
        $readTotal = 0
        while ($readTotal -lt $bytes.Length) {
            $read = $stream.Read($bytes, $readTotal, $bytes.Length - $readTotal)
            if ($read -le 0) { break }
            $readTotal += $read
        }
        if ($readTotal -lt $bytes.Length) {
            $trimmed = [System.Array]::CreateInstance([byte], $readTotal)
            if ($readTotal -gt 0) { [System.Array]::Copy($bytes, $trimmed, $readTotal) }
            $bytes = $trimmed
            $fileLength = $Offset + $readTotal
        }

        $lastNewline = [System.Array]::LastIndexOf($bytes, [byte]10)
        if ($lastNewline -lt 0) {
            return [pscustomobject]@{ Lines = [string[]]@(); CompleteByteCount = [long]0; ReadLength = $fileLength }
        }

        $completeText = [System.Text.Encoding]::UTF8.GetString($bytes, 0, $lastNewline + 1)
        if ($Offset -eq 0 -and $completeText.Length -gt 0 -and $completeText[0] -eq [char]0xFEFF) {
            $completeText = $completeText.Substring(1)
        }
        $lines = $completeText.Split([char[]]@([char]10), [System.StringSplitOptions]::None)
        if ($lines.Length -gt 0 -and $lines[$lines.Length - 1].Length -eq 0) {
            if ($lines.Length -eq 1) { $lines = [string[]]@() }
            else { $lines = $lines[0..($lines.Length - 2)] }
        }
        for ($index = 0; $index -lt $lines.Length; $index++) {
            $line = $lines[$index]
            if ($line.EndsWith("`r", [StringComparison]::Ordinal)) { $line = $line.Substring(0, $line.Length - 1) }
            $lines[$index] = $line
        }

        return [pscustomobject]@{
            Lines = $lines
            CompleteByteCount = [long]($lastNewline + 1)
            ReadLength = $fileLength
        }
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Get-CodexHistoryColdModernLines {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string[]]$Lines
    )

    if ($null -eq $script:HistoryJsonSerializer) {
        Add-Type -AssemblyName System.Web.Extensions -ErrorAction Stop
        $script:HistoryJsonSerializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $script:HistoryJsonSerializer.MaxJsonLength = [int]::MaxValue
    }

    $recentStarts = New-Object 'System.Collections.Generic.List[string]'
    $recentStartIds = @{}
    $recentStartLines = @{}
    $startCount = 0
    $trackedStartLimit = [Math]::Max(1, $State.MaxTurns * 2)

    for ($lineIndex = 0; $lineIndex -lt $Lines.Length; $lineIndex++) {
        $line = $Lines[$lineIndex]
        $candidateIndex = $line.IndexOf('"task_started"', [StringComparison]::Ordinal)
        while ($candidateIndex -ge 0 -and $candidateIndex -gt 0 -and $line[$candidateIndex - 1] -eq '\') {
            $candidateIndex = $line.IndexOf('"task_started"', $candidateIndex + 1, [StringComparison]::Ordinal)
        }
        if ($candidateIndex -lt 0) { continue }

        try { $event = $script:HistoryJsonSerializer.DeserializeObject($line) }
        catch { continue }
        if ($event -isnot [System.Collections.IDictionary] -or [string]$event['type'] -ne 'event_msg') { continue }
        $payload = $event['payload']
        if ($payload -isnot [System.Collections.IDictionary] -or [string]$payload['type'] -ne 'task_started') { continue }

        $turnId = [string]$payload['turn_id']
        if ([string]::IsNullOrWhiteSpace($turnId) -or $recentStartIds.ContainsKey($turnId)) { continue }

        $recentStartIds[$turnId] = $true
        $recentStartLines[$turnId] = $lineIndex
        $recentStarts.Add($turnId)
        $startCount++
        if ($recentStarts.Count -gt $trackedStartLimit) {
            $expiredId = $recentStarts[0]
            $recentStarts.RemoveAt(0)
            [void]$recentStartIds.Remove($expiredId)
            [void]$recentStartLines.Remove($expiredId)
        }
    }

    if ($startCount -eq 0) { return $null }

    $expiredStartIndex = [Math]::Max(0, $recentStarts.Count - $trackedStartLimit)
    $expiredEndIndex = [Math]::Max(0, $recentStarts.Count - $State.MaxTurns)
    for ($index = $expiredStartIndex; $index -lt $expiredEndIndex; $index++) {
        $turnId = $recentStarts[$index]
        $State.ExpiredModernTurnIds[$turnId] = $true
        $State.ExpiredModernTurnOrder.Add($turnId)
    }

    $currentTurnStartIndex = [Math]::Max(0, $recentStarts.Count - $State.MaxTurns)
    $currentTurnIds = @{}
    $currentTurnStartLines = @{}
    for ($index = $currentTurnStartIndex; $index -lt $recentStarts.Count; $index++) {
        $turnId = $recentStarts[$index]
        $currentTurnIds[$turnId] = $true
        $currentTurnStartLines[$turnId] = $recentStartLines[$turnId]
    }
    $State.ModernTurnNumber = $startCount - $currentTurnIds.Count

    $selectedLines = New-Object 'System.Collections.Generic.List[string]'
    for ($lineIndex = 0; $lineIndex -lt $Lines.Length; $lineIndex++) {
        $line = $Lines[$lineIndex]
        $searchFrom = 0
        $matchedCurrentTurn = $false
        while ($searchFrom -lt $line.Length) {
            $turnIdIndex = $line.IndexOf('"turn_id"', $searchFrom, [StringComparison]::Ordinal)
            if ($turnIdIndex -lt 0) { break }
            $searchFrom = $turnIdIndex + 9
            if ($turnIdIndex -gt 0 -and $line[$turnIdIndex - 1] -eq '\') { continue }

            $colonIndex = $line.IndexOf(':', $searchFrom)
            if ($colonIndex -lt 0) { break }
            $valueStart = $colonIndex + 1
            while ($valueStart -lt $line.Length -and [char]::IsWhiteSpace($line[$valueStart])) { $valueStart++ }
            if ($valueStart -ge $line.Length -or $line[$valueStart] -ne '"') { continue }
            $valueStart++
            $valueEnd = $line.IndexOf('"', $valueStart)
            if ($valueEnd -lt 0) { break }
            $turnId = $line.Substring($valueStart, $valueEnd - $valueStart)
            if ($currentTurnIds.ContainsKey($turnId) -and $lineIndex -ge $currentTurnStartLines[$turnId]) {
                $matchedCurrentTurn = $true
                break
            }
            $searchFrom = $valueEnd + 1
        }
        if ($matchedCurrentTurn) { $selectedLines.Add($line) }
    }

    return [pscustomobject]@{
        Lines = $selectedLines.ToArray()
        RetainedTurnCount = $currentTurnIds.Count
    }
}

function Get-CodexHistoryResult {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][int]$MaxTurns
    )

    $turns = New-Object 'System.Collections.Generic.List[object]'
    if ($State.HasModernTurns) {
        foreach ($turn in $State.ModernTurns) {
            $turn.Prompt = ConvertTo-CodexDisplayText ([string]::Join(' | ', $turn.PromptParts.ToArray())) 200
            $turns.Add((ConvertTo-CodexTurnSummary -Turn $turn))
        }
    }
    else {
        foreach ($turn in $State.LegacyTurns) { $turns.Add($turn) }
        if ($null -ne $State.CurrentLegacy) {
            $turns.Add((ConvertTo-CodexTurnSummary -Turn $State.CurrentLegacy))
        }
    }

    $firstIndex = [Math]::Max(0, $turns.Count - $MaxTurns)
    $result = New-Object 'System.Collections.Generic.List[object]'
    for ($index = $firstIndex; $index -lt $turns.Count; $index++) {
        $result.Add($turns[$index])
    }
    return $result.ToArray()
}

function New-CodexSharedStreamReader {
    param([Parameter(Mandatory = $true)][string]$Path)

    $stream = [System.IO.File]::Open(
        $Path,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::ReadWrite
    )
    return New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8, $true)
}

function Get-CodexIndexedTaskNames {
    [CmdletBinding()]
    param()

    $names = @{}
    $indexPath = Join-Path (Get-CodexDataRoot) 'session_index.jsonl'
    if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf)) {
        return $names
    }

    $reader = $null
    try {
        $reader = New-CodexSharedStreamReader -Path $indexPath
        while (-not $reader.EndOfStream) {
            $line = $reader.ReadLine()
            try {
                $entry = ConvertFrom-Json -InputObject $line -ErrorAction Stop
                $id = [string](Get-ObjectPropertyValue -Object $entry -Name 'id')
                $name = ConvertTo-CodexDisplayText ([string](Get-ObjectPropertyValue -Object $entry -Name 'thread_name')) 80
                if (-not [string]::IsNullOrWhiteSpace($id) -and -not [string]::IsNullOrWhiteSpace($name)) {
                    $names[$id] = $name
                }
            }
            catch {
                continue
            }
        }
    }
    catch {
        return @{}
    }
    finally {
        if ($null -ne $reader) { $reader.Dispose() }
    }
    return $names
}

function Get-CodexTaskName {
    param(
        [Parameter(Mandatory = $true)][string]$SessionId,
        [Parameter(Mandatory = $true)][string]$SessionPath,
        [switch]$SkipIndex
    )

    $indexPath = Join-Path (Get-CodexDataRoot) 'session_index.jsonl'
    $indexedName = ''
    if (-not $SkipIndex -and (Test-Path -LiteralPath $indexPath -PathType Leaf)) {
        $reader = $null
        try {
            $reader = New-CodexSharedStreamReader -Path $indexPath
            while (-not $reader.EndOfStream) {
                $line = $reader.ReadLine()
                if ($line.IndexOf($SessionId, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
                    continue
                }
                try {
                    $entry = ConvertFrom-Json -InputObject $line -ErrorAction Stop
                    if ([string](Get-ObjectPropertyValue -Object $entry -Name 'id') -eq $SessionId) {
                        $indexedName = ConvertTo-CodexDisplayText ([string](Get-ObjectPropertyValue -Object $entry -Name 'thread_name')) 80
                    }
                }
                catch {
                    continue
                }
            }
        }
        catch {
            $indexedName = ''
        }
        finally {
            if ($null -ne $reader) { $reader.Dispose() }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($indexedName)) {
        return $indexedName
    }

    $reader = $null
    $fallback = ''
    try {
        $reader = New-CodexSharedStreamReader -Path $SessionPath
        while (-not $reader.EndOfStream) {
            $line = $reader.ReadLine()
            if ($line -notmatch '"type"\s*:\s*"user_message"') {
                continue
            }
            $record = ConvertFrom-CodexEventLine -Line $line
            if ($null -ne $record -and $record.EventType -eq 'event_msg' -and $record.PayloadType -eq 'user_message') {
                $fallback = ConvertTo-CodexDisplayText ([string](Get-ObjectPropertyValue -Object $record.Payload -Name 'message')) 80
                if (-not [string]::IsNullOrWhiteSpace($fallback)) {
                    break
                }
            }
        }
    }
    catch {
        $fallback = ''
    }
    finally {
        if ($null -ne $reader) { $reader.Dispose() }
    }
    if (-not [string]::IsNullOrWhiteSpace($fallback)) {
        return $fallback
    }

    return 'Task ' + $SessionId.Substring(0, [Math]::Min(8, $SessionId.Length))
}

function Get-CodexTurnNumber {
    param(
        [Parameter(Mandatory = $true)][string]$SessionPath,
        [Parameter(Mandatory = $true)][string]$TurnTimestamp
    )

    $cacheKey = [System.IO.Path]::GetFullPath($SessionPath)
    $cached = $script:TurnNumberCache[$cacheKey]
    if ($null -ne $cached -and $cached.TurnTimestamp -eq $TurnTimestamp) {
        return [int]$cached.TurnNumber
    }

    $file = Get-Item -LiteralPath $SessionPath -ErrorAction SilentlyContinue
    if ($null -eq $file -or $file.Length -gt 67108864) {
        return 0
    }

    $reader = $null
    try {
        $reader = New-CodexSharedStreamReader -Path $SessionPath
        $count = 0
        while (-not $reader.EndOfStream) {
            $line = $reader.ReadLine()
            if ($line.IndexOf('"type":"user_message"', [StringComparison]::Ordinal) -lt 0) {
                continue
            }
            $record = ConvertFrom-CodexEventLine -Line $line
            if ($null -eq $record -or $record.EventType -ne 'event_msg' -or $record.PayloadType -ne 'user_message') {
                continue
            }
            $count++
            if ([string](Get-ObjectPropertyValue -Object $record.Event -Name 'timestamp') -eq $TurnTimestamp) {
                break
            }
        }
    }
    catch {
        return 0
    }
    finally {
        if ($null -ne $reader) { $reader.Dispose() }
    }
    if ($count -gt 0) {
        $script:TurnNumberCache[$cacheKey] = [pscustomobject]@{
            TurnTimestamp = $TurnTimestamp
            TurnNumber    = $count
        }
    }
    return $count
}

function ConvertTo-CodexTurnSummary {
    param([Parameter(Mandatory = $true)]$Turn)

    $latest = $Turn.LatestUsage
    $baseline = $Turn.BaselineUsage
    $completedAt = if ($Turn.CompletedAtUtc -ne [DateTime]::MinValue) {
        $Turn.CompletedAtUtc
    }
    elseif ($null -ne $latest -and $latest.EventTimestampUtc -ne [DateTime]::MinValue) {
        $latest.EventTimestampUtc
    }
    else {
        $Turn.StartedAtUtc
    }
    $elapsedSeconds = if ($null -ne (Get-ObjectPropertyValue -Object $Turn -Name 'ElapsedSecondsOverride')) {
        [Math]::Max(0, [Math]::Round([double]$Turn.ElapsedSecondsOverride))
    }
    elseif ($Turn.StartedAtUtc -ne [DateTime]::MinValue -and $completedAt -ne [DateTime]::MinValue) {
        [Math]::Max(0, [Math]::Round(($completedAt - $Turn.StartedAtUtc).TotalSeconds))
    }
    else {
        0
    }

    return [pscustomobject]@{
        TurnNumber        = $Turn.TurnNumber
        Prompt            = $Turn.Prompt
        Status            = $Turn.Status
        CallCount         = $Turn.CallCount
        InputTokens       = Get-UsageDifference (Get-LongProperty -Object $latest -Name 'TotalInputTokens') (Get-LongProperty -Object $baseline -Name 'TotalInputTokens')
        CachedInputTokens = Get-UsageDifference (Get-LongProperty -Object $latest -Name 'TotalCachedInputTokens') (Get-LongProperty -Object $baseline -Name 'TotalCachedInputTokens')
        CacheWriteInputTokens = Get-UsageDifference (Get-LongProperty -Object $latest -Name 'TotalCacheWriteInputTokens') (Get-LongProperty -Object $baseline -Name 'TotalCacheWriteInputTokens')
        OutputTokens      = Get-UsageDifference (Get-LongProperty -Object $latest -Name 'TotalOutputTokens') (Get-LongProperty -Object $baseline -Name 'TotalOutputTokens')
        ReasoningTokens   = Get-UsageDifference (Get-LongProperty -Object $latest -Name 'TotalReasoningTokens') (Get-LongProperty -Object $baseline -Name 'TotalReasoningTokens')
        TotalTokens       = Get-UsageDifference (Get-LongProperty -Object $latest -Name 'TotalTokens') (Get-LongProperty -Object $baseline -Name 'TotalTokens')
        StartedAtUtc      = $Turn.StartedAtUtc
        CompletedAtUtc    = $completedAt
        ElapsedSeconds    = [long]$elapsedSeconds
    }
}

function Get-CodexTurnHistory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SessionPath,
        [ValidateRange(1, 10000)][int]$MaxTurns = 100
    )

    if (-not (Test-Path -LiteralPath $SessionPath -PathType Leaf)) {
        $missingPath = [System.IO.Path]::GetFullPath($SessionPath)
        [void]$script:TurnHistoryCache.Remove($missingPath)
        return @()
    }

    $cacheKey = [System.IO.Path]::GetFullPath($SessionPath)
    $cacheEntry = $script:TurnHistoryCache[$cacheKey]
    $markerOffset = if ($null -ne $cacheEntry) { [long]$cacheEntry.State.CompleteOffset } else { [long]0 }
    try {
        $markers = Get-CodexHistoryFileMarkers -Path $cacheKey -CompleteOffset $markerOffset
    }
    catch {
        return @()
    }

    $state = $null
    if (
        $null -ne $cacheEntry -and
        $MaxTurns -le $cacheEntry.State.MaxTurns -and
        $markers.FileLength -ge $cacheEntry.State.FileLength -and
        $markers.FileLength -ge $cacheEntry.State.CompleteOffset -and
        $markers.CreationTimeUtc -eq $cacheEntry.State.CreationTimeUtc -and
        $markers.PrefixHash -eq $cacheEntry.State.PrefixHash -and
        $markers.CheckpointHash -eq $cacheEntry.State.CheckpointHash -and
        $markers.LastWriteTimeUtc -ge $cacheEntry.State.LastWriteTimeUtc
    ) {
        if (
            $markers.FileLength -eq $cacheEntry.State.FileLength -and
            $markers.LastWriteTimeUtc -eq $cacheEntry.State.LastWriteTimeUtc
        ) {
            $cacheEntry.LastAccessUtc = [DateTime]::UtcNow
            return Get-CodexHistoryResult -State $cacheEntry.State -MaxTurns $MaxTurns
        }
        if ($markers.FileLength -gt $cacheEntry.State.FileLength) {
            $state = $cacheEntry.State
        }
    }

    if ($null -eq $state) {
        $state = New-CodexTurnHistoryState -MaxTurns $MaxTurns
        $markerOffset = 0
        try {
            $markers = Get-CodexHistoryFileMarkers -Path $cacheKey -CompleteOffset 0
        }
        catch {
            return @()
        }
    }

    $batch = $null
    try {
        $batch = Get-CodexHistoryLineBatch -Path $cacheKey -Offset $state.CompleteOffset
        if ($batch.Lines.Count -gt 0) {
            if ($state.CompleteOffset -eq 0) {
                $coldSelection = Get-CodexHistoryColdModernLines -State $state -Lines $batch.Lines
                if ($null -ne $coldSelection) {
                    Add-CodexHistoryLines -State $state -Lines $coldSelection.Lines
                }
                else {
                    Add-CodexHistoryLines -State $state -Lines $batch.Lines
                }
            }
            else {
                Add-CodexHistoryLines -State $state -Lines $batch.Lines
            }
        }
    }
    catch {
        [void]$script:TurnHistoryCache.Remove($cacheKey)
        return @()
    }

    $state.CompleteOffset += $batch.CompleteByteCount
    $state.FileLength = $batch.ReadLength
    $state.LastWriteTimeUtc = $markers.LastWriteTimeUtc
    $state.CreationTimeUtc = $markers.CreationTimeUtc
    $state.PrefixHash = $markers.PrefixHash
    $checkpointLength = [int][Math]::Min([long]64, [long]$state.CompleteOffset)
    $state.CheckpointHash = Get-CodexHistoryRangeHash -Path $cacheKey -Offset ($state.CompleteOffset - $checkpointLength) -Length $checkpointLength

    $result = Get-CodexHistoryResult -State $state -MaxTurns $MaxTurns
    $script:TurnHistoryCache[$cacheKey] = [pscustomobject]@{
        State = $state
        LastAccessUtc = [DateTime]::UtcNow
    }

    while ($script:TurnHistoryCache.Count -gt 4) {
        $leastRecentlyUsedKey = $null
        $leastRecentlyUsedAt = [DateTime]::MaxValue
        foreach ($candidateKey in @($script:TurnHistoryCache.Keys)) {
            if ($candidateKey -eq $cacheKey) { continue }
            $candidate = $script:TurnHistoryCache[$candidateKey]
            if ($candidate.LastAccessUtc -lt $leastRecentlyUsedAt) {
                $leastRecentlyUsedAt = $candidate.LastAccessUtc
                $leastRecentlyUsedKey = $candidateKey
            }
        }
        if ($null -eq $leastRecentlyUsedKey) { break }
        [void]$script:TurnHistoryCache.Remove($leastRecentlyUsedKey)
    }

    return $result
}

function Add-ModernCurrentTurnUsage {
    param(
        [Parameter(Mandatory = $true)]$Snapshot,
        [Parameter(Mandatory = $true)][string]$SessionPath
    )

    $turns = @(Get-CodexTurnHistory -SessionPath $SessionPath -MaxTurns 1)
    if ($turns.Count -eq 0) { return $false }

    $turn = $turns[$turns.Count - 1]
    if ([string]::IsNullOrWhiteSpace([string]$turn.Prompt)) { return $false }

    $Snapshot | Add-Member -NotePropertyName TurnInputTokens -NotePropertyValue ([long]$turn.InputTokens)
    $Snapshot | Add-Member -NotePropertyName TurnCachedInputTokens -NotePropertyValue ([long]$turn.CachedInputTokens)
    $Snapshot | Add-Member -NotePropertyName TurnCacheWriteInputTokens -NotePropertyValue ([long]$turn.CacheWriteInputTokens)
    $Snapshot | Add-Member -NotePropertyName TurnOutputTokens -NotePropertyValue ([long]$turn.OutputTokens)
    $Snapshot | Add-Member -NotePropertyName TurnReasoningTokens -NotePropertyValue ([long]$turn.ReasoningTokens)
    $Snapshot | Add-Member -NotePropertyName TurnTotalTokens -NotePropertyValue ([long]$turn.TotalTokens)
    $Snapshot | Add-Member -NotePropertyName TurnCallCount -NotePropertyValue ([int]$turn.CallCount)
    $Snapshot | Add-Member -NotePropertyName TurnStatus -NotePropertyValue ([string]$turn.Status)
    $Snapshot | Add-Member -NotePropertyName TurnNumber -NotePropertyValue ([int]$turn.TurnNumber)
    $Snapshot | Add-Member -NotePropertyName TurnPrompt -NotePropertyValue (ConvertTo-CodexDisplayText ([string]$turn.Prompt) 160)
    $Snapshot | Add-Member -NotePropertyName TurnDataAvailable -NotePropertyValue $true
    return $true
}

function Add-CurrentTurnUsage {
    param(
        [Parameter(Mandatory = $true)]$Snapshot,
        [Parameter(Mandatory = $true)][string[]]$Lines,
        [Parameter(Mandatory = $true)][string]$SessionPath,
        [Parameter(Mandatory = $true)][int]$LatestUsageIndex
    )

    $turnStartIndex = -1
    $turnStartRecord = $null
    for ($index = $LatestUsageIndex; $index -ge 0; $index--) {
        if ($Lines[$index] -notmatch '"type"\s*:\s*"user_message"') {
            continue
        }
        $record = ConvertFrom-CodexEventLine -Line $Lines[$index]
        if ($null -ne $record -and $record.EventType -eq 'event_msg' -and $record.PayloadType -eq 'user_message') {
            $turnStartIndex = $index
            $turnStartRecord = $record
            break
        }
    }

    if ($turnStartIndex -lt 0) {
        $hasModernTurnEvents = $false
        foreach ($line in $Lines) {
            if ($line -match '"type"\s*:\s*"(?:task_started|token_usage_record)"') {
                $hasModernTurnEvents = $true
                break
            }
        }
        if ($hasModernTurnEvents) {
            [void](Add-ModernCurrentTurnUsage -Snapshot $Snapshot -SessionPath $SessionPath)
        }
        return
    }

    $baseline = $null
    for ($index = $turnStartIndex - 1; $index -ge 0; $index--) {
        $candidate = ConvertFrom-CodexTokenEventLine -Line $Lines[$index]
        if ($null -ne $candidate) {
            $baseline = $candidate
            break
        }
    }

    $callCount = 0
    $lastTotal = if ($null -eq $baseline) { [long]0 } else { [long]$baseline.TotalTokens }
    for ($index = $turnStartIndex + 1; $index -le $LatestUsageIndex; $index++) {
        $candidate = ConvertFrom-CodexTokenEventLine -Line $Lines[$index]
        if ($null -ne $candidate -and $candidate.TotalTokens -gt $lastTotal) {
            $callCount++
            $lastTotal = $candidate.TotalTokens
        }
    }

    $isComplete = $false
    for ($index = $LatestUsageIndex + 1; $index -lt $Lines.Count; $index++) {
        if ($Lines[$index] -notmatch '"type"\s*:\s*"(?:task_complete|turn_aborted)"') {
            continue
        }
        $record = ConvertFrom-CodexEventLine -Line $Lines[$index]
        if ($null -ne $record -and $record.EventType -eq 'event_msg' -and $record.PayloadType -in @('task_complete', 'turn_aborted')) {
            $isComplete = $true
            break
        }
    }

    $Snapshot | Add-Member -NotePropertyName TurnInputTokens -NotePropertyValue (Get-UsageDifference $Snapshot.TotalInputTokens (Get-LongProperty -Object $baseline -Name 'TotalInputTokens'))
    $Snapshot | Add-Member -NotePropertyName TurnCachedInputTokens -NotePropertyValue (Get-UsageDifference $Snapshot.TotalCachedInputTokens (Get-LongProperty -Object $baseline -Name 'TotalCachedInputTokens'))
    $Snapshot | Add-Member -NotePropertyName TurnCacheWriteInputTokens -NotePropertyValue (Get-UsageDifference $Snapshot.TotalCacheWriteInputTokens (Get-LongProperty -Object $baseline -Name 'TotalCacheWriteInputTokens'))
    $Snapshot | Add-Member -NotePropertyName TurnOutputTokens -NotePropertyValue (Get-UsageDifference $Snapshot.TotalOutputTokens (Get-LongProperty -Object $baseline -Name 'TotalOutputTokens'))
    $Snapshot | Add-Member -NotePropertyName TurnReasoningTokens -NotePropertyValue (Get-UsageDifference $Snapshot.TotalReasoningTokens (Get-LongProperty -Object $baseline -Name 'TotalReasoningTokens'))
    $Snapshot | Add-Member -NotePropertyName TurnTotalTokens -NotePropertyValue (Get-UsageDifference $Snapshot.TotalTokens (Get-LongProperty -Object $baseline -Name 'TotalTokens'))
    $Snapshot | Add-Member -NotePropertyName TurnCallCount -NotePropertyValue $callCount
    $Snapshot | Add-Member -NotePropertyName TurnStatus -NotePropertyValue $(if ($isComplete) { 'Complete' } else { 'Running' })
    $turnTimestamp = [string](Get-ObjectPropertyValue -Object $turnStartRecord.Event -Name 'timestamp')
    $Snapshot | Add-Member -NotePropertyName TurnNumber -NotePropertyValue (Get-CodexTurnNumber -SessionPath $SessionPath -TurnTimestamp $turnTimestamp)
    $Snapshot | Add-Member -NotePropertyName TurnPrompt -NotePropertyValue (ConvertTo-CodexDisplayText ([string](Get-ObjectPropertyValue -Object $turnStartRecord.Payload -Name 'message')) 160)
    $Snapshot | Add-Member -NotePropertyName TurnDataAvailable -NotePropertyValue $true
}

function Add-UnavailableTurnUsage {
    param([Parameter(Mandatory = $true)]$Snapshot)

    $Snapshot | Add-Member -NotePropertyName TurnInputTokens -NotePropertyValue ([long]0)
    $Snapshot | Add-Member -NotePropertyName TurnCachedInputTokens -NotePropertyValue ([long]0)
    $Snapshot | Add-Member -NotePropertyName TurnCacheWriteInputTokens -NotePropertyValue ([long]0)
    $Snapshot | Add-Member -NotePropertyName TurnOutputTokens -NotePropertyValue ([long]0)
    $Snapshot | Add-Member -NotePropertyName TurnReasoningTokens -NotePropertyValue ([long]0)
    $Snapshot | Add-Member -NotePropertyName TurnTotalTokens -NotePropertyValue ([long]0)
    $Snapshot | Add-Member -NotePropertyName TurnCallCount -NotePropertyValue 0
    $Snapshot | Add-Member -NotePropertyName TurnStatus -NotePropertyValue 'Unavailable'
    $Snapshot | Add-Member -NotePropertyName TurnNumber -NotePropertyValue 0
    $Snapshot | Add-Member -NotePropertyName TurnPrompt -NotePropertyValue ''
    $Snapshot | Add-Member -NotePropertyName TurnDataAvailable -NotePropertyValue $false
}

function Get-CodexUsageSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SessionPath,

        [ValidateRange(20, 5000)]
        [int]$TailLines = 500,

        [ValidateRange(65536, 67108864)]
        [int]$MaxTailBytes = 16777216
    )

    if (-not (Test-Path -LiteralPath $SessionPath -PathType Leaf)) {
        return $null
    }

    try {
        $lines = @(Get-CodexTailLines -Path $SessionPath -LineCount $TailLines -MaxBytes $MaxTailBytes)
    }
    catch {
        return $null
    }

    for ($index = $lines.Count - 1; $index -ge 0; $index--) {
        $usage = ConvertFrom-CodexTokenEventLine -Line $lines[$index]
        if ($null -eq $usage) {
            continue
        }

        $file = Get-Item -LiteralPath $SessionPath -ErrorAction SilentlyContinue
        $sessionId = [System.IO.Path]::GetFileNameWithoutExtension($SessionPath)
        if ($sessionId -match '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})(?:_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})?$') {
            $sessionId = $Matches[1]
        }

        $eventTime = [DateTime]::MinValue
        [void][DateTime]::TryParse(
            $usage.EventTimestamp,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal,
            [ref]$eventTime
        )

        $usage | Add-Member -NotePropertyName SessionId -NotePropertyValue $sessionId
        $usage | Add-Member -NotePropertyName SessionShortId -NotePropertyValue $sessionId.Substring(0, [Math]::Min(8, $sessionId.Length))
        $usage | Add-Member -NotePropertyName SessionPath -NotePropertyValue $SessionPath
        $usage | Add-Member -NotePropertyName TaskName -NotePropertyValue (Get-CodexTaskName -SessionId $sessionId -SessionPath $SessionPath)
        $usage | Add-Member -NotePropertyName EventTimestampUtc -NotePropertyValue $eventTime
        $usage | Add-Member -NotePropertyName FileUpdatedUtc -NotePropertyValue $(if ($null -ne $file) { $file.LastWriteTimeUtc } else { [DateTime]::MinValue })
        Add-CurrentTurnUsage -Snapshot $usage -Lines $lines -SessionPath $SessionPath -LatestUsageIndex $index
        if ($null -eq $usage.PSObject.Properties['TurnNumber'] -and $TailLines -lt 5000) {
            return Get-CodexUsageSnapshot -SessionPath $SessionPath -TailLines 5000 -MaxTailBytes $MaxTailBytes
        }
        if ($null -eq $usage.PSObject.Properties['TurnNumber']) {
            Add-UnavailableTurnUsage -Snapshot $usage
        }
        return $usage
    }

    return $null
}

function Get-CodexSessionFiles {
    [CmdletBinding()]
    param(
        [string]$SessionsRoot = $(Join-Path (Get-CodexDataRoot) 'sessions')
    )

    if (-not (Test-Path -LiteralPath $SessionsRoot -PathType Container)) {
        return @()
    }

    try {
        return @([System.IO.Directory]::EnumerateFiles(
            $SessionsRoot,
            'rollout-*.jsonl',
            [System.IO.SearchOption]::AllDirectories
        ))
    }
    catch {
        return @()
    }
}

function Get-MostRecentCodexSession {
    [CmdletBinding()]
    param(
        [string[]]$SessionPaths = $(Get-CodexSessionFiles)
    )

    $latestPath = $null
    $latestTime = [DateTime]::MinValue

    foreach ($path in $SessionPaths) {
        try {
            $writeTime = [System.IO.File]::GetLastWriteTimeUtc($path)
            if ($writeTime -gt $latestTime) {
                $latestTime = $writeTime
                $latestPath = $path
            }
        }
        catch {
            continue
        }
    }

    return $latestPath
}

function Format-CompactTokenCount {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [long]$Value
    )

    $culture = [Globalization.CultureInfo]::InvariantCulture
    if ([Math]::Abs($Value) -ge 1000000000) {
        return ($Value / 1000000000.0).ToString('0.00B', $culture)
    }
    if ([Math]::Abs($Value) -ge 1000000) {
        return ($Value / 1000000.0).ToString('0.00M', $culture)
    }
    if ([Math]::Abs($Value) -ge 1000) {
        return ($Value / 1000.0).ToString('0.0K', $culture)
    }
    return $Value.ToString('N0', $culture)
}

Export-ModuleMember -Function @(
    'Get-CodexDataRoot',
    'ConvertFrom-CodexEventLine',
    'ConvertFrom-CodexTokenEventLine',
    'Get-CodexIndexedTaskNames',
    'Get-CodexTaskName',
    'Get-CodexTurnHistory',
    'Get-CodexUsageSnapshot',
    'Get-CodexSessionFiles',
    'Get-MostRecentCodexSession',
    'Format-CompactTokenCount'
)
