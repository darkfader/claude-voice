# claude-voice/scripts/ButtonAction.Tests.ps1
BeforeAll {
    Import-Module "$PSScriptRoot/ButtonAction.psm1" -Force
}

Describe 'Get-ButtonAction' {
    It 'double_press with nothing pending says nothing pending' {
        $a = Get-ButtonAction -EventType 'double_press' -PendingSessions @{} -Cursor $null
        $a.Action | Should -Be 'none'
        $a.Speak | Should -Be 'Nothing pending'
    }

    It 'double_press cycles from no cursor to the oldest session' {
        $pending = @{
            work     = @{ since = '2026-07-26T11:00:00Z' }
            personal = @{ since = '2026-07-26T10:00:00Z' }
        }
        $a = Get-ButtonAction -EventType 'double_press' -PendingSessions $pending -Cursor $null
        $a.Action | Should -Be 'select'
        $a.SessionId | Should -Be 'personal'
    }

    It 'double_press wraps around from the newest session back to the oldest' {
        $pending = @{
            work     = @{ since = '2026-07-26T11:00:00Z' }
            personal = @{ since = '2026-07-26T10:00:00Z' }
        }
        $a = Get-ButtonAction -EventType 'double_press' -PendingSessions $pending -Cursor 'work'
        $a.SessionId | Should -Be 'personal'
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

    It 'cycles in arrival order, oldest first - not alphabetically' {
        $pending = @{
            'zzz' = @{ since = '2026-07-26T10:00:00Z' }
            'aaa' = @{ since = '2026-07-26T11:00:00Z' }
        }
        Get-DialCycleTarget -PendingSessions $pending -Cursor $null | Should -Be 'zzz'
        Get-DialCycleTarget -PendingSessions $pending -Cursor 'zzz' | Should -Be 'aaa'
    }

    It 'wraps from the newest back to the oldest' {
        $pending = @{
            'zzz' = @{ since = '2026-07-26T10:00:00Z' }
            'aaa' = @{ since = '2026-07-26T11:00:00Z' }
        }
        Get-DialCycleTarget -PendingSessions $pending -Cursor 'aaa' | Should -Be 'zzz'
    }
}

Describe 'Get-DialCycleTarget' {
    It 'advances from no cursor to the oldest session' {
        $pending = @{
            work     = @{ since = '2026-07-26T11:00:00Z' }
            personal = @{ since = '2026-07-26T10:00:00Z' }
        }
        Get-DialCycleTarget -PendingSessions $pending -Cursor $null | Should -Be 'personal'
    }

    It 'wraps around from the newest back to the oldest' {
        $pending = @{
            work     = @{ since = '2026-07-26T11:00:00Z' }
            personal = @{ since = '2026-07-26T10:00:00Z' }
        }
        Get-DialCycleTarget -PendingSessions $pending -Cursor 'work' | Should -Be 'personal'
    }

    It 'returns $null when nothing is pending' {
        Get-DialCycleTarget -PendingSessions @{} -Cursor $null | Should -BeNullOrEmpty
    }

    It 'advances through the middle of a three-session list, oldest to newest' {
        $pending = @{
            alpha   = @{ since = '2026-07-26T10:00:00Z' }
            bravo   = @{ since = '2026-07-26T11:00:00Z' }
            charlie = @{ since = '2026-07-26T12:00:00Z' }
        }
        Get-DialCycleTarget -PendingSessions $pending -Cursor 'alpha' | Should -Be 'bravo'
    }

    It 'treats a stale cursor (no longer pending) as if starting from the top' {
        $pending = @{
            work     = @{ since = '2026-07-26T11:00:00Z' }
            personal = @{ since = '2026-07-26T10:00:00Z' }
        }
        Get-DialCycleTarget -PendingSessions $pending -Cursor 'someone-else' | Should -Be 'personal'
    }

    It 'with exactly one pending session, keeps returning that same session no matter the cursor' {
        # Final review (Fix 1): this is the single-session case the existing
        # 0/2/3-session tests never covered. Get-DialCycleTarget itself has
        # no special-case for count -eq 1 -- both a $null cursor (index -1,
        # wraps to names[0]) and a cursor already equal to names[0]
        # ((0 + 1) % 1 = 0) land back on the same lone session. That's
        # correct behavior for this pure function, but calling it
        # unconditionally on every dial detent (as ha-bridge.ps1's
        # Invoke-DialRotationEvent used to) would re-announce/re-pulse the
        # same session forever on a single ordinary volume/hue turn -- which
        # is why ha-bridge.ps1 now gates dial-cycling to only run when 2+
        # sessions are pending, never calling this function at all for the
        # 1-session case.
        $pending = @{ personal = @{ since = '2026-07-26T10:00:00Z' } }
        Get-DialCycleTarget -PendingSessions $pending -Cursor $null | Should -Be 'personal'
        Get-DialCycleTarget -PendingSessions $pending -Cursor 'personal' | Should -Be 'personal'
    }
}
