function Get-NotifyPlan {
    param(
        [Parameter(Mandatory)][ValidateSet('notification','stop','clear')][string]$Event,
        [Parameter(Mandatory)][string]$DisplayName,
        [AllowEmptyString()][string]$Message = '',
        [Parameter(Mandatory)][bool]$Muted,
        [Parameter(Mandatory)][int]$OtherPendingCount
    )
    # A pending session HOLDS SOLID at full brightness, with one flash on
    # arrival. Never a sustained pulse: flash:'long' is a one-shot that
    # reverts the light to its previous state after ~10s, so a "pulsing"
    # notification would go dark on its own and be missed entirely.
    switch ($Event) {
        'notification' {
            if ($OtherPendingCount -gt 0) {
                # Something is already waiting. Chime so the arrival is
                # noticed, but do not move the display out from under a
                # decision the human is already making.
                return @{
                    Led = @{ Action = 'none'; Bright = $false; Flash = $false }
                    Sound = 'chime'; AnnounceText = ''
                }
            }
            return @{
                Led = @{ Action = 'set'; Bright = $true; Flash = $true }
                Sound = if ($Muted) { 'chime' } else { 'announce' }
                AnnounceText = "$DisplayName needs input: $Message"
            }
        }
        'stop' {
            # Pending outranks active: a finished session must not take the
            # ring away from one that still needs the human.
            if ($OtherPendingCount -gt 0) {
                return @{ Led = @{ Action = 'none'; Bright = $false; Flash = $false }; Sound = 'chime'; AnnounceText = '' }
            }
            return @{ Led = @{ Action = 'set'; Bright = $false; Flash = $false }; Sound = 'chime'; AnnounceText = '' }
        }
        'clear' {
            # This is UserPromptSubmit: the human just typed into this
            # session, so it becomes the DIM ambient "you are here"
            # indicator. It is deliberately NOT turned off -- only the
            # 10-minute idle timeout in ha-bridge.ps1 does that. Turning it
            # off here would mean the ambient indicator never showed at all.
            if ($OtherPendingCount -gt 0) {
                return @{ Led = @{ Action = 'none'; Bright = $false; Flash = $false }; Sound = 'none'; AnnounceText = '' }
            }
            return @{ Led = @{ Action = 'set'; Bright = $false; Flash = $false }; Sound = 'none'; AnnounceText = '' }
        }
    }
}

Export-ModuleMember -Function Get-NotifyPlan
