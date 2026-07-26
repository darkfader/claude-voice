# claude-voice — User Guide

Day-to-day use. For installation see [`../README.md`](../README.md); for
hardware facts see [`home-assistant-voice-device.md`](home-assistant-voice-device.md).

## The two halves are independent

This matters more than anything else here, because it determines what breaks
when something isn't running:

| | What it does | What it needs running |
|---|---|---|
| **Notifications** | Device chimes / lights up / speaks when a Claude Code session finishes or needs you | Nothing extra. Claude Code's hooks call `notify-ha.ps1` directly. |
| **Control** | Button and dial let you cycle pending sessions and send a reply back | `ha-bridge.ps1`, as a Scheduled Task (README Step 5). **Without it, the button and dial do nothing.** |
| **"Hey Claude" voice** | Ask Claude questions out loud via the device | Nothing on this PC. Runs entirely in Home Assistant. |

So if notifications work but the button does nothing, the bridge isn't
running — that's the first thing to check, not a bug.

## What you'll see and hear

| When | LED ring | Sound |
|---|---|---|
| Session needs your input | Pulses in that account's colour — **blue** = personal, **purple** = work | Speaks: *"personal session needs input: &lt;message&gt;"* |
| Session finished | Solid in that account's colour | Chime |
| You replied (typed or via the device) | Off | — |
| Cycling with the dial | Pulses in the newly-selected account's colour | Silent (chime only if muted) |

**LED off means nothing is pending.** That is the normal resting state — and
it's what you'll see most of the time while actively typing to Claude, because
sending a prompt clears the pending state immediately.

### The mute slider is a "don't talk to me" switch

Slide it to mute and spoken output stops, but **the chime still plays and the
LED still works** — and the button and dial still work completely. That's the
point: full control, no talking.

## Controls

Once the bridge is running:

| Gesture | Action |
|---|---|
| **Double-press** | Cycle to the next pending account (speaks its name) |
| **Long-press** | Send `continue` to the selected session — focuses its VS Code window and types it |
| **Triple-press** | Dismiss the selected account without replying |
| **Rotate the dial** | Cycle accounts — but only when **2 or more** are pending |

Long-press works with no prior press when exactly one session is pending —
there's only one thing it could mean.

**The dial is still your volume knob.** With 0 or 1 sessions pending — i.e.
almost always — rotating it just changes volume as it always has. Cycling only
engages when there are 2+ pending sessions to choose between, which is the only
situation where cycling means anything.

## Seeing what happened

### Right now

```powershell
# What's pending this second (the source of truth the LED reflects)
Get-Content claude-voice/state/pending.json

# Is the bridge actually running?
Get-ScheduledTask -TaskName ClaudeVoiceHaBridge -ErrorAction SilentlyContinue |
  Select-Object TaskName, State
```

### History of device activity

Home Assistant records every state change, so you can replay what the device
did. This works today — verified:

```powershell
$vars = @{}
Get-Content claude-voice/.env | ForEach-Object { if ($_ -match '^([^=]+)=(.*)$') { $vars[$matches[1]] = $matches[2] } }
$headers = @{ Authorization = "Bearer $($vars.HA_TOKEN)" }
$since = (Get-Date).AddHours(-3).ToString('yyyy-MM-ddTHH:mm:ss')

# LED history = a log of every notification you were sent
$u = "$($vars.HA_URL)/api/history/period/$since`?filter_entity_id=light.home_assistant_voice_0932b4_led_ring&minimal_response"
(Invoke-RestMethod -Uri $u -Headers $headers)[0] |
  Select-Object -Last 20 | ForEach-Object { "{0} -> {1}" -f $_.last_changed, $_.state }
```

Swap `filter_entity_id` for other entities to answer different questions:

| Entity | Answers |
|---|---|
| `light.home_assistant_voice_0932b4_led_ring` | When was I notified? |
| `event.home_assistant_voice_0932b4_button_press` | When did I press the button, and how? |
| `sensor.bedroom_home_assistant_voice_0932b4_dial_rotation` | When did I turn the dial? |
| `switch.home_assistant_voice_0932b4_mute` | When was it muted? |
| `assist_satellite.home_assistant_voice_0932b4_assist_satellite` | When was the device listening/speaking? |

The same data is browsable in the HA UI under **History** (pick the entity) and
**Logbook**, which is usually easier than the API for a quick look.

### Voice conversations ("Hey Claude" / "Okay Nabu")

Home Assistant keeps debug traces of Assist pipeline runs — each one shows the
wake word that triggered, what speech-to-text heard, what the agent replied,
and the timings. In the HA UI: **Settings → Voice assistants**, select the
pipeline, and open its debug view (in recent HA versions this is behind the
three-dot menu on the pipeline). This is the place to look when a voice command
is misheard or Claude's answer seems off — you can see exactly what text the
model actually received.

### Bridge problems

```powershell
Get-Content claude-voice/state/ha-bridge.log -Tail 20   # only exists after a failure
```

The bridge writes here when it loses its connection or a handler throws. **If
this file doesn't exist, nothing has gone wrong** — it isn't a routine activity
log, only a fault log. The bridge reconnects on its own with backoff, so
occasional entries after an HA restart are expected and self-healing.

### Your Claude Code sessions

Session transcripts are Claude Code's own, not something this project stores:

```powershell
claude --resume     # pick from a list of past sessions in this directory
```

**In the Claude app or on claude.ai?** Only if you explicitly start a session
with Remote Control (`claude remote-control`, or enable it for all sessions via
`/config`) — that relays your local session through Anthropic's servers so you
can view and drive it from the mobile app or claude.ai/code. It requires a
Pro/Max subscription and is an Anthropic feature entirely separate from this
project. Sessions run normally, without that flag, exist only on this PC and
won't appear in the app.

## Quick troubleshooting

| Symptom | Likely cause |
|---|---|
| Notifications work, button/dial do nothing | Bridge not running — README Step 5, needs an elevated PowerShell |
| Nothing happens at all | Kill switch off (`input_boolean.claude_notifications_enabled`), or the helper was never created — README Step 1 |
| Warning: *"Entity not found: input_boolean.claude_notifications_enabled"* | Same — the helper doesn't exist yet. Harmless: the code deliberately fails open and still notifies. |
| Device speaks but plays no chime | `chime.wav` never reached HA's media folder — README Step 2 |
| It says the wrong account name | Each project's `.claude/settings.json` hardcodes `-Account`; check that repo's hooks |
| Dial cycles when you only wanted volume | Only possible with 2+ sessions pending; resolve or dismiss one |
| "Hey Claude" triggers by accident | Its sensitivity is fixed at flash time and **not** adjustable by the device's sensitivity control — see [`home-assistant-voice-device.md`](home-assistant-voice-device.md) |
