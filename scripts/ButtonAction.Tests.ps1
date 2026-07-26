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
        $a.Action | Should -Be 'focus'
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
        $a.Action | Should -Be 'focus'
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

Describe 'Get-DialCycleTarget' {
    It 'advances from no cursor to the first account alphabetically' {
        Get-DialCycleTarget -PendingAccounts @{ work = @{}; personal = @{} } -Cursor $null | Should -Be 'personal'
    }

    It 'wraps around from the last account to the first' {
        Get-DialCycleTarget -PendingAccounts @{ work = @{}; personal = @{} } -Cursor 'work' | Should -Be 'personal'
    }

    It 'returns $null when nothing is pending' {
        Get-DialCycleTarget -PendingAccounts @{} -Cursor $null | Should -BeNullOrEmpty
    }

    It 'advances through the middle of a three-account list' {
        $pending = @{ alpha = @{}; bravo = @{}; charlie = @{} }
        Get-DialCycleTarget -PendingAccounts $pending -Cursor 'alpha' | Should -Be 'bravo'
    }

    It 'treats a stale cursor (no longer pending) as if starting from the top' {
        $pending = @{ work = @{}; personal = @{} }
        Get-DialCycleTarget -PendingAccounts $pending -Cursor 'someone-else' | Should -Be 'personal'
    }

    It 'with exactly one pending account, keeps returning that same account no matter the cursor' {
        # Final review (Fix 1): this is the single-account case the existing
        # 0/2/3-account tests never covered. Get-DialCycleTarget itself has
        # no special-case for count -eq 1 -- both a $null cursor (index -1,
        # wraps to names[0]) and a cursor already equal to names[0]
        # ((0 + 1) % 1 = 0) land back on the same lone account. That's
        # correct behavior for this pure function, but calling it
        # unconditionally on every dial detent (as ha-bridge.ps1's
        # Invoke-DialRotationEvent used to) would re-announce/re-pulse the
        # same account forever on a single ordinary volume/hue turn -- which
        # is why ha-bridge.ps1 now gates dial-cycling to only run when 2+
        # accounts are pending, never calling this function at all for the
        # 1-account case.
        $pending = @{ personal = @{} }
        Get-DialCycleTarget -PendingAccounts $pending -Cursor $null | Should -Be 'personal'
        Get-DialCycleTarget -PendingAccounts $pending -Cursor 'personal' | Should -Be 'personal'
    }
}
