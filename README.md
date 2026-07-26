# claude-voice

Claude Code ↔ Home Assistant Voice integration. See
`docs/superpowers/specs/2026-07-25-ha-voice-claude-integration-design.md`
for the full design.

## Components
- `scripts/PendingState.psm1` — tracks which accounts are waiting on input.
- `scripts/HaClient.psm1` — thin wrapper around the HA REST API.
- `scripts/notify-ha.ps1` — called by Claude Code hooks.
- `scripts/confirm-session.ps1` — focuses a VS Code window and types a reply.
- `scripts/ha-bridge.ps1` — persistent process reacting to the device's
  button and mute switch. Runs as a Scheduled Task (see Task 8).

## Setup

### Prerequisites

Before starting, ensure:
- Home Assistant is running and accessible (default assumed URL is `http://homeassistant.local:8123`; override via credentials in Step 0)
- You have a valid HA long-lived access token (created in HA UI: Settings → Developer Tools → Long-Lived Access Tokens)
- VS Code window titles match the patterns `WindowFocus.psm1` looks for (see Step 4 / the note under Step 6) so `confirm-session.ps1` can focus the right window

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

### Step 4: Wire up the hooks (personal account)

The three notification hooks are already defined in `.claude/settings.json`:
- `Notification` — fires on permission requests and when Claude is idle waiting for input
- `Stop` — fires when a session stops
- `UserPromptSubmit` — fires when a user input is submitted

These hooks are already wired for the `personal` account. They will automatically trigger notifications to Home Assistant when you run Claude Code sessions in this repo.

To add notifications to **other projects**, copy these three hooks to that project's `.claude/settings.json`, or update them to use `-Account work` if you want to wire the work account (see "Work-account integration" below).

### Step 5: Register the background Scheduled Task (requires Administrator)

**Important:** This step requires an elevated PowerShell window. Right-click PowerShell or Windows Terminal and select **Run as Administrator**.

Then:

```powershell
./claude-voice/scripts/install-ha-bridge-task.ps1
```

This registers a Scheduled Task called `ClaudeVoiceHaBridge` that:
- Starts automatically at logon
- Listens for button presses and mute-switch toggles on your HA Voice device
- Responds to button presses by focusing the correct VS Code window and cycling notifications
- Respects the `input_boolean.claude_notifications_enabled` kill-switch

If the script fails with "Access is denied," you forgot to run as Administrator. Close the PowerShell window and try again with elevation.

### Step 6: Work-account integration (optional, separate repo)

The three hooks in `.claude/settings.json` use `-Account personal`. To enable notifications for your work account, you must:

1. **In your work-account repo** (not this repo), add the same three hooks to `.claude/settings.json` but change `-Account personal` to `-Account work`
2. Window focusing does **not** rely on literal `[personal]`/`[work]` tags in the window title — `WindowFocus.psm1` matches VS Code's default title format (which includes the open folder/workspace name) against two hardcoded wildcard patterns:
   - `personal` → `*HomeAssistant*Visual Studio Code*` (matches this repo, whose folder is named `HomeAssistant`)
   - `work` → `*sownet*Visual Studio Code*`

   If your work repo's folder name doesn't contain `sownet`, this pattern won't match your window and you must edit the `work` entry in `$script:AccountWindowPatterns` at the top of `WindowFocus.psm1` to match your actual folder name instead.

This is documented separately in that project's integration notes.

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

In the Stream Controller app, create a new page called "Claude" with two buttons:

**Button 1: "Approve: Personal"**
- Action 1 (SwitchTo): Target window title `*HomeAssistant*Visual Studio Code*`
- Action 2 (Execute Terminal Command): Text `continue`

**Button 2: "Approve: Work"**
- Action 1 (SwitchTo): Target window title `*sownet*Visual Studio Code*`
- Action 2 (Execute Terminal Command): Text `continue`

#### Verification

With a pending Claude session (check `claude-voice/state/pending.json`), press the corresponding button on your Stream Controller. The expected behavior:
1. The correct VS Code window (personal or work) comes to the front
2. The text "continue" is typed and submitted into the terminal
3. The pending state clears and any LED indicator resets

Because `UserPromptSubmit` fires regardless of who typed the reply, no additional integration code is needed — the pending-state sync works the same way as with the HA Voice button.

### Verification Checklist

Run through all four phases to confirm the integration is working:

There is no `single_press` event on this device — a single press just
triggers Assist listening (built into the firmware) and is never published
as an automatable button event, so it plays no role in this integration.

#### Phase 1: Single-account notification flow (personal)
- [ ] Open a Claude Code session in this repo (or another project with personal hooks)
- [ ] Trigger a notification (e.g., a permission prompt, or let Claude go idle waiting for input)
- [ ] Confirm on your HA Voice device:
  - LED pulses in the personal color (blue)
  - Chime plays (if audio is on)
  - TTS announces `"personal session needs input: <your message>"`
- [ ] Long-press the button — since exactly one account is pending, this confirms it directly with no prior double-press needed: the personal VS Code window comes to focus and a reply ("continue" by default) is typed and submitted
- [ ] Confirm the reply arrives in the Claude session and `pending.json` clears the account
- [ ] Run `ha-bridge.ps1` in the background (it's normally a Scheduled Task) — check that notifications continue to work

#### Phase 2: Multi-account simultaneous notifications (personal + work)
*Skip this if you haven't set up work-account hooks yet.*
- [ ] Trigger a personal notification (as in Phase 1)
- [ ] While it's pending, open your work-account repo and trigger a work notification
- [ ] With two accounts now pending, a long-press does nothing (no cursor is set and there's more than one candidate) — you must double-press first
- [ ] Double-press the button — it selects the first pending account **alphabetically** (`personal`, since `p` < `w` — cycling order is alphabetical by account name, not by recency), LED pulses blue, TTS announces "personal selected"
- [ ] Double-press again — cycles to `work` (LED pulses purple, TTS announces "work selected")
- [ ] Confirm in `pending.json` that both accounts are listed and neither clobbered the other
- [ ] Long-press — confirms whichever account is currently selected (the cursor): its VS Code window gains focus and a reply is typed

#### Phase 3: Button control
- [ ] Trigger a personal notification
- [ ] Test button behaviors:
  - **Double-press (two quick taps):** Cycles the selection cursor to the next pending account, alphabetically
  - **Long-press (>1 second):** Confirms/sends a reply for the currently selected account — focuses its VS Code window and types the reply. Works with zero prior double-presses when exactly one account is pending (see Phase 1); otherwise a cursor must first be set via double-press (see Phase 2)
  - **Triple-press:** Dismisses the currently selected account without responding (clears it from pending, no reply sent)
- [ ] Confirm the reply arrives in the Claude session

#### Phase 4: Mute-switch suppression
- [ ] Toggle the physical **mute switch** on your HA Voice device to the **mute** position
- [ ] Trigger a notification
- [ ] Confirm:
  - LED still pulses (visual feedback works, unchanged by mute)
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
