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

function Test-ShouldHandOffRing {
    param(
        [Parameter(Mandatory)][ValidateSet('notification', 'stop', 'clear')][string]$Event,
        [Parameter(Mandatory)][int]$OthersCount,
        [AllowNull()][string]$DisplayedSession,
        [Parameter(Mandatory)][string]$SessionId
    )
    # Final review: the hand-off (spec rule 3, "Resolved") must only fire
    # when the session that just resolved is the one the ring was actually
    # showing. The prior guard was just `($Event -eq 'stop' -or $Event -eq
    # 'clear') -and $OthersCount -gt 0` -- it never checked WHICH session
    # resolved, only that survivors remained. That silently discarded a
    # user's dial selection: N1 and N2 both pending, the user rotates the
    # dial to N2 (Set-PendingCursor/-DisplayedSession both move to N2), then
    # types a prompt in an unrelated session X. X's own 'clear' fires (any
    # UserPromptSubmit resolves that session, whether or not X itself was
    # ever pending -- Clear-PendingSession is a no-op if it wasn't), and
    # $OthersCount is still 2 (N1 and N2, untouched) -- so the old guard
    # handed the ring to N1 anyway, silently overriding the dial choice the
    # user had just made. This violates the stated rule ("if there's
    # already a session wanting attention and there's another, just do the
    # chime but don't switch session yet") and spec rule 2's principle that
    # the display only moves when the user moves it or when what it was
    # showing is resolved -- X resolving is neither.
    #
    # $DisplayedSession -eq $SessionId closes that: only a resolution of the
    # SESSION CURRENTLY ON DISPLAY can hand the ring off. A $null
    # DisplayedSession (nothing has ever lit the ring) never equals a real
    # session id, so it correctly never hands off either.
    ($Event -eq 'stop' -or $Event -eq 'clear') -and $OthersCount -gt 0 -and $DisplayedSession -eq $SessionId
}

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

Export-ModuleMember -Function Set-RemainingLed, Test-ShouldHandOffRing
