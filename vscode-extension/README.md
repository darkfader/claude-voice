# Claude Voice — VS Code extension

Lets the Home Assistant Voice dial switch between Claude Code threads, and puts
the bridge's status and install steps behind the command palette.

## Why it has to exist

Focus used to call Win32 `SetForegroundWindow` on the window a session runs in.
That cannot work here: measured live, **one** VS Code window was hosting **41**
`claude.exe` processes. Windows has no handle for a tab, so focusing an
already-focused window is a no-op — the bridge logged `focus -> X` correctly
every time and nothing moved.

Claude Code's own extension cannot help either: it contributes 22 commands and
none of them accepts a session id.

Sessions do open as editor tabs, though, and tabs are labelled with the thread
title — which the bridge already stores. So the bridge writes a focus request
into `claude-voice/state/focus-request.json`, and this extension matches the
title against its tab labels and focuses by index.

Every VS Code window runs its own copy and reads the same file. Only the window
that owns that tab acts; the rest log a miss and ignore it.

## Install

No build step — it is plain JavaScript.

```powershell
# From the repo root. Symlink so edits take effect on reload.
New-Item -ItemType SymbolicLink `
  -Path "$env:USERPROFILE\.vscode\extensions\claude-voice" `
  -Target "$PWD\claude-voice\vscode-extension"
```

Then **Developer: Reload Window**. Copy the folder instead of symlinking if you
would rather it not track the repo.

## Commands

| Command | Does |
|---|---|
| `Claude Voice: Show Status` | Bridge state, known threads, and every tab in this window with its index |
| `Claude Voice: Focus Thread...` | Quick-pick any known thread — works without the device |
| `Claude Voice: Install Global Hooks` | Writes the three hooks into `~/.claude/settings.json` with absolute paths, backing it up first |
| `Claude Voice: Uninstall Global Hooks` | Removes them, with a backup |
| `Claude Voice: Start Bridge` / `Stop Bridge` | Runs the bridge hidden, or stops it |
| `Claude Voice: Show Log` | Extension output channel |

Install/uninstall run **visibly in a terminal** rather than silently, because
they edit global settings and you should see exactly what happened.

## Settings

All under `claudeVoice.*` — see the Settings UI for descriptions.

| Setting | Default |
|---|---|
| `enabled` | `true` |
| `stateDir` | `""` (auto-detect) |
| `matchStrategy` | `title` |
| `pollIntervalMs` | `500` |
| `requestMaxAgeMs` | `5000` |
| `showStatusBar` | `true` |
| `notifyOnFocusFailure` | `false` |

`notifyOnFocusFailure` is off by default on purpose: with several windows open,
a miss is the normal case for every window that does not own the thread.

## Known limits

- **Untitled threads can't be matched.** Claude Code generates a title a few
  turns in; before that there is nothing to match on. Set `matchStrategy` to
  `titleThenPath` to fall back to the project folder name.
- **Duplicate titles are ambiguous** — the first match wins, and the log says so.
- **`fs.watch` is unreliable on Windows**, so a poll backs it up. That is what
  `pollIntervalMs` is for; the watcher only makes it prompt.
