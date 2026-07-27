# claude-voice/scripts/AmbientState.psm1
# Pure decision logic for the ambient (dim) indicator's idle fade. Extracted
# from ha-bridge.ps1 (final review Fix 1) so the actual expiry decision is
# unit-testable. The inline version this replaced threw on every real call:
#
#     $since = $null
#     if (-not [datetime]::TryParse($state.activeSince, [ref]$since)) { return }
#
# [ref] cannot bind to a $null-VALUED/untyped variable as a [ref] DateTime
# out-parameter, so this threw "Cannot find an overload for TryParse and the
# argument count: 2" on every call that reached it -- i.e. exactly the
# steady state the 10-minute fade exists for. ha-bridge.ps1's outer
# try/catch swallowed the exception to the log, so the ring silently never
# faded. Nothing exercised this with a real timestamp before now: the prior
# task verified the timer was ARMED, never that it FIRED.
function Test-AmbientIdleExpired {
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][datetime]$Now,
        [Parameter(Mandatory)][int]$IdleMinutes
    )
    # Pending outranks active: a session waiting for input must never be
    # faded out from under the human because an unrelated ambient timer
    # expired.
    if ($State.sessions -and $State.sessions.Count -gt 0) { return $false }
    if (-not $State.activeSession -or -not $State.activeSince) { return $false }

    # [datetime]-TYPED with a real default value, NOT `$since = $null` --
    # this is the exact line that must never regress back to the untyped
    # form above.
    [datetime]$since = [datetime]::MinValue
    if (-not [datetime]::TryParse($State.activeSince, [ref]$since)) { return $false }

    ($Now - $since).TotalMinutes -ge $IdleMinutes
}

Export-ModuleMember -Function Test-AmbientIdleExpired
