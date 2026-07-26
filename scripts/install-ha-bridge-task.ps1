# claude-voice/scripts/install-ha-bridge-task.ps1
$scriptPath = Join-Path $PSScriptRoot 'ha-bridge.ps1'
$action = New-ScheduledTaskAction -Execute 'pwsh.exe' -Argument "-NoProfile -WindowStyle Hidden -File `"$scriptPath`""
$trigger = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit (New-TimeSpan -Days 0)

Register-ScheduledTask -TaskName 'ClaudeVoiceHaBridge' -Action $action -Trigger $trigger -Settings $settings -Description 'Watches HA Voice button/mute events for Claude Code session control' -Force
Write-Host "Registered Scheduled Task 'ClaudeVoiceHaBridge' (runs at logon, restarts up to 3x on failure)."
