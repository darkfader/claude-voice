BeforeAll {
    Import-Module "$PSScriptRoot/PendingState.psm1" -Force
}

Describe 'PendingState' {
    BeforeEach {
        Set-PendingStatePath -Path (Join-Path $TestDrive 'pending.json')

        # Every test gets its own throwaway mutex. Without this the suite takes
        # the real 'Global\ClaudeVoicePendingState' that live Claude Code hooks
        # use, so a hook firing mid-run could block a test past its 5s timeout
        # (spurious 'Timed out' failures), and a test run could equally stall
        # real hooks. Observed in practice: consecutive full-suite runs giving
        # 6/6, 6/6, then 4/6.
        Set-PendingStateMutexName -Name "Global\ClaudeVoicePendingStateTest_$([guid]::NewGuid().ToString('N'))"
        Set-PendingStateExpiryHours -Hours 4
    }

    It 'returns empty state when no file exists yet' {
        $state = Get-PendingState
        $state.sessions.Count | Should -Be 0
        $state.cursor | Should -BeNullOrEmpty
        $state.activeSession | Should -BeNullOrEmpty
    }

    It 'adds a pending session with all its fields' {
        Set-PendingSession -SessionId 's1' -Project 'HomeAssistant' -Cwd 'C:/git/HomeAssistant' -Message 'fix bug' -Color @(255,0,0) -Slot 0 -Ordinal 1
        $s = (Get-PendingState).sessions.s1
        $s.project | Should -Be 'HomeAssistant'
        $s.cwd     | Should -Be 'C:/git/HomeAssistant'
        $s.message | Should -Be 'fix bug'
        $s.color   | Should -Be @(255,0,0)
        $s.slot    | Should -Be 0
        $s.ordinal | Should -Be 1
        $s.since   | Should -Not -BeNullOrEmpty
    }

    It 'clears a pending session' {
        Set-PendingSession -SessionId 's1' -Project 'p' -Cwd 'c' -Message 'm' -Color @(1,2,3) -Slot 0 -Ordinal 1
        Clear-PendingSession -SessionId 's1'
        (Get-PendingState).sessions.ContainsKey('s1') | Should -BeFalse
    }

    It 'clearing the cursor session resets the cursor' {
        Set-PendingSession -SessionId 's1' -Project 'p' -Cwd 'c' -Message 'm' -Color @(1,2,3) -Slot 0 -Ordinal 1
        Set-PendingCursor -SessionId 's1'
        Clear-PendingSession -SessionId 's1'
        (Get-PendingState).cursor | Should -BeNullOrEmpty
    }

    It 'clearing a different session leaves the cursor alone' {
        Set-PendingSession -SessionId 's1' -Project 'p' -Cwd 'c' -Message 'm' -Color @(1,2,3) -Slot 0 -Ordinal 1
        Set-PendingSession -SessionId 's2' -Project 'q' -Cwd 'd' -Message 'm' -Color @(4,5,6) -Slot 1 -Ordinal 1
        Set-PendingCursor -SessionId 's2'
        Clear-PendingSession -SessionId 's1'
        (Get-PendingState).cursor | Should -Be 's2'
    }

    It 'tracks the active session and can clear it' {
        Set-ActiveSession -SessionId 's9'
        $st = Get-PendingState
        $st.activeSession | Should -Be 's9'
        $st.activeSince   | Should -Not -BeNullOrEmpty
        Clear-ActiveSession
        (Get-PendingState).activeSession | Should -BeNullOrEmpty
    }

    It 'drops sessions older than the expiry window' {
        Set-PendingStateExpiryHours -Hours 4
        Set-PendingSession -SessionId 'old' -Project 'p' -Cwd 'c' -Message 'm' -Color @(1,2,3) -Slot 0 -Ordinal 1
        # Rewrite that entry's timestamp to 5 hours ago, bypassing the setter.
        $path = Join-Path $TestDrive 'pending.json'
        $raw = Get-Content $path -Raw | ConvertFrom-Json -AsHashtable
        $raw.sessions.old.since = (Get-Date).AddHours(-5).ToString('o')
        $raw | ConvertTo-Json -Depth 6 | Set-Content $path
        (Get-PendingState).sessions.ContainsKey('old') | Should -BeFalse
    }

    It 'keeps sessions inside the expiry window' {
        Set-PendingStateExpiryHours -Hours 4
        Set-PendingSession -SessionId 'fresh' -Project 'p' -Cwd 'c' -Message 'm' -Color @(1,2,3) -Slot 0 -Ordinal 1
        (Get-PendingState).sessions.ContainsKey('fresh') | Should -BeTrue
    }

    It 'treats an old account-shaped file as empty rather than throwing' {
        $path = Join-Path $TestDrive 'pending.json'
        '{ "accounts": { "personal": { "project": "x" } }, "cursor": null }' | Set-Content $path
        (Get-PendingState).sessions.Count | Should -Be 0
    }

    It 'throws when unable to acquire lock within timeout' {
        # This test's mutex is the unique throwaway one set in BeforeEach, so
        # holding it here cannot stall a real hook, and a real hook cannot stop
        # the background job from acquiring it.
        $mutexName = "Global\ClaudeVoicePendingStateTest_$([guid]::NewGuid().ToString('N'))"
        Set-PendingStateMutexName -Name $mutexName

        # Two file signals replace the original's blind `Start-Sleep 200ms`,
        # which was a race: Start-Job spawns a whole PowerShell process and
        # routinely needs longer than that, and if the job hadn't acquired yet
        # then Set-PendingAccount below would simply succeed and the assertion
        # would fail with a misleading 'Expected $true, but got $false'.
        $readyFile   = Join-Path $TestDrive 'lock-held.flag'
        $releaseFile = Join-Path $TestDrive 'lock-release.flag'

        $lockJob = Start-Job -ScriptBlock {
            param($MutexName, $ReadyFile, $ReleaseFile)
            $mutex = New-Object System.Threading.Mutex($false, $MutexName)
            if ($mutex.WaitOne(30000)) {
                try {
                    Set-Content -Path $ReadyFile -Value 'held'
                    # Hold until released, with a failsafe so a crashed test
                    # can never wedge this process indefinitely.
                    $deadline = (Get-Date).AddSeconds(60)
                    while (-not (Test-Path $ReleaseFile) -and (Get-Date) -lt $deadline) {
                        Start-Sleep -Milliseconds 50
                    }
                } finally {
                    # Explicit release, unlike the original's Stop-Job, which
                    # killed the holder mid-hold and left the mutex ABANDONED --
                    # the next WaitOne then throws AbandonedMutexException
                    # instead of returning, poisoning later runs.
                    $mutex.ReleaseMutex()
                }
            }
        } -ArgumentList $mutexName, $readyFile, $releaseFile

        try {
            $deadline = (Get-Date).AddSeconds(30)
            while (-not (Test-Path $readyFile) -and (Get-Date) -lt $deadline) {
                Start-Sleep -Milliseconds 50
            }
            (Test-Path $readyFile) | Should -BeTrue -Because 'the background job must actually hold the lock before the timeout assertion means anything'

            { Set-PendingSession -SessionId 'test' -Project 'p' -Cwd 'c' -Message 'm' -Color @(1,2,3) -Slot 0 -Ordinal 1 } |
                Should -Throw -ExpectedMessage '*Timed out*'
        } finally {
            Set-Content -Path $releaseFile -Value 'go'
            $lockJob | Wait-Job -Timeout 15 | Out-Null
            $lockJob | Remove-Job -Force -ErrorAction SilentlyContinue
        }
    }
}
