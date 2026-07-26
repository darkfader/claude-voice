# claude-voice/scripts/setup-ha-helpers.ps1
Import-Module (Join-Path $PSScriptRoot 'HaClient.psm1') -Force

$conn = Get-HaConnection
$existing = Get-HaState -Connection $conn -EntityId 'input_boolean.claude_notifications_enabled'

if ($existing) {
    Write-Host "input_boolean.claude_notifications_enabled exists (state: $($existing.state))."
} else {
    Write-Host @"
input_boolean.claude_notifications_enabled does not exist yet.
Home Assistant's REST API has no endpoint for creating helpers (confirmed
by testing multiple endpoint patterns -- this isn't a bug in this script,
HA genuinely doesn't expose helper creation over REST). Create it manually:

  Settings -> Devices & Services -> Helpers -> + Create Helper -> Toggle
  Name: "Claude Notifications Enabled"
"@
}
