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

Export-ModuleMember -Function Get-ButtonAction, Get-DialCycleTarget
