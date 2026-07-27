BeforeAll {
    # Register-PendingNotification calls into SessionColor.psm1 but
    # PendingState.psm1 deliberately does not import it itself (see the
    # comment at the top of PendingState.psm1) -- import it here, same as
    # ha-bridge.ps1/notify-ha.ps1 both do in production.
    Import-Module "$PSScriptRoot/SessionColor.psm1" -Force
    Import-Module "$PSScriptRoot/PendingState.psm1" -Force
}

Describe 'PendingState' {
    BeforeEach {
        $script:testStatePath = Join-Path $TestDrive 'pending.json'
        # $TestDrive is shared across every It in this Describe (Pester does
        # not recreate it per-test), so a leftover pending.json from a prior
        # It would otherwise silently leak state (extra sessions, a stale
        # cursor, etc.) into the next one. The original suite got away with
        # this because every existing test only ever asserted on keys it had
        # itself just written -- newer tests here (OthersCount counts,
        # "nothing else pending" cursor checks) need a genuinely empty file.
        if (Test-Path $script:testStatePath) { Remove-Item -Path $script:testStatePath -Force }
        Set-PendingStatePath -Path $script:testStatePath

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

    It 'treats a "sessions" value that is an array (not a dictionary) as empty rather than throwing' {
        # Cheap-minor fix, final review: {"sessions": []} previously passed
        # the old shape guard (it's non-null and the key exists), and a bare
        # JSON array deserialises via ConvertFrom-Json -AsHashtable to an
        # Object[], not an IDictionary -- so the very next .ContainsKey call
        # anywhere in this module would throw, wedging every future hook.
        # One bad write must never be able to do that (spec: "Corrupt or
        # old-format pending.json -- treated as empty rather than throwing").
        $path = Join-Path $TestDrive 'pending.json'
        '{ "sessions": [], "cursor": null }' | Set-Content $path
        { Get-PendingState } | Should -Not -Throw
        (Get-PendingState).sessions.Count | Should -Be 0
    }

    It 'tracks the displayed session and can clear it' {
        Set-DisplayedSession -SessionId 's7'
        (Get-PendingState).displayedSession | Should -Be 's7'
        Clear-DisplayedSession
        (Get-PendingState).displayedSession | Should -BeNullOrEmpty
    }

    It 'does NOT reset displayedSession when the named session is no longer in `sessions` -- unlike cursor, it must survive to let Invoke-IdleCheck detect the orphan' {
        # Final review Fix 3: a Notification can light the ring bright for a
        # session that is later cleared out by read-time expiry without ever
        # going through Clear-PendingSession. displayedSession has to keep
        # pointing at that now-gone session so the bridge's idle check can
        # notice the mismatch and turn the ring off -- if this getter nulled
        # it out first (as it does for `cursor`), that orphan would become
        # permanently undetectable and the ring would stay lit forever.
        Set-PendingSession -SessionId 's1' -Project 'p' -Cwd 'c' -Message 'm' -Color @(1, 2, 3) -Slot 0 -Ordinal 1
        Set-DisplayedSession -SessionId 's1'
        Clear-PendingSession -SessionId 's1'
        (Get-PendingState).displayedSession | Should -Be 's1'
    }

    It 'Register-PendingNotification assigns colour/ordinal, sets the cursor when nothing else was pending, and reports OthersCount' {
        $result = Register-PendingNotification -SessionId 's1' -Project 'HomeAssistant' -Cwd 'C:/git/HomeAssistant' -Message 'wants to run git push'
        $result.OthersCount | Should -Be 0

        $state = Get-PendingState
        $state.sessions.s1.project | Should -Be 'HomeAssistant'
        $state.sessions.s1.message | Should -Be 'wants to run git push'
        $state.sessions.s1.color   | Should -Not -BeNullOrEmpty
        $state.sessions.s1.ordinal | Should -Be 1
        $state.cursor              | Should -Be 's1'
    }

    It 'Register-PendingNotification does not move the cursor when another session is already pending, and reports the correct OthersCount' {
        Register-PendingNotification -SessionId 's1' -Project 'A' -Cwd 'C:/git/A' -Message 'm1' | Out-Null
        $result = Register-PendingNotification -SessionId 's2' -Project 'B' -Cwd 'C:/git/B' -Message 'm2'
        $result.OthersCount | Should -Be 1
        (Get-PendingState).cursor | Should -Be 's1'
    }

    It 'Register-PendingNotification nudges a colliding colour slot to the next free one' {
        Register-PendingNotification -SessionId 's1' -Project 'HomeAssistant' -Cwd 'C:/Users/darkf/git/HomeAssistant' -Message 'm1' | Out-Null
        Register-PendingNotification -SessionId 's2' -Project 'HomeAssistant2' -Cwd 'C:/Users/darkf/git/HomeAssistant' -Message 'm2' | Out-Null
        $state = Get-PendingState
        $state.sessions.s1.slot | Should -Not -Be $state.sessions.s2.slot
    }

    It 'Register-PendingNotification is idempotent for a session already pending -- does not reassign its colour, message, or cursor' {
        Register-PendingNotification -SessionId 's1' -Project 'A' -Cwd 'C:/git/A' -Message 'm1' | Out-Null
        $before = (Get-PendingState).sessions.s1.color
        $result = Register-PendingNotification -SessionId 's1' -Project 'A' -Cwd 'C:/git/A' -Message 'm2 should be ignored'
        (Get-PendingState).sessions.s1.color   | Should -Be $before
        (Get-PendingState).sessions.s1.message | Should -Be 'm1'
        (Get-PendingState).cursor              | Should -Be 's1'
        $result.OthersCount | Should -Be 0
    }

    It 'Register-PendingNotification does not let an entry with a missing slot spuriously block slot 0' {
        # Cheap-minor fix, final review (notify-ha.ps1:69 originally): a
        # bare $null slot value coerces to 0 under [int[]], marking slot 0
        # "taken" even though nothing actually holds it. Set-PendingSession's
        # -Slot is a Mandatory [int], so a legacy entry missing its slot
        # (e.g. hand-edited, or written by an older version) is simulated by
        # writing the JSON directly rather than through the setter.
        Set-PendingSession -SessionId 'legacy' -Project 'Legacy' -Cwd 'C:/legacy' -Message 'm' -Color @(1, 1, 1) -Slot 5 -Ordinal 1
        $path = Join-Path $TestDrive 'pending.json'
        $raw = Get-Content $path -Raw | ConvertFrom-Json -AsHashtable
        $raw.sessions.legacy.Remove('slot')
        $raw | ConvertTo-Json -Depth 6 | Set-Content $path

        # 'C:\git\proj3' is a path whose SHA256-derived preferred slot is
        # verified (independently, via SessionColor.psm1) to be 0 -- the
        # exact slot the coercion bug would have spuriously marked taken.
        $result = Register-PendingNotification -SessionId 's1' -Project 'proj3' -Cwd 'C:/git/proj3' -Message 'm1'
        $result.OthersCount | Should -Be 1
        (Get-PendingState).sessions.s1.slot | Should -Be 0
    }

    It 'Resolve-PendingSession clears the session, marks it active, and reports how many others remain pending' {
        Set-PendingSession -SessionId 's1' -Project 'A' -Cwd 'ca' -Message 'm' -Color @(1, 2, 3) -Slot 0 -Ordinal 1
        Set-PendingSession -SessionId 's2' -Project 'B' -Cwd 'cb' -Message 'm' -Color @(4, 5, 6) -Slot 1 -Ordinal 1

        $result = Resolve-PendingSession -SessionId 's1'

        $result.OthersCount | Should -Be 1
        $state = Get-PendingState
        $state.sessions.ContainsKey('s1') | Should -BeFalse
        $state.sessions.ContainsKey('s2') | Should -BeTrue
        $state.activeSession | Should -Be 's1'
        $state.activeSince   | Should -Not -BeNullOrEmpty
    }

    It 'Resolve-PendingSession reports zero remaining when it was the only pending session' {
        Set-PendingSession -SessionId 's1' -Project 'A' -Cwd 'ca' -Message 'm' -Color @(1, 2, 3) -Slot 0 -Ordinal 1
        $result = Resolve-PendingSession -SessionId 's1'
        $result.OthersCount | Should -Be 0
    }

    It 'Save-PendingState is atomic: unlocked concurrent reads never observe a torn/empty write' {
        # Final review Fix 4: Save-PendingState used to truncate-and-rewrite
        # the file in place. Get-PendingState deliberately does NOT take the
        # lock (only writers serialise against each other -- see
        # Invoke-WithPendingStateLock's comment), so an unlocked reader
        # landing mid-write could see invalid JSON and silently fall back to
        # an empty state, i.e. a reader could transiently believe nothing is
        # pending while a session is still waiting. The fix writes to a temp
        # file and [System.IO.File]::Replace's it into place, which is a
        # genuine atomic swap (verified empirically: Move-Item -Force was
        # tried FIRST and rejected -- it showed the destination transiently
        # MISSING in ~18% of concurrent checks under stress, which is not
        # atomic at all). This test seeds a session that is NEVER removed by
        # the background writer (it only ever adds/updates OTHER session
        # ids), so if any read ever silently loses it, something regressed.
        #
        # Write cadence here (~5ms between writes, a realistic-sized
        # message) is deliberately NOT an adversarial zero-delay firehose --
        # empirically, even Get-PendingState's retry-hardened reader (see
        # its own comment) cannot achieve a perfect 100% success rate
        # against a writer that NEVER pauses, because Windows' own file-
        # replace operation briefly blocks concurrent opens and an unbroken
        # stream of them can occasionally outlast any bounded retry budget.
        # That is an accepted, documented residual (degrades to the same
        # "treated as empty" fallback already established for corrupt
        # files), not something a real hook-firing pattern would ever
        # trigger -- a real hook writes once and exits. This test proves
        # the property that actually matters: under realistic concurrent
        # access, reads are reliably consistent, not that the reader can
        # survive an unrealistic adversarial write-storm.
        $statePath = Join-Path $TestDrive 'pending.json'
        # Explicit, test-local mutex name -- $script:MutexName inside the
        # module is not visible from here, and this must be the SAME name
        # the background job below uses so its writes are lock-serialised
        # against each other exactly as production hooks are.
        $mutexName = "Global\ClaudeVoicePendingStateTest_$([guid]::NewGuid().ToString('N'))"
        Set-PendingStateMutexName -Name $mutexName
        Set-PendingSession -SessionId 'seed' -Project 'p' -Cwd 'c' -Message 'm' -Color @(1, 2, 3) -Slot 0 -Ordinal 1

        $stopFile = Join-Path $TestDrive 'stop.flag'
        $writerJob = Start-Job -ScriptBlock {
            param($ModulePath, $StatePath, $MutexName, $StopFile)
            Import-Module $ModulePath -Force
            Set-PendingStatePath -Path $StatePath
            Set-PendingStateMutexName -Name $MutexName
            $msg = 'wants to run a fairly long shell command that needs approval ' * 5
            $i = 0
            while (-not (Test-Path $StopFile)) {
                # Best-effort: an occasional Windows file-locking collision
                # between the atomic swap and a concurrent (very briefly
                # open) reader handle is a transient hiccup, not a
                # correctness bug -- production callers already sit behind
                # notify-ha.ps1's top-level try/catch for exactly this kind
                # of rare I/O error. Swallowing it here just keeps the
                # stress loop running for the test's full window instead of
                # dying on the first hiccup.
                try {
                    Set-PendingSession -SessionId "writer$($i % 5)" -Project "p$i" -Cwd "c$i" -Message $msg -Color @(1, 2, 3) -Slot ($i % 16) -Ordinal 1
                } catch { }
                $i++
                Start-Sleep -Milliseconds 5
            }
        } -ArgumentList "$PSScriptRoot/PendingState.psm1", $statePath, $mutexName, $stopFile

        try {
            $deadline = (Get-Date).AddSeconds(5)
            $reads = 0
            while ((Get-Date) -lt $deadline) {
                # A transient "file in use" from the raw Windows handle-open
                # call is a different (and acceptable) failure mode than the
                # bug under test: it's a loud, catchable exception every
                # caller already handles (notify-ha.ps1/ha-bridge.ps1 both
                # wrap every state read in their own try/catch), not a
                # SILENT wrong answer. What this test must never see is a
                # successful read that silently reports an empty/torn state
                # -- so only a clean read counts as a `reads` sample.
                try { $state = Get-PendingState } catch { continue }
                $reads++
                $state.sessions.ContainsKey('seed') | Should -BeTrue -Because 'an atomic write must never be visible to an unlocked reader as a torn/empty file'
            }
            $reads | Should -BeGreaterThan 0 -Because 'the test is meaningless if it never actually raced a concurrent write'
        } finally {
            Set-Content -Path $stopFile -Value 'stop'
            $writerJob | Wait-Job -Timeout 15 | Out-Null
            $writerJob | Remove-Job -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Save-PendingState leaves no leftover temp file behind' {
        Set-PendingSession -SessionId 's1' -Project 'p' -Cwd 'c' -Message 'm' -Color @(1, 2, 3) -Slot 0 -Ordinal 1
        Get-ChildItem -Path $TestDrive -Filter 'pending.*.tmp' | Should -BeNullOrEmpty
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
