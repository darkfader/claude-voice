# Firmware API

**Generated — do not edit by hand.** Regenerate with:

```powershell
./claude-voice/scripts/Export-FirmwareApi.ps1
```

Generated 2026-07-28 04:39 from `custom-voice-pe.yaml`.

## Entities exposed to Home Assistant

An entity appears here when its platform block in the merged config carries
a `name:` key (including an explicit empty one, which ESPHome renders as the
device's own name) and is not `internal: true`. Domain reflects where the
entity actually surfaces in HA, not the ESPHome YAML key it is declared under --
notably, ESPHome `text_sensor:` entities are listed here as `sensor`, since HA
has no `text_sensor` domain.

Two categories of real HA entity this table cannot ever show, by nature of
parsing config text rather than querying HA:

1. Entities an ESPHome component synthesizes from *other* configuration
   instead of declaring with its own `name:` key -- e.g. `voice_assistant`/
   `micro_wake_word` create extra `assist_satellite`/`select.*` entities in HA
   when multiple wake-word or assistant pipeline slots are configured. There is
   no `name:` text anywhere in the merged config for this parser to find.
2. Rows below marked *(disabled by default)* are declared entities
   (`disabled_by_default: true` in the merged config) that report no live
   state in HA until a user enables them -- the table can show that they
   *exist*, not whether HA currently reports a state for them.

| Domain | Name | Platform |
|---|---|---|
| `button` | Restart *(disabled by default)* | `restart` |
| `event` | Button press | `template` |
| `light` | LED Ring | `partition` |
| `media_player` | Media Player | `speaker_source` |
| `select` | Wake word sensitivity | `template` |
| `sensor` | Dial Rotation | `rotary_encoder` |
| `sensor` | Firmware Build | `template` |
| `switch` | Beta firmware *(disabled by default)* | `template` |
| `switch` | Mute | `template` |
| `switch` | Wake sound | `template` |
| `text` | Claude Ring State | `template` |
| `update` | *(device name)* | `http_request` |

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

