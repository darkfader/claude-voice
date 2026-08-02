# claude-voice/scripts/ButtonAction.psm1
function Get-KnownCycleTarget {
    param(
        [Parameter(Mandatory)][hashtable]$KnownSessions,
        [string]$Cursor,
        [Parameter(Mandatory)][ValidateSet('cw','ccw')][string]$Direction
    )
    # Working (mid-turn) threads are no longer selectable by the dial. An
    # earlier version of this comment argued the opposite -- that you often
    # want to land on one, to watch or interrupt it -- but PTT (hold the
    # center button and talk) now gives a direct way to interrupt whatever is
    # running without dial-selecting it first, so the dial's job narrows to
    # "what's waiting for you or has finished."
    #
    # Stable firstSeen order, NOT most-recently-used. MRU suits Alt-Tab, where
    # the list is invisible and a held modifier bounds the gesture. On a
    # physical dial it means the list reorders under your fingers, so the same
    # rotation stops landing in the same place.
    $names = @($KnownSessions.Keys | Where-Object { $KnownSessions[$_].activity -ne 'working' } |
        Sort-Object { $KnownSessions[$_].firstSeen })
    if ($names.Count -eq 0) { return $null }

    $idx = [array]::IndexOf($names, $Cursor)
    if ($idx -lt 0) {
        # No cursor, one naming a session that has since expired, or one that
        # has since started working (and so dropped out of $names above).
        #
        # Enter at whatever LAST WANTED YOU, not at the end of the list. The
        # overwhelmingly common reason to reach for the dial is that something
        # just finished or asked a question -- so the first detent should land
        # there rather than making you hunt for it. Among the (already
        # working-excluded) candidates, the most recent activitySince wins.
        $entry = @($names | Sort-Object -Descending {
            [datetime]$t = [datetime]::MinValue
            if ([datetime]::TryParse([string]$KnownSessions[$_].activitySince, [ref]$t)) { $t } else { [datetime]::MinValue }
        })[0]
        return $entry
    }

    $step = if ($Direction -eq 'cw') { 1 } else { -1 }
    # PowerShell's % keeps the sign of the dividend, so -1 % 3 is -1, not 2.
    # The second modulo is what makes anticlockwise wrap instead of indexing
    # backwards off the end of the array.
    $names[((($idx + $step) % $names.Count) + $names.Count) % $names.Count]
}

function Get-ButtonAction {
    param(
        [Parameter(Mandatory)][ValidateSet('single_press','double_press','long_press','triple_press','easter_egg_press')]
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
    # must be handled before the "nothing pending" bail-out below.
    #
    # No longer resolves against the dial's current selection ("take me to
    # what's selected") -- it now jumps straight to whichever known thread
    # most recently finished or asked for you, ignoring $Cursor entirely.
    # Reuses Get-KnownCycleTarget's own entry-point ranking (working threads
    # excluded, most recent activitySince wins) by asking it to resolve with
    # no cursor, rather than duplicating that ranking here.
    if ($EventType -eq 'double_press') {
        $target = Get-KnownCycleTarget -KnownSessions $KnownSessions -Cursor $null -Direction 'cw'
        if (-not $target) {
            return @{ Action = 'none'; SessionId = $null; Speak = 'Nothing pending' }
        }
        return @{ Action = 'activate'; SessionId = $target; Speak = $null }
    }

    if ($names.Count -eq 0) {
        return @{ Action = 'none'; SessionId = $null; Speak = 'Nothing pending' }
    }

    switch ($EventType) {
        'single_press' {
            # A quick tap: reply on the session's behalf without switching
            # focus to it -- firmware now fires this instead of starting HA's
            # own Assist pipeline (see custom-voice-pe.yaml's on_multi_click
            # redefinition).
            $effectiveCursor = $Cursor
            if ((-not $effectiveCursor -or $names -notcontains $effectiveCursor) -and $names.Count -eq 1) {
                $effectiveCursor = $names[0]
            }
            if (-not $effectiveCursor -or $names -notcontains $effectiveCursor) {
                return @{ Action = 'none'; SessionId = $null; Speak = 'Nothing selected' }
            }
            $activity = $null
            if ($KnownSessions.ContainsKey($effectiveCursor)) { $activity = $KnownSessions[$effectiveCursor].activity }
            if ($activity -eq 'attention') {
                # 'attention' is overwhelmingly a permission prompt. A blind
                # auto-typed "yes" from across the room would approve
                # whatever it's asking sight-unseen -- the exact thing
                # long_press's own comment above already refuses to do.
                # Fall back to focus instead, so a human actually sees the
                # prompt before answering it themselves.
                return @{ Action = 'focus'; SessionId = $effectiveCursor; Speak = $null }
            }
            $text = if ($activity -eq 'idle') { 'continue' } else { 'okay' }
            return @{ Action = 'reply'; SessionId = $effectiveCursor; Speak = $null; Text = $text }
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

Export-ModuleMember -Function Get-ButtonAction, Get-KnownCycleTarget
