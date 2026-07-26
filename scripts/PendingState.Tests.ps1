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
    }

    It 'returns an empty state when no file exists yet' {
        $state = Get-PendingState
        $state.accounts.Count | Should -Be 0
        $state.cursor | Should -BeNullOrEmpty
    }

    It 'adds a pending account with project and message' {
        Set-PendingAccount -Account 'personal' -Project 'HomeAssistant' -Message 'fix bug'
        $state = Get-PendingState
        $state.accounts.personal.project | Should -Be 'HomeAssistant'
        $state.accounts.personal.message | Should -Be 'fix bug'
        $state.accounts.personal.since | Should -Not -BeNullOrEmpty
    }

    It 'clears a pending account' {
        Set-PendingAccount -Account 'work' -Project 'sownet-app' -Message 'review PR'
        Clear-PendingAccount -Account 'work'
        (Get-PendingState).accounts.ContainsKey('work') | Should -BeFalse
    }

    It 'clearing the cursor account resets the cursor' {
        Set-PendingAccount -Account 'personal' -Project 'p' -Message 'm'
        Set-PendingCursor -Account 'personal'
        Clear-PendingAccount -Account 'personal'
        (Get-PendingState).cursor | Should -BeNullOrEmpty
    }

    It 'clearing a different account leaves the cursor alone' {
        Set-PendingAccount -Account 'personal' -Project 'p' -Message 'm'
        Set-PendingAccount -Account 'work' -Project 'w' -Message 'm2'
        Set-PendingCursor -Account 'work'
        Clear-PendingAccount -Account 'personal'
        (Get-PendingState).cursor | Should -Be 'work'
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

            { Set-PendingAccount -Account 'test' -Project 'p' -Message 'm' } |
                Should -Throw -ExpectedMessage '*Timed out*'
        } finally {
            Set-Content -Path $releaseFile -Value 'go'
            $lockJob | Wait-Job -Timeout 15 | Out-Null
            $lockJob | Remove-Job -Force -ErrorAction SilentlyContinue
        }
    }
}
