# claude-voice/scripts/RingState.Tests.ps1
BeforeAll {
    Import-Module "$PSScriptRoot/RingState.psm1" -Force
}

Describe 'Get-RingStateString' {
    BeforeEach {
        $script:now = [datetime]'2026-07-28T12:00:00+02:00'
        $script:mk = {
            param($slot, $rgb, $activity, $sinceMinutesAgo = 1)
            @{
                ringSlot      = $slot
                color         = $rgb
                activity      = $activity
                activitySince = $script:now.AddMinutes(-1 * $sinceMinutesAgo).ToString('o')
                lastSeen      = $script:now.AddMinutes(-1 * $sinceMinutesAgo).ToString('o')
            }
        }
    }

    It 'returns an empty string when nothing is known' {
        Get-RingStateString -KnownSessions @{} -Now $script:now | Should -Be ''
    }

    It 'encodes slot, colour and state' {
        $k = @{ a = (& $script:mk 3 @(223,255,0) 'working') }
        Get-RingStateString -KnownSessions $k -Now $script:now | Should -Be '3,dfff00,w'
    }

    It 'pads colour components to two hex digits' {
        $k = @{ a = (& $script:mk 0 @(0,10,255) 'idle') }
        Get-RingStateString -KnownSessions $k -Now $script:now | Should -Be '0,000aff,i'
    }

    It 'joins several threads with semicolons, ordered by slot' {
        $k = @{
            b = (& $script:mk 7 @(128,255,0) 'idle')
            a = (& $script:mk 3 @(223,255,0) 'working')
        }
        Get-RingStateString -KnownSessions $k -Now $script:now | Should -Be '3,dfff00,w;7,80ff00,i'
    }

    It 'marks the cursor session as selected' {
        $k = @{ a = (& $script:mk 3 @(223,255,0) 'idle') }
        Get-RingStateString -KnownSessions $k -Cursor 'a' -Now $script:now | Should -Be '3,dfff00,s'
    }

    It 'lets attention outrank selected' {
        # A thread that wants you must never be demoted to merely selected.
        $k = @{ a = (& $script:mk 3 @(223,255,0) 'attention') }
        Get-RingStateString -KnownSessions $k -Cursor 'a' -Now $script:now | Should -Be '3,dfff00,a'
    }

    It 'marks the arriving session with A' {
        $k = @{ a = (& $script:mk 3 @(223,255,0) 'attention') }
        Get-RingStateString -KnownSessions $k -ArrivingSessionId 'a' -Now $script:now |
            Should -Be '3,dfff00,A'
    }

    It 'expires working to idle after the timeout' {
        # A crashed terminal never fires Stop, so without this the dot orbits
        # forever.
        $k = @{ a = (& $script:mk 3 @(223,255,0) 'working' 31) }
        Get-RingStateString -KnownSessions $k -Now $script:now -WorkingExpiryMinutes 30 |
            Should -Be '3,dfff00,i'
    }

    It 'keeps working inside the timeout' {
        $k = @{ a = (& $script:mk 3 @(223,255,0) 'working' 29) }
        Get-RingStateString -KnownSessions $k -Now $script:now -WorkingExpiryMinutes 30 |
            Should -Be '3,dfff00,w'
    }

    It 'does not expire attention, only working' {
        # Something waiting on you stays waiting however long you ignore it.
        $k = @{ a = (& $script:mk 3 @(223,255,0) 'attention' 120) }
        Get-RingStateString -KnownSessions $k -Now $script:now -WorkingExpiryMinutes 30 |
            Should -Be '3,dfff00,a'
    }

    It 'treats an unparseable activitySince as already expired' {
        # A thread we cannot date is a thread we cannot claim is still
        # working -- fail safe the same way the crashed-terminal case does.
        $k = @{ a = @{
            ringSlot      = 3
            color         = @(223,255,0)
            activity      = 'working'
            activitySince = 'not-a-date'
            lastSeen      = $script:now.ToString('o')
        } }
        Get-RingStateString -KnownSessions $k -Now $script:now -WorkingExpiryMinutes 30 |
            Should -Be '3,dfff00,i'
    }

    It 'treats a missing activitySince as already expired' {
        $k = @{ a = @{
            ringSlot = 3
            color    = @(223,255,0)
            activity = 'working'
            lastSeen = $script:now.ToString('o')
        } }
        Get-RingStateString -KnownSessions $k -Now $script:now -WorkingExpiryMinutes 30 |
            Should -Be '3,dfff00,i'
    }

    It 'pads a short colour array to a full six-digit hex field' {
        $k = @{ a = @{
            ringSlot      = 3
            color         = @(255,0)
            activity      = 'idle'
            activitySince = $script:now.ToString('o')
            lastSeen      = $script:now.ToString('o')
        } }
        Get-RingStateString -KnownSessions $k -Now $script:now | Should -Be '3,ff0000,i'
    }

    It 'treats a missing colour as black rather than a short hex field' {
        $k = @{ a = @{
            ringSlot      = 3
            activity      = 'idle'
            activitySince = $script:now.ToString('o')
            lastSeen      = $script:now.ToString('o')
        } }
        Get-RingStateString -KnownSessions $k -Now $script:now | Should -Be '3,000000,i'
    }

    It 'caps at twelve threads, dropping the least interesting' {
        $k = @{}
        # 12 idle threads seen recently, plus one that needs attention but
        # was last touched longest ago of all thirteen. Only a cap that
        # weighs priority ahead of recency keeps it -- a naive recency-only
        # cap would drop it first, since it is the oldest entry here.
        foreach ($i in 0..11) { $k["idle$i"] = (& $script:mk $i @(1,2,3) 'idle' $i) }
        $k['urgent'] = (& $script:mk 5 @(255,0,0) 'attention' 1000)
        $s = Get-RingStateString -KnownSessions $k -Now $script:now
        @($s -split ';').Count | Should -Be 12
        $s | Should -Match 'ff0000,a'
    }

    It 'prefers attention, then selected, then working, then recent idle' {
        $k = @{
            old  = (& $script:mk 0 @(1,1,1) 'idle' 300)
            new  = (& $script:mk 1 @(2,2,2) 'idle' 1)
            work = (& $script:mk 2 @(3,3,3) 'working')
            sel  = (& $script:mk 4 @(5,5,5) 'idle')
            att  = (& $script:mk 3 @(4,4,4) 'attention')
        }
        # Cap to two, with a cursor on 'sel', so priority alone decides
        # which two survive: attention and selected must outrank working
        # outright, not just idle -- the 'selected' tier is only genuinely
        # exercised here because -Cursor is passed.
        $s = Get-RingStateString -KnownSessions $k -Cursor 'sel' -Now $script:now -MaxThreads 2
        $s | Should -Match '040404,a'
        $s | Should -Match '050505,s'
        $s | Should -Not -Match '030303'
        $s | Should -Not -Match '020202'
        $s | Should -Not -Match '010101'
    }

    It 'stays within the 255-character text limit at full capacity' {
        $k = @{}
        foreach ($i in 0..11) { $k["s$i"] = (& $script:mk $i @(255,255,255) 'working') }
        (Get-RingStateString -KnownSessions $k -Now $script:now).Length |
            Should -BeLessOrEqual 255
    }
}
