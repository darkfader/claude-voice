# Compares the compile timestamp baked into the built binary against the one
# the running device reports. A mismatch means the last flash did not take --
# the exact failure that cost an hour on 2026-07-27, when two OTAs reported
# success while the device kept running the previous day's image.
#
# Run this after every flash. File mtimes are refreshed even by the silent
# no-op build path, so they prove nothing; only these two values do.
param(
    [string]$BinPath = (Join-Path $PSScriptRoot '..\firmware\.esphome\build\home-assistant-voice\build\firmware.ota.bin')
)
Import-Module (Join-Path $PSScriptRoot 'HaClient.psm1') -Force

if (-not (Test-Path $BinPath)) { Write-Error "Binary not found: $BinPath"; exit 1 }

$txt = [System.Text.Encoding]::ASCII.GetString((Get-Content $BinPath -AsByteStream -Raw))
$built = ([regex]::Matches($txt, '\d{4}-\d\d-\d\d \d\d:\d\d:\d\d') |
    ForEach-Object { $_.Value } | Select-Object -Unique | Select-Object -First 1)

$conn = Get-HaConnection
# Entity ID confirmed live (Task 1): ESPHome's `text_sensor:` platform
# entities surface in HA under the `sensor.` domain (HA has no `text_sensor.`
# domain), and this instance area-prefixes entity IDs with "bedroom_" -- the
# same pattern already documented for the dial rotation sensor in Task 4 of
# docs/superpowers/plans/2026-07-25-ha-voice-claude-wakeword-firmware.md.
$state = (Get-HaState -Connection $conn -EntityId 'sensor.bedroom_home_assistant_voice_0932b4_firmware_build').state

Write-Host "binary  : $built"
Write-Host "device  : $state"

if (-not $built) { Write-Error 'Could not read a compile timestamp from the binary.'; exit 1 }
if (-not $state) { Write-Error 'Device did not report a build. Old firmware, or entity missing.'; exit 1 }
if ($state -notlike "$built*") {
    Write-Error 'MISMATCH: the running firmware is not the binary you just built. The flash did not take.'
    exit 1
}
Write-Host 'OK: device is running the binary you built.' -ForegroundColor Green
