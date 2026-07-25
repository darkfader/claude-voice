# claude-voice/scripts/NotifyPlan.Tests.ps1
BeforeAll {
    Import-Module "$PSScriptRoot/NotifyPlan.psm1" -Force
}

Describe 'Get-NotifyPlan' {
    It 'stop event: solid LED, chime only, no speech' {
        $plan = Get-NotifyPlan -Event 'stop' -Account 'personal' -Message '' -Muted $false
        $plan.Led.Account | Should -Be 'personal'
        $plan.Led.Pulse | Should -BeFalse
        $plan.Sound | Should -Be 'chime'
    }

    It 'notification event, not muted: pulsing LED, spoken announcement' {
        $plan = Get-NotifyPlan -Event 'notification' -Account 'work' -Message 'needs a decision' -Muted $false
        $plan.Led.Account | Should -Be 'work'
        $plan.Led.Pulse | Should -BeTrue
        $plan.Sound | Should -Be 'announce'
        $plan.AnnounceText | Should -BeLike '*work*needs a decision*'
    }

    It 'notification event, muted: pulsing LED, chime only, no speech' {
        $plan = Get-NotifyPlan -Event 'notification' -Account 'work' -Message 'needs a decision' -Muted $true
        $plan.Led.Pulse | Should -BeTrue
        $plan.Sound | Should -Be 'chime'
    }

    It 'clear event: LED off, no sound' {
        $plan = Get-NotifyPlan -Event 'clear' -Account 'personal' -Message '' -Muted $false
        $plan.Led.Off | Should -BeTrue
        $plan.Sound | Should -Be 'none'
    }
}
