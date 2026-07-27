# claude-voice/scripts/AmbientState.Tests.ps1
BeforeAll { Import-Module "$PSScriptRoot/AmbientState.psm1" -Force }

Describe 'Test-AmbientIdleExpired' {
    It 'is false when a session is pending, no matter how stale activeSince is -- pending outranks active' {
        $state = @{
            sessions      = @{ s1 = @{ since = '2026-07-26T10:00:00Z' } }
            activeSession = 'old'
            activeSince   = '2020-01-01T00:00:00Z'
        }
        Test-AmbientIdleExpired -State $state -Now (Get-Date '2026-07-26T12:00:00Z') -IdleMinutes 10 |
            Should -BeFalse
    }

    It 'is false when activeSession/activeSince are absent' {
        $state = @{ sessions = @{}; activeSession = $null; activeSince = $null }
        Test-AmbientIdleExpired -State $state -Now (Get-Date) -IdleMinutes 10 | Should -BeFalse
    }

    It 'is false when activeSince does not parse as a date -- the exact case that let the original TryParse bug survive undetected' {
        # Final review Fix 1: the inline version this function replaces was
        # `$since = $null; [datetime]::TryParse($state.activeSince, [ref]$since)`,
        # which THROWS on every call ([ref] cannot bind to a $null-valued
        # variable), not just on unparseable input. Nothing before this test
        # exercised the function with a real timestamp at all -- the prior
        # task only verified the idle timer was armed, never that it fired.
        # This case in particular is the one that would have caught the bug:
        # if the fix regresses to the untyped `$since = $null` form, this
        # call throws instead of returning $false.
        $state = @{ sessions = @{}; activeSession = 's1'; activeSince = 'not-a-date' }
        Test-AmbientIdleExpired -State $state -Now (Get-Date) -IdleMinutes 10 | Should -BeFalse
    }

    It 'is true only when nothing is pending and activeSince is at least IdleMinutes old' {
        $state = @{
            sessions      = @{}
            activeSession = 's1'
            activeSince   = '2026-07-26T10:00:00Z'
        }
        Test-AmbientIdleExpired -State $state -Now (Get-Date '2026-07-26T10:09:59Z') -IdleMinutes 10 |
            Should -BeFalse -Because 'just under the threshold must not expire yet'
        Test-AmbientIdleExpired -State $state -Now (Get-Date '2026-07-26T10:10:00Z') -IdleMinutes 10 |
            Should -BeTrue -Because 'exactly at the threshold must expire'
        Test-AmbientIdleExpired -State $state -Now (Get-Date '2026-07-26T11:00:00Z') -IdleMinutes 10 |
            Should -BeTrue -Because 'well past the threshold must expire'
    }
}
