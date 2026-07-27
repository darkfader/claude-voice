# claude-voice/scripts/setup-ha-helpers.ps1
#
# Creates the kill-switch helper if it's missing, and reports its state.
#
# Note on the API used: Home Assistant's REST API genuinely has NO endpoint for
# creating helpers -- an earlier version of this script concluded from that
# that creation was impossible and told you to do it by hand in the UI. That
# was wrong. HA's *websocket* API does support it (`input_boolean/create`),
# which is exactly what the HA frontend itself calls when you click "Create
# Helper". So this script uses the websocket API. Only the REST path is
# unavailable, not helper creation as such.
Import-Module (Join-Path $PSScriptRoot 'HaClient.psm1') -Force

$EntityId = 'input_boolean.claude_notifications_enabled'
$conn = Get-HaConnection

function New-HaInputBoolean {
    param(
        [Parameter(Mandatory)][hashtable]$Connection,
        [Parameter(Mandatory)][string]$Name,
        [string]$Icon = 'mdi:bell'
    )
    $token = $Connection.Headers.Authorization -replace '^Bearer ', ''
    $wsUrl = ($Connection.Url -replace '^http', 'ws') + '/api/websocket'

    $ws = [System.Net.WebSockets.ClientWebSocket]::new()
    try {
        $ws.ConnectAsync([Uri]$wsUrl, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
        $buffer = [byte[]]::new(16384)

        $recv = {
            $seg = [ArraySegment[byte]]::new($buffer)
            $r = $ws.ReceiveAsync($seg, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
            [System.Text.Encoding]::UTF8.GetString($buffer, 0, $r.Count) | ConvertFrom-Json
        }.GetNewClosure()
        $send = {
            param($Obj)
            $bytes = [System.Text.Encoding]::UTF8.GetBytes(($Obj | ConvertTo-Json -Depth 5 -Compress))
            $ws.SendAsync([ArraySegment[byte]]::new($bytes), 'Text', $true, [Threading.CancellationToken]::None).GetAwaiter().GetResult() | Out-Null
        }.GetNewClosure()

        & $recv | Out-Null                                   # auth_required
        & $send @{ type = 'auth'; access_token = $token }
        $auth = & $recv
        if ($auth.type -ne 'auth_ok') { throw "HA websocket auth failed: $($auth.type)" }

        & $send @{ id = 1; type = 'input_boolean/create'; name = $Name; icon = $Icon }
        $res = & $recv
        if (-not $res.success) { throw "input_boolean/create failed: $($res.error | ConvertTo-Json -Compress)" }
        $res.result
    } finally {
        $ws.Dispose()
    }
}

$existing = Get-HaState -Connection $conn -EntityId $EntityId

if ($existing) {
    Write-Host "$EntityId exists (state: $($existing.state))."
    exit 0
}

Write-Host "$EntityId is missing - creating it via the HA websocket API..."
try {
    $created = New-HaInputBoolean -Connection $conn -Name 'Claude Notifications Enabled' -Icon 'mdi:bell'
    Write-Host "  created: $($created | ConvertTo-Json -Compress)"
} catch {
    Write-Error @"
Could not create the helper automatically: $_

Create it by hand instead:
  Settings -> Devices & Services -> Helpers -> + Create Helper -> Toggle
  Name: "Claude Notifications Enabled"
"@
    exit 1
}

# Newly-created input_booleans default to off, which would silence every
# notification -- turn it on so the default state is "notifications enabled".
Start-Sleep -Seconds 1
Invoke-HaService -Connection $conn -Domain input_boolean -Service turn_on -Body @{ entity_id = $EntityId } | Out-Null
Start-Sleep -Seconds 1

$now = Get-HaState -Connection $conn -EntityId $EntityId
if ($now) {
    Write-Host "$EntityId is now present (state: $($now.state))."
} else {
    Write-Warning "Created the helper but $EntityId did not appear - check Settings -> Helpers."
}
