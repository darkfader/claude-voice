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
        Set-KnownExpiryHours -Hours 24
        Set-KnownIdleFadeHours -Hours 1
        Set-KnownHardExpiryHours -Hours 48
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
        Set-KnownExpiryHours -Hours 24
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
        Set-KnownExpiryHours -Hours 24
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

    It 'Save-PendingState is atomic: the destination file is never transiently missing under a concurrent write-storm' {
        # Final review Fix 4, then corrected in a LATER final-review pass.
        # Save-PendingState used to truncate-and-rewrite the file in place;
        # the first fix swapped that for [System.IO.File]::Replace (Win32
        # ReplaceFile). This test originally probed atomicity THROUGH
        # Get-PendingState (i.e. checked `$state.sessions.ContainsKey('seed')`
        # after a full read/retry/parse round trip) and passed -- but that
        # was under-powered: Get-PendingState's own bounded retry loop (see
        # its comment) repeatedly opens/reads the file, and that repeated
        # opening happens to phase-shift the reader out of the exact instant
        # ReplaceFile's rename-out/rename-in gap is open, masking the bug
        # entirely. A later, direct probe of [System.IO.File]::Exists in a
        # tight loop -- nothing else between the check and the writer --
        # found File.Replace is NOT actually atomic: the destination was
        # transiently MISSING in 5.45% and 5.71% of ~100k-sample runs. That
        # is exactly the "reader believes nothing is pending" bug this fix
        # exists to close, just hiding behind Get-PendingState's own
        # incidental timing. This test now probes File.Exists directly, the
        # same way that gap was actually found, so it would have failed
        # against File.Replace instead of passing.
        #
        # The current implementation is
        # [System.IO.File]::Move($tempPath, $script:StatePath, $true) --
        # MoveFileEx with MOVEFILE_REPLACE_EXISTING. (Move-Item -Force was
        # tried before File.Replace and rejected outright: ~18% missing
        # under the same style of stress test -- see Save-PendingState's
        # comment for the full history of all three attempts.)
        #
        # Write cadence here (~5ms between writes, a realistic-sized
        # message) is deliberately NOT an adversarial zero-delay firehose --
        # a real hook writes once and exits; this proves the property that
        # actually matters under realistic concurrent access.
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
            $probes = 0
            $misses = 0
            while ((Get-Date) -lt $deadline) {
                # Direct, unmediated existence check -- no Get-Content, no
                # retry loop, no JSON parse -- so nothing can phase-shift
                # this sampling window away from the writer's swap the way
                # Get-PendingState's own retry loop did in the original,
                # under-powered version of this test.
                $probes++
                if (-not [System.IO.File]::Exists($statePath)) { $misses++ }
            }
            $probes | Should -BeGreaterThan 0 -Because 'the test is meaningless if it never actually raced a concurrent write'
            # This is the actual measured result, reported so a future
            # reader (or CI log) doesn't have to trust an assertion blindly.
            Write-Host "Save-PendingState atomicity probe: $misses / $probes direct File.Exists misses"
            $misses | Should -Be 0 -Because "File.Move with MOVEFILE_REPLACE_EXISTING must never leave the destination transiently missing (measured $misses/$probes misses)"
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

Describe 'known session registry' {
    BeforeEach {
        $script:knownStatePath = Join-Path $TestDrive 'known.json'
        # Same reasoning as the Describe above: $TestDrive is shared across
        # every It, so a leftover file would leak known entries into the next
        # test and quietly break the ordinal/expiry assertions.
        if (Test-Path $script:knownStatePath) { Remove-Item -Path $script:knownStatePath -Force }
        Set-PendingStatePath -Path $script:knownStatePath
        Set-PendingStateMutexName -Name "Global\ClaudeVoiceKnownTest_$([guid]::NewGuid().ToString('N'))"
        Set-PendingStateExpiryHours -Hours 4
        Set-KnownExpiryHours -Hours 24
        Set-KnownIdleFadeHours -Hours 1
        Set-KnownHardExpiryHours -Hours 48
    }

    It 'registers a session with base colour, ordinal 1, and matching first/last seen' {
        Register-KnownSession -SessionId 's1' -Project 'HomeAssistant' -Cwd 'C:/Users/darkf/git/HomeAssistant'
        $k = (Get-PendingState).known['s1']
        $k.project     | Should -Be 'HomeAssistant'
        $k.cwd         | Should -Be 'C:/Users/darkf/git/HomeAssistant'
        $k.ordinal     | Should -Be 1
        $k.color.Count | Should -Be 3
        $k.firstSeen   | Should -Be $k.lastSeen
    }

    It 're-registering bumps lastSeen but preserves firstSeen, colour and ordinal' {
        Register-KnownSession -SessionId 's1' -Project 'HomeAssistant' -Cwd 'C:/git/HomeAssistant'
        $before = (Get-PendingState).known['s1']
        Start-Sleep -Milliseconds 20
        Register-KnownSession -SessionId 's1' -Project 'HomeAssistant' -Cwd 'C:/git/HomeAssistant'
        $after = (Get-PendingState).known['s1']
        $after.firstSeen | Should -Be $before.firstSeen
        $after.lastSeen  | Should -BeGreaterThan $before.lastSeen
        $after.color     | Should -Be $before.color
        $after.ordinal   | Should -Be $before.ordinal
    }

    It 'reassigns a fresh ringSlot/slot/colour when a faded session re-registers' {
        Register-KnownSession -SessionId 's1' -Project 'P' -Cwd 'C:/git/P'
        # 0.001h (3.6s) rather than the even tighter 0.0001h used elsewhere in
        # this file: this test does extra Get-PendingState/Register-KnownSession
        # calls AFTER the sleep, on the way to its final assertion, and each of
        # those costs real wall-clock time under Pester. A 0.36s fade window
        # left no margin -- the test's own follow-up reads could themselves
        # cross back over the threshold and re-fade the reactivated session,
        # observed empirically as ~50% flakiness. 3.6s comfortably outlasts
        # that overhead while still keeping the test fast.
        Set-KnownIdleFadeHours -Hours 0.001
        Start-Sleep -Milliseconds 4000
        $faded = (Get-PendingState).known['s1']
        $faded.ringSlot | Should -BeNullOrEmpty
        $faded.color    | Should -BeNullOrEmpty

        Register-KnownSession -SessionId 's1' -Project 'P' -Cwd 'C:/git/P'
        $reactivated = (Get-PendingState).known['s1']
        $reactivated.ringSlot | Should -Not -BeNullOrEmpty
        $reactivated.slot     | Should -Not -BeNullOrEmpty
        $reactivated.color    | Should -Not -BeNullOrEmpty
    }

    It 'does not collide ring slots when reactivating one of two known sessions' {
        Register-KnownSession -SessionId 's1' -Project 'P1' -Cwd 'C:/git/P1'
        Register-KnownSession -SessionId 's2' -Project 'P2' -Cwd 'C:/git/P2'
        # See the comment in the previous test -- 0.001h/4s instead of
        # 0.0001h/500ms for the same margin-against-flakiness reason.
        Set-KnownIdleFadeHours -Hours 0.001
        Start-Sleep -Milliseconds 4000
        [void](Get-PendingState)  # trigger the fade for both

        Register-KnownSession -SessionId 's1' -Project 'P1' -Cwd 'C:/git/P1'
        $state = Get-PendingState
        # s2 is still faded (never re-registered), s1 got a fresh slot that
        # must not collide with anything s2 might still be holding (it holds
        # nothing right now since both faded, but this guards the taken-slots
        # computation actually runs against live state, not a stale snapshot).
        $state.known['s1'].ringSlot | Should -Not -BeNullOrEmpty
    }

    It 'gives a second session in the same project ordinal 2' {
        Register-KnownSession -SessionId 's1' -Project 'HomeAssistant' -Cwd 'C:/git/HomeAssistant'
        Register-KnownSession -SessionId 's2' -Project 'HomeAssistant' -Cwd 'C:/git/HomeAssistant'
        (Get-PendingState).known['s2'].ordinal | Should -Be 2
    }

    It 'expires known entries with no transcript after the KNOWN backstop window' {
        # `known` no longer follows the pending expiry clock -- it has its own,
        # much longer one (24h), and that clock is only a backstop for entries
        # with no transcript path recorded. Retirement normally happens when
        # the transcript file disappears, not on a timer.
        Register-KnownSession -SessionId 's1' -Project 'Old' -Cwd 'C:/git/Old'
        Set-KnownExpiryHours -Hours 0.0001
        Start-Sleep -Milliseconds 500
        (Get-PendingState).known.ContainsKey('s1') | Should -BeFalse
    }

    It 'allows overriding the idle-fade and hard-expiry windows' {
        # No behavioural assertion here -- just proves the setters exist and
        # don't throw. Behaviour is covered by the fade/expiry tests below,
        # which rely on these setters to shrink the windows to milliseconds.
        { Set-KnownIdleFadeHours -Hours 0.0001 } | Should -Not -Throw
        { Set-KnownHardExpiryHours -Hours 0.0002 } | Should -Not -Throw
    }

    It 'does NOT expire a known entry on the pending clock' {
        # Regression guard: a pending session going stale after 4h must not
        # drag the known entry off the ring with it.
        Register-KnownSession -SessionId 's1' -Project 'Old' -Cwd 'C:/git/Old'
        Set-PendingStateExpiryHours -Hours 0.0001
        Start-Sleep -Milliseconds 500
        (Get-PendingState).known.ContainsKey('s1') | Should -BeTrue
    }

    It 'defaults known to an empty map for a state file written before it existed' {
        $legacy = Join-Path $TestDrive 'legacy.json'
        if (Test-Path $legacy) { Remove-Item -Path $legacy -Force }
        Set-PendingStatePath -Path $legacy
        '{"sessions":{},"cursor":null,"activeSession":null,"activeSince":null,"displayedSession":null}' |
            Set-Content -Path $legacy
        $state = Get-PendingState
        $state.ContainsKey('known') | Should -BeTrue
        $state.known.Count | Should -Be 0
    }

    It 'keeps a cursor that names a known but non-pending session' {
        Register-KnownSession -SessionId 's1' -Project 'HomeAssistant' -Cwd 'C:/git/HomeAssistant'
        Set-PendingCursor -SessionId 's1'
        (Get-PendingState).cursor | Should -Be 's1'
    }

    It 'clears a cursor that names neither a pending nor a known session' {
        Register-KnownSession -SessionId 's1' -Project 'HomeAssistant' -Cwd 'C:/git/HomeAssistant'
        Set-PendingCursor -SessionId 's1'
        Set-KnownExpiryHours -Hours 0.0001
        Start-Sleep -Milliseconds 500
        (Get-PendingState).cursor | Should -BeNullOrEmpty
    }

    It 'removes a known session at the hard-expiry window even if its transcript still exists' {
        $t = Join-Path $TestDrive "hardexpire-$([guid]::NewGuid().ToString('N')).jsonl"
        'x' | Set-Content -Path $t
        Register-KnownSession -SessionId 's1' -Project 'P' -Cwd 'C:/git/P' -TranscriptPath $t
        (Get-PendingState).known.ContainsKey('s1') | Should -BeTrue

        Set-KnownHardExpiryHours -Hours 0.0001
        Start-Sleep -Milliseconds 500
        (Get-PendingState).known.ContainsKey('s1') | Should -BeFalse
        # The transcript file itself is untouched -- only the known-session
        # entry is removed, not the underlying transcript.
        Test-Path -LiteralPath $t | Should -BeTrue
    }

    It 'keeps a known session alive while its transcript exists, within the hard-expiry window' {
        # A thread you left this morning is still resumable tonight, so it
        # stays on the ring even if KnownExpiryHours (the transcript-less
        # backstop) would have expired it -- but only up to the 48h hard
        # expiry, which is a separate, unconditional cutoff (see the test
        # above).
        $t = Join-Path $TestDrive "alive-$([guid]::NewGuid().ToString('N')).jsonl"
        'x' | Set-Content -Path $t
        Register-KnownSession -SessionId 's1' -Project 'P' -Cwd 'C:/git/P' -TranscriptPath $t
        Set-KnownExpiryHours -Hours 0.0001
        Start-Sleep -Milliseconds 500
        (Get-PendingState).known.ContainsKey('s1') | Should -BeTrue
    }

    It 'retires a known session once its transcript is deleted' {
        # Deletion is the real "this thread is gone" signal, and it applies
        # immediately -- no waiting out a clock.
        $t = Join-Path $TestDrive "gone-$([guid]::NewGuid().ToString('N')).jsonl"
        'x' | Set-Content -Path $t
        Register-KnownSession -SessionId 's1' -Project 'P' -Cwd 'C:/git/P' -TranscriptPath $t
        (Get-PendingState).known.ContainsKey('s1') | Should -BeTrue

        Remove-Item -Path $t -Force
        (Get-PendingState).known.ContainsKey('s1') | Should -BeFalse
    }

    It 'records the transcript path on registration and refreshes it' {
        $a = Join-Path $TestDrive "a-$([guid]::NewGuid().ToString('N')).jsonl"
        $b = Join-Path $TestDrive "b-$([guid]::NewGuid().ToString('N')).jsonl"
        'x' | Set-Content -Path $a
        'x' | Set-Content -Path $b
        Register-KnownSession -SessionId 's1' -Project 'P' -Cwd 'C:/git/P' -TranscriptPath $a
        (Get-PendingState).known['s1'].transcriptPath | Should -Be $a
        # Unlike title and ringSlot, this must track the live value -- a
        # stale path would retire a session that is still very much alive.
        Register-KnownSession -SessionId 's1' -Project 'P' -Cwd 'C:/git/P' -TranscriptPath $b
        (Get-PendingState).known['s1'].transcriptPath | Should -Be $b
    }

    It 'clears ringSlot/slot/color for a known session idle past the fade window, but keeps the entry' {
        $t = Join-Path $TestDrive "fade-$([guid]::NewGuid().ToString('N')).jsonl"
        'x' | Set-Content -Path $t
        Register-KnownSession -SessionId 's1' -Project 'P' -Cwd 'C:/git/P' -TranscriptPath $t
        $before = (Get-PendingState).known['s1']
        $before.ringSlot | Should -Not -BeNullOrEmpty
        $before.color    | Should -Not -BeNullOrEmpty

        Set-KnownIdleFadeHours -Hours 0.0001
        Start-Sleep -Milliseconds 500
        $after = (Get-PendingState).known['s1']
        $after.ringSlot | Should -BeNullOrEmpty
        $after.slot     | Should -BeNullOrEmpty
        $after.color    | Should -BeNullOrEmpty
        (Get-PendingState).known.ContainsKey('s1') | Should -BeTrue
    }

    It 'does not fade a known session inside the idle-fade window' {
        Register-KnownSession -SessionId 's1' -Project 'P' -Cwd 'C:/git/P'
        $after = (Get-PendingState).known['s1']
        $after.ringSlot | Should -Not -BeNullOrEmpty
        $after.color    | Should -Not -BeNullOrEmpty
    }

    It 'keeps slot and colour in sync after a fade -- both null or colour matches ConvertFrom-HueSlot of slot' {
        # Regression guard for the final-review cross-task bug: Get-PendingState
        # used to default ringSlot and recompute colour BEFORE checking whether
        # the entry was still within the idle-fade window. On a read that landed
        # while still faded, those defaulting blocks would reassign fresh
        # (collision-unaware) ringSlot/colour values that the fade check then
        # re-nulled a few lines later -- a wasteful no-op in the common case,
        # but `slot` has no equivalent defaulting block of its own, so a
        # differently-timed read could leave colour/ringSlot non-null while
        # slot stayed null, desyncing the two fields that collision avoidance
        # (which keys off `.slot`) depends on being consistent. With the fix,
        # the ringSlot-default and colour-recompute blocks are gated on the
        # same "is this entry currently faded" check the fade block itself
        # uses, so a still-faded entry can never have colour/ringSlot
        # repopulated while slot remains null.
        Register-KnownSession -SessionId 's1' -Project 'P' -Cwd 'C:/git/P'
        Set-KnownIdleFadeHours -Hours 0.0001
        Start-Sleep -Milliseconds 500
        $faded = (Get-PendingState).known['s1']
        $faded.slot     | Should -BeNullOrEmpty
        $faded.ringSlot | Should -BeNullOrEmpty
        $faded.color    | Should -BeNullOrEmpty

        # Read again -- with the bug, this second read would have repopulated
        # ringSlot/color (via the pre-existing defaulting blocks) while leaving
        # slot null, desyncing the two. With the fix, they must stay consistently
        # null together since the entry is still within the fade window.
        $stillFaded = (Get-PendingState).known['s1']
        $stillFaded.slot     | Should -BeNullOrEmpty
        $stillFaded.ringSlot | Should -BeNullOrEmpty
        $stillFaded.color    | Should -BeNullOrEmpty
    }

    It 'still resolves ringSlot and colour normally for a legitimately-missing (not faded) entry' {
        # Strengthens the gate above by proving it is scoped correctly: the
        # ringSlot-default / colour-recompute blocks must still fire for an
        # entry that is NOT currently faded but genuinely has a missing/
        # invalid ringSlot or colour (e.g. a legacy entry written before those
        # fields existed). Simulate that by registering normally (not faded)
        # then blanking ringSlot/color directly, bypassing the fade path.
        Register-KnownSession -SessionId 's1' -Project 'P' -Cwd 'C:/git/P'
        $raw = Get-Content -Path $script:knownStatePath -Raw | ConvertFrom-Json -AsHashtable
        $raw.known['s1'].ringSlot = $null
        $raw.known['s1'].color    = $null
        $raw | ConvertTo-Json -Depth 5 | Set-Content -Path $script:knownStatePath

        $after = (Get-PendingState).known['s1']
        $after.ringSlot | Should -Not -BeNullOrEmpty
        $after.color    | Should -Not -BeNullOrEmpty
        ($after.color -join ',') | Should -Be ((ConvertFrom-HueSlot -Slot $after.slot) -join ',')
    }

    It 'does not fade a working session whose transcript is still being written past the idle-fade window' {
        # A single long-running turn can leave lastSeen (hook-driven) hours
        # stale while the session is genuinely still active -- the transcript
        # file is still growing, which is the real liveness signal for this
        # case. Simulated here by touching the transcript again AFTER the
        # fade window has already elapsed relative to registration.
        $t = Join-Path $TestDrive "working-live-$([guid]::NewGuid().ToString('N')).jsonl"
        'x' | Set-Content -Path $t
        Register-KnownSession -SessionId 's1' -Project 'P' -Cwd 'C:/git/P' -Activity 'working' -TranscriptPath $t
        Set-KnownIdleFadeHours -Hours 0.0001
        Start-Sleep -Milliseconds 300
        'still writing' | Add-Content -Path $t
        Start-Sleep -Milliseconds 50

        $after = (Get-PendingState).known['s1']
        $after.ringSlot | Should -Not -BeNullOrEmpty
        $after.color    | Should -Not -BeNullOrEmpty
    }

    It 'still fades a working session whose transcript has ALSO gone stale (crashed mid-turn)' {
        # Distinguishes "genuinely still running" from "orphaned mid-turn" --
        # the entire point of using transcript mtime is that a crashed
        # session's transcript stops updating too, so it must not be exempted
        # from the fade forever just because activity is stuck on 'working'.
        $t = Join-Path $TestDrive "working-crashed-$([guid]::NewGuid().ToString('N')).jsonl"
        'x' | Set-Content -Path $t
        Register-KnownSession -SessionId 's1' -Project 'P' -Cwd 'C:/git/P' -Activity 'working' -TranscriptPath $t
        Set-KnownIdleFadeHours -Hours 0.0001
        Start-Sleep -Milliseconds 500

        $after = (Get-PendingState).known['s1']
        $after.ringSlot | Should -BeNullOrEmpty
        $after.color    | Should -BeNullOrEmpty
    }
}

Describe 'known session colour distinctness' {
    BeforeEach {
        $script:distinctPath = Join-Path $TestDrive 'distinct.json'
        if (Test-Path $script:distinctPath) { Remove-Item -Path $script:distinctPath -Force }
        Set-PendingStatePath -Path $script:distinctPath
        Set-PendingStateMutexName -Name "Global\ClaudeVoiceDistinctTest_$([guid]::NewGuid().ToString('N'))"
        Set-PendingStateExpiryHours -Hours 4
        Set-KnownExpiryHours -Hours 24
        Set-KnownIdleFadeHours -Hours 1
        Set-KnownHardExpiryHours -Hours 48
    }

    It 'gives two sessions in the SAME folder different colours' {
        # The dial identifies the selected session by ring colour alone, so
        # same-folder siblings sharing a colour makes the whole feature
        # unreadable. Regression guard for exactly that.
        Register-KnownSession -SessionId 's1' -Project 'HomeAssistant' -Cwd 'C:/git/HomeAssistant'
        Register-KnownSession -SessionId 's2' -Project 'HomeAssistant' -Cwd 'C:/git/HomeAssistant'
        $k = (Get-PendingState).known
        $k['s1'].slot | Should -Not -Be $k['s2'].slot
        ($k['s1'].color -join ',') | Should -Not -Be ($k['s2'].color -join ',')
    }

    It 'still gives the first session of a project its stable base colour' {
        # Stability across restarts was an explicit requirement: the FIRST
        # session in a project must keep the path-derived colour, and only
        # siblings get nudged off it.
        $base = ConvertFrom-HueSlot -Slot (Resolve-SessionColorSlot -ProjectPath 'C:/git/HomeAssistant')
        Register-KnownSession -SessionId 's1' -Project 'HomeAssistant' -Cwd 'C:/git/HomeAssistant'
        ((Get-PendingState).known['s1'].color -join ',') | Should -Be ($base -join ',')
    }

    It 'gives three same-folder sessions three distinct colours' {
        Register-KnownSession -SessionId 's1' -Project 'P' -Cwd 'C:/git/P'
        Register-KnownSession -SessionId 's2' -Project 'P' -Cwd 'C:/git/P'
        Register-KnownSession -SessionId 's3' -Project 'P' -Cwd 'C:/git/P'
        $k = (Get-PendingState).known
        @($k['s1'].slot, $k['s2'].slot, $k['s3'].slot) | Select-Object -Unique |
            Should -HaveCount 3
    }
}

Describe 'ring slot and activity on known sessions' {
    BeforeEach {
        $script:ringPath = Join-Path $TestDrive 'ring.json'
        if (Test-Path $script:ringPath) { Remove-Item -Path $script:ringPath -Force }
        Set-PendingStatePath -Path $script:ringPath
        Set-PendingStateMutexName -Name "Global\ClaudeVoiceRingTest_$([guid]::NewGuid().ToString('N'))"
        Set-PendingStateExpiryHours -Hours 4
        Set-KnownExpiryHours -Hours 24
        Set-KnownIdleFadeHours -Hours 1
        Set-KnownHardExpiryHours -Hours 48
    }

    It 'assigns a ringSlot and records activity' {
        Register-KnownSession -SessionId 's1' -Project 'P' -Cwd 'C:/git/P' -Activity 'working'
        $k = (Get-PendingState).known['s1']
        $k.ringSlot      | Should -BeGreaterOrEqual 0
        $k.ringSlot      | Should -BeLessOrEqual 11
        $k.activity      | Should -Be 'working'
        $k.activitySince | Should -Not -BeNullOrEmpty
    }

    It 'gives two same-folder sessions different ring slots' {
        Register-KnownSession -SessionId 's1' -Project 'P' -Cwd 'C:/git/P' -Activity 'idle'
        Register-KnownSession -SessionId 's2' -Project 'P' -Cwd 'C:/git/P' -Activity 'idle'
        $k = (Get-PendingState).known
        $k['s1'].ringSlot | Should -Not -Be $k['s2'].ringSlot
    }

    It 'keeps the same ringSlot when a session re-registers' {
        Register-KnownSession -SessionId 's1' -Project 'P' -Cwd 'C:/git/P' -Activity 'working'
        $first = (Get-PendingState).known['s1'].ringSlot
        Register-KnownSession -SessionId 's1' -Project 'P' -Cwd 'C:/git/P' -Activity 'idle'
        (Get-PendingState).known['s1'].ringSlot | Should -Be $first
    }

    It 'updates activity and its timestamp on re-registration' {
        Register-KnownSession -SessionId 's1' -Project 'P' -Cwd 'C:/git/P' -Activity 'working'
        $before = (Get-PendingState).known['s1'].activitySince
        Start-Sleep -Milliseconds 20
        Register-KnownSession -SessionId 's1' -Project 'P' -Cwd 'C:/git/P' -Activity 'attention'
        $after = (Get-PendingState).known['s1']
        $after.activity      | Should -Be 'attention'
        $after.activitySince | Should -BeGreaterThan $before
    }

    It 'defaults activity to idle for a state file written before the field existed' {
        $legacy = Join-Path $TestDrive 'legacy-ring.json'
        Set-PendingStatePath -Path $legacy
        # firstSeen/lastSeen are derived from Get-Date (comfortably inside
        # the 4h expiry window set in BeforeEach) rather than a fixed
        # absolute literal. A hardcoded timestamp would eventually age past
        # the cutoff and Get-PendingState's expiry loop would remove this
        # entry before the defaulting code -- or the assertions -- ever ran,
        # making the test fail spuriously (and permanently) once real time
        # caught up to the literal. Found in review.
        # Kept at 30 minutes (rather than 1h+) so this stays inside the
        # KnownIdleFadeHours default too -- this test is about the legacy
        # activity default, not idle-fade, so it shouldn't be coupled to
        # that cutoff.
        $recentIso = (Get-Date).AddMinutes(-30).ToString('o')
        ('{{"sessions":{{}},"known":{{"old":{{"project":"P","cwd":"C:/git/P","firstSeen":"{0}","lastSeen":"{0}"}}}},"cursor":null,"activeSession":null,"activeSince":null,"displayedSession":null}}' -f $recentIso) |
            Set-Content -Path $legacy
        $k = (Get-PendingState).known['old']
        $k.activity | Should -Be 'idle'
        $k.ringSlot | Should -BeGreaterOrEqual 0
    }
}
