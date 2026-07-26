# claude-voice/scripts/ha-bridge.ps1
Import-Module (Join-Path $PSScriptRoot 'PendingState.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'HaClient.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ButtonAction.psm1') -Force

$logPath = Join-Path $PSScriptRoot '..\state\ha-bridge.log'

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
        Invoke-HaLed -Connection $Connection -Account $names[0]
    } else {
        Invoke-HaLed -Connection $Connection -Off
    }
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
        'confirm' {
            & (Join-Path $PSScriptRoot 'confirm-session.ps1') -Account $result.Account
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
            }
        }
        Write-BridgeLog "websocket left Open state ($($stream.Socket.State)) -- reconnecting"
    } catch {
        Write-BridgeLog "connection error: $_"
    }
    Start-Sleep -Seconds $backoffSec
    $backoffSec = [Math]::Min($backoffSec * 2, 60)
}
