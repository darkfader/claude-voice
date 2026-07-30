// claude-voice VS Code extension
//
// Exists because focusing a Claude Code thread from outside VS Code is
// impossible. Focus used to call Win32 SetForegroundWindow on the window a
// session runs in -- but measured live, one VS Code window hosted 41
// claude.exe processes. Windows has no handle for a tab, so focusing an
// already-focused window is a no-op: the bridge logged "focus -> X" correctly
// every time and nothing moved.
//
// Claude Code itself cannot be asked to help. Its extension contributes 22
// commands and not one accepts a session id.
//
// What does work: sessions open as editor tabs, tabs are labelled with the
// thread title, and the bridge already stores that title per session. So the
// bridge drops a focus request in claude-voice/state/, this extension matches
// the title against the tab labels, and focuses by index.

const vscode = require('vscode');
const fs = require('fs');
const path = require('path');
const os = require('os');
const cp = require('child_process');

const FOCUS_REQUEST = 'focus-request.json';
const PENDING_STATE = 'pending.json';
const BRIDGE_LOG = 'ha-bridge.log';

let out;
let statusItem;
let watcher;
let pollTimer;
let statusTimer;
let lastHandledStamp = 0;

function cfg() {
    return vscode.workspace.getConfiguration('claudeVoice');
}

function log(msg) {
    if (out) out.appendLine(`[${new Date().toISOString()}] ${msg}`);
}

// ---------------------------------------------------------------- state dir

/**
 * Locate claude-voice/state.
 *
 * Auto-detection deliberately walks up from each workspace folder rather than
 * assuming the folder IS the repo: this extension is useful in a window opened
 * on a subdirectory, or on an entirely different project whose threads are
 * being switched.
 */
function findStateDir() {
    const configured = cfg().get('stateDir');
    if (configured) return configured;

    const folders = vscode.workspace.workspaceFolders || [];
    for (const f of folders) {
        let dir = f.uri.fsPath;
        for (let i = 0; i < 6; i++) {
            const candidate = path.join(dir, 'claude-voice', 'state');
            if (fs.existsSync(candidate)) return candidate;
            const parent = path.dirname(dir);
            if (parent === dir) break;
            dir = parent;
        }
    }
    return null;
}

/**
 * Read a JSON state file, retrying briefly on transient failures.
 *
 * The retry is not optional politeness. The bridge replaces these files with
 * an atomic File.Move on every state change, and a read landing during the
 * swap fails with a sharing violation -- "being used by another process". A
 * single-shot read therefore returns null intermittently, which showed up as
 * the extension reporting "0 threads" while the file plainly had five.
 *
 * PendingState.psm1's Get-PendingState solves the identical problem with a
 * bounded retry loop and documents it at length; this mirrors that. Bounded so
 * a genuinely corrupt or missing file still fails fast rather than blocking
 * the extension host.
 */
function readJson(file, attempts = 20, delayMs = 10) {
    for (let i = 0; i < attempts; i++) {
        try {
            const raw = fs.readFileSync(file, 'utf8');
            if (!raw.trim()) return null;
            return JSON.parse(raw);
        } catch (e) {
            // ENOENT is a real answer, not a race -- do not burn retries on it.
            if (e && e.code === 'ENOENT') return null;
            if (i === attempts - 1) {
                log(`readJson(${path.basename(file)}) gave up after ${attempts} attempts: ${e}`);
                return null;
            }
            // Synchronous spin: this runs on the extension host thread, and
            // the window is sub-millisecond in practice. Keep it tiny.
            const until = Date.now() + delayMs;
            while (Date.now() < until) { /* spin */ }
        }
    }
    return null;
}

// ------------------------------------------------------------- tab matching

function normalise(s) {
    return String(s || '').toLowerCase().replace(/\s+/g, ' ').trim();
}

/**
 * All open tabs, flattened, with their index within their own group.
 *
 * Index is per-group because workbench.action.openEditorAtIndex operates on
 * the ACTIVE group -- so the group has to be focused first, then the index
 * applied within it.
 */
function allTabs() {
    const result = [];
    for (const group of vscode.window.tabGroups.all) {
        group.tabs.forEach((tab, index) => {
            result.push({ tab, group, index, label: tab.label });
        });
    }
    return result;
}

/**
 * Find the tab for a focus request.
 *
 * Exact match first, then prefix, then substring. Claude Code truncates long
 * titles in the tab label, so an exact comparison alone misses often; going
 * straight to substring would instead risk matching an unrelated tab that
 * merely contains the words.
 */
function findTab(request) {
    const tabs = allTabs();
    const title = normalise(request.title);
    const project = normalise(request.project);
    const strategy = cfg().get('matchStrategy');

    if (title) {
        let hit = tabs.find(t => normalise(t.label) === title);
        if (hit) return { hit, how: 'exact title' };

        hit = tabs.find(t => normalise(t.label).startsWith(title) || title.startsWith(normalise(t.label)));
        if (hit) return { hit, how: 'prefix title' };

        hit = tabs.find(t => normalise(t.label).includes(title));
        if (hit) return { hit, how: 'substring title' };
    }

    // Threads are untitled for their first few turns -- Claude Code generates
    // the title a little way in. Falling back to the project name at least
    // lands in the right neighbourhood.
    if (strategy === 'titleThenPath' && project) {
        const hit = tabs.find(t => normalise(t.label).includes(project));
        if (hit) return { hit, how: 'project name' };
    }

    return null;
}

async function focusTab(entry) {
    // Focus the owning group first: openEditorAtIndex acts on the active one.
    await vscode.commands.executeCommand('workbench.action.focusFirstEditorGroup');
    const groups = vscode.window.tabGroups.all;
    const groupIndex = groups.indexOf(entry.group);
    for (let i = 0; i < groupIndex; i++) {
        await vscode.commands.executeCommand('workbench.action.focusNextGroup');
    }

    // openEditorAtIndex only goes up to 9. Past that, step -- bounded by the
    // tab count so a mismatch cannot spin.
    if (entry.index < 9) {
        await vscode.commands.executeCommand(`workbench.action.openEditorAtIndex${entry.index + 1}`);
        return;
    }
    await vscode.commands.executeCommand('workbench.action.openEditorAtIndex1');
    for (let i = 0; i < entry.index && i < entry.group.tabs.length; i++) {
        await vscode.commands.executeCommand('workbench.action.nextEditor');
    }
}

// ------------------------------------------------------------ focus request

async function handleFocusRequest(stateDir) {
    if (!cfg().get('enabled')) return;

    const file = path.join(stateDir, FOCUS_REQUEST);
    const req = readJson(file);
    if (!req || !req.stamp) return;

    // Only act once per request, and never on a stale one -- a file left by a
    // crash must not cause a surprise focus minutes later.
    if (req.stamp === lastHandledStamp) return;
    const age = Date.now() - Number(req.stamp);
    if (!Number.isFinite(age) || age > Number(cfg().get('requestMaxAgeMs'))) {
        lastHandledStamp = req.stamp;
        return;
    }
    lastHandledStamp = req.stamp;

    const found = findTab(req);
    if (!found) {
        // Expected whenever the thread lives in another window: every window
        // runs this extension and only one of them owns the tab.
        log(`no tab for "${req.title || req.sessionId}" (${allTabs().length} tabs here)`);
        if (cfg().get('notifyOnFocusFailure')) {
            vscode.window.showInformationMessage(`Claude Voice: no tab here for "${req.title || req.sessionId}"`);
        }
        return;
    }

    try {
        await focusTab(found.hit);
        log(`focused "${found.hit.label}" via ${found.how}`);
        setStatus(`$(target) ${found.hit.label}`);
    } catch (e) {
        log(`focus failed: ${e}`);
    }
}

// ------------------------------------------------------------------- status

function bridgeRunning() {
    try {
        const out = cp.execSync(
            'powershell -NoProfile -Command "@(Get-CimInstance Win32_Process -Filter \\"Name=\'pwsh.exe\'\\" | Where-Object { $_.CommandLine -like \'*ha-bridge.ps1*\' -and $_.CommandLine -notlike \'*Where-Object*\' }).Count"',
            { encoding: 'utf8', timeout: 5000, windowsHide: true }
        );
        return parseInt(out.trim(), 10) > 0;
    } catch (e) {
        return false;
    }
}

function setStatus(text) {
    if (!statusItem) return;
    if (!cfg().get('showStatusBar')) { statusItem.hide(); return; }
    statusItem.text = text;
    statusItem.show();
}

function refreshStatus(stateDir) {
    if (!stateDir) { setStatus('$(circle-slash) Claude Voice: no state dir'); return; }
    const state = readJson(path.join(stateDir, PENDING_STATE));
    const threads = state && state.known ? Object.keys(state.known).length : 0;
    const running = bridgeRunning();
    setStatus(`${running ? '$(radio-tower)' : '$(debug-disconnect)'} Claude Voice: ${threads} thread${threads === 1 ? '' : 's'}`);
    statusItem.tooltip = `Bridge: ${running ? 'running' : 'NOT running'}\nThreads: ${threads}\nState: ${stateDir}\n\nClick for status`;
}

// ----------------------------------------------------------------- commands

function repoRootFrom(stateDir) {
    // stateDir is <repo>/claude-voice/state
    return path.dirname(path.dirname(stateDir));
}

// ------------------------------------------------------------------- colour
//
// Output channels do not render ANSI -- they show the escape codes literally.
// A pseudoterminal is xterm.js, which does, and supports 24-bit truecolor. So
// the status view is a terminal: the swatches are then the thread's EXACT rgb,
// not a 256-palette approximation of it, which matters when the whole point is
// telling near-neighbour hues apart.

const ANSI = {
    reset: '\x1b[0m',
    dim: '\x1b[2m',
    bold: '\x1b[1m',
    fg: (r, g, b) => `\x1b[38;2;${r};${g};${b}m`,
    bg: (r, g, b) => `\x1b[48;2;${r};${g};${b}m`
};

function rgbOf(entry) {
    const c = Array.isArray(entry && entry.color) ? entry.color : [];
    return [Number(c[0]) || 0, Number(c[1]) || 0, Number(c[2]) || 0];
}

/** A solid block in the thread's own colour, plus its hex. */
function swatch(entry) {
    const [r, g, b] = rgbOf(entry);
    const hex = [r, g, b].map(v => v.toString(16).padStart(2, '0')).join('');
    return `${ANSI.bg(r, g, b)}    ${ANSI.reset} ${ANSI.fg(r, g, b)}#${hex}${ANSI.reset}`;
}

/** Colour the activity word the way the ring renders that state. */
function activityTag(activity) {
    switch (activity) {
        case 'attention': return `${ANSI.fg(255, 80, 80)}attention${ANSI.reset}`;
        case 'working':   return `${ANSI.fg(120, 200, 255)}working  ${ANSI.reset}`;
        default:          return `${ANSI.dim}idle     ${ANSI.reset}`;
    }
}

/**
 * Render status into a pseudoterminal, reusing the same one across calls.
 *
 * One terminal, cleared and rewritten each time -- rather than a fresh one per
 * invocation, which piles up tabs you then have to close by hand.
 *
 * The emitter has to outlive the call, since writing after `open` is how a
 * reused terminal gets new content. Both are dropped when the user closes the
 * terminal, so the next call builds a fresh one instead of firing into a dead
 * pty.
 */
let statusTerm = null;
let statusWrite = null;

function renderStatus(lines) {
    // \r\n, not \n: a pty needs the carriage return or every line staircases.
    // 2J clears the viewport, 3J clears scrollback so old runs cannot be
    // scrolled back into and mistaken for current, H homes the cursor.
    return '\x1b[2J\x1b[3J\x1b[H' + lines.join('\r\n') + '\r\n';
}

function showColourStatus(title, lines) {
    if (statusTerm && statusWrite) {
        statusWrite.fire(renderStatus(lines));
        statusTerm.show(true);
        return;
    }

    const writeEmitter = new vscode.EventEmitter();
    let opened = false;
    const pty = {
        onDidWrite: writeEmitter.event,
        open: () => {
            opened = true;
            writeEmitter.fire(renderStatus(lines));
        },
        close: () => { /* nothing to tear down */ },
        handleInput: () => { /* read-only view */ }
    };

    statusWrite = writeEmitter;
    statusTerm = vscode.window.createTerminal({ name: title, pty });
    statusTerm.show(true);

    // If open() has not fired yet the content above is already queued, so
    // nothing more to do -- this only guards against a terminal that failed
    // to open at all.
    if (!opened) log('status terminal created; content queued until open');
}

function disposeStatusTerminal(closed) {
    if (statusTerm && closed === statusTerm) {
        statusTerm = null;
        if (statusWrite) { statusWrite.dispose(); statusWrite = null; }
    }
}

async function cmdShowStatus(stateDir) {
    if (!stateDir) {
        vscode.window.showErrorMessage('Claude Voice: could not find claude-voice/state. Set claudeVoice.stateDir.');
        return;
    }
    const state = readJson(path.join(stateDir, PENDING_STATE)) || {};
    const known = state.known || {};
    const lines = [];
    lines.push(`State dir : ${stateDir}`);
    lines.push(`Bridge    : ${bridgeRunning() ? 'running' : 'NOT running'}`);
    lines.push(`Threads   : ${Object.keys(known).length}`);
    lines.push(`Cursor    : ${state.cursor || '(none)'}`);
    lines.push('');

    // Every thread, from every project and every VS Code window -- the state
    // file is shared, so this list is global. The tab list below is the only
    // window-local part.
    lines.push(`${ANSI.bold}ALL THREADS${ANSI.reset} (every window, every project)`);
    lines.push(`${ANSI.dim}  colour  hex      slot  state      where        title${ANSI.reset}`);
    const sorted = Object.entries(known).sort((a, b) => (a[1].ringSlot || 0) - (b[1].ringSlot || 0));
    const localLabels = allTabs().map(t => normalise(t.label));
    for (const [, e] of sorted) {
        const here = localLabels.some(l => l === normalise(e.title) || (e.title && l.includes(normalise(e.title))));
        lines.push(
            `  ${swatch(e)}  ` +
            `${String(e.ringSlot).padStart(2)}    ` +
            `${activityTag(e.activity)}  ` +
            `${here ? `${ANSI.bold}THIS WINDOW${ANSI.reset}` : `${ANSI.dim}elsewhere  ${ANSI.reset}`}  ` +
            `${e.title || `${ANSI.dim}(untitled)${ANSI.reset}`}`
        );
    }
    lines.push('');
    lines.push(`${ANSI.bold}TABS IN THIS WINDOW${ANSI.reset} (${allTabs().length})`);
    for (const t of allTabs()) lines.push(`  ${ANSI.dim}[${t.index}]${ANSI.reset} ${t.label}`);
    lines.push('');
    lines.push(`${ANSI.dim}"elsewhere" threads are still reachable: Focus Thread... broadcasts to`);
    lines.push(`every window, and whichever one owns the tab focuses it.${ANSI.reset}`);
    lines.push('');
    lines.push(`${ANSI.dim}Swatches are the thread's exact rgb, as sent to the device.${ANSI.reset}`);

    // Terminal, not the output channel: output channels show ANSI escapes
    // literally, so the swatches would be gibberish there. The output channel
    // stays for the running log (Claude Voice: Show Log).
    showColourStatus('Claude Voice Status', lines);
}

async function cmdFocusThread(stateDir) {
    const state = readJson(path.join(stateDir || '', PENDING_STATE));
    if (!state || !state.known) {
        vscode.window.showErrorMessage('Claude Voice: no thread state found.');
        return;
    }
    const items = Object.entries(state.known).map(([id, e]) => ({
        label: e.title || '(untitled)',
        description: `slot ${e.ringSlot} · ${e.activity || 'idle'}`,
        detail: id,
        req: { sessionId: id, title: e.title, project: e.project, stamp: Date.now() }
    }));
    if (!items.length) { vscode.window.showInformationMessage('Claude Voice: no threads known.'); return; }

    const pick = await vscode.window.showQuickPick(items, {
        placeHolder: 'Focus which thread? (searches every VS Code window)',
        matchOnDescription: true,
        matchOnDetail: true
    });
    if (!pick) return;

    // Try this window first, since that is instant and the common case.
    const found = findTab(pick.req);
    if (found) {
        await focusTab(found.hit);
        return;
    }

    // Not here -- broadcast it. Every window runs this extension and watches
    // the same request file, so whichever one owns that tab will focus it.
    // Without this, the quick-pick could only ever reach threads in the window
    // you happened to run it from, which is the opposite of useful when the
    // whole point is finding a thread you have lost track of.
    if (!stateDir) {
        vscode.window.showWarningMessage(`Claude Voice: no tab here for "${pick.label}", and no state dir to broadcast through.`);
        return;
    }
    try {
        writeFocusRequest(stateDir, pick.req);
        log(`broadcast focus request for "${pick.label}"`);
        vscode.window.showInformationMessage(`Claude Voice: asked other windows to focus "${pick.label}".`);
    } catch (e) {
        vscode.window.showErrorMessage(`Claude Voice: could not broadcast focus request: ${e}`);
    }
}

/**
 * Write a focus request for every window to see.
 *
 * Same shape and the same atomic-swap discipline the bridge uses, so a reader
 * polling the file never sees a half-written one.
 */
function writeFocusRequest(stateDir, req) {
    const tmp = path.join(stateDir, `focus-request.${Date.now()}.${process.pid}.tmp`);
    fs.writeFileSync(tmp, JSON.stringify(req), 'utf8');
    fs.renameSync(tmp, path.join(stateDir, FOCUS_REQUEST));
}

function runPwsh(args, label) {
    const term = vscode.window.createTerminal({ name: label });
    term.show(true);
    term.sendText(args);
}

function cmdInstallHooks(stateDir) {
    const root = stateDir ? repoRootFrom(stateDir) : '';
    const script = path.join(root, 'claude-voice', 'scripts', 'notify-ha.ps1');
    if (!fs.existsSync(script)) {
        vscode.window.showErrorMessage(`Claude Voice: notify-ha.ps1 not found at ${script}`);
        return;
    }
    // Run visibly in a terminal rather than silently: this edits the user's
    // global settings, and they should see exactly what happened.
    runPwsh(
        `& { $s='${script.replace(/\\/g, '\\\\')}'; ` +
        `$p="$env:USERPROFILE\\.claude\\settings.json"; ` +
        `Copy-Item $p "$p.bak-$(Get-Date -f yyyyMMdd-HHmmss)"; ` +
        `$j = Get-Content $p -Raw | ConvertFrom-Json; ` +
        `if ($j.PSObject.Properties.Name -contains 'hooks') { Write-Warning 'hooks key already present - merge by hand'; return }; ` +
        `function H($e) { @{ hooks = @(@{ type='command'; command = ('pwsh -NoProfile -File "{0}" -Event {1}' -f $s, $e) }) } }; ` +
        `$j | Add-Member hooks ([ordered]@{ Notification=@(H 'notification'); Stop=@(H 'stop'); UserPromptSubmit=@(H 'clear') }); ` +
        `$j | ConvertTo-Json -Depth 10 | Set-Content $p -Encoding UTF8; ` +
        `Write-Host 'Installed. Hook events:' ((Get-Content $p -Raw | ConvertFrom-Json).hooks.PSObject.Properties.Name -join ', ') }`,
        'Claude Voice: install hooks'
    );
}

function cmdUninstallHooks() {
    runPwsh(
        `& { $p="$env:USERPROFILE\\.claude\\settings.json"; ` +
        `Copy-Item $p "$p.bak-$(Get-Date -f yyyyMMdd-HHmmss)"; ` +
        `$j = Get-Content $p -Raw | ConvertFrom-Json; ` +
        `$j.PSObject.Properties.Remove('hooks'); ` +
        `$j | ConvertTo-Json -Depth 10 | Set-Content $p -Encoding UTF8; ` +
        `Write-Host 'Removed hooks from global settings.' }`,
        'Claude Voice: uninstall hooks'
    );
}

function cmdStartBridge(stateDir) {
    const root = stateDir ? repoRootFrom(stateDir) : '';
    const script = path.join(root, 'claude-voice', 'scripts', 'ha-bridge.ps1');
    runPwsh(`Start-Process pwsh -ArgumentList '-NoProfile','-File','${script}' -WindowStyle Hidden; Write-Host 'Bridge started.'`, 'Claude Voice: start bridge');
}

function cmdStopBridge() {
    runPwsh(
        `Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" | ` +
        `Where-Object { $_.CommandLine -like '*ha-bridge.ps1*' -and $_.CommandLine -notlike '*Where-Object*' } | ` +
        `ForEach-Object { Stop-Process -Id $_.ProcessId -Force; "stopped $($_.ProcessId)" }`,
        'Claude Voice: stop bridge'
    );
}

// ---------------------------------------------------------------- lifecycle

function startWatching(stateDir, context) {
    if (watcher) { try { watcher.close(); } catch (e) { /* ignore */ } watcher = null; }
    if (pollTimer) { clearInterval(pollTimer); pollTimer = null; }
    if (!stateDir) return;

    // fs.watch is unreliable for single files on Windows -- it misses events
    // and sometimes fires on a directory rename instead. The poll below is the
    // backstop that makes this dependable; the watcher just makes it prompt.
    try {
        watcher = fs.watch(stateDir, (evt, name) => {
            if (name === FOCUS_REQUEST) handleFocusRequest(stateDir);
        });
        context.subscriptions.push({ dispose: () => { try { watcher.close(); } catch (e) { /* ignore */ } } });
    } catch (e) {
        log(`fs.watch unavailable (${e}) -- polling only`);
    }

    pollTimer = setInterval(() => handleFocusRequest(stateDir), Number(cfg().get('pollIntervalMs')));
    context.subscriptions.push({ dispose: () => clearInterval(pollTimer) });
}

function activate(context) {
    out = vscode.window.createOutputChannel('Claude Voice');
    context.subscriptions.push(out);

    statusItem = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Right, 100);
    statusItem.command = 'claudeVoice.showStatus';
    context.subscriptions.push(statusItem);

    let stateDir = findStateDir();
    log(`activated. state dir: ${stateDir || '(not found)'}`);

    startWatching(stateDir, context);
    refreshStatus(stateDir);
    statusTimer = setInterval(() => refreshStatus(stateDir), 10000);
    context.subscriptions.push({ dispose: () => clearInterval(statusTimer) });

    context.subscriptions.push(
        vscode.commands.registerCommand('claudeVoice.showStatus', () => cmdShowStatus(stateDir)),
        vscode.commands.registerCommand('claudeVoice.focusThread', () => cmdFocusThread(stateDir)),
        vscode.commands.registerCommand('claudeVoice.installHooks', () => cmdInstallHooks(stateDir)),
        vscode.commands.registerCommand('claudeVoice.uninstallHooks', () => cmdUninstallHooks()),
        vscode.commands.registerCommand('claudeVoice.startBridge', () => cmdStartBridge(stateDir)),
        vscode.commands.registerCommand('claudeVoice.stopBridge', () => cmdStopBridge()),
        vscode.commands.registerCommand('claudeVoice.showLog', () => out.show(true))
    );

    // Drop our reference when the user closes the status terminal, so the next
    // Show Status builds a new one rather than firing into a dead pty.
    context.subscriptions.push(
        vscode.window.onDidCloseTerminal(t => disposeStatusTerminal(t))
    );

    context.subscriptions.push(
        vscode.workspace.onDidChangeConfiguration(e => {
            if (!e.affectsConfiguration('claudeVoice')) return;
            stateDir = findStateDir();
            log(`config changed. state dir: ${stateDir || '(not found)'}`);
            startWatching(stateDir, context);
            refreshStatus(stateDir);
        })
    );
}

function deactivate() {
    if (watcher) { try { watcher.close(); } catch (e) { /* ignore */ } }
    if (pollTimer) clearInterval(pollTimer);
    if (statusTimer) clearInterval(statusTimer);
    if (statusWrite) { statusWrite.dispose(); statusWrite = null; }
    statusTerm = null;
}

module.exports = { activate, deactivate };
