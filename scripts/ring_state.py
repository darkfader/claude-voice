# claude-voice/scripts/ring_state.py
"""Turns the known-session map into the compact string the firmware renders.

Ported from RingState.psm1 (kept alongside during the migration) -- see
that file's comments for the reasoning behind each rule. Pure: every
display decision worth testing (precedence, the cap, the working expiry,
colour formatting) lives here and is testable with no device attached. The
firmware renders exactly what it is told and makes no decisions of its own.

Encoding, one group per thread, semicolons between:
  <ringSlot>,<rrggbb>,<state>     e.g.  3,dfff00,w;7,80ff00,i
States: i idle, w working, s selected, a attention, A arriving.
"""
from datetime import datetime, timedelta, timezone

# Lower number sorts first, i.e. survives the cap. Plain dict is fine in
# Python (unlike the PowerShell original, which needed a case-sensitive
# Dictionary[string,int] specifically because PowerShell hashtables compare
# string keys case-insensitively by default and 'A'/'a' would collide).
_STATE_PRIORITY = {'A': 0, 'a': 1, 's': 2, 'w': 3, 'i': 4}


def to_ring_hex(rgb):
    """Always emits exactly six hex digits: the firmware parser depends on
    the fixed rrggbb width and drops any group whose hex field is a
    different length, so a short/absent colour would otherwise silently
    vanish from the ring instead of failing loudly. Pads missing trailing
    components with 0 -- a wrong/dim colour beats a missing thread."""
    rgb = list(rgb or [])
    r = rgb[0] if len(rgb) >= 1 else 0
    g = rgb[1] if len(rgb) >= 2 else 0
    b = rgb[2] if len(rgb) >= 3 else 0
    return f'{r:02x}{g:02x}{b:02x}'


def _parse_datetime_or_none(value):
    if value:
        try:
            return datetime.fromisoformat(str(value).replace('Z', '+00:00'))
        except ValueError:
            pass
    return None


def get_ring_state_string(known_sessions, cursor=None, arriving_session_id=None, now=None,
                           working_expiry_minutes=30, max_threads=12):
    if now is None:
        now = datetime.now(timezone.utc)
    if not known_sessions:
        return ''

    rows = []
    for sid, e in known_sessions.items():
        if e.get('ringSlot') is None:
            continue

        activity = e.get('activity') or 'idle'

        # A crashed terminal never fires Stop. Without this the dot orbits
        # forever. Deliberately applies to `working` only -- something
        # waiting on you stays waiting however long you ignore it.
        if activity == 'working':
            since = _parse_datetime_or_none(e.get('activitySince'))
            if since is not None:
                if since < now - timedelta(minutes=working_expiry_minutes):
                    activity = 'idle'
            else:
                # Fail safe: an unparseable or missing activitySince must
                # not read as "never expires". A thread we cannot date is a
                # thread we cannot claim is still working -- treat it the
                # same as the crashed-terminal case this expiry exists to
                # catch, i.e. already expired.
                activity = 'idle'

        # Precedence: attention > selected > working > idle. Resolved here,
        # never in firmware, so it stays unit-testable off-device.
        if activity == 'attention':
            state = 'a'
        elif activity == 'working':
            state = 'w'
        else:
            state = 'i'
        if state != 'a' and cursor and sid == cursor:
            state = 's'
        if arriving_session_id and sid == arriving_session_id:
            state = 'A'

        seen = _parse_datetime_or_none(e.get('lastSeen')) or datetime.min.replace(tzinfo=timezone.utc)

        rows.append({
            'slot': int(e['ringSlot']),
            'hex': to_ring_hex(e.get('color')),
            'state': state,
            'priority': _STATE_PRIORITY[state],
            'last_seen': seen,
        })

    if not rows:
        return ''

    # Cap by interest (priority ascending, then most-recently-seen first --
    # two stable sorts, secondary key applied first, same trick as the
    # slot-order redraw below), then draw in slot order so the string reads
    # around the ring rather than in priority order.
    by_interest = sorted(rows, key=lambda r: r['last_seen'], reverse=True)
    by_interest.sort(key=lambda r: r['priority'])
    kept = by_interest[:max_threads]
    kept.sort(key=lambda r: r['slot'])

    return ';'.join(f"{r['slot']},{r['hex']},{r['state']}" for r in kept)
