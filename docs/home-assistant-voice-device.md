# Home Assistant Voice — Device Reference & UX Decisions

Consolidated facts about this specific device and the UX decisions made for
the `claude-voice` project, gathered by directly querying the device/HA and
reading the actual firmware source rather than assuming.

## Device identity

- Model: Home Assistant Voice Preview Edition (Nabu Casa/ESPHome), entity
  prefix `..._0932b4`.
- Chip: ESP32-S3-WROOM-1. Firmware is fully open source
  (`esphome/home-assistant-voice-pe`, MIT + GPLv3), fully user-flashable.
  ROM-level hardware bootloader — effectively unbrickable via USB/UART
  recovery, though wrong flash/PSRAM variant settings have bricked some
  units in the community (not a bootloader problem, a config problem).
- Firmware version at last check: `26.6.0` (latest as of 2026-07). The device
  runs a **custom build** based on that same `26.6.0` tag — see
  `README.md` for the build/flash procedure — not unmodified stock. The
  official
  `update.home_assistant_voice_0932b4` OTA card still tracks stock upstream
  releases; installing from it would silently overwrite the custom build.
  **Do not click Install on that entity** — see `claude-voice/README.md`
  for the full warning.

## Hardware capabilities

### Microphone / wake word

- Two simultaneous on-device wake-word slots (`select.wake_word`,
  `select.wake_word_2`), each independently routable to a different Assist
  pipeline via `select.assistant` / `select.assistant_2`.
- Built-in stock wake words: `Hey Jarvis`, `Hey Mycroft`, `Okay Nabu`. No
  custom-phrase support in stock firmware at any released version so far —
  confirmed by checking the live device after updating to the latest
  release. A custom phrase requires training a microWakeWord model and
  building/flashing custom firmware — there is no simpler path.
  **Update (Mode 2, now built and flashed):** a fourth wake word, `Hey
  Claude`, has been trained and added via a custom firmware overlay
  (`claude-voice/firmware/overlay.yaml`). Four wake words are available on this device
  today: `Hey Jarvis`, `Hey Mycroft`, `Okay Nabu` (stock), and `Hey Claude`
  (custom, routes to a second Assist pipeline backed by the Anthropic
  conversation agent — see "Wake-word routing" below).
  - **Sensitivity limitation:** the physical "Wake word sensitivity" select
    (`select.home_assistant_voice_0932b4_wake_word_sensitivity` —
    Slightly/Moderately/Very sensitive) only adjusts `probability_cutoff`
    for the three stock models (`okay_nabu`, `hey_jarvis`, `hey_mycroft`);
    the overlay never extended that lambda to cover `hey_claude`, so this
    on-device control does nothing for it. `Hey Claude`'s cutoff (`0.5`,
    baked into `models/hey_claude.json`) is more aggressive than any stock
    model's (`0.85`–`0.97` at "Slightly sensitive"), and this wake word
    routes to a paid Anthropic API, so false wakes have a real cost.
    Sensitivity is fixed at flash time — retraining and reflashing the
    model is currently the only way to change it.
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
  integrated push-button ("center button"), **24 detents per revolution**.
  Stock behavior was: rotate alone → volume up/down; hold the center button
  while rotating → LED ring hue. **Custom firmware changes both** — see
  "Dial behaviour (custom firmware)" below. Bare rotation is now a Claude
  session switcher and volume moved to centre-held rotation.
  - The rotation sensor `sensor.bedroom_home_assistant_voice_0932b4_dial_rotation`
    still exists and still counts, but **nothing reads it any more**. It was
    unusable as a gesture source once volume also lived on the dial: both
    gestures drive the same counter, and both volume scripts end with
    `sensor.rotary_encoder.set_value: 0`, so a reset from a nonzero value
    reads as a large negative delta. The bridge consumes an explicit
    `esphome.claude_dial` event instead.
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
- `flash: short` and `flash: long` are both available; this project uses
  `short`, empirically a one-shot of about 10 seconds (see "Notification
  behavior" below for why the ordering of the solid-color call and the
  flash call around it matters). `transition` (smooth fade) is available
  but unused — firmware defaults to a 0ms instant snap unless a transition
  is explicitly requested in the service call.
- **Not currently possible without custom firmware**: showing two colors
  at once (e.g. half-ring in each of two simultaneously-pending sessions'
  own colors) — would need exposing the two 6-LED halves as separate
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

- **Task finishes** (`Stop` hook), nothing else pending: LED solid **dim**
  in the session's color, chime only, no speech — a finished task doesn't
  need narrating. If another session is already pending, the ring is left
  alone entirely (a finished task must never take the ring away from one
  that still needs the human) — but the **chime still plays** either way;
  only the ring is conditional on `OtherPendingCount`. `notify-ha.ps1` also
  marks this session as the active one (`Set-ActiveSession`) regardless of
  whether the ring was actually touched, so whichever dim glow is showing
  once nothing is pending always has a live idle-fade timer attached to it
  — see the idle-fade note below. (This was a real bug until fixed: `stop`
  used to only call `Clear-PendingSession`, so a dim ring left by a
  finished turn had no timer watching it and could glow indefinitely if the
  human walked away — the exact overnight-glow case the idle timeout exists
  to prevent, on a device that lives in a bedroom.)
- **Needs input** (`Notification` hook), nothing else pending: LED
  full-brightness **solid** in the session's color, with a single one-shot
  flash on arrival to catch the eye, chime, AND spoken summary naming the
  session and the message — unless quiet submode is active (below), in
  which case just the chime. If another session is already pending, only
  the chime plays and the ring is **not** touched — see "Second
  notification while one is pending" below.
- **Resolved** (`UserPromptSubmit` hook — fires whether the reply was
  typed by hand or injected by a control surface), nothing else pending:
  LED becomes the **dim** ambient "you're working here" indicator in the
  session's color — deliberately **not** turned off. Only the 10-minute
  idle-fade check in `ha-bridge.ps1` (`Invoke-IdleCheck`) turns it off,
  and only once nothing is pending. Turning it off here instead would mean
  the ambient indicator never showed at all.
- **Solid, never pulsing.** `flash: short` on this hardware is a one-shot
  effect (~10s) that reverts the light to whatever it was showing right
  before the flash fired — not to "off". `Invoke-HaLed` in `HaClient.psm1`
  always sets the solid color *first* and only fires the flash ~800ms
  later (`$FlashDelayMs`), specifically so the flash has something correct
  to revert to. Verified live: with that gap, the ring held its color at
  t+1/5/10/16s; without it, the ring went dark at t+16s (it had captured
  and reverted to the pre-solid "off" state instead). A sustained pulse
  isn't achievable on this hardware without fighting the firmware, so the
  UI never claims one — the ring holds solid for as long as it's pending.
- **Second notification while one is pending**: chimes only, ring
  untouched. This is `Get-NotifyPlan`'s `OtherPendingCount -gt 0` branch —
  it exists so a second arrival can't steal the ring out from under a
  decision already in progress on the first one.
- **Per-session LED colors, not per-account.** `SessionColor.psm1` derives
  a color from a SHA256 hash (not `.NET`'s `GetHashCode`, which is
  randomized per process and would give a different color every run) of
  the session's *normalized project path*, quantized into 16 hues at full
  saturation/value (`ConvertFrom-HueSlot`). This makes a project's color:
  (a) **stable across restarts** — same path hashes to the same preferred
  slot every time — and (b) not a hardcoded per-account constant, so a
  brand-new project needs zero code changes to get a distinct color. If
  two sessions are pending simultaneously and their preferred hues would
  collide, `Resolve-SessionColorSlot` nudges the second to the next free
  slot (linear probe over the 16 slots) so two sessions pending at once
  are never color-identical — this includes two sessions in the *same*
  project, which also get an ordinal suffix on their spoken/display name
  (`Get-SessionDisplayName`, e.g. `HomeAssistant` then `HomeAssistant 2`)
  since color alone isn't a legible way to tell them apart out loud.
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
- LED behavior is unchanged (it was already carrying the
  which-session/what-state info independent of mute state).
- Button/dial control keeps working fully — the actual point of quiet
  submode is full session control with zero spoken output.
- Mode 2 (wake words) needs no special handling — mic is physically off,
  wake-word detection is already impossible.
- Dial-cycling speaks the selected session's name via TTS when unmuted, and
  chimes instead when muted (`Invoke-DialSettleCheck` in `ha-bridge.ps1`);
  `double_press` chimes on a successful activate. Speech happens on
  **settle**, not per detent — an earlier design spoke on every detent,
  which queued overlapping 10-second announce calls and stalled the
  bridge's event loop. The 400ms settle window is what makes a spoken name
  safe: a whole gesture collapses into one utterance.

### Control surfaces (device → Claude Code session)

- **Primary**: rotate the dial to cycle sessions, long-press
  (center-button click) to jump to the selected session, triple-press to
  dismiss without responding. Long-press is deliberately **"focus", not
  "confirm"** — it brings the session's VS Code window to the front and
  clears its pending light, but types nothing
  (`confirm-session.ps1 -FocusOnly`). The `Notification` hook fires mainly
  on permission prompts, so auto-sending a reply from across the room would
  mean approving something unseen; a deliberate typed reply happens at the
  desk instead (by hand, or via the optional Stream Controller page below).
  - **Two detents make one session step.** 24 detents per revolution
    against 12 LEDs means 2 detents is exactly one LED position, and one
    step per detent would be far too twitchy for a short session list — a
    small flick would blow past the whole thing. Accumulation lives in
    `ha-bridge.ps1` (`$script:DialDetentsPerStep`), not the firmware, so it
    is tunable without a reflash; the firmware has no notion of how many
    sessions exist. A change of direction resets the accumulator, so a
    cw-then-ccw wobble does not bank half a step.
  - **The ring updates per step; focus waits for the dial to settle.** Each
    step repaints the ring immediately, but the window switch fires once,
    400ms after the last detent — turning three steps gives one window
    switch, not three. The spoken session name also happens on settle.
  - **The LED is now genuinely visible during rotation.** It previously was
    not: the stock `control_leds` lambda treated the dial as "recently
    touched" for about a second after the last detent and drove the same
    strip with its own "Volume Display" effect, overwriting our LED call.
    Custom firmware stops setting `dial_touched` on bare rotation, so that
    animation no longer runs and the per-session colour stays on screen.
  - **No 2+ pending gate.** The dial cycles every session seen in the last
    4 hours, pending or not. The old gate existed because the dial was also
    the volume knob, so cycling had to stay out of the way; volume has
    moved, and a switcher that only worked when two things happened to be
    pending was inert almost always.
  - Cycling order is **`firstSeen` order over the `known` map**, from
    `Get-KnownCycleTarget` — stable, not most-recently-used. MRU suits
    Alt-Tab, where the list is invisible; on a physical dial it means the
    list reorders under your fingers, so the same rotation stops landing in
    the same place.
- **`double_press` activates the selected session** — focuses its window
  and leaves its pending light lit. It no longer cycles; the dial owns
  that, which is precisely what freed the gesture. The difference from
  long-press is that long-press also clears.
  - It resolves against the **`known`** map, not `sessions`, unlike
    long/triple-press. The dial sets the cursor from `known`, so resolving
    against pending sessions would ignore the dial's selection outright —
    and with exactly one session pending it would silently activate that
    one instead of the one the ring is showing. `Get-ButtonAction` takes
    `-KnownSessions` for this, and only `double_press` consults it.
- **Optional, richer**: a Stream Controller ("Soomfon", StreamDock/HotSpot
  platform) macro deck already on this PC, with native plugins for HA
  control, VS Code terminal injection, and window-focus/switch-to — a
  "Claude" page there can do direct per-project approve buttons with zero
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

## Dial behaviour (custom firmware)

Bare rotation fires the Home Assistant event `esphome.claude_dial` with
`data.direction` of `cw` or `ccw`, and does nothing on-device. Volume lives
on centre-button-and-rotate.

The `sensor…dial_rotation` entity still exists and still counts, but nothing
reads it any more. Both volume scripts reset it to `0` about a second after
the last detent, which is why the old counter-watching approach needed a
zero-sentinel skip — the event carries the gesture unambiguously instead.

Rotation no longer sets the `dial_touched` flag, so the firmware's volume-bar
animation no longer paints over the ring. Session colours stay visible while
you turn the dial. Centre-held rotation still sets it, where the bar is the
correct display.

Centre-held rotation sets `group_volume_changed` for one second afterwards.
That flag is what stops releasing the button from also firing the
single-click action — without it, every volume nudge would start the
assistant or stop the music on release.

**LED hue control is gone.** Centre-held rotation used to set the ring's hue;
volume displaced it. Nothing preserves it, deliberately: here hue means
*which session* and brightness means *attention*, so a manually-set hue
fought that scheme and would be overwritten by the next notification anyway.

### How the overlay overrides the handlers

ESPHome merges package lists by **concatenation**, so handlers declared in
`overlay.yaml` are *appended* to the stock ones rather than replacing them —
verified with `esphome config`, which showed stock `control_volume` and
`control_hue` running first and ours second. Bare rotation would still have
changed volume.

`on_clockwise: !remove` strips the stock handlers cleanly, but a key cannot
be both removed and assigned in the same mapping. So the two halves are split
across the merge order:

- `overlay.yaml` (a package) carries the `!remove` tags and the
  `claude_held_volume` script.
- `custom-voice-pe.yaml` (the main config, merged **after** all packages)
  carries the replacement handlers.

Check the merged result with `esphome config custom-voice-pe.yaml` after any
change here — the failure mode is silent, and looks exactly like the feature
simply not working.

### There is no touch sensor

The device has exactly two physical inputs: the rotary encoder (`GPIO16` /
`GPIO18`) and `center_button` (`GPIO0`). There is no capacitive touch
hardware — no `esp32_touch` component, no touch pads.

The `dial_touched` global is easy to misread as one. It is a
rotation-recency flag: set `true` when the encoder turns, cleared about a
second later, and used only to decide whether to draw the volume bar.
