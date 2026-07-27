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

    It 'matches a project whose name contains wildcard metacharacters' {
        $procs = @(
            [PSCustomObject]@{ MainWindowTitle = 'x.ps1 - my[test]proj - Visual Studio Code'; MainWindowHandle = [IntPtr]1; Id = 42 }
        )
        (Find-SessionWindow -Project 'my[test]proj' -Processes $procs).Id | Should -Be 42
    }
}

Describe 'Select-OwningWindowPid' {
    It 'returns the nearest ancestor that owns a window' {
        $chain = @(
            @{ ProcessId = 100; Name = 'pwsh.exe';     HasWindow = $false }
            @{ ProcessId = 200; Name = 'claude.exe';   HasWindow = $false }
            @{ ProcessId = 300; Name = 'Code.exe';     HasWindow = $false }
            @{ ProcessId = 400; Name = 'Code.exe';     HasWindow = $true  }
            @{ ProcessId = 500; Name = 'explorer.exe'; HasWindow = $true  }
        )
        Select-OwningWindowPid -Chain $chain | Should -Be 400
    }

    It 'does not skip past a windowed terminal to reach explorer' {
        # A session in Windows Terminal has no Code.exe ancestor at all, and
        # explorer.exe is an ancestor of nearly everything -- a "prefer
        # Code.exe" or last-match rule would focus the desktop instead.
        $chain = @(
            @{ ProcessId = 100; Name = 'pwsh.exe';            HasWindow = $false }
            @{ ProcessId = 200; Name = 'WindowsTerminal.exe'; HasWindow = $true  }
            @{ ProcessId = 300; Name = 'explorer.exe';        HasWindow = $true  }
        )
        Select-OwningWindowPid -Chain $chain | Should -Be 200
    }

    It 'returns null when no ancestor owns a window' {
        $chain = @(
            @{ ProcessId = 100; Name = 'pwsh.exe';   HasWindow = $false }
            @{ ProcessId = 200; Name = 'claude.exe'; HasWindow = $false }
        )
        Select-OwningWindowPid -Chain $chain | Should -BeNullOrEmpty
    }

    It 'returns null for an empty chain' {
        Select-OwningWindowPid -Chain @() | Should -BeNullOrEmpty
    }
}

Describe 'Get-OwningWindowPid (live)' {
    It 'finds a real windowed ancestor of this test process' {
        # Integration check: the walk must work against real Win32_Process
        # data, not just the pure selection rule. Pester runs under a console
        # or editor, so some ancestor owns a window.
        $found = Get-OwningWindowPid
        $found | Should -Not -BeNullOrEmpty
        (Get-Process -Id $found -ErrorAction SilentlyContinue).MainWindowHandle |
            Should -Not -Be ([IntPtr]::Zero)
    }
}
