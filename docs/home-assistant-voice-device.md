# Home Assistant Voice — Device Reference & UX Decisions

Consolidated facts about this specific device and the UX decisions made for
the `claude-voice` project, gathered by directly querying the device/HA and
reading the actual firmware source rather than assuming. See
`docs/superpowers/specs/2026-07-25-ha-voice-claude-integration-design.md`
for the full design rationale.

## Device identity

- Model: Home Assistant Voice Preview Edition (Nabu Casa/ESPHome), entity
  prefix `..._0932b4`.
- Chip: ESP32-S3-WROOM-1. Firmware is fully open source
  (`esphome/home-assistant-voice-pe`, MIT + GPLv3), fully user-flashable.
  ROM-level hardware bootloader — effectively unbrickable via USB/UART
  recovery, though wrong flash/PSRAM variant settings have bricked some
  units in the community (not a bootloader problem, a config problem).
- Firmware version at last check: `26.6.0` (latest as of 2026-07).

## Hardware capabilities

### Microphone / wake word

- Two simultaneous on-device wake-word slots (`select.wake_word`,
  `select.wake_word_2`), each independently routable to a different Assist
  pipeline via `select.assistant` / `select.assistant_2`.
- Built-in stock wake words: `Hey Jarvis`, `Hey Mycroft`, `Okay Nabu`. No
  custom-phrase support in stock firmware at any released version so far —
  confirmed by checking the live device after updating to the latest
  release. A custom phrase (e.g. "Hey Claude") requires training a
  microWakeWord model and building/flashing custom firmware (see Mode 2 in
  the design spec) — there is no simpler path.
- Wake-word engine is microWakeWord (on-device, low latency) — different
  from openWakeWord (server-side, used by satellites like the ATOM Echo
  that stream raw audio to HA). This matters because openWakeWord's
  drop-a-`.tflite`-in-a-folder custom-wake-word workflow does NOT apply
  here; on-device models must be compiled into the firmware.
- Claude Code's own voice dictation (`/voice`) is NOT usable as this
  device's or HA's STT engine: it requires Claude.ai account auth (not an
  API key) and has no public API. HA's Assist pipelines need a
  conventional STT engine (e.g. local Whisper) regardless of which
  conversation agent answers.

### Physical controls

- **Rotary dial** (`platform: rotary_encoder`, GPIO16/18) with an
  integrated push-button ("center button"). Stock behavior: rotate alone →
  volume up/down; hold the center button while rotating → LED ring hue
  change instead.
  - **Rotation itself is NOT exposed to Home Assistant** in stock
    firmware — the sensor has no `name:` in the upstream YAML, so it's
    internal-only, consumed entirely by on-device volume/hue scripts.
    Exposing it (just adding a `name:` via a `!extend` override, no other
    change) is part of the Mode 2 firmware work.
  - The center-button click IS exposed, as part of the same button-press
    event entity below (best guess — the "center button" binary_sensor
    referenced in the volume-control lambda is very likely the same
    physical control as `event.button_press`; not separately confirmed).
- **Button press event**: `event.home_assistant_voice_0932b4_button_press`.
  Discrete event types actually available: `double_press`, `long_press`,
  `triple_press`, `easter_egg_press`. Notably **no plain `single_press`
  event** — a single press is reserved for triggering Assist listening and
  isn't published as a separate automatable event.
- **Mute slider** (physical, side of device): `switch.home_assistant_voice_0932b4_mute`.
  Mirrors the physical slider's live position — confirmed by watching it
  flip from `off` to `on` in HA the moment the slider was physically
  toggled mid-session. Real automation trigger, not just a hardware-only
  mic cutoff.
- **Wake sound toggle**: `switch.home_assistant_voice_0932b4_wake_sound`
  (device's own acknowledgment chime on wake, separate from anything this
  project plays).

### LED ring

- Entity: `light.home_assistant_voice_0932b4_led_ring`.
- `supported_color_modes: [rgb]`, `supported_features: 40` (FLASH + TRANSITION
  bits set; no EFFECT bit, no `effect_list`).
- **Physically 12 individually-addressable LEDs**, but the HA-facing entity
  is a `partition` that merges all 12 into one uniform-color light —
  whole-ring single RGB color only, no per-LED addressing exposed.
- The firmware has internal per-LED chase/animation lambdas (a loading-bar
  chase, symmetric "jack plugged/unplugged" animations) but these are
  hardcoded to specific device states, not exposed as a selectable effect.
- `flash: short` and `flash: long` are both available (this project
  currently only uses `long`). `transition` (smooth fade) is available but
  unused — firmware defaults to a 0ms instant snap unless a transition is
  explicitly requested in the service call.
- **Not currently possible without custom firmware**: showing two colors
  at once (e.g. half-ring blue / half-ring purple for two simultaneously
  pending accounts) — would need exposing the two 6-LED halves as separate
  entities, same class of firmware work as the dial-rotation exposure.

### Speaker / media player

- Entity: `media_player.home_assistant_voice_0932b4_media_player`.
- Services used by this project: `media_player.play_media` (chime),
  `assist_satellite.announce` (TTS, plays its own preannounce chime
  automatically before speaking).
- `assist_satellite.announce` legitimately takes longer than 2 seconds for
  real TTS generation — confirmed empirically (the device spoke
  successfully even when a 2-second-timeout client call reported failure).
  This project gives that specific call a 10-second timeout; other calls
  (LED, chime, state checks) stay at 2 seconds.

### Assist satellite

- Entity: `assist_satellite.home_assistant_voice_0932b4_assist_satellite`.
- Relevant services: `announce`, `start_conversation`, `ask_question`.

## UX decisions made for this project

### Notification behavior (Claude Code session → device)

- **Task finishes** (`Stop` hook): LED solid in the account's color, chime
  only, no speech — a finished task doesn't need narrating.
- **Needs input** (`Notification` hook): LED pulsing in the account's
  color, chime, AND spoken summary naming the account and the message —
  unless quiet submode is active (below), in which case just the chime.
- **Resolved** (`UserPromptSubmit` hook — fires whether the reply was
  typed by hand or injected by a control surface): LED off.
- Per-account LED colors: **personal = `[0,120,255]` (blue)**, **work =
  `[160,32,240]` (purple)**. Used both for notify-state color and as the
  visual "who's selected" indicator while cycling.
- Kill switch: `input_boolean.claude_notifications_enabled` — every
  notify/control action checks this first and no-ops if off. (Helper
  entities like this can't be created via HA's REST API — no endpoint
  exists for it, confirmed by testing 6 variants — so this one is created
  manually via Settings → Helpers rather than scripted.)

### Quiet submode

- Trigger: `switch.home_assistant_voice_0932b4_mute` = `on` (the physical
  slider).
- Spoken output is suppressed entirely. The chime still plays — audio
  isn't fully off, just narration.
- LED behavior is unchanged (it was already carrying the account/status
  info independent of mute state).
- Button/dial control keeps working fully — the actual point of quiet
  submode is full session control with zero spoken output.
- Mode 2 (wake words) needs no special handling — mic is physically off,
  wake-word detection is already impossible.

### Control surfaces (device → Claude Code session)

- **Primary, once Mode 2 firmware lands**: rotate the dial to cycle
  through pending accounts (LED updates live per detent, in that account's
  color), long-press (center-button click) to confirm/send a reply,
  triple-press to dismiss without responding.
- **Fallback, stock firmware, always available**: `double_press`
  substitutes for dial rotation (same cursor, spoken account name instead
  of live LED preview since there's no continuous rotation signal to key
  off of). `long_press`/`triple_press` behave identically either way.
- **Optional, richer**: a Stream Controller ("Soomfon", StreamDock/HotSpot
  platform) macro deck already on this PC, with native plugins for HA
  control, VS Code terminal injection, and window-focus/switch-to — a
  "Claude" page there can do direct per-account approve buttons with zero
  code in this repo. Fully optional; the device's own button/dial keeps
  working without it.
- Chosen over: HA Voice's own on-device custom-wake-word-triggered voice
  commands for control (rejected — button/dial gives precise, silent,
  unambiguous session targeting that voice recognition for short
  imperative phrases wouldn't reliably beat); OS-level blind
  window-focus-and-keystroke automation as the *only* mechanism (rejected
  as the sole path — Stream Controller's VS Code extension API is more
  reliable where available, window-focus automation is the fallback
  `confirm-session.ps1` actually uses under the hood).

### Wake-word routing (Mode 2 — separate subsystem from the above)

- `Okay Nabu` (wake-word slot 1, stock) stays mapped to the existing
  default Assist pipeline for Home Assistant device control — unchanged.
- `Hey Claude` (wake-word slot 2, custom-trained) routes to a second
  Assist pipeline backed by the official `anthropic` HA integration
  (confirmed to exist — no need for a HACS alternative), for freeform
  voice Q&A. Unrelated to controlling a running Claude Code session — this
  is ambient conversation, not session approval.
- Only needs to work reliably for one person's voice — no multi-speaker
  robustness tuning during training.
