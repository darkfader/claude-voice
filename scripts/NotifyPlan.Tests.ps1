# claude-voice/scripts/NotifyPlan.Tests.ps1
BeforeAll { Import-Module "$PSScriptRoot/NotifyPlan.psm1" -Force }

Describe 'Get-NotifyPlan' {
    It 'first notification takes the ring: flash then solid bright, and speaks' {
        $p = Get-NotifyPlan -Event notification -DisplayName 'HomeAssistant' -Message 'needs a decision' -Muted $false -OtherPendingCount 0
        $p.Led.Action | Should -Be 'set'
        $p.Led.Bright | Should -BeTrue
        $p.Led.Flash  | Should -BeTrue
        $p.Sound      | Should -Be 'announce'
        $p.AnnounceText | Should -Be 'HomeAssistant needs input: needs a decision'
    }

    It 'first notification while muted: same ring, chime instead of speech' {
        $p = Get-NotifyPlan -Event notification -DisplayName 'HomeAssistant' -Message 'x' -Muted $true -OtherPendingCount 0
        $p.Led.Action | Should -Be 'set'
        $p.Sound      | Should -Be 'chime'
    }

    It 'second notification chimes only and must not touch the ring' {
        $p = Get-NotifyPlan -Event notification -DisplayName 'other' -Message 'x' -Muted $false -OtherPendingCount 1
        $p.Led.Action | Should -Be 'none'
        $p.Sound      | Should -Be 'chime'
        $p.AnnounceText | Should -Be ''
    }

    It 'stop: solid dim, chime, no speech' {
        $p = Get-NotifyPlan -Event stop -DisplayName 'HomeAssistant' -Muted $false -OtherPendingCount 0
        $p.Led.Action | Should -Be 'set'
        $p.Led.Bright | Should -BeFalse
        $p.Led.Flash  | Should -BeFalse
        $p.Sound      | Should -Be 'chime'
    }

    It 'stop with others pending returns Led.Action none for ITS OWN colour -- ring hand-off to the oldest remaining session is driven by notify-ha.ps1 (Set-RemainingLed), not by this pure function' {
        # Final review Fix 2: an earlier version of this test was titled
        # "stop must not steal the ring from a pending session" and was read
        # as licence to leave the ring showing a resolved session forever
        # when others were still pending -- spec rule 3 (Resolved) requires
        # the ring MOVE to the oldest remaining pending session. That
        # hand-off is implemented in notify-ha.ps1 via the shared
        # RingDisplay.psm1, not here: Get-NotifyPlan has no notion of
        # *other* sessions' colours and stays pure, so 'none' only means
        # "don't show THIS session's own colour" -- it is not a promise that
        # nothing about the ring changes.
        $p = Get-NotifyPlan -Event stop -DisplayName 'HomeAssistant' -Muted $false -OtherPendingCount 1
        $p.Led.Action | Should -Be 'none'
        $p.Sound      | Should -Be 'chime'
    }

    It 'clear becomes the DIM ambient indicator, not off' {
        # clear == the UserPromptSubmit hook == "you are now actively working
        # in this session". Turning the ring off here would mean the ambient
        # indicator never appears at all. Only the idle timeout turns it off.
        $p = Get-NotifyPlan -Event clear -DisplayName 'HomeAssistant' -Muted $false -OtherPendingCount 0
        $p.Led.Action | Should -Be 'set'
        $p.Led.Bright | Should -BeFalse
        $p.Led.Flash  | Should -BeFalse
        $p.Sound      | Should -Be 'none'
    }

    It 'clear with others pending returns Led.Action none for ITS OWN colour -- ring hand-off to the oldest remaining session is driven by notify-ha.ps1 (Set-RemainingLed), not by this pure function' {
        # Final review Fix 2: this test used to be titled "clear leaves the
        # ring alone when another session is still pending", which pinned
        # the wrong system-level behaviour -- replying (the 'clear' event)
        # is the most common resolution path, and spec rule 3 requires the
        # ring move to the oldest remaining pending session, not stay on the
        # one that just got replied to. See the 'stop' test above: same
        # reasoning applies here. This function's contract is unchanged and
        # correct (it never had visibility into other sessions' colours);
        # only the test's claim about what happens system-wide was wrong.
        $p = Get-NotifyPlan -Event clear -DisplayName 'HomeAssistant' -Muted $false -OtherPendingCount 1
        $p.Led.Action | Should -Be 'none'
    }
}
