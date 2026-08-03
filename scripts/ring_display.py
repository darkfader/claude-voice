# claude-voice/scripts/ring_display.py
"""Shared "hand the ring to the oldest remaining pending session" logic.

Ported from RingDisplay.psm1 (kept alongside during the migration) -- see
that file's comments for the regression this guards (a resolved session
that wasn't the one on display used to silently discard the user's dial
selection)."""
import pending_state as ps
from ha_client import invoke_ha_led


def should_hand_off_ring(event, others_count, displayed_session, session_id):
    """event: 'notification' | 'stop' | 'clear'. Only a resolution ('stop'
    or 'clear') of the session CURRENTLY ON DISPLAY, with survivors
    remaining, hands the ring off -- see RingDisplay.psm1's comment for the
    discarded-dial-selection bug this specific check exists to prevent."""
    if event not in ('notification', 'stop', 'clear'):
        raise ValueError(f"event must be one of 'notification', 'stop', 'clear', got {event!r}")
    return event in ('stop', 'clear') and others_count > 0 and displayed_session == session_id


def set_remaining_led(connection):
    state = ps.get_pending_state()
    ids = sorted(state['sessions'].keys(), key=lambda sid: state['sessions'][sid].get('since') or '')
    if ids:
        next_id = ids[0]
        ps.set_pending_cursor(next_id)
        ps.set_displayed_session(next_id)
        # Solid full brightness, no flash: this is a hand-off to an
        # existing waiting session, not a new arrival.
        invoke_ha_led(connection, rgb=state['sessions'][next_id]['color'], brightness=255)
    else:
        ps.clear_displayed_session()
        invoke_ha_led(connection, off=True)
