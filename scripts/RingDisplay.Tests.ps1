# claude-voice/scripts/RingDisplay.Tests.ps1
BeforeAll {
    # RingDisplay.psm1 deliberately does not import its own dependencies
    # (see its top comment) -- the caller must, so both are imported here
    # BEFORE RingDisplay.psm1 itself.
    Import-Module "$PSScriptRoot/PendingState.psm1" -Force
    Import-Module "$PSScriptRoot/HaClient.psm1"     -Force
    Import-Module "$PSScriptRoot/RingDisplay.psm1"  -Force
}

Describe 'Set-RemainingLed' {
    BeforeEach {
        # $TestDrive persists across It blocks within a Describe, so without
        # removing a leftover file, the second test's "nothing remains
        # pending" premise could be contaminated by the first test's
        # sessions (see the same fix in PendingState.Tests.ps1).
        $path = Join-Path $TestDrive 'pending.json'
        if (Test-Path $path) { Remove-Item -Path $path -Force }
        Set-PendingStatePath -Path $path
        # Own throwaway mutex per test, mirroring PendingState.Tests.ps1 --
        # keeps this suite isolated from both live hooks and other test files.
        Set-PendingStateMutexName -Name "Global\ClaudeVoicePendingStateTest_$([guid]::NewGuid().ToString('N'))"
        Set-PendingStateExpiryHours -Hours 4
        Mock -CommandName Invoke-HaLed -ModuleName RingDisplay
    }

    It 'moves the ring to the oldest remaining pending session, solid full brightness, no flash, and updates cursor + displayedSession' {
        Set-PendingSession -SessionId 'newer' -Project 'B' -Cwd 'cb' -Message 'm' -Color @(9, 9, 9)  -Slot 1 -Ordinal 1
        Set-PendingSession -SessionId 'older' -Project 'A' -Cwd 'ca' -Message 'm' -Color @(1, 2, 3) -Slot 0 -Ordinal 1

        # Pin explicit, RECENT `since` timestamps rather than relying on
        # call-order timing, matching the pattern PendingState.Tests.ps1
        # uses for its expiry tests -- avoids any flakiness from two
        # Set-PendingSession calls landing within the same clock tick.
        # Must be recent (minutes, not a fixed calendar date): Get-PendingState
        # expires anything older than 4 hours on every read, so a hardcoded
        # past date works today and silently starts failing the moment real
        # time catches up to it.
        $path = Join-Path $TestDrive 'pending.json'
        $raw = Get-Content $path -Raw | ConvertFrom-Json -AsHashtable
        $raw.sessions.newer.since = (Get-Date).AddMinutes(-5).ToString('o')
        $raw.sessions.older.since = (Get-Date).AddMinutes(-10).ToString('o')
        $raw | ConvertTo-Json -Depth 6 | Set-Content $path

        Set-RemainingLed -Connection @{ Url = 'http://fake' }

        Should -Invoke -CommandName Invoke-HaLed -ModuleName RingDisplay -Times 1 -ParameterFilter {
            ($Rgb -join ',') -eq '1,2,3' -and $Brightness -eq 255 -and -not $Flash
        }
        (Get-PendingState).cursor           | Should -Be 'older'
        (Get-PendingState).displayedSession | Should -Be 'older'
    }

    It 'turns the ring off and clears displayedSession when nothing remains pending' {
        Set-DisplayedSession -SessionId 'stale-leftover'

        Set-RemainingLed -Connection @{ Url = 'http://fake' }

        Should -Invoke -CommandName Invoke-HaLed -ModuleName RingDisplay -Times 1 -ParameterFilter { $Off }
        (Get-PendingState).displayedSession | Should -BeNullOrEmpty
    }
}

Describe 'Test-ShouldHandOffRing' {
    BeforeEach {
        # Same isolation as the 'Set-RemainingLed' Describe above -- a
        # sibling Describe does NOT inherit another Describe's BeforeEach in
        # Pester, and the "end to end" tests below exercise real
        # PendingState/Set-RemainingLed calls, not just the pure predicate.
        $path = Join-Path $TestDrive 'pending.json'
        if (Test-Path $path) { Remove-Item -Path $path -Force }
        Set-PendingStatePath -Path $path
        Set-PendingStateMutexName -Name "Global\ClaudeVoicePendingStateTest_$([guid]::NewGuid().ToString('N'))"
        Set-PendingStateExpiryHours -Hours 4
        Mock -CommandName Invoke-HaLed -ModuleName RingDisplay
    }

    # Regression test for the final-review defect: notify-ha.ps1 used to
    # hand off the ring to the oldest remaining pending session whenever a
    # stop/clear left survivors, WITHOUT checking whether the resolved
    # session was the one actually on display. Scenario from the review: N1
    # and N2 pending, the user rotates the dial to N2 (ring now shows N2,
    # displayedSession = 'n2'), then types a prompt in an unrelated session
    # X. X's 'clear' resolves X (a no-op on the pending dict if X was never
    # pending) and reports OthersCount = 2 (n1, n2 untouched) -- so the old
    # unguarded check handed the ring to n1 anyway, silently discarding the
    # dial selection the user had just made. These tests pin the corrected
    # behaviour at the decision-function level, since it's a pure predicate
    # with no side effects to fake.
    It 'is false when the resolved session is not the one currently displayed, even with survivors pending -- the discarded-dial-selection regression' {
        Test-ShouldHandOffRing -Event 'clear' -OthersCount 2 -DisplayedSession 'n2' -SessionId 'x' | Should -BeFalse
    }

    It 'is true when the resolved session IS the one currently displayed and survivors remain' {
        Test-ShouldHandOffRing -Event 'clear' -OthersCount 1 -DisplayedSession 'n2' -SessionId 'n2' | Should -BeTrue
    }

    It 'is false when the resolved session was displayed but nothing survives it' {
        Test-ShouldHandOffRing -Event 'stop' -OthersCount 0 -DisplayedSession 'n2' -SessionId 'n2' | Should -BeFalse
    }

    It 'is false when nothing has ever been displayed (displayedSession is null)' {
        Test-ShouldHandOffRing -Event 'clear' -OthersCount 2 -DisplayedSession $null -SessionId 'x' | Should -BeFalse
    }

    It 'is false for a notification event regardless of the other inputs -- only a resolution can hand off' {
        Test-ShouldHandOffRing -Event 'notification' -OthersCount 2 -DisplayedSession 'n2' -SessionId 'n2' | Should -BeFalse
    }

    It 'end to end: a resolved-but-not-displayed session leaves cursor and displayedSession untouched, and never touches the LED' {
        Set-PendingSession -SessionId 'n1' -Project 'A' -Cwd 'ca' -Message 'm' -Color @(1, 2, 3) -Slot 0 -Ordinal 1
        Set-PendingSession -SessionId 'n2' -Project 'B' -Cwd 'cb' -Message 'm' -Color @(4, 5, 6) -Slot 1 -Ordinal 1
        Set-PendingCursor    -SessionId 'n2'
        Set-DisplayedSession -SessionId 'n2'

        # Mirrors notify-ha.ps1's actual call site: only call Set-RemainingLed
        # when the guard says to.
        if (Test-ShouldHandOffRing -Event 'clear' -OthersCount 2 -DisplayedSession 'n2' -SessionId 'x') {
            Set-RemainingLed -Connection @{ Url = 'http://fake' }
        }

        Should -Invoke -CommandName Invoke-HaLed -ModuleName RingDisplay -Times 0
        (Get-PendingState).cursor           | Should -Be 'n2'
        (Get-PendingState).displayedSession | Should -Be 'n2'
    }

    It 'end to end: resolving the displayed session hands off to the oldest remaining pending session' {
        Set-PendingSession -SessionId 'n1' -Project 'A' -Cwd 'ca' -Message 'm' -Color @(1, 2, 3) -Slot 0 -Ordinal 1
        $path = Join-Path $TestDrive 'pending.json'
        $raw = Get-Content $path -Raw | ConvertFrom-Json -AsHashtable
        $raw.sessions.n1.since = (Get-Date).AddMinutes(-10).ToString('o')
        $raw | ConvertTo-Json -Depth 6 | Set-Content $path
        Set-PendingCursor    -SessionId 'n2'
        Set-DisplayedSession -SessionId 'n2'

        if (Test-ShouldHandOffRing -Event 'clear' -OthersCount 1 -DisplayedSession 'n2' -SessionId 'n2') {
            Set-RemainingLed -Connection @{ Url = 'http://fake' }
        }

        Should -Invoke -CommandName Invoke-HaLed -ModuleName RingDisplay -Times 1 -ParameterFilter {
            ($Rgb -join ',') -eq '1,2,3' -and $Brightness -eq 255 -and -not $Flash
        }
        (Get-PendingState).cursor           | Should -Be 'n1'
        (Get-PendingState).displayedSession | Should -Be 'n1'
    }
}
