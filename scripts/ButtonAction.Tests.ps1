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

    It 'double_press jumps to whichever known thread most recently finished, ignoring the cursor' {
        # Cursor points at 'work', but 'personal' asked more recently -- the
        # cursor is no longer consulted at all for double_press.
        $known = @{
            work     = @{ firstSeen = '2026-07-26T10:00:00Z'; activity = 'idle'; activitySince = '2026-07-26T10:30:00Z' }
            personal = @{ firstSeen = '2026-07-26T11:00:00Z'; activity = 'idle'; activitySince = '2026-07-26T12:00:00Z' }
        }
        $a = Get-ButtonAction -EventType 'double_press' -PendingSessions @{} -Cursor 'work' -KnownSessions $known
        $a.Action | Should -Be 'activate'
        $a.SessionId | Should -Be 'personal'
    }

    It 'double_press ignores pending state entirely, resolving purely from known/activity' {
        # Not resolved against pending sessions at all -- only KnownSessions'
        # activity/activitySince decide the target.
        $known = @{
            browsing = @{ firstSeen = '2026-07-26T10:00:00Z'; activity = 'idle'; activitySince = '2026-07-26T10:05:00Z' }
            waiting  = @{ firstSeen = '2026-07-26T11:00:00Z'; activity = 'idle'; activitySince = '2026-07-26T11:05:00Z' }
        }
        $pending = @{ waiting = @{ since = '2026-07-26T11:00:00Z' } }
        $a = Get-ButtonAction -EventType 'double_press' -PendingSessions $pending -Cursor 'browsing' -KnownSessions $known
        $a.Action | Should -Be 'activate'
        $a.SessionId | Should -Be 'waiting'
    }

    It 'double_press with one known session activates that one' {
        $known = @{ solo = @{ firstSeen = '2026-07-26T10:00:00Z' } }
        $a = Get-ButtonAction -EventType 'double_press' -PendingSessions @{} -Cursor $null -KnownSessions $known
        $a.Action | Should -Be 'activate'
        $a.SessionId | Should -Be 'solo'
    }

    It 'double_press skips a working thread even if it is the only recent activity' {
        $known = @{
            working = @{ firstSeen = '2026-07-26T11:00:00Z'; activity = 'working'; activitySince = '2026-07-26T12:00:00Z' }
            idle    = @{ firstSeen = '2026-07-26T10:00:00Z'; activity = 'idle';    activitySince = '2026-07-26T10:05:00Z' }
        }
        $a = Get-ButtonAction -EventType 'double_press' -PendingSessions @{} -Cursor $null -KnownSessions $known
        $a.Action | Should -Be 'activate'
        $a.SessionId | Should -Be 'idle'
    }

    It 'double_press with only working threads known does nothing' {
        $known = @{
            work = @{ firstSeen = '2026-07-26T11:00:00Z'; activity = 'working'; activitySince = '2026-07-26T12:00:00Z' }
        }
        $a = Get-ButtonAction -EventType 'double_press' -PendingSessions @{} -Cursor $null -KnownSessions $known
        $a.Action | Should -Be 'none'
        $a.Speak | Should -Be 'Nothing pending'
    }

    It 'single_press replies "continue" to an idle session' {
        $pending = @{ personal = @{ since = '2026-07-26T10:00:00Z' } }
        $known = @{ personal = @{ activity = 'idle' } }
        $a = Get-ButtonAction -EventType 'single_press' -PendingSessions $pending -Cursor 'personal' -KnownSessions $known
        $a.Action | Should -Be 'reply'
        $a.SessionId | Should -Be 'personal'
        $a.Text | Should -Be 'continue'
    }

    It 'single_press replies "okay" when activity is unknown/working' {
        $pending = @{ personal = @{ since = '2026-07-26T10:00:00Z' } }
        $known = @{ personal = @{ activity = 'working' } }
        $a = Get-ButtonAction -EventType 'single_press' -PendingSessions $pending -Cursor 'personal' -KnownSessions $known
        $a.Action | Should -Be 'reply'
        $a.Text | Should -Be 'okay'
    }

    It 'single_press replies "okay" when the session is not in KnownSessions at all' {
        $pending = @{ personal = @{ since = '2026-07-26T10:00:00Z' } }
        $a = Get-ButtonAction -EventType 'single_press' -PendingSessions $pending -Cursor 'personal' -KnownSessions @{}
        $a.Action | Should -Be 'reply'
        $a.Text | Should -Be 'okay'
    }

    It 'single_press on an attention session focuses instead of auto-replying' {
        # Never blind-approve a permission prompt from across the room.
        $pending = @{ personal = @{ since = '2026-07-26T10:00:00Z' } }
        $known = @{ personal = @{ activity = 'attention' } }
        $a = Get-ButtonAction -EventType 'single_press' -PendingSessions $pending -Cursor 'personal' -KnownSessions $known
        $a.Action | Should -Be 'focus'
        $a.SessionId | Should -Be 'personal'
    }

    It 'single_press with no cursor but exactly one pending session resolves that one' {
        $pending = @{ personal = @{ since = '2026-07-26T10:00:00Z' } }
        $known = @{ personal = @{ activity = 'idle' } }
        $a = Get-ButtonAction -EventType 'single_press' -PendingSessions $pending -Cursor $null -KnownSessions $known
        $a.Action | Should -Be 'reply'
        $a.SessionId | Should -Be 'personal'
    }

    It 'single_press with a stale cursor and multiple pending sessions does nothing' {
        $pending = @{
            personal = @{ since = '2026-07-26T10:00:00Z' }
            work     = @{ since = '2026-07-26T11:00:00Z' }
        }
        $a = Get-ButtonAction -EventType 'single_press' -PendingSessions $pending -Cursor 'someone-else'
        $a.Action | Should -Be 'none'
    }

    It 'single_press with nothing pending does nothing' {
        $a = Get-ButtonAction -EventType 'single_press' -PendingSessions @{} -Cursor $null
        $a.Action | Should -Be 'none'
        $a.Speak | Should -Be 'Nothing pending'
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

    It 'finds nothing to enter on when every known thread is working' {
        $k = @{
            old = @{ firstSeen = '2026-07-29T10:00:00Z'; activity = 'working'; activitySince = '2026-07-29T10:10:00Z' }
            new = @{ firstSeen = '2026-07-29T10:01:00Z'; activity = 'working'; activitySince = '2026-07-29T10:20:00Z' }
        }
        Get-KnownCycleTarget -KnownSessions $k -Cursor $null -Direction 'cw' | Should -BeNullOrEmpty
    }

    It 'still cycles in stable firstSeen order once a cursor exists, skipping working threads' {
        # c is 'working' and excluded from the candidate set entirely, so
        # rotation among {a, b} wraps without ever landing on it.
        Get-KnownCycleTarget -KnownSessions $script:byAttention -Cursor 'a' -Direction 'cw' | Should -Be 'b'
        Get-KnownCycleTarget -KnownSessions $script:byAttention -Cursor 'b' -Direction 'cw' | Should -Be 'a'
    }

    It 'never lands on a working thread when cycling' {
        # PTT (hold the button and talk) is the way to reach a working thread
        # directly now -- the dial no longer stops on one at all. A cursor
        # naming a thread that dropped out of the candidate set (started
        # working since it was selected) is treated like any other stale
        # cursor: falls back to the entry-point ranking.
        Get-KnownCycleTarget -KnownSessions $script:byAttention -Cursor 'c' -Direction 'cw' | Should -Be 'b'
    }

    It 'returns null when every known thread is working' {
        $allWorking = @{
            old = @{ firstSeen = '2026-07-29T10:00:00Z'; activity = 'working'; activitySince = '2026-07-29T10:10:00Z' }
            new = @{ firstSeen = '2026-07-29T10:01:00Z'; activity = 'working'; activitySince = '2026-07-29T10:20:00Z' }
        }
        Get-KnownCycleTarget -KnownSessions $allWorking -Cursor $null -Direction 'cw' | Should -BeNullOrEmpty
    }
}
