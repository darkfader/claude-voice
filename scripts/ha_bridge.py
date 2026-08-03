# claude-voice/scripts/ha_bridge.py
"""Ported from ha-bridge.ps1 (kept alongside during the migration) -- see
that file's comments for the reasoning behind each rule and timing choice,
preserved here rather than re-derived.

Websocket client uses `websocket-client` (sync, low-level WebSocket, not
the async `websockets` package) so the polling-with-timeout receive loop
structure -- and the reasoning behind it (the dial settle timer and idle
check both need a clock even on a quiet connection) -- ports directly
without restructuring into an asyncio event loop.

confirm-session.ps1/dictate-type.ps1 were subprocess calls from the PS
original; here they're direct in-process function calls (confirm_session())
since everything is now the same language -- no correctness change, just
one less process spawn per button press.
"""
import ctypes
import json
import os
import sys
import time
import uuid
from ctypes import wintypes
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

import websocket

import ambient_state
import button_action
import pending_state as ps
import ring_display
import ring_state
import session_color
from confirm_session import confirm_session
from ha_client import (
    get_ha_connection,
    invoke_ha_announce,
    invoke_ha_chime,
    invoke_ha_error_sound,
    invoke_ha_led,
    invoke_ha_ring_state,
    is_ha_muted,
    is_ha_notifications_enabled,
    RING_STATE_ENTITY_ID,
)

_LOG_PATH = Path(__file__).resolve().parent.parent / 'state' / 'ha-bridge.log'
_STATE_DIR = Path(__file__).resolve().parent.parent / 'state'

# Single-instance guard -- see ha-bridge.ps1's own comment on why this
# matters (two bridges would both react to every dial rotation and button
# press). Same ctypes approach as pending_state.py's mutex, same name so a
# running PowerShell bridge and this Python one mutually exclude each
# other during the migration, not just two Python instances.
_kernel32 = ctypes.WinDLL('kernel32', use_last_error=True)
_kernel32.CreateMutexW.restype = wintypes.HANDLE
_kernel32.CreateMutexW.argtypes = [wintypes.LPVOID, wintypes.BOOL, wintypes.LPCWSTR]
_kernel32.WaitForSingleObject.restype = wintypes.DWORD
_kernel32.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]

_SINGLETON_MUTEX_NAME = 'Global\\ClaudeVoiceHaBridgeSingleton'
_WAIT_OBJECT_0 = 0x0
_WAIT_ABANDONED = 0x80


def _acquire_singleton_or_exit():
    handle = _kernel32.CreateMutexW(None, False, _SINGLETON_MUTEX_NAME)
    if not handle:
        raise ctypes.WinError(ctypes.get_last_error())
    result = _kernel32.WaitForSingleObject(handle, 0)
    if result not in (_WAIT_OBJECT_0, _WAIT_ABANDONED):
        print('ha_bridge.py is already running (another instance holds the singleton mutex) -- exiting.',
              file=sys.stderr)
        sys.exit(1)
    return handle  # deliberately never released/closed -- held for the process lifetime


@dataclass
class BridgeState:
    # Dial settle timer -- see Invoke-DialSettleCheck's comment: focus fires
    # once, 150ms after the last detent, not per-detent, so a multi-step
    # turn causes one window switch rather than several.
    dial_settle_ms: int = 150
    dial_settle_at: datetime = field(default_factory=lambda: datetime.min.replace(tzinfo=timezone.utc))
    dial_settle_session: str = None
    # Two detents make one session step -- the encoder has 24 detents per
    # revolution and the ring has 12 LEDs.
    dial_detents_per_step: int = 2
    dial_accumulator: int = 0
    last_idle_check_at: datetime = field(default_factory=lambda: datetime.min.replace(tzinfo=timezone.utc))
    idle_fade_minutes: int = 10


def write_bridge_log(message, level='fault'):
    line = f'{datetime.now().astimezone().isoformat()} [{level}] {message}'
    _LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
    with open(_LOG_PATH, 'a', encoding='utf-8') as f:
        f.write(line + '\n')
    # Faults still surface on the console; info would drown them, and the
    # bridge runs hidden in production anyway.
    if level == 'fault':
        print(f'WARNING: {line}', file=sys.stderr)


def _truncate_log_if_large():
    # Startup-only truncation, same as the PS original -- checking size on
    # every write would cost a stat call per line for nothing, given the
    # bridge restarts at every logon.
    if not _LOG_PATH.exists():
        return
    if _LOG_PATH.stat().st_size > 1_000_000:
        lines = _LOG_PATH.read_text(encoding='utf-8').splitlines()
        _LOG_PATH.write_text('\n'.join(lines[-2000:]) + '\n', encoding='utf-8')


def get_session_spoken_name(entry):
    """Claude Code's own thread title when there is one; falls back to
    project + ordinal for sessions too new to have been titled, and for
    pending entries (which carry no title, only their `known` counterpart
    does)."""
    if entry.get('title'):
        return str(entry['title'])
    return session_color.get_session_display_name(entry.get('project'), entry.get('ordinal', 1))


class HaEventStream:
    """Mirrors Connect-HaEventStream: handshake (auth, subscribe to
    state_changed and esphome.claude_dial), then a receive() that returns
    None on a quiet 250ms slice rather than blocking -- that poll is what
    gives the dial-settle timer and idle check a clock even when nothing
    is happening on the connection."""

    def __init__(self, connection):
        ws_url = connection['url'].replace('http', 'ws', 1) + '/api/websocket'
        self.ws = websocket.create_connection(ws_url, timeout=10)
        self._next_id = 1

        hello = self._recv_blocking()
        if hello.get('type') != 'auth_required':
            raise RuntimeError(f"Unexpected HA handshake: {hello.get('type')}")
        token = connection['headers']['Authorization'].removeprefix('Bearer ')
        self._send({'type': 'auth', 'access_token': token})
        auth = self._recv_blocking()
        if auth.get('type') != 'auth_ok':
            raise RuntimeError(f"HA websocket auth failed: {auth.get('type')}")

        self._subscribe('state_changed')
        # The dial is read from an explicit event, not from the rotation
        # sensor's counter -- once volume also lives on the dial, both
        # gestures drive the same counter and are indistinguishable.
        self._subscribe('esphome.claude_dial')

        self.ws.settimeout(0.25)

    def _send(self, obj):
        self.ws.send(json.dumps(obj))

    def _recv_blocking(self):
        raw = self.ws.recv()
        if not raw:
            raise RuntimeError('Received empty/close frame from HA websocket')
        return json.loads(raw)

    def _subscribe(self, event_type):
        msg_id = self._next_id
        self._next_id += 1
        self._send({'id': msg_id, 'type': 'subscribe_events', 'event_type': event_type})
        ack = self._recv_blocking()
        if not ack.get('success'):
            raise RuntimeError(f"HA subscribe_events({event_type}) failed: {ack.get('error')}")

    def receive(self):
        """None on a quiet 250ms slice, the parsed message otherwise."""
        try:
            raw = self.ws.recv()
        except websocket.WebSocketTimeoutException:
            return None
        if not raw:
            raise RuntimeError('Received empty/close frame from HA websocket')
        return json.loads(raw)

    @property
    def connected(self):
        return self.ws.connected


def request_editor_focus(session_id, title, project):
    """Ask the VS Code extension to focus a thread's tab -- Win32 focus can
    only address a WINDOW, and all of a user's Claude Code threads
    routinely live as tabs inside ONE VS Code window. A file rather than a
    socket: no port, no auth, no protocol version, survives either side
    restarting."""
    try:
        req = {
            'sessionId': session_id,
            'title': title or '',
            'project': project or '',
            # Milliseconds since epoch. The extension ignores anything
            # older than a few seconds, so a file left behind by a crash
            # cannot cause a surprise focus later.
            'stamp': int(datetime.now(timezone.utc).timestamp() * 1000),
        }
        tmp = _STATE_DIR / f'focus-request.{uuid.uuid4().hex}.tmp'
        tmp.write_text(json.dumps(req), encoding='utf-8')
        # Atomic swap, same reasoning as pending.json.
        os.replace(tmp, _STATE_DIR / 'focus-request.json')
    except OSError as exc:
        write_bridge_log(f'focus request write failed (continuing): {exc}')


def publish_ring_state(connection):
    try:
        s = ps.get_pending_state()
        invoke_ha_ring_state(connection, ring_state.get_ring_state_string(s['known'], cursor=s.get('cursor')))
    except Exception as exc:
        write_bridge_log(f'ring state publish failed (continuing): {exc}')


def invoke_dial_rotation_event(connection, bridge, direction):
    if not is_ha_notifications_enabled(connection):
        return

    # Accumulate detents into session steps. A change of direction resets
    # rather than subtracts: a clockwise-then-anticlockwise wobble is a
    # hesitation, not half a step forward and half a step back.
    delta = 1 if direction == 'cw' else -1
    if bridge.dial_accumulator != 0 and (bridge.dial_accumulator > 0) != (delta > 0):
        bridge.dial_accumulator = 0
    bridge.dial_accumulator += delta
    if abs(bridge.dial_accumulator) < bridge.dial_detents_per_step:
        return
    bridge.dial_accumulator = 0

    state = ps.get_pending_state()
    next_id = button_action.get_known_cycle_target(state['known'], state.get('cursor'), direction)
    # Nothing known: a fresh state file, or everything expired. Rotation
    # is a no-op.
    if not next_id:
        return

    entry = state['known'][next_id]
    ps.set_pending_cursor(next_id)
    ps.set_displayed_session(next_id)

    # Brightness still means attention, hue still means identity: full
    # brightness only if this session is actually waiting on you.
    if next_id in state['sessions']:
        invoke_ha_led(connection, rgb=state['sessions'][next_id]['color'], brightness=255)
    else:
        invoke_ha_led(connection, rgb=entry['color'], brightness=100)

    # Arm the settle timer; the focus and the announcement happen there.
    bridge.dial_settle_session = next_id
    bridge.dial_settle_at = datetime.now(timezone.utc).timestamp() + bridge.dial_settle_ms / 1000.0
    write_bridge_log(f'dial {direction} -> {get_session_spoken_name(entry)}', level='info')
    publish_ring_state(connection)


def invoke_dial_settle_check(bridge):
    if not bridge.dial_settle_session:
        return
    if time.time() < bridge.dial_settle_at:
        return

    session_id = bridge.dial_settle_session
    # Disarm FIRST: an exception below must not re-fire the focus on every
    # subsequent tick of the receive pump.
    bridge.dial_settle_session = None

    state = ps.get_pending_state()
    if session_id not in state['known']:
        return
    entry = state['known'][session_id]
    name = get_session_spoken_name(entry)

    # Ask the VS Code extension first: it is the only thing that can
    # switch between threads sharing one window, which is the normal case.
    request_editor_focus(session_id, str(entry.get('title') or ''), str(entry.get('project') or ''))

    # Then the Win32 path, which still earns its place for threads in a
    # DIFFERENT window. -keep_pending: rotation is navigation, must not
    # dismiss the light telling you a session still wants something.
    window_pid = int(entry['windowPid']) if entry.get('windowPid') else 0
    ok = confirm_session(session_id, entry.get('project'), focus_only=True, keep_pending=True, window_pid=window_pid)
    if not ok:
        # SILENT, and only logged at info -- Request-editor-focus above has
        # almost certainly already succeeded; Win32 only covers threads in
        # a DIFFERENT window, so it failing here usually means "the
        # extension dealt with it", not "nothing happened".
        write_bridge_log(f'win32 focus miss for {name} (extension path likely handled it)', level='info')
        return

    write_bridge_log(f'focus -> {name}', level='info')
    # SILENT -- no chime, no speech. See ha-bridge.ps1's comment: speech/
    # chime both spin up the whole audio pipeline, and rotating the dial
    # fires them back to back, which was visible in the serial log right
    # before a dial-triggered reboot.


def invoke_button_event(connection, event_type):
    if not is_ha_notifications_enabled(connection):
        return

    state = ps.get_pending_state()
    # known_sessions is what double_press resolves against: the dial sets
    # the cursor from the known map, so without this the button would
    # ignore the dial's selection whenever it wasn't also pending.
    result = button_action.get_button_action(event_type, state['sessions'], cursor=state.get('cursor'),
                                              known_sessions=state['known'])
    action = result['Action']

    if action == 'activate':
        entry = state['known'].get(result['SessionId'])
        if not entry:
            return
        name = get_session_spoken_name(entry)
        ps.set_pending_cursor(result['SessionId'])
        ps.set_displayed_session(result['SessionId'])
        activate_pid = int(entry['windowPid']) if entry.get('windowPid') else 0
        ok = confirm_session(result['SessionId'], entry.get('project'), focus_only=True, keep_pending=True,
                              window_pid=activate_pid)
        if not ok:
            write_bridge_log(f'activate failed for {name} (no matching window)')
            invoke_ha_error_sound(connection)
        else:
            write_bridge_log(f'activate -> {name}', level='info')
            invoke_ha_chime(connection)
        if result['SessionId'] in state['sessions']:
            invoke_ha_led(connection, rgb=state['sessions'][result['SessionId']]['color'], brightness=255)
        else:
            invoke_ha_led(connection, rgb=entry['color'], brightness=100)
        publish_ring_state(connection)

    elif action == 'focus':
        entry = state['sessions'][result['SessionId']]
        focus_pid = 0
        if result['SessionId'] in state['known']:
            known_entry = state['known'][result['SessionId']]
            if known_entry.get('windowPid'):
                focus_pid = int(known_entry['windowPid'])
            if known_entry.get('title'):
                entry = known_entry
        ok = confirm_session(result['SessionId'], entry.get('project'), focus_only=True, window_pid=focus_pid)
        if not ok:
            invoke_ha_error_sound(connection)
            ps.set_displayed_session(result['SessionId'])
            invoke_ha_led(connection, rgb=entry['color'], brightness=255)
        else:
            invoke_ha_chime(connection)
            ring_display.set_remaining_led(connection)
        publish_ring_state(connection)

    elif action == 'reply':
        entry = state['sessions'][result['SessionId']]
        reply_pid = 0
        if result['SessionId'] in state['known']:
            known_entry = state['known'][result['SessionId']]
            if known_entry.get('windowPid'):
                reply_pid = int(known_entry['windowPid'])
            if known_entry.get('title'):
                entry = known_entry
        ok = confirm_session(result['SessionId'], entry.get('project'), text=result['Text'], window_pid=reply_pid)
        if not ok:
            invoke_ha_error_sound(connection)
        else:
            invoke_ha_chime(connection)
            ring_display.set_remaining_led(connection)
        publish_ring_state(connection)

    elif action == 'dismiss':
        ps.clear_pending_session(result['SessionId'])
        ring_display.set_remaining_led(connection)
        publish_ring_state(connection)

    elif action == 'none':
        if result.get('Speak') and not is_ha_muted(connection):
            invoke_ha_announce(connection, result['Speak'])


def invoke_idle_check(connection, bridge):
    state = ps.get_pending_state()
    if len(state['sessions']) > 0:
        return  # pending outranks active

    # The ring can be showing a session that is neither pending nor the
    # current ambient activeSession -- displayedSession is deliberately
    # never auto-cleared by get_pending_state precisely so this check can
    # still see it here.
    if state.get('displayedSession') and state['displayedSession'] != state.get('activeSession'):
        ps.clear_displayed_session()
        invoke_ha_led(connection, off=True)
        return

    if ambient_state.is_ambient_idle_expired(state, datetime.now(timezone.utc), bridge.idle_fade_minutes):
        ps.clear_active_session()
        ps.clear_displayed_session()
        invoke_ha_led(connection, off=True)


def _run():
    _truncate_log_if_large()
    bridge = BridgeState()

    # Outer supervision loop: any failure (connect, auth, subscribe, or a
    # receive-loop exception/dropped connection) logs and retries rather
    # than exiting. Exponential backoff capped at 60s; resets after a
    # successful connect.
    backoff_sec = 5
    while True:
        try:
            conn = get_ha_connection()
            stream = HaEventStream(conn)
            write_bridge_log(f"connected to {conn['url']}", level='info')
            backoff_sec = 5

            # Republish the ring on every connect -- the device does not
            # persist ring state across a reboot, and the bridge otherwise
            # only publishes when something happens.
            publish_ring_state(conn)

            while stream.connected:
                msg = stream.receive()
                data = msg.get('event', {}).get('data') if msg and msg.get('type') == 'event' else None

                if data is not None and msg['event'].get('event_type') == 'esphome.claude_dial':
                    direction = str(data.get('direction') or '')
                    if direction in ('cw', 'ccw'):
                        try:
                            invoke_dial_rotation_event(conn, bridge, direction)
                        except Exception as exc:
                            write_bridge_log(f'invoke_dial_rotation_event failed (continuing): {exc}')
                elif data is not None and data.get('entity_id') == RING_STATE_ENTITY_ID:
                    # Self-heal after a device reboot -- claude_ring_state
                    # has initial_value "", so a firmware flash or power
                    # cycle wipes it and the ring goes dark. Guarded on
                    # having something to send, so this cannot spin.
                    ring_now = str((data.get('new_state') or {}).get('state') or '')
                    if not ring_now.strip() or ring_now in ('unknown', 'unavailable'):
                        try:
                            heal_state = ps.get_pending_state()
                            if len(heal_state['known']) > 0:
                                write_bridge_log(f"ring state was '{ring_now}' -- republishing", level='info')
                                publish_ring_state(conn)
                        except Exception as exc:
                            write_bridge_log(f'ring self-heal failed (continuing): {exc}')
                elif data is not None and data.get('entity_id') == 'event.home_assistant_voice_0932b4_button_press':
                    event_type = ((data.get('new_state') or {}).get('attributes') or {}).get('event_type')
                    if event_type:
                        try:
                            invoke_button_event(conn, event_type)
                        except Exception as exc:
                            write_bridge_log(f'invoke_button_event failed (continuing): {exc}')

                # Runs every pass, including on empty 250ms slices -- that
                # is what gives the settle timer a clock to fire against.
                try:
                    invoke_dial_settle_check(bridge)
                except Exception as exc:
                    write_bridge_log(f'invoke_dial_settle_check failed (continuing): {exc}')

                if time.time() - bridge.last_idle_check_at.timestamp() >= 60:
                    bridge.last_idle_check_at = datetime.now(timezone.utc)
                    try:
                        invoke_idle_check(conn, bridge)
                    except Exception as exc:
                        write_bridge_log(f'invoke_idle_check failed (continuing): {exc}')

            write_bridge_log('websocket left open state -- reconnecting')
        except Exception as exc:
            write_bridge_log(f'connection error: {exc}')

        time.sleep(backoff_sec)
        backoff_sec = min(backoff_sec * 2, 60)


def main():
    _acquire_singleton_or_exit()
    _run()


if __name__ == '__main__':
    main()
