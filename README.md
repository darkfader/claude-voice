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
(filled in as later tasks land)
