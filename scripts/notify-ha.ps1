# claude-voice/scripts/notify-ha.ps1
param(
    [Parameter(Mandatory,ValueFromPipeline=$false)][ValidateSet('notification','stop','clear')][string]$Event,
    [Parameter(Mandatory,ValueFromPipeline=$false)][ValidateSet('personal','work')][string]$Account,
    [Parameter(ValueFromPipeline=$true)][object]$InputObject,
    [string]$Message
)

Import-Module (Join-Path $PSScriptRoot 'PendingState.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'HaClient.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'NotifyPlan.psm1') -Force

if (-not $PSBoundParameters.ContainsKey('Message')) {
    $Message = ''
    if ($InputObject) {
        try {
            if ($InputObject -is [string]) {
                $parsed = $InputObject | ConvertFrom-Json
                $Message = $parsed.message
            } else {
                $Message = $InputObject.message
            }
        } catch { $Message = '' }
    }
    if (-not $Message) {
        try {
            $stdin = [Console]::In.ReadToEnd()
            if ($stdin) { $Message = ($stdin | ConvertFrom-Json).message }
        } catch { }
    }
}

try {
    $conn = Get-HaConnection

    if (-not (Test-HaNotificationsEnabled -Connection $conn)) {
        exit 0
    }

    $muted = Test-HaMuted -Connection $conn
    $plan = Get-NotifyPlan -Event $Event -Account $Account -Message $Message -Muted $muted

    switch ($Event) {
        'notification' { Set-PendingAccount -Account $Account -Project (Split-Path (Get-Location) -Leaf) -Message $Message }
        'clear'        { Clear-PendingAccount -Account $Account }
    }

    if ($plan.Led.Off) {
        Invoke-HaLed -Connection $conn -Off
    } else {
        Invoke-HaLed -Connection $conn -Account $plan.Led.Account -Pulse:$plan.Led.Pulse
    }

    switch ($plan.Sound) {
        'chime'    { Invoke-HaChime -Connection $conn }
        'announce' { Invoke-HaAnnounce -Connection $conn -Text $plan.AnnounceText }
    }
} catch {
    Write-Warning "notify-ha.ps1 failed non-fatally: $_"
}

exit 0
