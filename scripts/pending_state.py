# claude-voice/scripts/pending_state.py
"""Ported from PendingState.psm1 (kept alongside during the migration) --
see that file's extensive comments for the reasoning behind each rule,
preserved here rather than re-derived. This module DELIBERATELY imports
session_color directly (unlike the PowerShell original, which required the
caller to import SessionColor.psm1 itself to avoid Import-Module -Force
forking a second module instance -- that risk doesn't exist for a plain
Python import).

Cross-process locking uses a real Win32 named mutex (via ctypes, not
pywin32, to avoid a new dependency) so this can safely interoperate with
PendingState.psm1 writing the SAME pending.json during the migration --
both must serialise against the same OS-level lock or a hook firing from
one language while this reads/writes from the other could race.
"""
import ctypes
import json
import os
import time
import uuid
from contextlib import contextmanager
from ctypes import wintypes
from datetime import datetime, timedelta, timezone
from pathlib import Path

from session_color import (
    convert_from_hue_slot,
    get_session_ordinal,
    resolve_ring_slot,
    resolve_session_color_slot,
)

_state_path = Path(__file__).resolve().parent.parent / 'state' / 'pending.json'
_mutex_name = 'Global\\ClaudeVoicePendingState'
_expiry_hours = 4.0
_known_expiry_hours = 24.0
# Idle-fade: a known session that hasn't been touched in this long loses its
# ring slot and colour (both set to None) but stays in `known`. Was 1h;
# halved after the ring accumulated enough old idle threads in the
# background to be distracting in practice -- 30 min still comfortably
# outlasts a normal thinking pause.
_known_idle_fade_hours = 0.5
_known_hard_expiry_hours = 48.0


class PendingStateLockTimeout(Exception):
    pass


def set_pending_state_path(path):
    global _state_path
    _state_path = Path(path)


def set_pending_state_mutex_name(name):
    global _mutex_name
    _mutex_name = name


def set_pending_state_expiry_hours(hours):
    global _expiry_hours
    _expiry_hours = hours


def set_known_expiry_hours(hours):
    global _known_expiry_hours
    _known_expiry_hours = hours


def set_known_idle_fade_hours(hours):
    global _known_idle_fade_hours
    _known_idle_fade_hours = hours


def set_known_hard_expiry_hours(hours):
    global _known_hard_expiry_hours
    _known_hard_expiry_hours = hours


# ------------------------------------------------------------- Win32 mutex

_kernel32 = ctypes.WinDLL('kernel32', use_last_error=True)
_kernel32.CreateMutexW.restype = wintypes.HANDLE
_kernel32.CreateMutexW.argtypes = [wintypes.LPVOID, wintypes.BOOL, wintypes.LPCWSTR]
_kernel32.WaitForSingleObject.restype = wintypes.DWORD
_kernel32.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
_kernel32.ReleaseMutex.restype = wintypes.BOOL
_kernel32.ReleaseMutex.argtypes = [wintypes.HANDLE]
_kernel32.CloseHandle.argtypes = [wintypes.HANDLE]

_WAIT_OBJECT_0 = 0x00000000
_WAIT_ABANDONED = 0x00000080


@contextmanager
def with_pending_state_lock():
    """Mirrors Invoke-WithPendingStateLock. Raises PendingStateLockTimeout
    if the mutex isn't acquired within 5s -- same timeout as the PS
    original's `$mutex.WaitOne(5000)`.

    WAIT_ABANDONED (the previous holder's process died mid-hold) is treated
    as a successful acquisition, same as any other Win32 caller would --
    unlike .NET's Mutex wrapper, which turns this into
    AbandonedMutexException. The PS original's own test comments document
    that quirk as a known "poisons later runs" risk if a holder is
    force-killed rather than releasing cleanly; raw Win32 has no such
    exception to poison anything with, so this is a deliberate
    improvement, not a faithfully-reproduced bug."""
    handle = _kernel32.CreateMutexW(None, False, _mutex_name)
    if not handle:
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        result = _kernel32.WaitForSingleObject(handle, 5000)
        if result not in (_WAIT_OBJECT_0, _WAIT_ABANDONED):
            raise PendingStateLockTimeout('Timed out waiting for pending-state lock')
        try:
            yield
        finally:
            _kernel32.ReleaseMutex(handle)
    finally:
        _kernel32.CloseHandle(handle)


# ------------------------------------------------------------ persistence

def _new_empty_state():
    return {'sessions': {}, 'known': {}, 'cursor': None, 'activeSession': None,
            'activeSince': None, 'displayedSession': None}


def save_pending_state(state):
    """Atomic write: write to a temp file in the SAME directory, then swap
    it into place via os.replace(). On Windows, os.replace() uses
    MoveFileExW with MOVEFILE_REPLACE_EXISTING -- the same underlying Win32
    call PendingState.psm1's [System.IO.File]::Move($tmp, $dest, $true)
    uses, which is the one of three approaches (see that file's Save-
    PendingState comment for the other two and why they were rejected)
    empirically verified atomic under a concurrent-write stress test (0
    misses / ~100k direct File.Exists probes)."""
    _state_path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = _state_path.parent / f'pending.{uuid.uuid4().hex}.tmp'
    try:
        tmp_path.write_text(json.dumps(state), encoding='utf-8')
        os.replace(tmp_path, _state_path)
    finally:
        if tmp_path.exists():
            try:
                tmp_path.unlink()
            except OSError:
                pass


def _parse_datetime_or_none(value):
    """None is the MinValue-equivalent sentinel used throughout this module
    -- an unparseable/missing timestamp NEVER triggers an expiry/fade check
    (every caller below explicitly guards on `is not None` first), mirroring
    [datetime]::TryParse's fail-safe-by-NOT-removing semantics. This is the
    OPPOSITE fail-safe direction from ring_state.py's rendering logic (which
    treats unparseable as "already expired" for display) -- two different
    modules, two different intentional defaults; do not unify them."""
    if value:
        try:
            return datetime.fromisoformat(str(value).replace('Z', '+00:00'))
        except ValueError:
            pass
    return None


def get_pending_state():
    if not _state_path.exists():
        return _new_empty_state()

    # Bounded retry against a transient collision with a concurrent atomic
    # swap in progress -- 40 attempts * 5ms = 200ms budget, same as the PS
    # original's comment on why that specific budget was chosen.
    raw = None
    max_attempts = 40
    for attempt in range(1, max_attempts + 1):
        try:
            raw = _state_path.read_text(encoding='utf-8')
            break
        except OSError:
            if attempt == max_attempts:
                return _new_empty_state()
            time.sleep(0.005)

    if raw is None or not raw.strip():
        return _new_empty_state()

    try:
        state = json.loads(raw)
    except json.JSONDecodeError:
        return _new_empty_state()

    # A file from the old account-keyed format (or any other shape) is
    # runtime state, not data worth migrating -- treat it as empty rather
    # than letting one stale file wedge every future hook. Also catches
    # `{"sessions": []}`: a JSON array deserialises to a list, not a dict.
    if not isinstance(state, dict) or not isinstance(state.get('sessions'), dict):
        return _new_empty_state()

    # Expire stale entries on read. A terminal closed while Claude was
    # waiting never fires a clearing hook, so without this an abandoned
    # session would sit in the dial rotation forever.
    cutoff = datetime.now(timezone.utc) - timedelta(hours=_expiry_hours)
    for sid in list(state['sessions'].keys()):
        since = _parse_datetime_or_none(state['sessions'][sid].get('since'))
        if since is not None and since < cutoff:
            del state['sessions'][sid]

    # `known` outlives `sessions`: the dial cycles every session seen
    # recently, not just the ones currently waiting on the user. Defaulted
    # rather than migrated: a pending.json written before this field
    # existed is runtime state, not data worth preserving.
    if not isinstance(state.get('known'), dict):
        state['known'] = {}

    now = datetime.now(timezone.utc)
    for sid in list(state['known'].keys()):
        entry = state['known'][sid]
        if not entry.get('activity'):
            entry['activity'] = 'idle'
        if not entry.get('activitySince'):
            entry['activitySince'] = entry.get('lastSeen')

        last_seen_at = _parse_datetime_or_none(entry.get('lastSeen'))

        # For a 'working' session, lastSeen is frozen at whenever the last
        # hook fired (turn start, typically) -- a single long-running turn
        # with no intermediate hook can leave it hours stale while the
        # session is still genuinely running. Claude Code keeps appending
        # to the transcript file for as long as a turn is actually in
        # progress, even with no hook firing, so its mtime is a truer
        # liveness signal than the hook-driven timestamp for this one case.
        # Deliberately does NOT just exempt 'working' outright: a CRASHED
        # mid-turn session has a transcript that stops updating too, so it
        # still fades/expires normally -- this only protects a session
        # that is actually still writing.
        liveness_at = last_seen_at
        if entry.get('activity') == 'working':
            transcript_path = entry.get('transcriptPath')
            if transcript_path:
                try:
                    mtime = datetime.fromtimestamp(os.path.getmtime(transcript_path), tz=timezone.utc)
                    if liveness_at is None or mtime > liveness_at:
                        liveness_at = mtime
                except OSError:
                    pass  # Unreadable transcript -- fall back to last_seen_at.

        # Hard expiry: 48h idle removes the entry ALWAYS, transcript or
        # not. Checked first and unconditionally -- overrides "keep
        # forever if transcript exists" below.
        if liveness_at is not None and liveness_at < now - timedelta(hours=_known_hard_expiry_hours):
            del state['known'][sid]
            continue

        # Gates BOTH the ringSlot/colour defaulting below and the
        # idle-fade block -- see PendingState.psm1's comment on why: a
        # still-faded entry must never have ringSlot/color repopulated
        # ahead of `slot` (which has no defaulting block of its own),
        # which would desync the two fields collision avoidance depends
        # on being consistent.
        is_faded = liveness_at is not None and liveness_at < now - timedelta(hours=_known_idle_fade_hours)

        if not is_faded:
            if entry.get('ringSlot') is None:
                entry['ringSlot'] = resolve_ring_slot(str(entry.get('cwd') or ''))
            # A thread must ALWAYS have a visible colour. A missing, short,
            # or all-zero colour renders as black -- the thread silently
            # vanishes from the ring while still occupying an LED.
            col = entry.get('color') or []
            if len(col) < 3 or sum(col) == 0:
                entry['color'] = convert_from_hue_slot(
                    resolve_session_color_slot(str(entry.get('cwd') or '')))

        # Idle-fade: releases the ring slot, hue slot, and colour (all
        # three set to None) so resolve_ring_slot/resolve_session_color_slot
        # can hand them to another session, but the entry itself stays in
        # `known`. READ-TIME PROJECTION ONLY: get_pending_state never
        # calls save_pending_state itself, so this mutation lives purely
        # in the returned dict until some OTHER code path (e.g.
        # register_known_session) separately persists it.
        if is_faded and (entry.get('ringSlot') is not None or entry.get('slot') is not None or
                          entry.get('color') is not None):
            entry['ringSlot'] = None
            entry['slot'] = None
            entry['color'] = None

        # Retire on DELETION, not on silence. Claude Code writes a
        # transcript file per session, so its absence is the real "this
        # thread is gone" signal.
        transcript = entry.get('transcriptPath')
        if transcript:
            if not os.path.exists(transcript):
                del state['known'][sid]
            continue

        # Backstop only, for entries registered before a transcript path
        # was recorded. 24h, not 4. Fires strictly before the 48h hard
        # expiry above would for this same subset of entries.
        seen = _parse_datetime_or_none(entry.get('lastSeen'))
        if seen is not None and seen < now - timedelta(hours=_known_expiry_hours):
            del state['known'][sid]

    # Widened to `known` (was `sessions` only) -- the cursor legitimately
    # points at sessions that are merely known, not just pending ones.
    cursor = state.get('cursor')
    if cursor and cursor not in state['sessions'] and cursor not in state['known']:
        state['cursor'] = None
    state.setdefault('activeSession', None)
    state.setdefault('activeSince', None)
    # Deliberately NOT reset to None when it no longer matches a live
    # session (unlike cursor above) -- displayedSession's whole purpose is
    # to keep tracking what the physical ring is showing even after the
    # session it names has left `sessions`, so an idle check elsewhere can
    # notice the mismatch and turn the ring off. Nulling it here first
    # would make that orphan undetectable.
    state.setdefault('displayedSession', None)
    return state


# --------------------------------------------------------------- mutators

def set_pending_session(session_id, project, cwd, message, color, slot, ordinal):
    with with_pending_state_lock():
        state = get_pending_state()
        state['sessions'][session_id] = {
            'project': project,
            'cwd': cwd,
            'message': message,
            'color': list(color),
            'slot': slot,
            'ordinal': ordinal,
            'since': datetime.now(timezone.utc).isoformat(),
        }
        save_pending_state(state)


def clear_pending_session(session_id):
    with with_pending_state_lock():
        state = get_pending_state()
        state['sessions'].pop(session_id, None)
        if state.get('cursor') == session_id:
            state['cursor'] = None
        save_pending_state(state)


def set_pending_cursor(session_id):
    with with_pending_state_lock():
        state = get_pending_state()
        state['cursor'] = session_id
        save_pending_state(state)


def set_active_session(session_id):
    with with_pending_state_lock():
        state = get_pending_state()
        state['activeSession'] = session_id
        state['activeSince'] = datetime.now(timezone.utc).isoformat()
        save_pending_state(state)


def clear_active_session():
    with with_pending_state_lock():
        state = get_pending_state()
        state['activeSession'] = None
        state['activeSince'] = None
        save_pending_state(state)


def set_displayed_session(session_id):
    with with_pending_state_lock():
        state = get_pending_state()
        state['displayedSession'] = session_id
        save_pending_state(state)


def clear_displayed_session():
    with with_pending_state_lock():
        state = get_pending_state()
        state['displayedSession'] = None
        save_pending_state(state)


def register_known_session(session_id, project, cwd, window_pid=0, title='', activity='idle', transcript_path=''):
    if activity not in ('idle', 'working', 'attention'):
        raise ValueError(f"activity must be one of 'idle', 'working', 'attention', got {activity!r}")
    with with_pending_state_lock():
        state = get_pending_state()
        now = datetime.now(timezone.utc).isoformat()
        if session_id in state['known']:
            entry = state['known'][session_id]
            entry['lastSeen'] = now
            if window_pid > 0:
                entry['windowPid'] = window_pid
            # Backfill only. Claude Code generates its title a few turns
            # in, so a session registered on its very first hook has none
            # yet; once set, left alone so the spoken name cannot drift
            # mid-session.
            if title and not entry.get('title'):
                entry['title'] = title
            entry['activity'] = activity
            entry['activitySince'] = now
            # Reactivation: a hook firing on a session whose slot/colour
            # were cleared by idle-fade means it's back in use.
            if entry.get('ringSlot') is None or entry.get('color') is None:
                taken_slots = [e['slot'] for sid, e in state['known'].items()
                               if sid != session_id and e.get('slot') is not None]
                new_slot = resolve_session_color_slot(cwd, taken_slots=taken_slots)
                taken_ring = [e['ringSlot'] for sid, e in state['known'].items()
                              if sid != session_id and e.get('ringSlot') is not None]
                new_ring_slot = resolve_ring_slot(cwd, taken_slots=taken_ring)
                entry['slot'] = new_slot
                entry['color'] = convert_from_hue_slot(new_slot)
                entry['ringSlot'] = new_ring_slot
            if transcript_path:
                entry['transcriptPath'] = transcript_path
        else:
            # Nudge against every OTHER known session's slot -- two
            # sessions in the same folder must not hash to the same slot,
            # or they're indistinguishable on the ring.
            taken_slots = [e['slot'] for e in state['known'].values() if e.get('slot') is not None]
            slot = resolve_session_color_slot(cwd, taken_slots=taken_slots)
            ords = [e['ordinal'] for e in state['known'].values() if e.get('project') == project]
            taken_ring = [e['ringSlot'] for e in state['known'].values() if e.get('ringSlot') is not None]
            ring_slot = resolve_ring_slot(cwd, taken_slots=taken_ring)
            state['known'][session_id] = {
                'project': project,
                'cwd': cwd,
                'color': convert_from_hue_slot(slot),
                'slot': slot,
                'ordinal': get_session_ordinal(taken_ordinals=ords),
                'windowPid': window_pid,
                'title': title,
                'firstSeen': now,
                'lastSeen': now,
                'ringSlot': ring_slot,
                'activity': activity,
                'activitySince': now,
                'transcriptPath': transcript_path,
            }
        save_pending_state(state)


def register_pending_notification(session_id, project, cwd, message=''):
    """Compound mutator: the read, slot/ordinal derivation, and write all
    happen inside one lock acquisition, so two hooks firing at the same
    instant can't both read othersCount=0 and both resolve the same colour
    slot. Win32 named mutexes ARE reentrant for the owning thread (same
    property PendingState.psm1's own comment relies on for .NET's Mutex,
    which is a thin wrapper over this same primitive) -- inlined here
    anyway rather than nesting calls to set_pending_session/
    set_pending_cursor, purely to keep this one compound write to a single
    save_pending_state call instead of two separate ones."""
    with with_pending_state_lock():
        state = get_pending_state()
        others_count = len([sid for sid in state['sessions'] if sid != session_id])
        if session_id not in state['sessions']:
            taken = [e['slot'] for e in state['sessions'].values() if e.get('slot') is not None]
            slot = resolve_session_color_slot(cwd, taken_slots=taken)
            ords = [e['ordinal'] for e in state['sessions'].values() if e.get('project') == project]
            ordinal = get_session_ordinal(taken_ordinals=ords)
            rgb = convert_from_hue_slot(slot)
            state['sessions'][session_id] = {
                'project': project, 'cwd': cwd, 'message': message,
                'color': rgb, 'slot': slot, 'ordinal': ordinal,
                'since': datetime.now(timezone.utc).isoformat(),
            }
            if others_count == 0:
                state['cursor'] = session_id
            save_pending_state(state)
        return {'OthersCount': others_count}


def resolve_pending_session(session_id):
    """Compound mutator: clear the resolved session, mark it active, and
    count what's left, all as one locked critical section."""
    with with_pending_state_lock():
        state = get_pending_state()
        state['sessions'].pop(session_id, None)
        if state.get('cursor') == session_id:
            state['cursor'] = None
        state['activeSession'] = session_id
        state['activeSince'] = datetime.now(timezone.utc).isoformat()
        save_pending_state(state)
        return {'OthersCount': len(state['sessions'])}
