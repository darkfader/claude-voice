# claude-voice/scripts/ButtonAction.Tests.ps1
BeforeAll {
    Import-Module "$PSScriptRoot/ButtonAction.psm1" -Force
}

Describe 'Get-ButtonAction' {
    It 'double_press with nothing known says nothing pending' {
        $a = Get-ButtonAction -EventType 'double_press' -PendingSessions @{} -Cursor $null -KnownSessions @{}
        $a.Action | Should -Be 'none'
        $a.Speak | Should -Be 'Nothing pending'
    }

    It 'double_press activates the selected session without cycling' {
        $known = @{
            work     = @{ firstSeen = '2026-07-26T11:00:00Z' }
            personal = @{ firstSeen = '2026-07-26T10:00:00Z' }
        }
        $a = Get-ButtonAction -EventType 'double_press' -PendingSessions @{} -Cursor 'work' -KnownSessions $known
        $a.Action | Should -Be 'activate'
        $a.SessionId | Should -Be 'work'
    }

    It 'double_press activates a session the dial selected even though it is not pending' {
        # The regression this guards: resolving double_press against pending
        # sessions ignored the dial's selection entirely, and with exactly one
        # session pending it activated THAT one instead of the one on the ring.
        $known = @{
            browsing = @{ firstSeen = '2026-07-26T10:00:00Z' }
            waiting  = @{ firstSeen = '2026-07-26T11:00:00Z' }
        }
        $pending = @{ waiting = @{ since = '2026-07-26T11:00:00Z' } }
        $a = Get-ButtonAction -EventType 'double_press' -PendingSessions $pending -Cursor 'browsing' -KnownSessions $known
        $a.Action | Should -Be 'activate'
        $a.SessionId | Should -Be 'browsing'
    }

    It 'double_press with one known session and no cursor activates that one' {
        $known = @{ solo = @{ firstSeen = '2026-07-26T10:00:00Z' } }
        $a = Get-ButtonAction -EventType 'double_press' -PendingSessions @{} -Cursor $null -KnownSessions $known
        $a.Action | Should -Be 'activate'
        $a.SessionId | Should -Be 'solo'
    }

    It 'double_press with several known and no cursor selects nothing' {
        $known = @{
            work     = @{ firstSeen = '2026-07-26T11:00:00Z' }
            personal = @{ firstSeen = '2026-07-26T10:00:00Z' }
        }
        $a = Get-ButtonAction -EventType 'double_press' -PendingSessions @{} -Cursor $null -KnownSessions $known
        $a.Action | Should -Be 'none'
        $a.Speak | Should -Be 'Nothing selected'
    }

    It 'long_press with a selected cursor confirms that session' {
        $pending = @{ personal = @{ since = '2026-07-26T10:00:00Z' } }
        $a = Get-ButtonAction -EventType 'long_press' -PendingSessions $pending -Cursor 'personal'
        $a.Action | Should -Be 'focus'
        $a.SessionId | Should -Be 'personal'
    }

    It 'long_press with a stale cursor and multiple pending sessions does nothing' {
        # Cursor points at a session no longer pending (e.g. it was cleared),
        # and there's more than one candidate, so it can't be auto-resolved
        # the way a single pending session can be. Distinct from the
        # no-cursor-at-all case covered below.
        $pending = @{
            personal = @{ since = '2026-07-26T10:00:00Z' }
            work     = @{ since = '2026-07-26T11:00:00Z' }
        }
        $a = Get-ButtonAction -EventType 'long_press' -PendingSessions $pending -Cursor 'someone-else'
        $a.Action | Should -Be 'none'
    }

    It 'long_press with no cursor but exactly one pending session confirms that session' {
        $pending = @{ personal = @{ since = '2026-07-26T10:00:00Z' } }
        $a = Get-ButtonAction -EventType 'long_press' -PendingSessions $pending -Cursor $null
        $a.Action | Should -Be 'focus'
        $a.SessionId | Should -Be 'personal'
    }

    It 'long_press with no cursor and two pending sessions still does nothing' {
        $pending = @{
            personal = @{ since = '2026-07-26T10:00:00Z' }
            work     = @{ since = '2026-07-26T11:00:00Z' }
        }
        $a = Get-ButtonAction -EventType 'long_press' -PendingSessions $pending -Cursor $null
        $a.Action | Should -Be 'none'
    }

    It 'triple_press dismisses the selected session' {
        $pending = @{ personal = @{ since = '2026-07-26T10:00:00Z' } }
        $a = Get-ButtonAction -EventType 'triple_press' -PendingSessions $pending -Cursor 'personal'
        $a.Action | Should -Be 'dismiss'
        $a.SessionId | Should -Be 'personal'
    }

    It 'easter_egg_press always does nothing' {
        $pending = @{ personal = @{ since = '2026-07-26T10:00:00Z' } }
        $a = Get-ButtonAction -EventType 'easter_egg_press' -PendingSessions $pending -Cursor 'personal'
        $a.Action | Should -Be 'none'
    }

}


Describe 'Get-KnownCycleTarget' {
    BeforeAll {
        $script:known = @{
            b = @{ firstSeen = '2026-07-27T10:01:00.0000000+02:00' }
            a = @{ firstSeen = '2026-07-27T10:00:00.0000000+02:00' }
            c = @{ firstSeen = '2026-07-27T10:02:00.0000000+02:00' }
        }
    }

    It 'returns null when nothing is known' {
        Get-KnownCycleTarget -KnownSessions @{} -Cursor $null -Direction 'cw'  | Should -BeNullOrEmpty
        Get-KnownCycleTarget -KnownSessions @{} -Cursor $null -Direction 'ccw' | Should -BeNullOrEmpty
    }

    It 'enters at the same thread regardless of direction when nothing has asked' {
        # Entry no longer depends on direction. It is decided by which thread
        # last wanted the human (see the 'entry point' Describe below); with no
        # activity data at all, every thread ranks equally and the stable sort
        # leaves firstSeen order, so both directions enter at the oldest.
        Get-KnownCycleTarget -KnownSessions $script:known -Cursor $null -Direction 'cw'  | Should -Be 'a'
        Get-KnownCycleTarget -KnownSessions $script:known -Cursor $null -Direction 'ccw' | Should -Be 'a'
    }

    It 'advances in firstSeen order clockwise' {
        Get-KnownCycleTarget -KnownSessions $script:known -Cursor 'a' -Direction 'cw' | Should -Be 'b'
        Get-KnownCycleTarget -KnownSessions $script:known -Cursor 'b' -Direction 'cw' | Should -Be 'c'
    }

    It 'retreats in firstSeen order anticlockwise' {
        Get-KnownCycleTarget -KnownSessions $script:known -Cursor 'c' -Direction 'ccw' | Should -Be 'b'
        Get-KnownCycleTarget -KnownSessions $script:known -Cursor 'b' -Direction 'ccw' | Should -Be 'a'
    }

    It 'wraps forward past the newest to the oldest' {
        Get-KnownCycleTarget -KnownSessions $script:known -Cursor 'c' -Direction 'cw' | Should -Be 'a'
    }

    It 'wraps backward past the oldest to the newest' {
        Get-KnownCycleTarget -KnownSessions $script:known -Cursor 'a' -Direction 'ccw' | Should -Be 'c'
    }

    It 'treats an unrecognised cursor as no cursor' {
        # A cursor naming an expired session falls back to the entry rule,
        # which is direction-independent.
        Get-KnownCycleTarget -KnownSessions $script:known -Cursor 'gone' -Direction 'cw'  | Should -Be 'a'
        Get-KnownCycleTarget -KnownSessions $script:known -Cursor 'gone' -Direction 'ccw' | Should -Be 'a'
    }

    It 'returns the only session regardless of direction' {
        $one = @{ solo = @{ firstSeen = '2026-07-27T10:00:00.0000000+02:00' } }
        Get-KnownCycleTarget -KnownSessions $one -Cursor 'solo' -Direction 'cw'  | Should -Be 'solo'
        Get-KnownCycleTarget -KnownSessions $one -Cursor 'solo' -Direction 'ccw' | Should -Be 'solo'
    }
}

Describe 'Get-KnownCycleTarget entry point' {
    BeforeAll {
        # b finished most recently; c is still working; a finished a while ago.
        $script:byAttention = @{
            a = @{ firstSeen = '2026-07-29T10:00:00Z'; activity = 'idle';      activitySince = '2026-07-29T10:30:00Z' }
            b = @{ firstSeen = '2026-07-29T10:01:00Z'; activity = 'idle';      activitySince = '2026-07-29T11:00:00Z' }
            c = @{ firstSeen = '2026-07-29T10:02:00Z'; activity = 'working';   activitySince = '2026-07-29T11:59:00Z' }
        }
    }

    It 'enters on whatever last wanted you, not the end of the list' {
        # b finished most recently. c is newer but merely working -- it has not
        # asked for anything, so it must not win the entry point.
        Get-KnownCycleTarget -KnownSessions $script:byAttention -Cursor $null -Direction 'cw'  | Should -Be 'b'
        Get-KnownCycleTarget -KnownSessions $script:byAttention -Cursor $null -Direction 'ccw' | Should -Be 'b'
    }

    It 'prefers an attention thread over an older finished one' {
        $k = @{
            fin = @{ firstSeen = '2026-07-29T10:00:00Z'; activity = 'idle';      activitySince = '2026-07-29T11:00:00Z' }
            ask = @{ firstSeen = '2026-07-29T10:01:00Z'; activity = 'attention'; activitySince = '2026-07-29T11:30:00Z' }
        }
        Get-KnownCycleTarget -KnownSessions $k -Cursor $null -Direction 'cw' | Should -Be 'ask'
    }

    It 'falls back to the most recent working thread when nothing has asked' {
        $k = @{
            old = @{ firstSeen = '2026-07-29T10:00:00Z'; activity = 'working'; activitySince = '2026-07-29T10:10:00Z' }
            new = @{ firstSeen = '2026-07-29T10:01:00Z'; activity = 'working'; activitySince = '2026-07-29T10:20:00Z' }
        }
        Get-KnownCycleTarget -KnownSessions $k -Cursor $null -Direction 'cw' | Should -Be 'new'
    }

    It 'still cycles in stable firstSeen order once a cursor exists' {
        # The attention-based entry applies ONLY to entering the list. After
        # that, order must stay predictable so the same turn lands the same way.
        Get-KnownCycleTarget -KnownSessions $script:byAttention -Cursor 'a' -Direction 'cw' | Should -Be 'b'
        Get-KnownCycleTarget -KnownSessions $script:byAttention -Cursor 'b' -Direction 'cw' | Should -Be 'c'
        Get-KnownCycleTarget -KnownSessions $script:byAttention -Cursor 'c' -Direction 'cw' | Should -Be 'a'
    }

    It 'can land on a working thread when cycling' {
        # All threads are reachable now -- you may well want to watch or
        # interrupt one mid-turn.
        Get-KnownCycleTarget -KnownSessions $script:byAttention -Cursor 'b' -Direction 'cw' | Should -Be 'c'
    }
}
