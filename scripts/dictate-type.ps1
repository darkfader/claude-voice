# claude-voice/scripts/dictate-type.ps1
param(
    [Parameter(Mandatory)][string]$Text
)

Import-Module (Join-Path $PSScriptRoot 'PendingState.psm1')     -Force
Import-Module (Join-Path $PSScriptRoot 'WindowFocus.psm1')      -Force
Import-Module (Join-Path $PSScriptRoot 'WindowTyping.psm1')     -Force
Import-Module (Join-Path $PSScriptRoot 'DictationTarget.psm1')  -Force

$state  = Get-PendingState
$target = Resolve-DictationTarget -State $state

if ($target.Mode -eq 'session') {
    $window = $null
    if ($target.WindowPid -gt 0) {
        $candidate = Get-Process -Id $target.WindowPid -ErrorAction SilentlyContinue
        if ($candidate -and $candidate.MainWindowHandle -ne [IntPtr]::Zero) { $window = $candidate }
    }
    if (-not $window) {
        $window = Find-SessionWindow -Project $target.Project -Processes (Get-Process)
    }
    if ($window) {
        Set-WindowForeground -WindowHandle $window.MainWindowHandle
    } else {
        Write-Warning "Active session '$($target.SessionId)' has no resolvable window; typing into whatever currently has focus."
    }
} else {
    Write-Verbose 'No active session tracked; typing into whatever currently has focus.'
}

Send-TextToForeground -Text $Text
exit 0
