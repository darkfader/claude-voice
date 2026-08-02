# Compares the compile timestamp baked into the built binary against the one
# the running device reports. A mismatch means the last flash did not take --
# the exact failure that cost an hour on 2026-07-27, when two OTAs reported
# success while the device kept running the previous day's image.
#
# Run this after every flash. File mtimes are refreshed even by the silent
# no-op build path, so they prove nothing; only these two values do.
param(
    [string]$BinPath = (Join-Path $PSScriptRoot '..\firmware\.esphome\build\home-assistant-voice\build\firmware.ota.bin'),
    # How long to keep retrying while HA reports the entity missing or
    # 'unavailable'/'unknown' before giving up. Overridable so ad-hoc checks
    # (or a mismatch, which resolves on the very first read -- see below)
    # don't have to eat a full reconnect window.
    [int]$RetrySeconds = 30,
    [int]$RetryIntervalSeconds = 3
)
Import-Module (Join-Path $PSScriptRoot 'HaClient.psm1') -Force

if (-not (Test-Path $BinPath)) { Write-Error "Binary not found: $BinPath"; exit 1 }

$txt = [System.Text.Encoding]::ASCII.GetString((Get-Content $BinPath -AsByteStream -Raw))
# The build embeds 16 remote files and 10 wake-word manifests/models
# alongside our own timestamp, so this regex can in principle match more
# than one date-shaped string in the binary. Picking "the first one" would
# silently validate against whichever artifact happens to sit earliest in
# the binary layout -- not necessarily App's own build time -- with no sign
# anything was ambiguous. So: exactly one distinct match is required. Zero
# or more-than-one are both reported as failures rather than resolved by
# picking one, because the whole point of this script is to refuse to
# report success when it cannot actually prove which build is running.
# @(...) forces an array even when exactly one match survives -Unique --
# without it, PowerShell unwraps a single-item pipeline result to a bare
# string, and `[0]` below would then index its first *character* ("2"),
# not the first *element*. Silently wrong in the single-match (common) case.
$timestampMatches = @([regex]::Matches($txt, '\d{4}-\d\d-\d\d \d\d:\d\d:\d\d') |
    ForEach-Object { $_.Value } | Select-Object -Unique)

if ($timestampMatches.Count -eq 0) {
    Write-Error 'Could not read a compile timestamp from the binary.'
    exit 1
}
if ($timestampMatches.Count -gt 1) {
    Write-Error ("AMBIGUOUS: found $($timestampMatches.Count) distinct timestamp-shaped strings in the binary " +
        "($($timestampMatches -join ', ')) -- cannot tell which one is App's own build time. " +
        'Inspect the binary manually (see claude-voice/README.md) before trusting this checker.')
    exit 1
}
$built = $timestampMatches[0]

$conn = Get-HaConnection
# Entity ID confirmed live (Task 1): ESPHome's `text_sensor:` platform
# entities surface in HA under the `sensor.` domain (HA has no `text_sensor.`
# domain), and this instance area-prefixes entity IDs with "bedroom_" -- the
# same pattern used for the dial rotation sensor.
$entityId = 'sensor.bedroom_home_assistant_voice_0932b4_firmware_build'

# Right after a flash the device reboots (observed ~15-20s) before HA's
# ESPHome integration reconnects. During that window the entity can either
# not exist yet at all (Get-HaState's underlying GET 404s, so $state is
# $null) or exist but report HA's own 'unavailable'/'unknown' placeholder
# states -- neither one says anything about which binary is running, so
# neither should be reported as a definitive "flash did not take". This
# script is meant to be run right after every flash -- exactly when that
# window is most likely to be open -- so it retries for a bounded time
# instead of either hanging forever or treating "still booting" as failure.
$retryUntil = (Get-Date).AddSeconds($RetrySeconds)
$state = $null
while ($true) {
    $state = (Get-HaState -Connection $conn -EntityId $entityId).state
    if ($state -and $state -notin @('unavailable', 'unknown')) { break }
    if ((Get-Date) -ge $retryUntil) { break }
    Start-Sleep -Seconds $RetryIntervalSeconds
}

Write-Host "binary  : $built"
Write-Host "device  : $state"

if (-not $state) {
    Write-Error "Device did not report a build within ${RetrySeconds}s. Old firmware, entity '$entityId' missing, or HA unreachable."
    exit 1
}
if ($state -in @('unavailable', 'unknown')) {
    # Deliberately a separate branch from the -notlike check below: this is
    # "cannot determine yet", not "determined to be wrong". Conflating the
    # two would make the exact post-OTA reconnect window this script exists
    # to be run in also the window where it is most likely to cry wolf.
    Write-Error ("CANNOT VERIFY: entity is still '$state' after ${RetrySeconds}s. This is normal for the first " +
        '~15-20s after an OTA while the device reboots and reconnects; if it persists, check the device is ' +
        'powered and on Wi-Fi. Not reporting OK, because the running build is unknown -- not confirmed matching.')
    exit 1
}
if ($state -notlike "$built*") {
    Write-Error 'MISMATCH: the running firmware is not the binary you just built. The flash did not take.'
    exit 1
}
Write-Host 'OK: device is running the binary you built.' -ForegroundColor Green
# Explicit, not implicit fallthrough: this is an unattended gate, and
# $LASTEXITCODE only reflects the last *native* command unless a script sets
# it itself -- relying on fallthrough success previously left the exit code
# undefined here when this script was invoked after another command that had
# already set a non-zero $LASTEXITCODE (observed while testing this fix).
exit 0
