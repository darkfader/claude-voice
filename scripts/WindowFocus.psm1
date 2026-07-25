$script:AccountWindowPatterns = @{
    personal = '*HomeAssistant*Visual Studio Code*'
    work     = '*sownet*Visual Studio Code*'
}

function Get-AccountWindowPattern {
    param([Parameter(Mandatory)][ValidateSet('personal','work')][string]$Account)
    $script:AccountWindowPatterns[$Account]
}

function Find-AccountWindow {
    param(
        [Parameter(Mandatory)][ValidateSet('personal','work')][string]$Account,
        [Parameter(Mandatory)]$Processes
    )
    $pattern = Get-AccountWindowPattern -Account $Account
    $Processes |
        Where-Object { $_.MainWindowHandle -ne [IntPtr]0 -and $_.MainWindowTitle -like $pattern } |
        Select-Object -First 1
}

Export-ModuleMember -Function Get-AccountWindowPattern, Find-AccountWindow
