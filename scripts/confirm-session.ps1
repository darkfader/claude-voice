param(
    [Parameter(Mandatory)][ValidateSet('personal','work')][string]$Account,
    [string]$Text = 'continue',

    # Focus the session's window and clear its pending state, but type
    # nothing. This is what the device's long-press uses: the Notification
    # hook fires mainly when Claude is asking PERMISSION for something, so
    # auto-sending "continue" from across the room approves whatever was
    # asked without the human having read it. Focus-only takes you to the
    # session and stops the light; you decide there.
    [switch]$FocusOnly
)

Import-Module (Join-Path $PSScriptRoot 'WindowFocus.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'PendingState.psm1') -Force

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class ClaudeVoiceWin32 {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
"@

$target = Find-AccountWindow -Account $Account -Processes (Get-Process)
if (-not $target) {
    Write-Warning "No window found for account '$Account' (pattern: $(Get-AccountWindowPattern -Account $Account))"
    exit 1
}

[ClaudeVoiceWin32]::ShowWindow($target.MainWindowHandle, 9) | Out-Null   # SW_RESTORE
[ClaudeVoiceWin32]::SetForegroundWindow($target.MainWindowHandle) | Out-Null
Start-Sleep -Milliseconds 300

if (-not $FocusOnly) {
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.SendKeys]::SendWait($Text)
    Start-Sleep -Milliseconds 100
    [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
}

Clear-PendingAccount -Account $Account
exit 0
