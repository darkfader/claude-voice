param(
    [Parameter(Mandatory)][string]$SessionId,
    [Parameter(Mandatory)][string]$Project,
    [string]$Text = 'continue',

    # Focus the session's window and clear its pending state, but type
    # nothing. This is what the device's long-press uses: the Notification
    # hook fires mainly when Claude is asking PERMISSION for something, so
    # auto-sending "continue" from across the room approves whatever was
    # asked without the human having read it.
    [switch]$FocusOnly,

    # Focus the window but leave the session's pending state alone. The dial
    # and double-press both use this: both are navigation, and browsing to a
    # session must not dismiss the light telling you it still wants something.
    # Long-press remains the only gesture that clears.
    [switch]$KeepPending,

    # Pid of the window this session runs inside, recorded by the session's
    # own hook. Preferred over title matching, which cannot distinguish two
    # sessions in one folder and, in practice, often matches nothing at all
    # because VS Code titles windows after the workspace rather than the
    # project folder. Falls back to the title search when 0 or when the
    # recorded process has since exited.
    [int]$WindowPid = 0
)

Import-Module (Join-Path $PSScriptRoot 'WindowFocus.psm1')  -Force
Import-Module (Join-Path $PSScriptRoot 'PendingState.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'WindowTyping.psm1') -Force

$target = $null
if ($WindowPid -gt 0) {
    $candidate = Get-Process -Id $WindowPid -ErrorAction SilentlyContinue
    if ($candidate -and $candidate.MainWindowHandle -ne [IntPtr]::Zero) { $target = $candidate }
}
if (-not $target) {
    # Fallback only -- see WindowFocus.psm1 for why this is unreliable.
    $target = Find-SessionWindow -Project $Project -Processes (Get-Process)
}
if (-not $target) {
    Write-Warning "No window found for session '$SessionId' (windowPid=$WindowPid, title pattern: $(Get-ProjectWindowPattern -Project $Project))"
    exit 1
}

Set-WindowForeground -WindowHandle $target.MainWindowHandle

if (-not $FocusOnly) {
    Send-TextToForeground -Text $Text -SubmitEnter
}

if (-not $KeepPending) { Clear-PendingSession -SessionId $SessionId }
exit 0
