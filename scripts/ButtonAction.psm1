# claude-voice/scripts/ButtonAction.psm1
function Get-DialCycleTarget {
    param(
        [Parameter(Mandatory)][hashtable]$PendingSessions,
        [string]$Cursor
    )
    # Arrival order (oldest waiting first). Session ids are random, so
    # sorting them would produce a meaningless rotation.
    $names = @($PendingSessions.Keys | Sort-Object { $PendingSessions[$_].since })
    if ($names.Count -eq 0) { return $null }
    $idx = [array]::IndexOf($names, $Cursor)
    $names[($idx + 1) % $names.Count]
}

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
        [string]$Cursor
    )
    $names = @($PendingSessions.Keys | Sort-Object { $PendingSessions[$_].since })

    if ($EventType -eq 'easter_egg_press') {
        return @{ Action = 'none'; SessionId = $null; Speak = $null }
    }
    if ($names.Count -eq 0) {
        return @{ Action = 'none'; SessionId = $null; Speak = 'Nothing pending' }
    }

    switch ($EventType) {
        'double_press' {
            $next = Get-DialCycleTarget -PendingSessions $PendingSessions -Cursor $Cursor
            # Speak stays $null: only the bridge knows the display name
            # (project + ordinal), so it composes the utterance.
            return @{ Action = 'select'; SessionId = $next; Speak = $null }
        }
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

Export-ModuleMember -Function Get-ButtonAction, Get-DialCycleTarget, Get-KnownCycleTarget
