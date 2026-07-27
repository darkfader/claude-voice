# claude-voice/scripts/RingDisplay.psm1
# Shared "hand the ring to the oldest remaining pending session" logic
# (spec: Notification precedence rule 3 -- Resolved).
#
# Final review Fix 2: this used to live only inside ha-bridge.ps1, used for
# long-press/triple-press (jumped-to/dismissed). notify-ha.ps1's own
# reply/stop path (replied/stopped) never called anything equivalent, so the
# most common resolution path -- typing a reply -- left the ring showing an
# already-resolved session while a genuinely different one was still
# waiting. Both call sites now import this one implementation so the bridge
# and the hook cannot diverge again.
#
# DELIBERATELY does not `Import-Module` PendingState.psm1 / HaClient.psm1
# itself -- the caller (ha-bridge.ps1, notify-ha.ps1, or a test file) must
# import both before calling Set-RemainingLed. This is not laziness: it was
# tried the other way first and reverted after finding, empirically, that
# PowerShell module-in-module `Import-Module -Force` can silently fork a
# SECOND instance of PendingState.psm1 with its OWN independent
# $script:StatePath/$script:MutexName, orphaned from whatever instance the
# top-level script (or a test's Set-PendingStatePath) configured -- Get- and
# Set- calls would then silently read/write two different files. PowerShell
# resolves an unqualified command name at CALL time against whichever
# module instance is current in scope, so as long as nothing in this file
# does its own nested import, every caller's already-loaded instance is the
# one that gets used, with no risk of a second copy forking off.

function Set-RemainingLed {
    param([Parameter(Mandatory)][hashtable]$Connection)
    $state = Get-PendingState
    $ids = @($state.sessions.Keys | Sort-Object { $state.sessions[$_].since })
    if ($ids.Count -gt 0) {
        $next = $ids[0]
        Set-PendingCursor    -SessionId $next
        Set-DisplayedSession -SessionId $next
        # Solid full brightness, no flash: this is a hand-off to an existing
        # waiting session, not a new arrival.
        Invoke-HaLed -Connection $Connection -Rgb $state.sessions[$next].color -Brightness 255 | Out-Null
    } else {
        Clear-DisplayedSession
        Invoke-HaLed -Connection $Connection -Off | Out-Null
    }
}

Export-ModuleMember -Function Set-RemainingLed
