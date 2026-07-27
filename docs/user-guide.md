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

**Colour says *which session*. Brightness says *what state*.** A session's
colour comes from a hash of its project's path (see
[`home-assistant-voice-device.md`](home-assistant-voice-device.md) for the
mechanics), so the same project shows the same colour every time, including
after a restart — and when two or more sessions are pending at once, their
colours are automatically nudged apart so they're never confused for each
other.

| When | LED ring | Sound |
|---|---|---|
| A session needs your input, nothing else pending | **Solid, full brightness**, that session's colour, one flash on arrival | Speaks: *"&lt;project&gt; needs input: &lt;message&gt;"* |
| A session needs your input, something else already pending | Unchanged — the ring is **not** touched | Chime only |
| A session finishes its turn (or you reply by typing), nothing else pending | Solid, **dim**, that session's colour — the ambient "you're working here" marker | Chime (typed reply: silent) |
| A session finishes its turn or you reply, something else already pending | Ring **moves to the oldest remaining pending session**, solid full brightness, no flash — it's a hand-off, not a new arrival | Chime still plays (typed reply: silent) |
| You jump to a session or dismiss it from the device (long-press/triple-press), nothing else pending | **Off** | — |
| You jump to a session or dismiss it from the device (long-press/triple-press), something else pending | Ring moves to the oldest remaining pending session, solid full brightness, no flash | — |
| Cycling with the dial or double-press | Solid, full brightness, the newly-selected session's colour | Speaks its name (chime only if muted) |
| Nothing pending, idle 10+ minutes | Off | — |

### It holds SOLID — it never pulses

A pending session lights the ring **solid** and leaves it there the entire
time it's waiting on you, with a single flash right on arrival to catch your
eye. That flash is a one-shot: this hardware's `flash: short` runs for about
10 seconds and then reverts to whatever the ring was already showing — which
is why "pulsing" is never an accurate description of a waiting session here.
There's no ongoing animation, just solid-and-held. Confirmed live: still lit,
unchanged, 15+ seconds after a notification arrives.

### A second notification while one is pending chimes — nothing moves

If a session lights the ring and a *different* session then also needs
input, the second one plays the chime and **stops there** — the ring keeps
showing the first session, untouched. This is deliberate, not a bug: you're
already looking at (or about to look at) whatever's on the ring, and having
it change colour out from under you mid-decision would be actively
unhelpful. `Get-Content claude-voice/state/pending.json` (below) always shows
everything that's actually waiting, ring or no ring.

### The ambient indicator fades on its own

Once nothing is pending, the ring doesn't necessarily jump straight to off.
Whichever session you most recently typed into, or that most recently
finished a turn, keeps a **dim** solid glow — a "you were last working here"
marker, nothing that needs action. `ha-bridge.ps1` checks about once a
minute and switches it off once that session has sat idle for **10 minutes**
with nothing pending.

### Subagent completions do not notify

A Claude Code session can spawn subagents — sometimes dozens of them in a
single turn. Claude Code has a `SubagentStop` hook event for exactly that
moment, and it is **deliberately not wired up** here. None of those
completions are moments that need you; only three events are hooked, in
`.claude/settings.json`:

- `Notification` — something needs you (a permission prompt, or Claude idle
  waiting on input)
- `Stop` — your turn finished
- `UserPromptSubmit` — you just replied

Wiring `SubagentStop` too would mean a single busy session lighting up the
device dozens of times for things that were never yours to act on.

### The mute slider is a "don't talk to me" switch

Slide it to mute and spoken output stops, but **the chime still plays and the
LED still works** — and the button and dial still work completely. That's the
point: full control, no talking.

## Controls

Once the bridge is running:

| Gesture | Action |
|---|---|
| **Double-press** | Cycle to the next pending session, oldest-arrived first (speaks its name) |
| **Long-press** | Jump to the selected session — focuses its VS Code window and clears its pending light. Types **nothing**; you read and reply yourself |
| **Triple-press** | Dismiss the selected session without replying |
| **Rotate the dial** | Same cycling as double-press — but only when **2 or more** sessions are pending |

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
| It names the wrong project | Display name comes from the last path segment of the hook payload's `cwd`; an unusual folder name or symlink can produce something unexpected |
| Dial cycles when you only wanted volume | Only possible with 2+ sessions pending; resolve or dismiss one |
| "Hey Claude" triggers by accident | Its sensitivity is fixed at flash time and **not** adjustable by the device's sensitivity control — see [`home-assistant-voice-device.md`](home-assistant-voice-device.md) |
