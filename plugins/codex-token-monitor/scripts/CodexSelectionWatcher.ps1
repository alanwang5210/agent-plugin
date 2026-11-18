[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [int]$ParentProcessId,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath,

    [ValidateRange(500, 10000)]
    [int]$PollIntervalMs = 1500
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

function Get-SelectedCodexTaskName {
    try {
        $process = Get-Process -Name 'ChatGPT' -ErrorAction SilentlyContinue |
            Where-Object { $_.MainWindowHandle -ne 0 } |
            Select-Object -First 1
        if ($null -eq $process) { return '' }

        $root = [System.Windows.Automation.AutomationElement]::FromHandle($process.MainWindowHandle)
        $condition = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::Button
        )
        $buttons = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition)
        for ($index = 0; $index -lt $buttons.Count; $index++) {
            $button = $buttons.Item($index)
            $className = $button.Current.ClassName
            $isSelectedThread =
                $className -match '(?:^|\s)bg-token-list-hover-background(?:\s|$)' -or
                $className -match '(?:^|\s)bg-primary-ghost-hover(?:\s|$)'
            if (
                $className -match '(?:^|\s)sidebar-item(?:\s|$)' -and
                $isSelectedThread -and
                -not [string]::IsNullOrWhiteSpace($button.Current.Name)
            ) {
                return $button.Current.Name
            }
        }
    }
    catch {
        return ''
    }
    return ''
}

$lastName = ''
while ($null -ne (Get-Process -Id $ParentProcessId -ErrorAction SilentlyContinue)) {
    $selectedName = Get-SelectedCodexTaskName
    if (-not [string]::IsNullOrWhiteSpace($selectedName) -and $selectedName -ne $lastName) {
        [System.IO.File]::WriteAllText($OutputPath, $selectedName, [System.Text.Encoding]::UTF8)
        $lastName = $selectedName
    }
    Start-Sleep -Milliseconds $PollIntervalMs
}
