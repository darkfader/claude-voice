function Resolve-DictationTarget {
    <#
    .SYNOPSIS
    Decide where dictated text should go: the tracked active Claude Code
    session's window, or (if none is tracked, or it's since expired out of
    `known`) whatever window currently has OS focus.
    #>
    param([Parameter(Mandatory)][hashtable]$State)

    $activeId = $State.activeSession
    if ($activeId -and $State.known.ContainsKey($activeId)) {
        $entry = $State.known[$activeId]
        return @{
            Mode      = 'session'
            SessionId = $activeId
            Project   = $entry.project
            WindowPid = if ($entry.ContainsKey('windowPid')) { [int]$entry.windowPid } else { 0 }
        }
    }
    return @{ Mode = 'focused' }
}

Export-ModuleMember -Function Resolve-DictationTarget
