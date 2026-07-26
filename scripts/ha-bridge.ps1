# claude-voice/scripts/ha-bridge.ps1
Import-Module (Join-Path $PSScriptRoot 'PendingState.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'HaClient.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ButtonAction.psm1') -Force

$logPath = Join-Path $PSScriptRoot '..\state\ha-bridge.log'

# Debounce state for dial-rotation gestures (Fix 3, final review): a single
# physical turn fires many rapid detent events plus one extra ~1s after the
# gesture ends (firmware resets its internal rotary counter). Track when the
# last dial-rotation action actually fired so a whole gesture collapses into
# one action instead of one HA call per detent.
$script:LastDialActionAt = [datetime]::MinValue
$script:DialDebounceMs = 800

function Write-BridgeLog {
    param([string]$Message)
    $line = "$(Get-Date -Format o) $Message"
    Add-Content -Path $logPath -Value $line
    Write-Warning $line
}

function Connect-HaEventStream {
    param([Parameter(Mandatory)][hashtable]$Connection)
    $wsUrl = ($Connection.Url -replace '^http', 'ws') + '/api/websocket'
    $ws = [System.Net.WebSockets.ClientWebSocket]::new()
    $ws.ConnectAsync([Uri]$wsUrl, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
    $buffer = [byte[]]::new(16384)

    $receive = {
        $seg = [ArraySegment[byte]]::new($buffer)
        $result = $ws.ReceiveAsync($seg, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
        if ($result.Count -eq 0) { throw "Received empty/close frame from HA websocket" }
        [System.Text.Encoding]::UTF8.GetString($buffer, 0, $result.Count) | ConvertFrom-Json
    }.GetNewClosure()

    $send = {
        param($Obj)
        $bytes = [System.Text.Encoding]::UTF8.GetBytes(($Obj | ConvertTo-Json -Depth 5 -Compress))
        $ws.SendAsync([ArraySegment[byte]]::new($bytes), 'Text', $true, [Threading.CancellationToken]::None).GetAwaiter().GetResult() | Out-Null
    }.GetNewClosure()

    $hello = & $receive
    if ($hello.type -ne 'auth_required') { throw "Unexpected HA handshake: $($hello.type)" }
    & $send @{ type = 'auth'; access_token = $Connection.Headers.Authorization -replace '^Bearer ', '' }
    $auth = & $receive
    if ($auth.type -ne 'auth_ok') { throw "HA websocket auth failed: $($auth.type)" }

    & $send @{ id = 1; type = 'subscribe_events'; event_type = 'state_changed' }
    $ack = & $receive
    if (-not $ack.success) { throw "HA subscribe_events failed: $($ack.error | ConvertTo-Json -Compress)" }

    [PSCustomObject]@{ Socket = $ws; Receive = $receive }
}

function Set-RemainingLed {
    param([Parameter(Mandatory)][hashtable]$Connection)
    $remaining = Get-PendingState
    $names = @($remaining.accounts.Keys | Sort-Object)
    if ($names.Count -gt 0) {
        # Pulse, not solid -- a solid LED means "done" in this project's
        # own vocabulary, and the remaining account is still waiting.
        # Also set the cursor so the button's notion of "selected" agrees
        # with what the LED is showing.
        Set-PendingCursor -Account $names[0]
        Invoke-HaLed -Connection $Connection -Account $names[0] -Pulse
    } else {
        Invoke-HaLed -Connection $Connection -Off
    }
}

function Invoke-DialRotationEvent {
    param([Parameter(Mandatory)][hashtable]$Connection)

    if (-not (Test-HaNotificationsEnabled -Connection $Connection)) { return }

    $state = Get-PendingState
    # Fix 1 (final review): the dial has ALWAYS controlled speaker volume
    # (rotate alone) and LED-ring hue (rotate while holding the center
    # button) in stock firmware -- that's the device's normal, everyday
    # behavior. Dial-cycling must only ever act for the specific case it was
    # built for: 2+ Claude Code sessions actually pending. With 0 pending
    # there's nothing to cycle. With exactly 1, Get-DialCycleTarget keeps
    # returning that same account on every single detent forever (cursor
    # $null -> index -1 -> wraps to names[0]; cursor already names[0] ->
    # (0+1) % 1 -> 0 -- same result again), which without this gate
    # re-announced/re-pulsed on every tick, endlessly. Gating here means
    # ordinary volume/hue turns (0 or 1 pending accounts -- every normal
    # day) are completely unaffected: no cursor mutation, no LED call, no
    # sound.
    if ($state.accounts.Count -lt 2) { return }

    $now = Get-Date
    if (($now - $script:LastDialActionAt).TotalMilliseconds -lt $script:DialDebounceMs) {
        # Fix 3: ignore events that arrive within the debounce window of the
        # last action actually taken -- collapses a whole rotation gesture
        # (many rapid detent events) into a single action.
        return
    }

    $next = Get-DialCycleTarget -PendingAccounts $state.accounts -Cursor $state.cursor
    if (-not $next) { return }

    $script:LastDialActionAt = $now
    Set-PendingCursor -Account $next
    Invoke-HaLed -Connection $Connection -Account $next -Pulse
    # Fix 3: no spoken account name for dial-cycling -- LED-only feedback by
    # design intent (a per-detent 10s-timeout TTS call was an unintended
    # Task 7 addition, not a deliberate spec choice, and could otherwise
    # stall this event loop for many seconds while button presses queue up
    # unhandled). The button's double_press fallback still announces the
    # name via Invoke-ButtonEvent -- unaffected by this change.
    if (Test-HaMuted -Connection $Connection) { Invoke-HaChime -Connection $Connection }
}

function Invoke-ButtonEvent {
    param([Parameter(Mandatory)][hashtable]$Connection, [Parameter(Mandatory)][string]$EventType)

    if (-not (Test-HaNotificationsEnabled -Connection $Connection)) { return }

    $state = Get-PendingState
    $result = Get-ButtonAction -EventType $EventType -PendingAccounts $state.accounts -Cursor $state.cursor

    switch ($result.Action) {
        'select' {
            Set-PendingCursor -Account $result.Account
            Invoke-HaLed -Connection $Connection -Account $result.Account -Pulse
            if (Test-HaMuted -Connection $Connection) { Invoke-HaChime -Connection $Connection }
            else { Invoke-HaAnnounce -Connection $Connection -Text $result.Speak }
        }
        'focus' {
            # -FocusOnly: take the human to the session and clear the light,
            # but type nothing. The Notification hook fires mainly on
            # permission prompts, so auto-answering from across the room would
            # approve things unseen. Deliberate replies happen at the desk
            # (e.g. the optional Stream Controller page), not from the device.
            & (Join-Path $PSScriptRoot 'confirm-session.ps1') -Account $result.Account -FocusOnly
            if ($LASTEXITCODE -ne 0) {
                Invoke-HaAnnounce -Connection $Connection -Text "Couldn't find the $($result.Account) session"
                Invoke-HaLed -Connection $Connection -Account $result.Account -Pulse
            } else {
                Invoke-HaChime -Connection $Connection
                Set-RemainingLed -Connection $Connection
            }
        }
        'dismiss' {
            Clear-PendingAccount -Account $result.Account
            Set-RemainingLed -Connection $Connection
        }
        'none' {
            if ($result.Speak -and -not (Test-HaMuted -Connection $Connection)) { Invoke-HaAnnounce -Connection $Connection -Text $result.Speak }
        }
    }
}

# Outer supervision loop: any failure (connect, auth, subscribe, or a
# receive-loop exception/dropped connection) logs and retries rather than
# exiting. Previously a clean HA-side close (e.g. an HA Core restart) made
# the inner loop exit with code 0, which Task Scheduler's failure-triggered
# restarts never caught -- the bridge died silently and permanently until
# next logon. Exponential backoff capped at 60s; resets after a successful
# connect.
$backoffSec = 5
while ($true) {
    try {
        $conn = Get-HaConnection
        $stream = Connect-HaEventStream -Connection $conn
        Write-BridgeLog "connected to $($conn.Url)"
        $backoffSec = 5

        while ($stream.Socket.State -eq 'Open') {
            $msg = & $stream.Receive
            if ($msg.type -ne 'event') { continue }
            $data = $msg.event.data
            if ($data.entity_id -eq 'event.home_assistant_voice_0932b4_button_press') {
                $eventType = $data.new_state.attributes.event_type
                if ($eventType) {
                    try {
                        Invoke-ButtonEvent -Connection $conn -EventType $eventType
                    } catch {
                        Write-BridgeLog "Invoke-ButtonEvent failed (continuing): $_"
                    }
                }
            } elseif ($data.entity_id -eq 'sensor.bedroom_home_assistant_voice_0932b4_dial_rotation') {
                # Fix 2 (final review): a reboot or Wi-Fi blip produces
                # <n> -> unavailable -> unknown transitions on this sensor,
                # each of which would otherwise fire a spurious cycle. Only
                # proceed when the new state actually parses as a number,
                # mirroring the button-press branch's `if ($eventType)` guard
                # above.
                $dialValue = 0.0
                $isNumericDialState = [double]::TryParse(
                    [string]$data.new_state.state,
                    [System.Globalization.NumberStyles]::Float,
                    [System.Globalization.CultureInfo]::InvariantCulture,
                    [ref]$dialValue)
                # Also skip the firmware's own counter-reset sentinel. Upstream
                # `control_volume` (home-assistant-voice.yaml:1283-1305) is
                # `mode: restart` with `- delay: 1s` then
                # `sensor.rotary_encoder.set_value: value: 0`, so ~1000ms after
                # the LAST detent of a gesture the firmware publishes a numeric
                # `0` that is not a user action at all. That lands outside the
                # 800ms debounce window (which is measured from the FIRST
                # detent's action), so without this guard every single turn
                # produced a second, phantom cursor advance -- and with exactly
                # 2 pending accounts, the gated primary case, it advanced and
                # immediately reverted, making the whole feature a no-op.
                # Skipping `0` also drops the equivalent spurious cycle on
                # device reboot (first post-boot publish is `0`). A genuine
                # user return-to-zero mid-gesture is almost always swallowed by
                # the debounce anyway, so this costs effectively nothing.
                if ($isNumericDialState -and $dialValue -ne 0) {
                    try {
                        Invoke-DialRotationEvent -Connection $conn
                    } catch {
                        Write-BridgeLog "Invoke-DialRotationEvent failed (continuing): $_"
                    }
                }
            }
        }
        Write-BridgeLog "websocket left Open state ($($stream.Socket.State)) -- reconnecting"
    } catch {
        Write-BridgeLog "connection error: $_"
    }
    Start-Sleep -Seconds $backoffSec
    $backoffSec = [Math]::Min($backoffSec * 2, 60)
}
