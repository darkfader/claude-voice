BeforeAll {
    Import-Module "$PSScriptRoot/WindowFocus.psm1" -Force
}

Describe 'Get-AccountWindowPattern' {
    It 'returns the personal workspace pattern' {
        Get-AccountWindowPattern -Account 'personal' | Should -BeLike '*HomeAssistant*'
    }
    It 'returns the work workspace pattern' {
        Get-AccountWindowPattern -Account 'work' | Should -BeLike '*sownet*'
    }
}

Describe 'Find-AccountWindow' {
    It 'finds the process whose title matches the account pattern' {
        $procs = @(
            [PSCustomObject]@{ MainWindowTitle = 'foo.txt - HomeAssistant - Visual Studio Code'; MainWindowHandle = [IntPtr]1; Id = 100 },
            [PSCustomObject]@{ MainWindowTitle = 'bar.txt - sownet-app - Visual Studio Code'; MainWindowHandle = [IntPtr]2; Id = 200 }
        )
        (Find-AccountWindow -Account 'personal' -Processes $procs).Id | Should -Be 100
        (Find-AccountWindow -Account 'work' -Processes $procs).Id | Should -Be 200
    }

    It 'ignores windows with no handle' {
        $procs = @(
            [PSCustomObject]@{ MainWindowTitle = 'HomeAssistant - Visual Studio Code'; MainWindowHandle = [IntPtr]0; Id = 100 }
        )
        Find-AccountWindow -Account 'personal' -Processes $procs | Should -BeNullOrEmpty
    }

    It 'returns $null when nothing matches' {
        $procs = @([PSCustomObject]@{ MainWindowTitle = 'unrelated'; MainWindowHandle = [IntPtr]1; Id = 1 })
        Find-AccountWindow -Account 'personal' -Processes $procs | Should -BeNullOrEmpty
    }
}
