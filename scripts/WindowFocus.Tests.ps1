BeforeAll { Import-Module "$PSScriptRoot/WindowFocus.psm1" -Force }

Describe 'Get-ProjectWindowPattern' {
    It 'builds a VS Code title pattern from the project name' {
        Get-ProjectWindowPattern -Project 'HomeAssistant' | Should -Be '*HomeAssistant*Visual Studio Code*'
    }
}

Describe 'Find-SessionWindow' {
    It 'finds the window whose title contains the project name' {
        $procs = @(
            [PSCustomObject]@{ MainWindowTitle = 'a.ps1 - HomeAssistant - Visual Studio Code'; MainWindowHandle = [IntPtr]1; Id = 100 },
            [PSCustomObject]@{ MainWindowTitle = 'b.ts - other-repo - Visual Studio Code';     MainWindowHandle = [IntPtr]2; Id = 200 }
        )
        (Find-SessionWindow -Project 'HomeAssistant' -Processes $procs).Id | Should -Be 100
        (Find-SessionWindow -Project 'other-repo'   -Processes $procs).Id | Should -Be 200
    }

    It 'ignores windows with no handle' {
        $procs = @([PSCustomObject]@{ MainWindowTitle = 'HomeAssistant - Visual Studio Code'; MainWindowHandle = [IntPtr]0; Id = 1 })
        Find-SessionWindow -Project 'HomeAssistant' -Processes $procs | Should -BeNullOrEmpty
    }

    It 'returns null when nothing matches' {
        $procs = @([PSCustomObject]@{ MainWindowTitle = 'unrelated'; MainWindowHandle = [IntPtr]1; Id = 1 })
        Find-SessionWindow -Project 'HomeAssistant' -Processes $procs | Should -BeNullOrEmpty
    }

    It 'does not match a non-VS-Code window that happens to contain the project name' {
        $procs = @([PSCustomObject]@{ MainWindowTitle = 'HomeAssistant - Notepad'; MainWindowHandle = [IntPtr]1; Id = 1 })
        Find-SessionWindow -Project 'HomeAssistant' -Processes $procs | Should -BeNullOrEmpty
    }
}
