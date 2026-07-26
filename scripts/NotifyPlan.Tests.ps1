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

    It 'stop must not steal the ring from a pending session' {
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

    It 'clear leaves the ring alone when another session is still pending' {
        $p = Get-NotifyPlan -Event clear -DisplayName 'HomeAssistant' -Muted $false -OtherPendingCount 1
        $p.Led.Action | Should -Be 'none'
    }
}
