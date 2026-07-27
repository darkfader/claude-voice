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
