# claude-voice/scripts/notify-ha.ps1
param(
    [Parameter(Mandatory)][ValidateSet('notification','stop','clear')][string]$Event,
    [Parameter(ValueFromPipeline = $true)][object]$InputObject
)

Import-Module (Join-Path $PSScriptRoot 'PendingState.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'HaClient.psm1')     -Force
Import-Module (Join-Path $PSScriptRoot 'NotifyPlan.psm1')   -Force
Import-Module (Join-Path $PSScriptRoot 'SessionColor.psm1') -Force

# --- read the hook payload -------------------------------------------------
$payload = $null
if ($InputObject) {
    if ($InputObject -is [string]) { try { $payload = $InputObject | ConvertFrom-Json } catch { } }
    else { $payload = $InputObject }
}
if (-not $payload) {
    try {
        if ([Console]::IsInputRedirected) {
            $stdin = [Console]::In.ReadToEnd()
            if ($stdin) { $payload = $stdin | ConvertFrom-Json }
        }
    } catch { }
}

$sessionId = $null; $cwd = $null; $message = ''
if ($payload) {
    $sessionId = $payload.session_id
    $cwd       = $payload.cwd
    if ($payload.PSObject.Properties.Name -contains 'message') { $message = [string]$payload.message }
}
# Fall back to the working directory so a notification is never lost outright
# just because a payload field was missing.
if (-not $cwd)       { $cwd = (Get-Location).Path }
if (-not $sessionId) { $sessionId = 'cwd:' + (Get-NormalisedProjectPath -Path $cwd) }
$project = Split-Path $cwd -Leaf

try {
    $before      = Get-PendingState
    $othersCount = @($before.sessions.Keys | Where-Object { $_ -ne $sessionId }).Count

    # --- local bookkeeping first, before any network call --------------------
    # Doing this ahead of the kill-switch check means toggling the switch off
    # can never strand an entry that can then never be cleared.
    switch ($Event) {
        'notification' {
            if (-not $before.sessions.ContainsKey($sessionId)) {
                $taken   = @($before.sessions.Values | ForEach-Object { $_.slot })
                $slot    = Resolve-SessionColorSlot -ProjectPath $cwd -TakenSlots $taken
                $ords    = @($before.sessions.Values | Where-Object { $_.project -eq $project } | ForEach-Object { $_.ordinal })
                $ordinal = Get-SessionOrdinal -TakenOrdinals $ords
                $rgb     = ConvertFrom-HueSlot -Slot $slot
                Set-PendingSession -SessionId $sessionId -Project $project -Cwd $cwd -Message $message -Color $rgb -Slot $slot -Ordinal $ordinal
                if ($othersCount -eq 0) { Set-PendingCursor -SessionId $sessionId }
            }
        }
        'stop'  { Clear-PendingSession -SessionId $sessionId }
        'clear' {
            Clear-PendingSession -SessionId $sessionId
            Set-ActiveSession    -SessionId $sessionId
        }
    }

    $after   = Get-PendingState
    $entry   = $after.sessions[$sessionId]
    $ordinal = if ($entry) { $entry.ordinal } else { 1 }
    $rgb     = if ($entry) { $entry.color } else { (ConvertFrom-HueSlot -Slot (Resolve-SessionColorSlot -ProjectPath $cwd)) }
    $display = Get-SessionDisplayName -Project $project -Ordinal $ordinal

    $conn = Get-HaConnection
    if (-not (Test-HaNotificationsEnabled -Connection $conn)) { exit 0 }

    $muted = if ($Event -eq 'notification') { Test-HaMuted -Connection $conn } else { $false }
    $plan  = Get-NotifyPlan -Event $Event -DisplayName $display -Message $message -Muted $muted -OtherPendingCount $othersCount

    switch ($plan.Led.Action) {
        'set' {
            $brightness = if ($plan.Led.Bright) { 255 } else { 60 }
            Invoke-HaLed -Connection $conn -Rgb $rgb -Brightness $brightness -Flash:$plan.Led.Flash | Out-Null
        }
        'off'  { Invoke-HaLed -Connection $conn -Off | Out-Null }
        'none' { }
    }

    switch ($plan.Sound) {
        'chime'    { Invoke-HaChime    -Connection $conn | Out-Null }
        'announce' { Invoke-HaAnnounce -Connection $conn -Text $plan.AnnounceText | Out-Null }
    }
} catch {
    Write-Warning "notify-ha.ps1 failed non-fatally: $_"
}

exit 0
