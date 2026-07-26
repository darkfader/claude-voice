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
- Home Assistant is running and accessible at `homeassistant.local` (or update `HaClient.psm1` with your HA URL)
- `.homeassistant/token.txt` contains a valid HA long-lived token (created in HA UI: Settings → Developer Tools → Long-Lived Access Tokens)
- The VS Code window title includes the account name (e.g., `Code — [personal]`) so button-listener can focus the right window

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
2. Click **Upload** and select `claude-voice/media/chime.wav`
3. The file will be accessible as `/media/source/local/chime.wav` or similar path

Verify the upload by checking Home Assistant's `/media` folder or triggering a notification to hear the chime.

### Step 3: Run the helper setup script

```powershell
./claude-voice/scripts/setup-ha-helpers.ps1
```

This script checks whether `input_boolean.claude_notifications_enabled` exists (idempotent) and reports its state. If you completed Step 1, it will report that the helper already exists and exit cleanly.

### Step 4: Wire up the hooks (personal account)

The three notification hooks are already defined in `.claude/settings.json`:
- `Notification` — fires when a Claude session sends output
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
2. Ensure that work-account VS Code window titles include `[work]` so the button-listener can distinguish them

This is documented separately in that project's integration notes.

### Verification Checklist

Run through all four phases to confirm the integration is working:

#### Phase 1: Single-account notification flow (personal)
- [ ] Open a Claude Code session in this repo (or another project with personal hooks)
- [ ] Trigger a notification (e.g., run a query, let Claude output text)
- [ ] Confirm on your HA Voice device:
  - LED flashes
  - Chime plays (if audio is on)
  - TTS announces "Claude has a message"
- [ ] Press and hold the button to focus the VS Code window — the personal window should come to focus
- [ ] Close the notification in VS Code or let it auto-dismiss after 30 seconds
- [ ] Run `ha-bridge.ps1` in the background (it's normally a Scheduled Task) — check that notifications continue to work

#### Phase 2: Multi-account simultaneous notifications (personal + work)
*Skip this if you haven't set up work-account hooks yet.*
- [ ] Trigger a personal notification (as in Phase 1)
- [ ] While it's pending, open your work-account repo and trigger a work notification
- [ ] On the device, press and hold the button — it should focus the **personal** window (newest first)
- [ ] Double-press the button to cycle to the **work** notification
- [ ] Confirm in `pending.json` that both accounts are listed and neither clobbered the other
- [ ] Long-press (>1 second) the button — the VS Code window should gain focus and a reply should be typed

#### Phase 3: Button control
- [ ] Trigger a personal notification
- [ ] Test button behaviors:
  - **Single-press (quick tap):** Focuses the VS Code window
  - **Double-press (two quick taps):** Cycles to the next pending notification (if multiple exist)
  - **Long-press (>1 second):** Confirms the current notification and types a pre-set reply into VS Code
- [ ] Confirm the reply arrives in the Claude session

#### Phase 4: Mute-switch suppression
- [ ] Toggle the physical **mute switch** on your HA Voice device to the **mute** position
- [ ] Trigger a notification
- [ ] Confirm:
  - LED still flashes (visual feedback works)
  - **Chime does NOT play** (audio muted)
  - **TTS does NOT play** (audio muted)
  - Button control still works (physical input is not suppressed, only audio output is)
- [ ] Toggle the mute switch back to the **unmute** position
- [ ] Trigger another notification and confirm audio resumes

#### (Optional) Kill-switch toggle
- [ ] Open Home Assistant UI → **Helpers → Claude Notifications Enabled**
- [ ] Toggle it **Off**
- [ ] Trigger a notification in Claude Code
- [ ] Confirm the device does **not** respond (no LED flash, no chime, no TTS, button control inactive)
- [ ] Toggle the helper back **On**
- [ ] Trigger a notification and confirm the device responds again
