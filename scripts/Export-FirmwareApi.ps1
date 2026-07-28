# Regenerates claude-voice/docs/firmware-api.md from the REAL merged ESPHome
# config, so the entity list cannot drift from the firmware. Run after any
# change to overlay.yaml or custom-voice-pe.yaml.
#
# Must run where `esphome` is on PATH. Unlike compile/upload this only reads
# config, so the Git Bash no-op-build hazard does not apply here.
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\firmware\custom-voice-pe.yaml'),
    [string]$OutPath    = (Join-Path $PSScriptRoot '..\docs\firmware-api.md')
)
$ErrorActionPreference = 'Stop'

Push-Location (Split-Path $ConfigPath -Parent)
try {
    $merged = & esphome config (Split-Path $ConfigPath -Leaf) 2>&1
} finally {
    Pop-Location
}
if ($LASTEXITCODE -ne 0) { Write-Error "esphome config failed"; exit 1 }

# --- Parsing -----------------------------------------------------------
#
# `esphome config` is not a stable API and its dump is not flat: an entity's
# `name:` sits at a fixed indentation (2-space domain -> 2-space "- platform:"
# list item -> 4-space item properties), but plenty of OTHER `name:` keys
# exist at deeper indentation that are not entities at all -- e.g. every
# addressable_lambda light effect ("Waiting for Command", "Thinking", ...)
# carries its own `name:` ten spaces in, and the top-level `esphome:`/
# `esp32_ble:`/`project:` blocks have `name:` two spaces in. A naive "does
# this line match `name:`" scan (regardless of indentation, and regardless
# of `internal: true`) was tried against the real output first and pulled in
# ~40 rows, most of them light-effect names mislabeled under whatever
# `platform:` last happened to be seen, plus internal-only sensors that
# never reach Home Assistant. That is a generator producing a confidently
# wrong document, which is worse than none -- see task-9-report.md.
#
# Fixed approach: track entity boundaries by exact indentation instead of
# just line content, and only trust `name:`/`internal:` when they are direct
# properties of the current entity's list item (exactly 4 spaces in), not
# nested inside `effects:`, `segments:`, lambda bodies, etc.
#
# The original domain-header regex `^([a-z_]+):\s*$` also can't match keys
# containing digits (`esp32:`, `esp32_ble:` -- `i2c:` is fine but those two
# are not under `[a-z_]+`), which would leave `$domain` stuck on a stale
# value while scanning through those blocks. Harmless in practice here (every
# such block was checked and none contains a stray 4-space `name:`/
# `internal:` that would get mis-attributed) but fixed anyway since it costs
# nothing and removes a landmine for the next person who adds a domain.
$rows = @()
$domain = ''
$inEntity = $false
$curPlatform = $null
$curName = $null
$curNameSeen = $false
$curInternal = $false

function Flush-Entity {
    if ($script:inEntity -and $script:curNameSeen -and -not $script:curInternal) {
        # ESPHome's `text_sensor:` platform has no corresponding Home
        # Assistant domain -- HA surfaces those entities under `sensor.`
        # (confirmed live: the firmware-build text_sensor is
        # sensor.bedroom_home_assistant_voice_0932b4_firmware_build, not
        # text_sensor.*). Mapping it here means the table's Domain column
        # documents where the entity actually lands in HA, not just what the
        # ESPHome YAML happens to call the platform.
        $displayDomain = if ($script:domain -eq 'text_sensor') { 'sensor' } else { $script:domain }
        # `name: ''` is a deliberate ESPHome idiom (seen on the OTA `update:`
        # entity) meaning "use the device's own name as the entity name" --
        # it is NOT the same as no name at all, and the entity IS exposed to
        # HA (confirmed live: update.home_assistant_voice_0932b4). A plain
        # PowerShell truthiness check (`if ($name -and $domain)`) would have
        # silently dropped it, since '' is falsy; tracking "was a name: key
        # seen at all" separately from "what string did it hold" avoids that.
        $displayName = if ([string]::IsNullOrEmpty($script:curName)) { '*(device name)*' } else { $script:curName }
        $script:rows += [PSCustomObject]@{ Domain = $displayDomain; Name = $displayName; Platform = $script:curPlatform }
    }
}

foreach ($line in $merged) {
    $text = "$line"
    if ($text -match '^([a-z][a-z0-9_]*):\s*$') {
        Flush-Entity
        $domain = $matches[1]
        $inEntity = $false
        continue
    }
    if ($text -match '^  - platform:\s*(\S+)\s*$') {
        Flush-Entity
        $curPlatform = $matches[1]
        $curName = $null
        $curNameSeen = $false
        $curInternal = $false
        $inEntity = $true
        continue
    }
    if ($inEntity -and $text -match '^    name:\s?(.*)$') {
        $curName = $matches[1].Trim().Trim("'`"")
        $curNameSeen = $true
        continue
    }
    if ($inEntity -and $text -match '^    internal:\s*true\s*$') {
        $curInternal = $true
        continue
    }
}
Flush-Entity

# --- Render --------------------------------------------------------------

$sb = [System.Text.StringBuilder]::new()
[void]$sb.AppendLine('# Firmware API')
[void]$sb.AppendLine()
[void]$sb.AppendLine('**Generated — do not edit by hand.** Regenerate with:')
[void]$sb.AppendLine()
[void]$sb.AppendLine('```powershell')
[void]$sb.AppendLine('./claude-voice/scripts/Export-FirmwareApi.ps1')
[void]$sb.AppendLine('```')
[void]$sb.AppendLine()
[void]$sb.AppendLine("Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm') from ``custom-voice-pe.yaml``.")
[void]$sb.AppendLine()
[void]$sb.AppendLine('## Entities exposed to Home Assistant')
[void]$sb.AppendLine()
[void]$sb.AppendLine('An entity appears here when its platform block in the merged config carries')
[void]$sb.AppendLine('a `name:` key (including an explicit empty one, which ESPHome renders as the')
[void]$sb.AppendLine('device''s own name) and is not `internal: true`. Domain reflects where the')
[void]$sb.AppendLine('entity actually surfaces in HA, not the ESPHome YAML key it is declared under --')
[void]$sb.AppendLine('notably, ESPHome `text_sensor:` entities are listed here as `sensor`, since HA')
[void]$sb.AppendLine('has no `text_sensor` domain.')
[void]$sb.AppendLine()
[void]$sb.AppendLine('Two things this table cannot show: (1) a handful of live entities --')
[void]$sb.AppendLine('`assist_satellite`, and 5 of the 6 `select.*` entities (assistant x2, wake word')
[void]$sb.AppendLine('x2, finished-speaking detection) -- are synthesized by the `voice_assistant`/')
[void]$sb.AppendLine('`micro_wake_word` components from *other* config (e.g. having two wake-word')
[void]$sb.AppendLine('slots configured) rather than from a `name:` key, so they cannot be recovered')
[void]$sb.AppendLine('by scanning for `name:`. (2) rows here with `disabled_by_default: true` in the')
[void]$sb.AppendLine('config (currently the `Beta firmware` switch and the `Restart` button) exist as')
[void]$sb.AppendLine('entities but report no state in HA until a user enables them.')
[void]$sb.AppendLine()
[void]$sb.AppendLine('| Domain | Name | Platform |')
[void]$sb.AppendLine('|---|---|---|')
foreach ($r in ($rows | Sort-Object Domain, Name)) {
    [void]$sb.AppendLine("| ``$($r.Domain)`` | $($r.Name) | ``$($r.Platform)`` |")
}
[void]$sb.AppendLine()
[void]$sb.AppendLine(@'
## Ring state encoding

`text.bedroom_home_assistant_voice_0932b4_claude_ring_state` carries the whole
per-thread display. One group per thread, semicolons between, max 255 chars:

```
<ringSlot>,<rrggbb>,<state>[;...]
3,dfff00,w;7,80ff00,i
```

| Field | Meaning |
|---|---|
| `ringSlot` | LED index 0-11; a thread's stable home position |
| `rrggbb` | the thread's colour, lowercase hex, no `#` |
| `state` | see below |

| State | Rendering |
|---|---|
| `i` | idle — steady, brightness 25 |
| `w` | working — orbiting, brightness 140, skipping parked slots |
| `s` | selected — steady, brightness 255 |
| `a` | attention — pulsing 1 Hz between 255 and 120 |
| `A` | arriving — 2 s whole-ring flash, then rendered as `a` |

Only one state per thread; the PC resolves precedence
(`attention > selected > working > idle`) before encoding. An empty or
unparseable value renders nothing and hands the ring back to stock behaviour.

At most twelve threads are drawn. `A` is sent once on arrival; the firmware
times the flash itself and needs no follow-up.

## Build identity

`sensor.bedroom_home_assistant_voice_0932b4_firmware_build` reports
`<compile-time> ring<N>`, e.g. `2026-07-28 01:14:22 ring1`. `ring<N>` is the
ring-state protocol version, bumped whenever the encoding above changes
incompatibly. Compare it against the binary after every flash with
`./claude-voice/scripts/Check-FirmwareBuild.ps1`.
'@)

Set-Content -Path $OutPath -Value $sb.ToString() -Encoding UTF8
Write-Host "Wrote $OutPath ($($rows.Count) entities)"
