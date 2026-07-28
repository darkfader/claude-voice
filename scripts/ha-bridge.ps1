# claude-voice/scripts/ha-bridge.ps1
Import-Module (Join-Path $PSScriptRoot 'PendingState.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'HaClient.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ButtonAction.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SessionColor.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'RingDisplay.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AmbientState.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'RingState.psm1') -Force

$logPath = Join-Path $PSScriptRoot '..\state\ha-bridge.log'

# Dial settle timer. Each detent moves the cursor and repaints the ring
# immediately, but focusing a window per detent would flick through three
# windows on a three-notch turn. Focus instead fires once, 400ms after the
# last detent -- the dial equivalent of releasing Alt.
$script:DialSettleMs = 400
$script:DialSettleAt = [datetime]::MinValue
$script:DialSettleSession = $null

# Two detents make one session step. The encoder has 24 detents per revolution
# and the ring has 12 LEDs, so two detents is exactly one LED position -- and
# one detent per session would be far too twitchy for a three-session list,
# where a small flick would blow past the whole thing. Accumulating here rather
# than dividing in firmware keeps it tunable without a reflash; the firmware
# has no idea how many sessions exist.
$script:DialDetentsPerStep = 2
$script:DialAccumulator = 0

$script:LastIdleCheckAt = [datetime]::MinValue
$script:IdleFadeMinutes = 10

function Write-BridgeLog {
    param(
        [string]$Message,
        [ValidateSet('info','fault')][string]$Level = 'fault'
    )
    $line = "$(Get-Date -Format o) [$Level] $Message"
    Add-Content -Path $logPath -Value $line
    # Faults still surface on the console; info would drown them, and the
    # bridge runs -WindowStyle Hidden in production anyway.
    if ($Level -eq 'fault') { Write-Warning $line }
}

# Startup-only truncation. This file logs routine activity now (every dial
# rotation, every focus), so it grows during normal use and needs a bound --
# but checking the size on every write would cost a stat call per line for
# nothing, given the bridge restarts at every logon.
if (Test-Path $logPath) {
    $logFile = Get-Item $logPath
    if ($logFile.Length -gt 1MB) {
        $keep = Get-Content $logPath -Tail 2000
        Set-Content -Path $logPath -Value $keep
    }
}

function Connect-HaEventStream {
    param([Parameter(Mandatory)][hashtable]$Connection)
    $wsUrl = ($Connection.Url -replace '^http', 'ws') + '/api/websocket'
    $ws = [System.Net.WebSockets.ClientWebSocket]::new()
    $ws.ConnectAsync([Uri]$wsUrl, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
    $buffer = [byte[]]::new(16384)

    # Retains the in-flight receive across calls and polls it in 250ms slices,
    # returning $null when nothing arrived. This exists so the outer loop keeps
    # ticking on a quiet connection -- the dial settle timer and the ambient
    # idle fade both need a clock, and Invoke-IdleCheck previously ran only
    # when some unrelated HA message happened to arrive.
    #
    # Deliberately NOT a CancellationToken with a timeout: cancelling
    # ReceiveAsync ABORTS a ClientWebSocket rather than yielding control, so a
    # 250ms token would tear the connection down and reconnect four times a
    # second. The task here is never cancelled, only awaited in slices.
    #
    # $rx is a hashtable rather than a plain variable because .GetNewClosure()
    # snapshots VALUES: reassigning a captured variable would not persist
    # between calls, whereas mutating a captured hashtable's contents does.
    # Only one receive is ever outstanding, so sharing $buffer stays safe.
    $rx = @{ Task = $null }
    $receive = {
        if (-not $rx.Task) {
            $seg = [ArraySegment[byte]]::new($buffer)
            $rx.Task = $ws.ReceiveAsync($seg, [Threading.CancellationToken]::None)
        }
        if (-not $rx.Task.Wait(250)) { return $null }
        $task = $rx.Task
        $rx.Task = $null
        $result = $task.GetAwaiter().GetResult()
        if ($result.Count -eq 0) { throw "Received empty/close frame from HA websocket" }
        [System.Text.Encoding]::UTF8.GetString($buffer, 0, $result.Count) | ConvertFrom-Json
    }.GetNewClosure()

    $send = {
        param($Obj)
        $bytes = [System.Text.Encoding]::UTF8.GetBytes(($Obj | ConvertTo-Json -Depth 5 -Compress))
        $ws.SendAsync([ArraySegment[byte]]::new($bytes), 'Text', $true, [Threading.CancellationToken]::None).GetAwaiter().GetResult() | Out-Null
    }.GetNewClosure()

    # The handshake reads must not treat a 250ms empty slice as a protocol
    # error -- retry up to 40 slices (10s) before giving up.
    $receiveBlocking = {
        for ($i = 0; $i -lt 40; $i++) {
            $m = & $receive
            if ($null -ne $m) { return $m }
        }
        throw "Timed out waiting for an HA websocket message"
    }.GetNewClosure()

    $hello = & $receiveBlocking
    if ($hello.type -ne 'auth_required') { throw "Unexpected HA handshake: $($hello.type)" }
    & $send @{ type = 'auth'; access_token = $Connection.Headers.Authorization -replace '^Bearer ', '' }
    $auth = & $receiveBlocking
    if ($auth.type -ne 'auth_ok') { throw "HA websocket auth failed: $($auth.type)" }

    & $send @{ id = 1; type = 'subscribe_events'; event_type = 'state_changed' }
    $ack = & $receiveBlocking
    if (-not $ack.success) { throw "HA subscribe_events failed: $($ack.error | ConvertTo-Json -Compress)" }

    # The dial is read from an explicit event, not from the rotation sensor's
    # counter. Once volume also lives on the dial, both gestures drive the same
    # counter and are indistinguishable to anything watching it.
    & $send @{ id = 2; type = 'subscribe_events'; event_type = 'esphome.claude_dial' }
    $dialAck = & $receiveBlocking
    if (-not $dialAck.success) { throw "HA subscribe_events(esphome.claude_dial) failed: $($dialAck.error | ConvertTo-Json -Compress)" }

    [PSCustomObject]@{ Socket = $ws; Receive = $receive }
}

function Get-SessionSpokenName {
    param([Parameter(Mandatory)][hashtable]$Entry)
    # Claude Code's own thread title when there is one -- "Explore Home
    # Assistant Voice capabilities" tells you which thread you are on;
    # "HomeAssistant 2" does not, and is actively useless when several
    # threads share a folder. Falls back to project + ordinal for sessions
    # too new to have been titled, and for pending entries (which carry no
    # title, only their `known` counterpart does).
    if ($Entry.title) { return [string]$Entry.title }
    Get-SessionDisplayName -Project $Entry.project -Ordinal $Entry.ordinal
}

# Set-RemainingLed itself now lives in RingDisplay.psm1 (final review Fix 2)
# so notify-ha.ps1 shares the exact same "hand the ring to the oldest
# remaining pending session" logic instead of reimplementing it.

function Publish-RingState {
    <#
    .SYNOPSIS
    Re-publish the ring picture from current state.
    #>
    param([Parameter(Mandatory)][hashtable]$Connection)
    try {
        $s = Get-PendingState
        Invoke-HaRingState -Connection $Connection -Value (
            Get-RingStateString -KnownSessions $s.known -Cursor $s.cursor
        ) | Out-Null
    } catch {
        Write-BridgeLog "ring state publish failed (continuing): $_"
    }
}

function Invoke-DialRotationEvent {
    param(
        [Parameter(Mandatory)][hashtable]$Connection,
        [Parameter(Mandatory)][ValidateSet('cw','ccw')][string]$Direction
    )
    if (-not (Test-HaNotificationsEnabled -Connection $Connection)) { return }

    # Accumulate detents into session steps. A change of direction resets
    # rather than subtracts: a clockwise-then-anticlockwise wobble is a
    # hesitation, not half a step forward and half a step back, and letting it
    # accumulate would make the dial fire a step on an intended no-op.
    $delta = if ($Direction -eq 'cw') { 1 } else { -1 }
    if ($script:DialAccumulator -ne 0 -and
        [math]::Sign($script:DialAccumulator) -ne $delta) { $script:DialAccumulator = 0 }
    $script:DialAccumulator += $delta
    if ([math]::Abs($script:DialAccumulator) -lt $script:DialDetentsPerStep) { return }
    $script:DialAccumulator = 0

    $state = Get-PendingState
    $next = Get-KnownCycleTarget -KnownSessions $state.known -Cursor $state.cursor -Direction $Direction
    # Nothing known: a fresh state file, or everything expired. Rotation is a
    # no-op -- it deliberately does NOT fall back to volume, because the
    # firmware no longer routes bare rotation there at all.
    if (-not $next) { return }

    $entry = $state.known[$next]
    Set-PendingCursor    -SessionId $next
    Set-DisplayedSession -SessionId $next

    # Brightness still means attention, hue still means identity: full
    # brightness only if this session is actually waiting on you. A pending
    # session's colour comes from its `sessions` entry, not its `known` entry
    # -- collision nudging may have moved it off its base hue.
    if ($state.sessions.ContainsKey($next)) {
        Invoke-HaLed -Connection $Connection -Rgb $state.sessions[$next].color -Brightness 255 | Out-Null
    } else {
        Invoke-HaLed -Connection $Connection -Rgb $entry.color -Brightness 100 | Out-Null
    }

    # Arm the settle timer; the focus and the announcement happen there.
    $script:DialSettleSession = $next
    $script:DialSettleAt = (Get-Date).AddMilliseconds($script:DialSettleMs)
    Write-BridgeLog -Level info -Message "dial $Direction -> $(Get-SessionSpokenName -Entry $entry)"
    Publish-RingState -Connection $Connection
}

function Invoke-DialSettleCheck {
    param([Parameter(Mandatory)][hashtable]$Connection)
    if (-not $script:DialSettleSession) { return }
    if ((Get-Date) -lt $script:DialSettleAt) { return }

    $sessionId = $script:DialSettleSession
    # Disarm FIRST: a throw below must not re-fire the focus on every
    # subsequent tick of the receive pump.
    $script:DialSettleSession = $null

    $state = Get-PendingState
    if (-not $state.known.ContainsKey($sessionId)) { return }
    $entry = $state.known[$sessionId]
    $name  = Get-SessionSpokenName -Entry $entry

    # -KeepPending: rotation is navigation. Browsing to a session must not
    # dismiss the light telling you it still wants something.
    $windowPid = if ($entry.windowPid) { [int]$entry.windowPid } else { 0 }
    & (Join-Path $PSScriptRoot 'confirm-session.ps1') -SessionId $sessionId -Project $entry.project -WindowPid $windowPid -FocusOnly -KeepPending
    if ($LASTEXITCODE -ne 0) {
        Write-BridgeLog "focus failed for $name (no matching window)"
        if (-not (Test-HaMuted -Connection $Connection)) {
            Invoke-HaAnnounce -Connection $Connection -Text "Couldn't find the $name session" | Out-Null
        }
        return
    }

    Write-BridgeLog -Level info -Message "focus -> $name"
    if (Test-HaMuted -Connection $Connection) { Invoke-HaChime -Connection $Connection | Out-Null }
    else { Invoke-HaAnnounce -Connection $Connection -Text $name | Out-Null }
}

function Invoke-ButtonEvent {
    param([Parameter(Mandatory)][hashtable]$Connection, [Parameter(Mandatory)][string]$EventType)
    if (-not (Test-HaNotificationsEnabled -Connection $Connection)) { return }

    $state  = Get-PendingState
    # -KnownSessions is what double_press resolves against: the dial sets the
    # cursor from the known map, so without this the button would ignore the
    # dial's selection whenever the selected session was not also pending.
    $result = Get-ButtonAction -EventType $EventType -PendingSessions $state.sessions -Cursor $state.cursor -KnownSessions $state.known

    switch ($result.Action) {
        'activate' {
            # From `known`, not `sessions`: double_press acts on whatever the
            # dial selected, which is frequently a session that is not pending.
            $entry = $state.known[$result.SessionId]
            if (-not $entry) { break }
            $name  = Get-SessionSpokenName -Entry $entry
            Set-PendingCursor    -SessionId $result.SessionId
            Set-DisplayedSession -SessionId $result.SessionId
            # -KeepPending: this focuses without dismissing. Long-press is the
            # gesture that clears; double-press deliberately leaves the light
            # lit so the session still reads as wanting something.
            $activatePid = if ($entry.windowPid) { [int]$entry.windowPid } else { 0 }
            & (Join-Path $PSScriptRoot 'confirm-session.ps1') -SessionId $result.SessionId -Project $entry.project -WindowPid $activatePid -FocusOnly -KeepPending
            if ($LASTEXITCODE -ne 0) {
                Write-BridgeLog "activate failed for $name (no matching window)"
                if (-not (Test-HaMuted -Connection $Connection)) {
                    Invoke-HaAnnounce -Connection $Connection -Text "Couldn't find the $name session" | Out-Null
                }
            } else {
                Write-BridgeLog -Level info -Message "activate -> $name"
                Invoke-HaChime -Connection $Connection | Out-Null
            }
            # Same rule as rotation: brightness means attention, so full only
            # when this session is actually pending. A pending session's colour
            # comes from its `sessions` entry, since collision nudging may have
            # moved it off the base hue recorded in `known`.
            if ($state.sessions.ContainsKey($result.SessionId)) {
                Invoke-HaLed -Connection $Connection -Rgb $state.sessions[$result.SessionId].color -Brightness 255 | Out-Null
            } else {
                Invoke-HaLed -Connection $Connection -Rgb $entry.color -Brightness 100 | Out-Null
            }
            Publish-RingState -Connection $Connection
        }
        'focus' {
            $entry = $state.sessions[$result.SessionId]
            # windowPid and title both live on the KNOWN entry, not the
            # pending one -- only the session's own hook can record them, and
            # they are recorded once per session rather than per notification.
            $focusPid = 0
            if ($state.known.ContainsKey($result.SessionId)) {
                $knownEntry = $state.known[$result.SessionId]
                if ($knownEntry.windowPid) { $focusPid = [int]$knownEntry.windowPid }
                if ($knownEntry.title)     { $entry = $knownEntry }
            }
            # -FocusOnly: take the human to the session and clear the light,
            # but type nothing. The Notification hook fires mainly on
            # permission prompts, so auto-answering from across the room would
            # approve things unseen. Deliberate replies happen at the desk
            # (e.g. the optional Stream Controller page), not from the device.
            & (Join-Path $PSScriptRoot 'confirm-session.ps1') -SessionId $result.SessionId -Project $entry.project -WindowPid $focusPid -FocusOnly
            if ($LASTEXITCODE -ne 0) {
                Invoke-HaAnnounce -Connection $Connection -Text "Couldn't find the $(Get-SessionSpokenName -Entry $entry) session" | Out-Null
                Set-DisplayedSession -SessionId $result.SessionId
                Invoke-HaLed -Connection $Connection -Rgb $entry.color -Brightness 255 | Out-Null
            } else {
                Invoke-HaChime -Connection $Connection | Out-Null
                Set-RemainingLed -Connection $Connection
            }
            Publish-RingState -Connection $Connection
        }
        'dismiss' {
            Clear-PendingSession -SessionId $result.SessionId
            Set-RemainingLed -Connection $Connection
            Publish-RingState -Connection $Connection
        }
        'none' {
            if ($result.Speak -and -not (Test-HaMuted -Connection $Connection)) {
                Invoke-HaAnnounce -Connection $Connection -Text $result.Speak | Out-Null
            }
        }
    }
}

function Invoke-IdleCheck {
    param([Parameter(Mandatory)][hashtable]$Connection)
    $state = Get-PendingState
    if ($state.sessions.Count -gt 0) { return }   # pending outranks active

    # Fix 3 (final review): the ring can be showing a session that is
    # neither pending (already resolved elsewhere, or expired out of
    # `sessions` at the 4h read-time cutoff) nor the current ambient
    # `activeSession` -- e.g. a Notification lit the ring bright without
    # ever touching activeSession, and its pending entry later expired
    # while nobody was looking. Nothing else ever turns a ring like that
    # off, so it would otherwise stay at full brightness indefinitely.
    # displayedSession is deliberately never auto-cleared by Get-PendingState
    # (see PendingState.psm1) precisely so this check can still see it here.
    if ($state.displayedSession -and $state.displayedSession -ne $state.activeSession) {
        Clear-DisplayedSession
        Invoke-HaLed -Connection $Connection -Off | Out-Null
        return
    }

    # Fix 1 (final review): the ambient-fade decision itself now lives in
    # Test-AmbientIdleExpired (AmbientState.psm1), a pure function unit-
    # tested directly with a stale timestamp -- including an unparseable
    # activeSince, which is the exact case that let the old inline
    # `$since = $null; [datetime]::TryParse(..., [ref]$since)` bug (a $null-
    # valued [ref] out-parameter cannot bind) survive undetected: it threw
    # on every real call, was swallowed by the outer try/catch to the log,
    # and the ring never faded.
    if (Test-AmbientIdleExpired -State $state -Now (Get-Date) -IdleMinutes $script:IdleFadeMinutes) {
        Clear-ActiveSession
        Clear-DisplayedSession
        Invoke-HaLed -Connection $Connection -Off | Out-Null
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
        Write-BridgeLog -Level info -Message "connected to $($conn.Url)"
        $backoffSec = 5

        while ($stream.Socket.State -eq 'Open') {
            $msg = & $stream.Receive
            # No `continue` here any more: an empty 250ms slice ($msg is $null,
            # and $null.type is $null) must still fall through to the periodic
            # checks below. That clock is the entire point of the polling
            # receive.
            $data = if ($msg.type -eq 'event') { $msg.event.data } else { $null }

            if ($null -ne $data -and $msg.event.event_type -eq 'esphome.claude_dial') {
                $direction = [string]$data.direction
                if ($direction -eq 'cw' -or $direction -eq 'ccw') {
                    try {
                        Invoke-DialRotationEvent -Connection $conn -Direction $direction
                    } catch {
                        Write-BridgeLog "Invoke-DialRotationEvent failed (continuing): $_"
                    }
                }
            } elseif ($null -ne $data -and $data.entity_id -eq 'event.home_assistant_voice_0932b4_button_press') {
                $eventType = $data.new_state.attributes.event_type
                if ($eventType) {
                    try {
                        Invoke-ButtonEvent -Connection $conn -EventType $eventType
                    } catch {
                        Write-BridgeLog "Invoke-ButtonEvent failed (continuing): $_"
                    }
                }
            }

            # Runs every pass, including on empty 250ms slices -- that is what
            # gives the 400ms settle a clock to fire against.
            try { Invoke-DialSettleCheck -Connection $conn } catch { Write-BridgeLog "Invoke-DialSettleCheck failed (continuing): $_" }

            if (((Get-Date) - $script:LastIdleCheckAt).TotalSeconds -ge 60) {
                $script:LastIdleCheckAt = Get-Date
                try { Invoke-IdleCheck -Connection $conn } catch { Write-BridgeLog "Invoke-IdleCheck failed (continuing): $_" }
            }
        }
        Write-BridgeLog "websocket left Open state ($($stream.Socket.State)) -- reconnecting"
    } catch {
        Write-BridgeLog "connection error: $_"
    }
    Start-Sleep -Seconds $backoffSec
    $backoffSec = [Math]::Min($backoffSec * 2, 60)
}
