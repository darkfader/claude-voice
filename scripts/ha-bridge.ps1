# claude-voice/scripts/ha-bridge.ps1
Import-Module (Join-Path $PSScriptRoot 'PendingState.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'HaClient.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ButtonAction.psm1') -Force

function Connect-HaEventStream {
    param([Parameter(Mandatory)][hashtable]$Connection)
    $wsUrl = ($Connection.Url -replace '^http', 'ws') + '/api/websocket'
    $ws = [System.Net.WebSockets.ClientWebSocket]::new()
    $ws.ConnectAsync([Uri]$wsUrl, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
    $buffer = [byte[]]::new(16384)

    $receive = {
        $seg = [ArraySegment[byte]]::new($buffer)
        $result = $ws.ReceiveAsync($seg, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
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
    & $receive | Out-Null   # subscription ack

    [PSCustomObject]@{ Socket = $ws; Receive = $receive }
}

function Invoke-ButtonEvent {
    param([Parameter(Mandatory)][hashtable]$Connection, [Parameter(Mandatory)][string]$EventType)

    if (-not (Test-HaNotificationsEnabled -Connection $Connection)) { return }

    $state = Get-PendingState
    $result = Get-ButtonAction -EventType $EventType -PendingAccounts $state.accounts -Cursor $state.cursor
    $muted = Test-HaMuted -Connection $Connection

    switch ($result.Action) {
        'select' {
            Set-PendingCursor -Account $result.Account
            Invoke-HaLed -Connection $Connection -Account $result.Account -Pulse
            if ($muted) { Invoke-HaChime -Connection $Connection }
            else { Invoke-HaAnnounce -Connection $Connection -Text $result.Speak }
        }
        'confirm' {
            & (Join-Path $PSScriptRoot 'confirm-session.ps1') -Account $result.Account
            Invoke-HaChime -Connection $Connection
            Invoke-HaLed -Connection $Connection -Off
        }
        'dismiss' {
            Clear-PendingAccount -Account $result.Account
            Invoke-HaLed -Connection $Connection -Off
        }
        'none' {
            if ($result.Speak -and -not $muted) { Invoke-HaAnnounce -Connection $Connection -Text $result.Speak }
        }
    }
}

$conn = Get-HaConnection
$stream = Connect-HaEventStream -Connection $conn
Write-Host "ha-bridge connected to $($conn.Url)"

while ($stream.Socket.State -eq 'Open') {
    $msg = & $stream.Receive
    if ($msg.type -ne 'event') { continue }
    $data = $msg.event.data
    if ($data.entity_id -eq 'event.home_assistant_voice_0932b4_button_press') {
        $eventType = $data.new_state.attributes.event_type
        if ($eventType) { Invoke-ButtonEvent -Connection $conn -EventType $eventType }
    }
}
