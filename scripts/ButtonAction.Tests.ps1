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

    It 'long_press with a stale cursor and multiple pending accounts does nothing' {
        # Cursor points at an account no longer pending (e.g. it was cleared),
        # and there's more than one candidate, so it can't be auto-resolved
        # the way a single pending account can be. Distinct from the
        # no-cursor-at-all case covered below.
        $a = Get-ButtonAction -EventType 'long_press' -PendingAccounts @{ personal = @{}; work = @{} } -Cursor 'someone-else'
        $a.Action | Should -Be 'none'
    }

    It 'long_press with no cursor but exactly one pending account confirms that account' {
        $a = Get-ButtonAction -EventType 'long_press' -PendingAccounts @{ personal = @{} } -Cursor $null
        $a.Action | Should -Be 'confirm'
        $a.Account | Should -Be 'personal'
    }

    It 'long_press with no cursor and two pending accounts still does nothing' {
        $a = Get-ButtonAction -EventType 'long_press' -PendingAccounts @{ personal = @{}; work = @{} } -Cursor $null
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
