# claude-voice/scripts/install-ha-bridge-startup.ps1
#
# Registers ha-bridge.ps1 to start at logon WITHOUT requiring Administrator.
#
# Why this exists alongside install-ha-bridge-task.ps1: Register-ScheduledTask
# needs an elevated session, and UAC elevation cannot be granted
# non-interactively -- it needs a human to click the consent prompt. That left
# the bridge unregistered (and therefore the button, the dial, and the ambient
# fade all dead) whenever nobody had run the elevated installer. The per-user
# Startup folder needs no elevation at all, so this path can be set up
# unattended.
#
# Trade-off vs. the Scheduled Task: the Scheduled Task restarts the process up
# to 3 times if it dies. This does not. In practice that matters less than it
# sounds -- ha-bridge.ps1 has its own outer supervision loop with exponential
# backoff, so connection drops and HA restarts are handled inside the process.
# Only an outright process death goes unrecovered until the next logon. If you
# later run the elevated installer, remove this one first so the bridge does
# not get started twice (see Uninstall below).
#
# Uninstall:
#   Remove-Item "$([Environment]::GetFolderPath('Startup'))\claude-voice-bridge.cmd"

$ErrorActionPreference = 'Stop'

$startup    = [Environment]::GetFolderPath('Startup')
$bridgePath = Join-Path (Resolve-Path $PSScriptRoot) 'ha-bridge.ps1'
$launcher   = Join-Path $startup 'claude-voice-bridge.cmd'

if (-not (Test-Path $bridgePath)) {
    Write-Error "ha-bridge.ps1 not found at $bridgePath"
    exit 1
}

$pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
if (-not $pwsh) { $pwsh = Join-Path $PSHOME 'pwsh.exe' }
if (-not (Test-Path $pwsh)) {
    Write-Error "Could not locate pwsh.exe (looked for it on PATH and in `$PSHOME)"
    exit 1
}

# `start ""` detaches so the console window closes immediately at logon rather
# than leaving a stray window; -WindowStyle Hidden keeps it out of the way.
# The empty "" is the title argument -- without it, cmd treats a quoted path as
# the window title and silently fails to launch anything.
$cmd = @"
@echo off
start "" /b "$pwsh" -NoProfile -WindowStyle Hidden -File "$bridgePath"
"@

Set-Content -Path $launcher -Value $cmd -Encoding ASCII

Write-Host "Installed logon launcher: $launcher"
Write-Host "  -> $pwsh -NoProfile -WindowStyle Hidden -File `"$bridgePath`""
Write-Host ""
Write-Host "It will start automatically at your next logon. To start it right now:"
Write-Host "  Start-Process -FilePath '$pwsh' -ArgumentList '-NoProfile','-WindowStyle','Hidden','-File','$bridgePath' -WindowStyle Hidden"
