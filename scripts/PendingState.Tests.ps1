BeforeAll {
    Import-Module "$PSScriptRoot/PendingState.psm1" -Force
}

Describe 'PendingState' {
    BeforeEach {
        Set-PendingStatePath -Path (Join-Path $TestDrive 'pending.json')
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
}
