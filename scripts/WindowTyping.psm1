Add-Type @"
using System;
using System.Runtime.InteropServices;
public class ClaudeVoiceWin32Typing {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
"@

function Set-WindowForeground {
    param([Parameter(Mandatory)][IntPtr]$WindowHandle)
    [ClaudeVoiceWin32Typing]::ShowWindow($WindowHandle, 9) | Out-Null   # SW_RESTORE
    [ClaudeVoiceWin32Typing]::SetForegroundWindow($WindowHandle) | Out-Null
    Start-Sleep -Milliseconds 300
}

function ConvertTo-SendKeysLiteral {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    [regex]::Replace($Text, '[+^%~(){}\[\]]', '{$0}')
}

function Send-TextToForeground {
    param(
        [Parameter(Mandatory)][string]$Text,
        [switch]$SubmitEnter
    )
    Add-Type -AssemblyName System.Windows.Forms
    $escaped = ConvertTo-SendKeysLiteral -Text $Text
    [System.Windows.Forms.SendKeys]::SendWait($escaped)
    if ($SubmitEnter) {
        Start-Sleep -Milliseconds 100
        [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
    }
}

Export-ModuleMember -Function Set-WindowForeground, Send-TextToForeground, ConvertTo-SendKeysLiteral
