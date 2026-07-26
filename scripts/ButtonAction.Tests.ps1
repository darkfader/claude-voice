# claude-voice/scripts/ButtonAction.Tests.ps1
BeforeAll {
    Import-Module "$PSScriptRoot/ButtonAction.psm1" -Force
}

Describe 'Get-ButtonAction' {
    It 'double_press with nothing pending says nothing pending' {
        $a = Get-ButtonAction -EventType 'double_press' -PendingAccounts @{} -Cursor $null
        $a.Action | Should -Be 'none'
        $a.Speak | Should -Be 'Nothing pending'
    }

    It 'double_press cycles from no cursor to the first account alphabetically' {
        $pending = @{ work = @{}; personal = @{} }
        $a = Get-ButtonAction -EventType 'double_press' -PendingAccounts $pending -Cursor $null
        $a.Action | Should -Be 'select'
        $a.Account | Should -Be 'personal'
    }

    It 'double_press wraps around from the last account to the first' {
        $pending = @{ work = @{}; personal = @{} }
        $a = Get-ButtonAction -EventType 'double_press' -PendingAccounts $pending -Cursor 'work'
        $a.Account | Should -Be 'personal'
    }

    It 'long_press with a selected cursor confirms that account' {
        $pending = @{ personal = @{} }
        $a = Get-ButtonAction -EventType 'long_press' -PendingAccounts $pending -Cursor 'personal'
        $a.Action | Should -Be 'confirm'
        $a.Account | Should -Be 'personal'
    }

    It 'long_press with no cursor selected does nothing' {
        $a = Get-ButtonAction -EventType 'long_press' -PendingAccounts @{ personal = @{} } -Cursor $null
        $a.Action | Should -Be 'none'
    }

    It 'triple_press dismisses the selected account' {
        $pending = @{ personal = @{} }
        $a = Get-ButtonAction -EventType 'triple_press' -PendingAccounts $pending -Cursor 'personal'
        $a.Action | Should -Be 'dismiss'
        $a.Account | Should -Be 'personal'
    }

    It 'easter_egg_press always does nothing' {
        $a = Get-ButtonAction -EventType 'easter_egg_press' -PendingAccounts @{ personal = @{} } -Cursor 'personal'
        $a.Action | Should -Be 'none'
    }
}
