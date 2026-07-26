# claude-voice/scripts/notify-ha.ps1
param(
    [Parameter(Mandatory)][ValidateSet('notification','stop','clear')][string]$Event,
    [Parameter(ValueFromPipeline = $true)][object]$InputObject
)

# Nothing below may ever throw out of this script: it runs as a Claude Code
# hook, and a non-zero exit would surface as a hook failure in the user's
# session. Belt and braces -- the try/catch below plus this trap.
trap { Write-Warning "notify-ha.ps1 trapped: $_"; exit 0 }

function Get-PayloadValue {
    param($Payload, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Payload) { return $null }
    # A hashtable's dictionary entries are NOT PSObject properties, so the
    # two shapes need different access paths.
    if ($Payload -is [System.Collections.IDictionary]) { return $Payload[$Name] }
    $prop = $Payload.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    $null
}

try {
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

    $sessionId = Get-PayloadValue -Payload $payload -Name 'session_id'
    $cwd       = Get-PayloadValue -Payload $payload -Name 'cwd'
    $message   = [string](Get-PayloadValue -Payload $payload -Name 'message')

    # Fall back to the working directory so a notification is never lost outright
    # just because a payload field was missing.
    if (-not $cwd)       { $cwd = (Get-Location).Path }
    if (-not $sessionId) { $sessionId = 'cwd:' + (Get-NormalisedProjectPath -Path $cwd) }
    $project = Split-Path $cwd -Leaf

    $before      = Get-PendingState
    $othersCount = @($before.sessions.Keys | Where-Object { $_ -ne $sessionId }).Count
    # Captured BEFORE the switch mutates state: for stop/clear the entry is gone
    # by the time we need its colour/ordinal, and recomputing is not equivalent --
    # Resolve-SessionColorSlot without -TakenSlots can pick a different slot than
    # the one originally assigned, so the dim ambient colour would not match what
    # was shown while the session was pending.
    $prevEntry = $before.sessions[$sessionId]

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
        'stop'  {
            Clear-PendingSession -SessionId $sessionId
            # Also mark this the active session: 'stop' lights the ring dim,
            # and Invoke-IdleCheck fades based on activeSession/activeSince.
            # Without this the dim ring a finished turn leaves behind has no
            # timer attached and would glow indefinitely -- the exact
            # overnight-glow case the idle timeout exists to prevent.
            Set-ActiveSession -SessionId $sessionId
        }
        'clear' {
            Clear-PendingSession -SessionId $sessionId
            Set-ActiveSession    -SessionId $sessionId
        }
    }

    $after   = Get-PendingState
    # Prefer the still-pending entry; fall back to the one just cleared (stop/clear
    # always land here since the switch above already removed it) rather than
    # recomputing, which would drop -TakenSlots collision-avoidance and could show
    # a colour that never matched what was actually displayed while pending.
    $entry   = if ($after.sessions.ContainsKey($sessionId)) { $after.sessions[$sessionId] } else { $prevEntry }
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
