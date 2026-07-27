# claude-voice/scripts/ButtonAction.psm1
function Get-KnownCycleTarget {
    param(
        [Parameter(Mandatory)][hashtable]$KnownSessions,
        [string]$Cursor,
        [Parameter(Mandatory)][ValidateSet('cw','ccw')][string]$Direction
    )
    # Stable firstSeen order, NOT most-recently-used. MRU suits Alt-Tab, where
    # the list is invisible and a held modifier bounds the gesture. On a
    # physical dial it means the list reorders under your fingers, so the same
    # rotation stops landing in the same place.
    $names = @($KnownSessions.Keys | Sort-Object { $KnownSessions[$_].firstSeen })
    if ($names.Count -eq 0) { return $null }

    $idx = [array]::IndexOf($names, $Cursor)
    if ($idx -lt 0) {
        # No cursor, or one naming a session that has since expired: enter the
        # list from the end the rotation is heading away from, so the first
        # detent lands on the oldest going forward and the newest going back.
        if ($Direction -eq 'cw') { return $names[0] } else { return $names[-1] }
    }

    $step = if ($Direction -eq 'cw') { 1 } else { -1 }
    # PowerShell's % keeps the sign of the dividend, so -1 % 3 is -1, not 2.
    # The second modulo is what makes anticlockwise wrap instead of indexing
    # backwards off the end of the array.
    $names[((($idx + $step) % $names.Count) + $names.Count) % $names.Count]
}

function Get-ButtonAction {
    param(
        [Parameter(Mandatory)][ValidateSet('double_press','long_press','triple_press','easter_egg_press')]
        [string]$EventType,
        [Parameter(Mandatory)][hashtable]$PendingSessions,
        [string]$Cursor,
        # Every session seen recently, pending or not -- the same map the dial
        # cycles. Only double_press consults it (see below). Optional so that
        # callers which genuinely only care about pending sessions, and the
        # pending-only tests, need not supply it.
        [hashtable]$KnownSessions = @{}
    )
    $names = @($PendingSessions.Keys | Sort-Object { $PendingSessions[$_].since })

    if ($EventType -eq 'easter_egg_press') {
        return @{ Action = 'none'; SessionId = $null; Speak = $null }
    }

    # double_press resolves against KNOWN sessions, not pending ones, and so
    # must be handled before the "nothing pending" bail-out below. The dial
    # sets the cursor from the known map, so a cursor pointing at a session
    # that is merely known is normal and expected -- resolving double_press
    # against pending sessions instead would ignore the dial's selection
    # entirely and, with exactly one session pending, silently activate THAT
    # one instead of the one the ring is showing.
    if ($EventType -eq 'double_press') {
        # The dial owns cycling now, which frees double-press to mean "take me
        # to what's selected" -- the gesture you want after alt-tabbing away,
        # when the selection is already right. Unlike long_press it
        # deliberately does NOT clear the pending light.
        $knownNames = @($KnownSessions.Keys | Sort-Object { $KnownSessions[$_].firstSeen })
        if ($knownNames.Count -eq 0) {
            return @{ Action = 'none'; SessionId = $null; Speak = 'Nothing pending' }
        }
        $effectiveCursor = $Cursor
        if ((-not $effectiveCursor -or $knownNames -notcontains $effectiveCursor) -and $knownNames.Count -eq 1) {
            $effectiveCursor = $knownNames[0]
        }
        if (-not $effectiveCursor -or $knownNames -notcontains $effectiveCursor) {
            return @{ Action = 'none'; SessionId = $null; Speak = 'Nothing selected' }
        }
        return @{ Action = 'activate'; SessionId = $effectiveCursor; Speak = $null }
    }

    if ($names.Count -eq 0) {
        return @{ Action = 'none'; SessionId = $null; Speak = 'Nothing pending' }
    }

    switch ($EventType) {
        'long_press' {
            $effectiveCursor = $Cursor
            if ((-not $effectiveCursor -or $names -notcontains $effectiveCursor) -and $names.Count -eq 1) {
                $effectiveCursor = $names[0]
            }
            if (-not $effectiveCursor -or $names -notcontains $effectiveCursor) {
                return @{ Action = 'none'; SessionId = $null; Speak = 'Nothing selected' }
            }
            # 'focus', not 'confirm': long-press takes you TO the session and
            # clears the light -- it deliberately does not answer for you. The
            # Notification hook fires mainly on permission prompts, so replying
            # unseen from across the room is the one thing this shouldn't do.
            return @{ Action = 'focus'; SessionId = $effectiveCursor; Speak = $null }
        }
        'triple_press' {
            $effectiveCursor = $Cursor
            if ((-not $effectiveCursor -or $names -notcontains $effectiveCursor) -and $names.Count -eq 1) {
                $effectiveCursor = $names[0]
            }
            if (-not $effectiveCursor -or $names -notcontains $effectiveCursor) {
                return @{ Action = 'none'; SessionId = $null; Speak = 'Nothing selected' }
            }
            return @{ Action = 'dismiss'; SessionId = $effectiveCursor; Speak = $null }
        }
    }
}

Export-ModuleMember -Function Get-ButtonAction, Get-KnownCycleTarget
