# Derived from the session's own project rather than a hardcoded per-account
# pattern, which is both more accurate and means adding a project needs no
# code change. Known limit: two sessions in the SAME folder resolve to the
# same window and cannot be told apart for focusing.
function Get-ProjectWindowPattern {
    param([Parameter(Mandatory)][string]$Project)
    # Escape wildcard metacharacters: -like treats * ? [ ] as pattern syntax,
    # and Windows folder names may legally contain [ or ]. Without this, a
    # project like "my[test]proj" silently never matches its own window.
    # WildcardPattern::Escape (not regex::Escape) is the right API for -like.
    $safe = [System.Management.Automation.WildcardPattern]::Escape($Project)
    "*$safe*Visual Studio Code*"
}

function Find-SessionWindow {
    param(
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)]$Processes
    )
    $pattern = Get-ProjectWindowPattern -Project $Project
    $Processes |
        Where-Object { $_.MainWindowHandle -ne [IntPtr]0 -and $_.MainWindowTitle -like $pattern } |
        Select-Object -First 1
}

Export-ModuleMember -Function Get-ProjectWindowPattern, Find-SessionWindow
