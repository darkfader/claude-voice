# claude-voice/scripts/NotifyPlan.psm1
function Get-NotifyPlan {
    param(
        [Parameter(Mandatory)][ValidateSet('notification','stop','clear')][string]$Event,
        [Parameter(Mandatory)][ValidateSet('personal','work')][string]$Account,
        [string]$Message = '',
        [Parameter(Mandatory)][bool]$Muted
    )
    switch ($Event) {
        'stop' {
            return @{
                Led          = @{ Account = $Account; Pulse = $false; Off = $false }
                Sound        = 'chime'
                AnnounceText = ''
            }
        }
        'notification' {
            return @{
                Led          = @{ Account = $Account; Pulse = $true; Off = $false }
                Sound        = if ($Muted) { 'chime' } else { 'announce' }
                AnnounceText = "$Account session needs input: $Message"
            }
        }
        'clear' {
            return @{
                Led          = @{ Account = $Account; Pulse = $false; Off = $true }
                Sound        = 'none'
                AnnounceText = ''
            }
        }
    }
}

Export-ModuleMember -Function Get-NotifyPlan
