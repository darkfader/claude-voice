# claude-voice/scripts/button_action.py
"""Pure decision logic for the Voice PE center button and dial.

First module in the PowerShell -> Python migration. Ported from
ButtonAction.psm1 (kept alongside this during the migration, not yet wired
into ha-bridge.ps1's live event loop) -- behavior must match it exactly;
see that file's comments for the reasoning behind each rule, preserved here
rather than re-derived. No I/O: given the same session maps and cursor,
returns the same result every time.
"""
from datetime import datetime, timezone

_VALID_EVENT_TYPES = ('single_press', 'double_press', 'long_press', 'triple_press', 'easter_egg_press')
_VALID_DIRECTIONS = ('cw', 'ccw')


def _parse_datetime(value):
    """Best-effort ISO8601 parse; datetime.min (UTC) on anything unparseable
    -- same fallback ButtonAction.psm1's [datetime]::TryParse uses, so an
    entry with a missing/malformed timestamp loses every ranking tiebreak
    rather than raising."""
    if value:
        try:
            return datetime.fromisoformat(str(value).replace('Z', '+00:00'))
        except ValueError:
            pass
    return datetime.min.replace(tzinfo=timezone.utc)


def get_known_cycle_target(known_sessions, cursor, direction):
    """Resolve the dial's next stop. known_sessions: {id: {activity, firstSeen, activitySince, ...}}.
    direction: 'cw' or 'ccw'. Returns a session id, or None if nothing is known."""
    if direction not in _VALID_DIRECTIONS:
        raise ValueError(f'direction must be one of {_VALID_DIRECTIONS}, got {direction!r}')

    # Working (mid-turn) threads are not selectable by the dial -- PTT (hold
    # the center button and talk) is the way to reach one directly now, so
    # the dial's job narrows to "what's waiting for you or has finished."
    #
    # Stable firstSeen order, NOT most-recently-used: on a physical dial, MRU
    # would reorder the list under your fingers, so the same rotation would
    # stop landing in the same place.
    names = sorted(
        (sid for sid, entry in known_sessions.items() if entry.get('activity') != 'working'),
        key=lambda sid: str(known_sessions[sid].get('firstSeen') or ''),
    )
    if not names:
        return None

    if cursor in names:
        idx = names.index(cursor)
        step = 1 if direction == 'cw' else -1
        return names[(idx + step) % len(names)]

    # No cursor, one naming a session that has since expired, or one that
    # has since started working (and so dropped out of `names` above).
    #
    # Enter at whatever LAST WANTED YOU, not the end of the list -- the
    # overwhelmingly common reason to reach for the dial is that something
    # just finished or asked a question. Among the (already working-
    # excluded) candidates, the most recent activitySince wins.
    return max(names, key=lambda sid: _parse_datetime(known_sessions[sid].get('activitySince')))


def get_button_action(event_type, pending_sessions, cursor=None, known_sessions=None):
    """pending_sessions: {id: {since, ...}}. known_sessions: same shape as
    get_known_cycle_target's, only double_press/single_press consult it.
    Returns {'Action', 'SessionId', 'Speak', ['Text']}."""
    if event_type not in _VALID_EVENT_TYPES:
        raise ValueError(f'event_type must be one of {_VALID_EVENT_TYPES}, got {event_type!r}')
    known_sessions = known_sessions or {}

    if event_type == 'easter_egg_press':
        return {'Action': 'none', 'SessionId': None, 'Speak': None}

    # double_press resolves against KNOWN sessions, not pending ones, and so
    # must be handled before the "nothing pending" bail-out below.
    #
    # No longer resolves against the dial's current selection ("take me to
    # what's selected") -- it jumps straight to whichever known thread most
    # recently finished or asked for you, ignoring cursor entirely. Reuses
    # get_known_cycle_target's own entry-point ranking (working threads
    # excluded, most recent activitySince wins) by asking it to resolve with
    # no cursor, rather than duplicating that ranking here.
    if event_type == 'double_press':
        target = get_known_cycle_target(known_sessions, None, 'cw')
        if not target:
            return {'Action': 'none', 'SessionId': None, 'Speak': 'Nothing pending'}
        return {'Action': 'activate', 'SessionId': target, 'Speak': None}

    names = sorted(pending_sessions.keys(), key=lambda sid: str(pending_sessions[sid].get('since') or ''))
    if not names:
        return {'Action': 'none', 'SessionId': None, 'Speak': 'Nothing pending'}

    effective_cursor = cursor
    if (not effective_cursor or effective_cursor not in names) and len(names) == 1:
        effective_cursor = names[0]

    if event_type == 'single_press':
        # A quick tap: reply on the session's behalf without switching focus
        # to it -- firmware fires this instead of starting HA's own Assist
        # pipeline (see custom-voice-pe.yaml's on_multi_click redefinition).
        if not effective_cursor or effective_cursor not in names:
            return {'Action': 'none', 'SessionId': None, 'Speak': 'Nothing selected'}
        activity = known_sessions.get(effective_cursor, {}).get('activity')
        if activity == 'attention':
            # 'attention' is overwhelmingly a permission prompt. A blind
            # auto-typed "yes" from across the room would approve whatever
            # it's asking sight-unseen -- the exact thing long_press's own
            # comment below already refuses to do. Fall back to focus
            # instead, so a human actually sees the prompt before answering
            # it themselves.
            return {'Action': 'focus', 'SessionId': effective_cursor, 'Speak': None}
        text = 'continue' if activity == 'idle' else 'okay'
        return {'Action': 'reply', 'SessionId': effective_cursor, 'Speak': None, 'Text': text}

    if event_type == 'long_press':
        if not effective_cursor or effective_cursor not in names:
            return {'Action': 'none', 'SessionId': None, 'Speak': 'Nothing selected'}
        # 'focus', not 'confirm': long-press takes you TO the session and
        # clears the light -- it deliberately does not answer for you. The
        # Notification hook fires mainly on permission prompts, so replying
        # unseen from across the room is the one thing this shouldn't do.
        return {'Action': 'focus', 'SessionId': effective_cursor, 'Speak': None}

    if event_type == 'triple_press':
        if not effective_cursor or effective_cursor not in names:
            return {'Action': 'none', 'SessionId': None, 'Speak': 'Nothing selected'}
        return {'Action': 'dismiss', 'SessionId': effective_cursor, 'Speak': None}
