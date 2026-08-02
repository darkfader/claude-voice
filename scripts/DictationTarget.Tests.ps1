BeforeAll { Import-Module "$PSScriptRoot/DictationTarget.psm1" -Force }

Describe 'Resolve-DictationTarget' {
    It 'targets the active session when one is tracked' {
        $state = @{
            activeSession = 'sess-1'
            known = @{
                'sess-1' = @{ project = 'HomeAssistant'; windowPid = 4242 }
            }
        }
        $result = Resolve-DictationTarget -State $state
        $result.Mode      | Should -Be 'session'
        $result.SessionId | Should -Be 'sess-1'
        $result.Project   | Should -Be 'HomeAssistant'
        $result.WindowPid | Should -Be 4242
    }

    It 'falls back to focused-window mode when no active session is tracked' {
        $state = @{ activeSession = $null; known = @{} }
        (Resolve-DictationTarget -State $state).Mode | Should -Be 'focused'
    }

    It 'falls back to focused-window mode when the active session id is stale (not in known)' {
        $state = @{
            activeSession = 'sess-gone'
            known = @{}
        }
        (Resolve-DictationTarget -State $state).Mode | Should -Be 'focused'
    }

    It 'defaults WindowPid to 0 when the known entry has none recorded' {
        $state = @{
            activeSession = 'sess-1'
            known = @{ 'sess-1' = @{ project = 'HomeAssistant' } }
        }
        (Resolve-DictationTarget -State $state).WindowPid | Should -Be 0
    }
}
