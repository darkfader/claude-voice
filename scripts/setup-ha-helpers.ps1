# claude-voice/scripts/setup-ha-helpers.ps1
Import-Module (Join-Path $PSScriptRoot 'HaClient.psm1') -Force

$conn = Get-HaConnection
$existing = Get-HaState -Connection $conn -EntityId 'input_boolean.claude_notifications_enabled'

if ($existing) {
    Write-Host "input_boolean.claude_notifications_enabled already exists (state: $($existing.state)) — nothing to do."
    exit 0
}

Invoke-RestMethod -Uri "$($conn.Url)/api/config/input_boolean/config/claude_notifications_enabled" `
    -Method POST -Headers $conn.Headers `
    -Body (@{ name = 'Claude Notifications Enabled'; initial = $true } | ConvertTo-Json)

Write-Host "Created input_boolean.claude_notifications_enabled."
