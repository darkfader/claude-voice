# Two ways to find a session's window, in preference order:
#
# 1. Get-OwningWindowPid -- the session's OWN window, resolved by walking up
#    the process tree from the hook that the session itself ran. Exact, works
#    for several sessions in one folder, and works across separate VS Code
#    instances. This is the one that should normally be used.
#
# 2. Find-SessionWindow -- matches the project name against window TITLES.
#    Kept only as a fallback for sessions registered before a window pid was
#    recorded, or whose recorded window has since closed. It is unreliable:
#    VS Code titles the window after the workspace, which frequently is not
#    the folder name the project is derived from (observed live: project
#    "HomeAssistant", window title "PC - Visual Studio Code" -- the pattern
#    never matched, so focus silently picked the wrong window or none). It
#    also cannot tell two sessions in the same folder apart.
function Get-ProjectWindowPattern {
    param([Parameter(Mandatory)][string]$Project)
    # Escape wildcard metacharacters: -like treats * ? [ ] as pattern syntax,
    # and Windows folder names may legally contain [ or ]. Without this, a
    # project like "my[test]proj" silently never matches its own window.
    # WildcardPattern::Escape (not regex::Escape) is the right API for -like.
    $safe = [System.Management.Automation.WildcardPattern]::Escape($Project)
    "*$safe*Visual Studio Code*"
}

function Find-SessionWindow {
    param(
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)]$Processes
    )
    $pattern = Get-ProjectWindowPattern -Project $Project
    $Processes |
        Where-Object { $_.MainWindowHandle -ne [IntPtr]0 -and $_.MainWindowTitle -like $pattern } |
        Select-Object -First 1
}

function Select-OwningWindowPid {
    <#
    .SYNOPSIS
    Pick the session's window from an ordered ancestry chain.

    .DESCRIPTION
    Pure, so the selection rule is testable without spawning processes. $Chain
    is ordered nearest-ancestor-first, each entry @{ ProcessId; Name; HasWindow }.

    The rule is "first ancestor that owns a window". Walking outward from the
    hook, that is the terminal or editor the session is running inside --
    VS Code, Windows Terminal, whatever. Anything further out (explorer.exe,
    the shell) also owns a window, which is why the FIRST match matters and a
    last-match or "prefer Code.exe" rule would be wrong: a session running in
    Windows Terminal has no Code.exe ancestor at all, and explorer.exe is an
    ancestor of practically everything.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Chain)
    foreach ($link in $Chain) {
        if ($link.HasWindow) { return $link.ProcessId }
    }
    $null
}

function Get-ProcessAncestry {
    <#
    .SYNOPSIS
    Ordered ancestry of a process, nearest first, for Select-OwningWindowPid.
    #>
    param(
        [Parameter(Mandatory)][int]$StartPid,
        [int]$MaxDepth = 12
    )
    $chain = @()
    $current = $StartPid
    for ($i = 0; $i -lt $MaxDepth; $i++) {
        $wmi = Get-CimInstance Win32_Process -Filter "ProcessId=$current" -ErrorAction SilentlyContinue
        if (-not $wmi) { break }
        $proc = Get-Process -Id $current -ErrorAction SilentlyContinue
        $chain += @{
            ProcessId = [int]$wmi.ProcessId
            Name      = [string]$wmi.Name
            HasWindow = ($null -ne $proc -and $proc.MainWindowHandle -ne [IntPtr]::Zero)
        }
        if (-not $wmi.ParentProcessId -or $wmi.ParentProcessId -eq 0) { break }
        $current = [int]$wmi.ParentProcessId
    }
    , $chain
}

function Get-OwningWindowPid {
    <#
    .SYNOPSIS
    The pid of the window this process is running inside, or $null.
    #>
    param([int]$StartPid = $PID)
    # Skip self: the hook process itself never owns a window, and including it
    # costs nothing, but starting the walk at the parent would break the
    # (testable) invariant that the chain begins where it was asked to.
    Select-OwningWindowPid -Chain (Get-ProcessAncestry -StartPid $StartPid)
}

Export-ModuleMember -Function Get-ProjectWindowPattern, Find-SessionWindow, Select-OwningWindowPid, Get-ProcessAncestry, Get-OwningWindowPid
