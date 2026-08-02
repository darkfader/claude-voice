# claude-voice

Claude Code ↔ Home Assistant Voice integration.

> **This is a personal project, built for one person's desk and one device.**
> Behaviour changes whenever the author feels like it — gestures get
> reassigned, colours and timings get retuned, features appear and disappear
> without deprecation or migration. There is no stability guarantee, no
> versioning policy, and no promise that today's controls mean the same thing
> tomorrow. Anything here worth relying on, fork.

- **Using it day to day → [`docs/user-guide.md`](docs/user-guide.md)** — what
  the lights and sounds mean, the button/dial controls, and how to see what
  happened.
- Installing it → this file.
- Hardware facts and UX decisions → [`docs/home-assistant-voice-device.md`](docs/home-assistant-voice-device.md).

## Components

Pure logic (no I/O, fully unit-tested — these hold the decision-making):
- `scripts/NotifyPlan.psm1` — `Get-NotifyPlan`: given an event, a session's
  display name, message, mute state and how many *other* sessions are
  pending, decides what the LED, sound and speech should be.
- `scripts/ButtonAction.psm1` — `Get-ButtonAction` / `Get-KnownCycleTarget`:
  decides what a button press or dial turn should do. The button acts on
  *pending* sessions; the dial cycles *known* ones (anything seen in the last
  4 hours) in stable `firstSeen` order, in either direction, wrapping at both
  ends. Never alphabetical — session ids are random, so sorting by name would
  be meaningless.
- `scripts/WindowFocus.psm1` — `Get-ProjectWindowPattern` /
  `Find-SessionWindow`: maps a session's own project name to its VS Code
  window. Derived from the session, not a hardcoded pattern — adding a new
  project needs no code change.
- `scripts/SessionColor.psm1` — `Get-ProjectColorSlot` /
  `ConvertFrom-HueSlot` / `Resolve-SessionColorSlot` / `Get-SessionOrdinal` /
  `Get-SessionDisplayName`: derives a stable per-project LED color from a
  hash of the project's path (same project, same color, every run,
  including after a restart), nudges apart two colors that would otherwise
  collide when their sessions are pending simultaneously, and composes the
  spoken/display name (with an ordinal suffix for repeat sessions in the
  same project).
- `scripts/AmbientState.psm1` — `Test-AmbientIdleExpired`: pure decision for
  whether the dim ambient indicator has been idle long enough to fade to
  off. Pending always outranks active, and an absent/unparseable
  `activeSince` never expires anything.

I/O and side effects (verified live rather than unit-tested, since they talk
to hardware, HTTP and the Windows desktop):
- `scripts/HaClient.psm1` — thin wrapper around the HA REST API. Single source
  of HA credentials via `Get-HaConnection` (see Step 0).
- `scripts/PendingState.psm1` — tracks which sessions are waiting on input,
  which one is active (ambient indicator), and which one the ring is
  currently displaying, in `state/pending.json`. Writes are atomic
  (temp-file + rename) so an unlocked reader can never observe a torn
  write, and serialised across concurrent hook processes by a named,
  reentrant mutex. `Register-PendingNotification` / `Resolve-PendingSession`
  are compound mutators that read, derive (colour slot, ordinal, how many
  *other* sessions are pending) and write as one locked critical section, so
  two hooks firing at once can't both resolve the same colour slot.
- `scripts/RingDisplay.psm1` — `Set-RemainingLed`: hands the ring to the
  oldest remaining pending session (or turns it off if none remain). Shared
  by `ha-bridge.ps1` (long-press/triple-press) and `notify-ha.ps1`
  (replied/stopped) so the two call sites can't diverge on what "resolved,
  others still pending" looks like.
- `scripts/notify-ha.ps1` — the entry point Claude Code hooks call.
- `scripts/confirm-session.ps1` — focuses a session's VS Code window and, by
  default, types a reply; called with `-FocusOnly` (what the device's
  long-press uses) it focuses and clears the pending light but types
  nothing.
- `scripts/ha-bridge.ps1` — persistent background process. Subscribes to HA's
  event stream and reacts to **button presses and dial rotation**; reconnects
  with backoff if HA restarts. Runs as a Scheduled Task (Step 5). It does not
  subscribe to the mute switch — mute is polled on demand, at the moment it
  needs to decide whether to speak.

Setup helpers:
- `scripts/setup-ha-helpers.ps1` — reports whether the kill-switch helper
  exists (it cannot create it; see Step 1).
- `scripts/install-ha-bridge-task.ps1` — registers the Scheduled Task.
  Requires an elevated PowerShell (Step 5).

## Running the tests

```powershell
Import-Module Pester -MinimumVersion 5.0 -Force   # NOT the Windows-bundled 3.4.0
Invoke-Pester claude-voice/scripts/*.Tests.ps1 -Output Detailed
```

74 tests, ~10-15 seconds. Two things worth knowing:

- **Pester 5+ is required.** Windows ships a bundled Pester 3.4.0 that does
  not support `BeforeAll`/`BeforeEach` and fails confusingly if it loads
  instead — hence the explicit `-MinimumVersion`.
- **The suite is isolated from your live hooks.** Each test runs against its
  own throwaway state file and its own uniquely-named mutex, so running it
  while Claude Code sessions are active neither blocks your real hooks nor
  produces spurious failures. (Before that isolation existed, consecutive
  full-suite runs gave 6/6, 6/6, then 4/6.)

`ha-bridge.ps1` itself has no automated coverage — it's a top-level script
wrapping an infinite supervision loop, so it isn't importable for testing. Its
decision logic lives in `ButtonAction.psm1`, which is tested; the loop and the
HA calls around it are verified by running it.

## Mode 2: Custom firmware ("Hey Claude" wake word + dial rotation)

Separate from the notification/control-surface setup below, this device
also runs **custom ESPHome firmware** that adds a fourth wake word,
"Hey Claude" (routed to an Anthropic-backed
Assist pipeline for freeform Q&A), and exposes the dial's rotation to Home
Assistant so `ha-bridge.ps1` can cycle pending sessions by rotating the
dial instead of double-pressing the button.

> **Do not click "Install" on the `update.home_assistant_voice_0932b4`
> entity in the Home Assistant UI.** That card tracks stock upstream
> ESPHome releases. Since this device is running **custom** firmware, an
> OTA install from that card would silently overwrite it with unmodified
> stock firmware — removing the "Hey Claude" wake word and the
> dial-rotation sensor with **no error shown anywhere**, and silently
> breaking `ha-bridge.ps1`'s dial-rotation branch (it would simply stop
> receiving events for a sensor that no longer exists). If a firmware
> update is ever wanted, re-run the build/flash procedure below against a
> newer submodule tag instead of using that entity.

### Initializing the firmware submodule

The upstream firmware source lives at
`claude-voice/firmware/home-assistant-voice-pe/` as a **git submodule**. A
plain `git clone` of this repo does **not** populate it — the directory
exists but is empty, and every `esphome` command below will fail on
missing files with no obvious hint that a submodule is the cause. Always
run:

```powershell
git submodule update --init --recursive
```

The submodule is pinned to tag `26.6.0` (the firmware version confirmed
installed on the device when this plan started) — a fixed commit, not a
moving branch. **Only the submodule is pinned.** The ESPHome CLI itself is
installed via a bare `pip install esphome`, which floats to whatever is
current on PyPI at install time — re-running that command later could pull
a newer ESPHome release and produce a different build than the one
actually flashed. The exact CLI version used for the currently-flashed
build was:

```
$ esphome version
Version: 2026.7.2
```

If reproducing an identical build later matters, pin to that version:
`pip install esphome==2026.7.2`.

### Building and flashing — PowerShell only

**All `esphome compile` / `esphome run` / `esphome upload` commands MUST be
run from native PowerShell — never from the Bash/Git-Bash tool.** ESP-IDF
detects `$env:MSYSTEM` (which Git Bash sets and PowerShell does not). This
isn't a preference, it's a hard requirement confirmed during Plan 2 Task 1.

**It does not fail loudly — that is the dangerous part.** Under Git Bash it
prints one easily-missed line:

```
MSys/Mingw is no longer supported. ... or continue at your own risk.
```

and then produces a **no-op build**: `main.cpp` is regenerated with your
changes, `firmware.ota.bin` gets a fresh file mtime, PlatformIO prints a
plausible RAM/Flash summary, and it reports `Successfully compiled program`
— but the binary is byte-identical to the previous build. `esphome upload`
then cheerfully flashes the *old* firmware and reports `OTA successful`.
Every signal says it worked. Observed for real during Plan 3 Task 1: two
OTAs, a genuine device reboot, and HA reconnecting, all while the device
kept running the previous day's image.

**Always verify what actually got built** — file mtimes lie, because they
are refreshed even by the no-op path. The compile timestamp baked into the
binary is the truth:

```powershell
$txt = [System.Text.Encoding]::ASCII.GetString(
    (Get-Content .esphome/build/home-assistant-voice/build/firmware.ota.bin -AsByteStream -Raw))
[regex]::Matches($txt, '\d{4}-\d\d-\d\d \d\d:\d\d:\d\d') |
    ForEach-Object { $_.Value } | Select-Object -Unique
```

and confirm the running device agrees, via `esphome logs`:

```
[I][app:151]: ESPHome version 2026.7.2 compiled on 2026-07-27 18:09:26 +0200
```

If those two dates don't match each other and today, the flash didn't take.

```powershell
# Compile only (no device needed) -- confirms the overlay still builds
esphome compile claude-voice/firmware/custom-voice-pe.yaml

# Flash over USB -- find the port first if you don't already know it
[System.IO.Ports.SerialPort]::GetPortNames()
esphome upload claude-voice/firmware/custom-voice-pe.yaml --device <COM port>
```

First flash of any custom build should always be over **USB**, not OTA, so
there's a known-good recovery path (BOOT/RESET button hold) if something's
wrong. `custom-voice-pe.yaml` packages the unmodified upstream
`home-assistant-voice.factory.yaml` plus `overlay.yaml` (the "Hey Claude"
model + the dial-rotation `name:` override) — board/flash/PSRAM settings
are never touched directly.

### Verifying Mode 2 after flashing

- Say "Okay Nabu" + a known-working command — confirms the stock pipeline
  still works, unregressed by the overlay.
- Say "Hey Claude" — the LED ring should show the same listening animation
  as "Okay Nabu", confirming the new wake-word model is being evaluated.
- In Home Assistant, check Developer Tools → States for
  **`sensor.bedroom_home_assistant_voice_0932b4_dial_rotation`** (confirmed
  real entity ID — area-prefixed, not the non-prefixed form originally
  assumed during planning) and confirm its state changes when the dial is
  rotated.
- Rotate the dial without holding the center button and confirm volume
  still changes exactly as before — confirms the dial-rotation `!extend`
  override didn't disturb the stock volume/hue scripts.
- With 2+ Claude Code sessions pending, rotate the dial and confirm it
  cycles the selection in arrival order and speaks the newly-selected
  session's name (LED update lags slightly behind the stock firmware's own
  "recently touched" volume-display overlay — see final review notes in
  `claude-voice/docs/home-assistant-voice-device.md`). With 0 or 1 sessions
  pending, rotating the dial should do nothing beyond its normal
  volume/hue behavior.

See `claude-voice/docs/home-assistant-voice-device.md` for the full device
reference (entity IDs, the LED-masking limitation, the wake-word
sensitivity-control limitation for "Hey Claude") and the plan document
above for the complete task-by-task build history.

## Setup

### Prerequisites

Before starting, ensure:
- Home Assistant is running and accessible (default assumed URL is `http://homeassistant.local:8123`; override via credentials in Step 0)
- You have a valid HA long-lived access token (created in HA UI: Settings → Developer Tools → Long-Lived Access Tokens)
- VS Code window titles contain each project's folder name, which VS Code
  does by default — `WindowFocus.psm1` derives its match pattern from the
  session's own project (`Get-ProjectWindowPattern`), so no per-project
  configuration is needed for `confirm-session.ps1` to find the right window

### Step 0: Credentials

`HaClient.psm1` reads HA connection details from `claude-voice/.env` (falling
back to environment variables if that file doesn't exist). It does **not**
read a URL hardcoded in `HaClient.psm1` and there is no
`.homeassistant/token.txt` file — both would be wrong places to put this.

```powershell
Copy-Item claude-voice/.env.example claude-voice/.env
```

Then edit `claude-voice/.env` and fill in:
```
HA_URL=http://homeassistant.local:8123
HA_TOKEN=<your long-lived access token>
```

If you'd rather not keep a `.env` file, set these instead and `Get-HaConnection`
will use them as a fallback:
```powershell
$env:CLAUDE_VOICE_HA_URL = 'http://homeassistant.local:8123'
$env:CLAUDE_VOICE_HA_TOKEN = '<your long-lived access token>'
```

### Step 1: Create the kill-switch helper in Home Assistant

Home Assistant's REST API does not expose an endpoint for creating helpers programmatically. You must create this manually:

1. Open Home Assistant UI → **Settings → Devices & Services → Helpers**
2. Click **+ Create Helper → Toggle**
3. Fill in:
   - **Name:** `Claude Notifications Enabled`
   - **Entity ID:** should auto-fill as `input_boolean.claude_notifications_enabled`
   - **Turn on by default:** Yes
4. Click **Create**

### Step 2: Upload the chime audio file to Home Assistant

The chime sound (`claude-voice/media/chime.wav`) must reach Home Assistant's local media folder. Two options:

#### Option A: SSH/SCP (preferred, if SSH is available)

```powershell
# Create the media directory on HA
ssh -p 22 root@homeassistant.local "mkdir -p /media/claude-voice"

# Copy the chime file
scp -P 22 claude-voice/media/chime.wav root@homeassistant.local:/media/claude-voice/chime.wav
```

Note: If you encounter SSH connection issues (e.g., "Corrupted MAC on input"), use Option B instead.

#### Option B: Upload via HA's Media page

1. Open Home Assistant UI → **Settings → Developer Tools → Media** (or find **Local Media** in the sidebar)
2. Click **Upload**, and when picking/creating the destination folder, make sure the file ends up inside a `claude-voice` subfolder of HA's local media root (create that folder if the upload dialog lets you) — i.e. select `claude-voice/chime.wav`
3. It must resolve to `media-source://media_source/local/claude-voice/chime.wav`, which is the exact media ID hardcoded as `$script:ChimeMediaId` in `HaClient.psm1`. If the file lands anywhere else (e.g. directly in `local/`), the chime will silently fail to play.

Verify the upload by checking Home Assistant's `/media` folder or triggering a notification to hear the chime.

### Step 3: Run the helper setup script

```powershell
./claude-voice/scripts/setup-ha-helpers.ps1
```

This script checks whether `input_boolean.claude_notifications_enabled` exists (idempotent) and reports its state. If you completed Step 1, it will report that the helper already exists and exit cleanly.

### Step 4: Wire up the hooks

The three notification hooks are already defined in `.claude/settings.json`:
- `Notification` — fires on permission requests and when Claude is idle waiting for input
- `Stop` — fires when a session stops
- `UserPromptSubmit` — fires when a user input is submitted

These hooks are **identical for every project** — there is no `-Account`
flag or any other per-project value to set. `notify-ha.ps1` reads the
session's identity (`session_id`, `cwd`) straight from the hook payload
Claude Code passes it, and derives that session's display name and LED
color from its own project path (`SessionColor.psm1`). They will
automatically trigger notifications to Home Assistant when you run Claude
Code sessions in this repo.

To add notifications to **other projects**, copy the same three hooks,
verbatim, to that project's `.claude/settings.json`. Nothing needs editing
— the new project will automatically get its own stable color the first
time it notifies.

### Step 5: Register the background Scheduled Task (requires Administrator)

**Important:** This step requires an elevated PowerShell window. Right-click PowerShell or Windows Terminal and select **Run as Administrator**.

Then:

```powershell
./claude-voice/scripts/install-ha-bridge-task.ps1
```

This registers a Scheduled Task called `ClaudeVoiceHaBridge` that:
- Starts automatically at logon
- Holds a WebSocket subscription to Home Assistant's event stream, reconnecting
  with backoff if HA restarts or the network drops
- Reacts to **button presses** (double-press cycles pending sessions in
  arrival order, long-press focuses the selected session's VS Code window
  and clears its light without typing anything, triple-press dismisses)
  and, on the custom Mode 2 firmware, to **dial rotation** as an
  alternative way to cycle
- Checks the mute switch on demand when deciding whether to speak — it does not
  subscribe to mute-switch changes
- Respects the `input_boolean.claude_notifications_enabled` kill-switch, which
  it checks before taking any action

If the script fails with "Access is denied," you forgot to run as Administrator. Close the PowerShell window and try again with elevation.

### Work sessions are out of scope

There is no work-account integration step, and there deliberately never
will be one for this setup: work sessions run on **Rafael-Laptop**, a
physically separate WSL2 Linux machine with no network route to the home
LAN and no PowerShell. `notify-ha.ps1` and `ha-bridge.ps1` are PowerShell
scripts that talk to a Home Assistant instance on the home LAN — neither
precondition holds on that machine, so this project simply cannot reach it.
This isn't an unfinished step; it's a hardware/network boundary that makes
the feature inapplicable there. If a project on *this* machine needs
notifications, Step 4 above already covers it — colors and names are
per-project, not per-account, so there's nothing account-specific left to
wire up regardless.

### (Optional) Stream Controller "Claude" page

If you own a [Stream Controller](https://www.soomfon.com) (StreamDock or HotSpot device) with the Nicollas R. Stream Deck VS Code plugin already installed, you can build an alternative control surface for approving pending Claude sessions without using the HA Voice device button.

**Note:** This section is entirely optional. The HA Voice device button (from Step 5) already provides full control — the Stream Controller is an alternative for users who prefer a dedicated button on their device.

#### Install the companion VS Code extension

In VS Code:
1. Open **Extensions** (Ctrl+Shift+X)
2. Search for **"Stream Deck for Visual Studio Code"** (by Nicollas R.)
3. Click **Install**

This extension allows the Stream Controller to execute terminal commands and focus VS Code windows.

#### Build the "Claude" page

In the Stream Controller app, create a new page called "Claude" with one
button per project you want a dedicated approve-button for. Window titles
follow VS Code's default format (folder/workspace name included), matching
what `Get-ProjectWindowPattern` in `WindowFocus.psm1` looks for — so the
target pattern is just `*<project folder name>*Visual Studio Code*`.

**Example button: "Approve: HomeAssistant"** (this repo)
- Action 1 (SwitchTo): Target window title `*HomeAssistant*Visual Studio Code*`
- Action 2 (Execute Terminal Command): Text `continue`

Add one more button, same shape, for each other project's folder name.

#### Verification

With a pending Claude session (check `claude-voice/state/pending.json`), press the corresponding button on your Stream Controller. The expected behavior:
1. The correct VS Code window (matching that project) comes to the front
2. The text "continue" is typed and submitted into the terminal
3. The pending state clears and any LED indicator resets

Because `UserPromptSubmit` fires regardless of who typed the reply, no additional integration code is needed — the pending-state sync works the same way as with the HA Voice button. Note this differs from the device's own long-press, which deliberately types nothing (see Phase 3 below) — a Stream Controller button is a conscious choice to auto-reply "continue" and should only be built for prompts you're comfortable auto-approving.

### Verification Checklist

Run through all four phases to confirm the integration is working:

There is no `single_press` event on this device — a single press just
triggers Assist listening (built into the firmware) and is never published
as an automatable button event, so it plays no role in this integration.

#### Phase 1: Single-session notification flow
- [ ] Open a Claude Code session in this repo (or another project with the same three hooks)
- [ ] Trigger a notification (e.g., a permission prompt, or let Claude go idle waiting for input)
- [ ] Confirm on your HA Voice device:
  - LED goes **solid, full brightness**, in that project's color, with one flash on arrival — not a sustained pulse (see [`docs/user-guide.md`](docs/user-guide.md))
  - TTS announces `"<project> needs input: <your message>"` — you'll
    hear the device's own built-in preannounce tone play automatically
    right before it speaks; that's `assist_satellite.announce`'s standard
    behavior, not this project's `chime.wav` file. Our custom chime only
    plays on its own when there's no speech (quiet submode, or a `Stop`
    event) — see Phase 4.
  - Ring is still lit, unchanged, 15+ seconds later (the persistence check — confirms the flash reverted to the solid color, not to darkness)
- [ ] Long-press the button — since exactly one session is pending, this jumps to it directly with no prior double-press needed: the project's VS Code window comes to focus and the light clears. **Nothing is typed** — long-press focuses, it doesn't reply for you
- [ ] Reply by hand in the now-focused session, and confirm `pending.json` clears that session
- [ ] Run `ha-bridge.ps1` in the background (it's normally a Scheduled Task) — check that notifications continue to work

#### Phase 2: Multiple simultaneous sessions
- [ ] Trigger a notification from this repo (as in Phase 1)
- [ ] While it's pending, trigger a notification from a *different* project (any other folder with the same three hooks — even a throwaway one works, since color/name derive automatically from its path)
- [ ] Confirm the second notification **chimes only** — the ring stays exactly as it was, still showing the first session's color
- [ ] With two sessions now pending, a long-press does nothing (no cursor is set and there's more than one candidate) — you must cycle first
- [ ] Double-press the button (or rotate the dial, Mode 2 only) — it selects the **oldest-pending** session (arrival order, not alphabetical — session ids are random, so alphabetical would be meaningless), LED goes solid in that session's color, TTS speaks its name
- [ ] Cycle again — moves to the other session (LED changes color, TTS speaks its name)
- [ ] Confirm in `pending.json` that both sessions are listed and neither clobbered the other
- [ ] Long-press — focuses whichever session is currently selected (the cursor): its VS Code window gains focus and its light clears; the other session's light is unaffected

#### Phase 3: Button control
- [ ] Trigger a notification
- [ ] Test button behaviors:
  - **Double-press (two quick taps):** Cycles the selection cursor to the next pending session, oldest-arrived first
  - **Long-press (>1 second):** Focuses the currently selected session — brings its VS Code window forward and clears its light. Types **nothing**. Works with zero prior double-presses when exactly one session is pending (see Phase 1); otherwise a cursor must first be set via double-press (see Phase 2)
  - **Triple-press:** Dismisses the currently selected session without responding (clears it from pending, no reply sent)
- [ ] Confirm the correct session's light clears in each case

#### Phase 4: Mute-switch suppression
- [ ] Toggle the physical **mute switch** on your HA Voice device to the **mute** position
- [ ] Trigger a notification
- [ ] Confirm:
  - LED still goes solid (visual feedback works, unchanged by mute)
  - **Chime still plays** — mute only suppresses spoken narration, not all audio
  - **TTS does NOT play** (spoken narration suppressed)
  - Button control still works (physical input is not suppressed, only spoken output is)
- [ ] Toggle the mute switch back to the **unmute** position
- [ ] Trigger another notification and confirm TTS resumes

#### (Optional) Kill-switch toggle
- [ ] Open Home Assistant UI → **Helpers → Claude Notifications Enabled**
- [ ] Toggle it **Off**
- [ ] Trigger a notification in Claude Code
- [ ] Confirm the device does **not** respond (no LED flash, no chime, no TTS, button control inactive)
- [ ] Toggle the helper back **On**
- [ ] Trigger a notification and confirm the device responds again
