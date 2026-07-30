# claude-voice/scripts/HaClient.psm1
$script:LedEntity = 'light.home_assistant_voice_0932b4_led_ring'
$script:MediaPlayerEntity = 'media_player.home_assistant_voice_0932b4_media_player'
$script:SatelliteEntity = 'assist_satellite.home_assistant_voice_0932b4_assist_satellite'
$script:MuteEntity = 'switch.home_assistant_voice_0932b4_mute'
$script:KillSwitchEntity = 'input_boolean.claude_notifications_enabled'
$script:ChimeMediaId = 'media-source://media_source/local/claude-voice/chime.wav'
# Two short descending low tones, deliberately blunt and nothing like the
# bright glass chime -- a failure must not sound like a success.
$script:ErrorMediaId = 'media-source://media_source/local/claude-voice/error.wav'
# Area-prefixed: this device's HA entity ids are not predictable from the
# ESPHome name. Confirmed live in Task 2 -- do not "fix" back to the
# unprefixed form, that entity does not exist.
$script:RingStateEntityId = 'text.bedroom_home_assistant_voice_0932b4_claude_ring_state'

function Get-HaRingStateEntityId {
    <#
    .SYNOPSIS
    The ring-state entity id, for callers that need to recognise its events.

    .DESCRIPTION
    Exists because $script: scope is per-MODULE: ha-bridge.ps1 referring to
    $script:RingStateEntityId gets $null, not this value, so a comparison
    against it silently never matches. Exposed as a function rather than
    duplicating the string, which would then have two places to get wrong --
    and this id is already unobvious (note the `bedroom_` area prefix).
    #>
    $script:RingStateEntityId
}

function Read-DotEnv {
    param([Parameter(Mandatory)][string]$Path)
    $result = @{}
    foreach ($line in Get-Content $Path) {
        if ($line -match '^\s*#' -or $line -notmatch '=') { continue }
        $key, $value = $line -split '=', 2
        $result[$key.Trim()] = $value.Trim()
    }
    $result
}

function Get-HaConnection {
    $envFile = Join-Path $PSScriptRoot '..\.env'
    if (Test-Path $envFile) {
        $vars = Read-DotEnv -Path $envFile
        $url = $vars.HA_URL
        $token = $vars.HA_TOKEN
    } else {
        $url = $env:CLAUDE_VOICE_HA_URL
        $token = $env:CLAUDE_VOICE_HA_TOKEN
    }
    if (-not $url -or -not $token) {
        throw "HA credentials not found - create claude-voice/.env (see claude-voice/.env.example) or set CLAUDE_VOICE_HA_URL/CLAUDE_VOICE_HA_TOKEN."
    }
    @{
        Url     = $url
        Headers = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }
    }
}

function Invoke-HaService {
    param(
        [Parameter(Mandatory)][hashtable]$Connection,
        [Parameter(Mandatory)][string]$Domain,
        [Parameter(Mandatory)][string]$Service,
        [Parameter(Mandatory)][hashtable]$Body,
        [int]$TimeoutSec = 2
    )
    try {
        Invoke-RestMethod -Uri "$($Connection.Url)/api/services/$Domain/$Service" `
            -Method POST -Headers $Connection.Headers `
            -Body ($Body | ConvertTo-Json -Depth 5) -TimeoutSec $TimeoutSec | Out-Null
        return $true
    } catch {
        Write-Warning "HA service call $Domain.$Service failed: $_"
        return $false
    }
}

function Get-HaState {
    param([Parameter(Mandatory)][hashtable]$Connection, [Parameter(Mandatory)][string]$EntityId)
    try {
        Invoke-RestMethod -Uri "$($Connection.Url)/api/states/$EntityId" -Headers $Connection.Headers -Method GET -TimeoutSec 2
    } catch {
        Write-Warning "HA state fetch for $EntityId failed: $_"
        $null
    }
}

function Test-HaMuted {
    param([Parameter(Mandatory)][hashtable]$Connection)
    $s = Get-HaState -Connection $Connection -EntityId $script:MuteEntity
    return $s -and $s.state -eq 'on'
}

function Test-HaNotificationsEnabled {
    param([Parameter(Mandatory)][hashtable]$Connection)
    $s = Get-HaState -Connection $Connection -EntityId $script:KillSwitchEntity
    # fail open if the helper doesn't exist yet or HA is unreachable — see Task 5
    return (-not $s) -or $s.state -eq 'on'
}

function Invoke-HaLed {
    param(
        [Parameter(Mandatory)][hashtable]$Connection,
        [int[]]$Rgb,
        [int]$Brightness = 255,
        [switch]$Flash,
        [switch]$Off,
        [double]$TransitionSec = 0.3,
        # Gap between setting the solid colour and firing the one-shot flash.
        # NOT optional padding: flash restores the light to the state it
        # captured when it fired, so without a gap it can capture the state
        # from BEFORE the solid set -- i.e. darkness -- and the ring goes
        # dark ~10s later, silently losing the notification. Verified live:
        # with no gap and the ring starting off, dark at t+16s; with this
        # gap, green held at t+1/5/10/16s.
        [int]$FlashDelayMs = 800
    )
    # RETIRED. The per-thread ring display now owns the LEDs.
    #
    # `led_ring` and `voice_assistant_leds` are two ESPHome partitions over
    # the SAME twelve physical LEDs (identical segments, 7..11 then 0..6).
    # This function drove `led_ring` -- the whole ring, one colour -- while
    # the `Claude Threads` effect drives `voice_assistant_leds` per LED. Both
    # writing the same hardware meant every hook painted the ring solid and
    # left it that way until `control_leds` next ran its idle branch and
    # re-selected the effect. Observed live as the ring "filling with one
    # colour" and staying there.
    #
    # The whole-ring vocabulary (one session's colour, brightness for state)
    # has been superseded by the per-thread one, so these calls are not just
    # conflicting, they are obsolete. Neutered here rather than deleted at
    # all eleven call sites so the change is one line to revert while the
    # per-thread display is still being tuned; the call sites get removed
    # properly once it has settled.
    return $true

    if ($Off) {
        Invoke-HaService -Connection $Connection -Domain light -Service turn_off -Body @{
            entity_id  = $script:LedEntity
            transition = $TransitionSec
        }
        return
    }
    if (-not $Rgb) { throw "Invoke-HaLed requires -Rgb unless -Off is used" }

    $body = @{
        entity_id  = $script:LedEntity
        rgb_color  = $Rgb
        brightness = $Brightness
        transition = $TransitionSec
    }
    $ok = Invoke-HaService -Connection $Connection -Domain light -Service turn_on -Body $body

    if ($Flash -and $ok) {
        # See $FlashDelayMs above: without this gap, flash can capture and
        # restore to the state that preceded this solid-colour call instead
        # of the solid colour itself.
        Start-Sleep -Milliseconds $FlashDelayMs
        # Separate call, deliberately after the solid set: the flash reverts
        # to whatever preceded it, which is now the solid colour we want.
        Invoke-HaService -Connection $Connection -Domain light -Service turn_on -Body @{
            entity_id = $script:LedEntity
            flash     = 'short'
        } | Out-Null
    }
    $ok
}

function Invoke-HaChime {
    param([Parameter(Mandatory)][hashtable]$Connection)
    Invoke-HaService -Connection $Connection -Domain media_player -Service play_media -Body @{
        entity_id           = $script:MediaPlayerEntity
        media_content_id    = $script:ChimeMediaId
        media_content_type  = 'music'
    }
}

function Invoke-HaErrorSound {
    <#
    .SYNOPSIS
    A short error tone, in place of speaking a failure aloud.

    .DESCRIPTION
    Speaking "Couldn't find the <long thread title> session" was slow, and
    worse, it routed through assist_satellite.announce -- which drives the
    device into its replying phase, whose LED animation outranks the thread
    display and wipes the ring. A failure notice that destroys the display is
    a poor trade for information you can get from the log.

    play_media does not touch the voice assistant's state at all.
    #>
    param([Parameter(Mandatory)][hashtable]$Connection)
    Invoke-HaService -Connection $Connection -Domain media_player -Service play_media -Body @{
        entity_id          = $script:MediaPlayerEntity
        media_content_id   = $script:ErrorMediaId
        media_content_type = 'music'
    }
}

function Invoke-HaAnnounce {
    param([Parameter(Mandatory)][hashtable]$Connection, [Parameter(Mandatory)][string]$Text)
    # 10s, not the default 2s: assist_satellite.announce legitimately takes
    # a few seconds for real TTS generation — confirmed empirically that a
    # 2s timeout reports failure even though the device successfully spoke.
    Invoke-HaService -Connection $Connection -Domain assist_satellite -Service announce -Body @{
        entity_id = $script:SatelliteEntity
        message   = $Text
    } -TimeoutSec 10
}

function Invoke-HaRingState {
    <#
    .SYNOPSIS
    Push the per-thread ring state to the device.

    .DESCRIPTION
    State only, never frames: all animation runs on-device, so this is called
    when something changes, not on a timer.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Connection,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value
    )
    Invoke-HaService -Connection $Connection -Domain text -Service set_value -Body @{
        entity_id = $script:RingStateEntityId
        value     = $Value
    }
}

Export-ModuleMember -Function Invoke-HaErrorSound, Get-HaRingStateEntityId, Get-HaConnection, Invoke-HaService, Get-HaState, Test-HaMuted, Test-HaNotificationsEnabled, Invoke-HaLed, Invoke-HaChime, Invoke-HaAnnounce, Invoke-HaRingState
