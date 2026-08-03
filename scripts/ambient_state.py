# claude-voice/scripts/ambient_state.py
"""Pure decision logic for the ambient (dim) indicator's idle fade. Ported
from AmbientState.psm1 (kept alongside during the migration) -- see that
file's comments for the PowerShell-specific bug ([ref] cannot bind to a
$null-valued out-parameter) this extraction fixed. That bug class doesn't
exist in Python, but the behavior it produces (an unparseable/missing
activeSince must return False, not raise) is still worth guarding, so the
test suite keeps the equivalent case."""
from datetime import datetime


def is_ambient_idle_expired(state, now, idle_minutes):
    # Named is_* rather than a literal Test-AmbientIdleExpired ->
    # test_ambient_idle_expired translation: pytest auto-collects any
    # test_*-named function it can import into a test module's namespace as
    # a test case in its own right, which would make this get invoked with
    # zero arguments by the test runner itself.
    # Pending outranks active: a session waiting for input must never be
    # faded out from under the human because an unrelated ambient timer
    # expired.
    if state.get('sessions') and len(state['sessions']) > 0:
        return False
    if not state.get('activeSession') or not state.get('activeSince'):
        return False

    try:
        since = datetime.fromisoformat(str(state['activeSince']).replace('Z', '+00:00'))
    except ValueError:
        return False

    return (now - since).total_seconds() / 60.0 >= idle_minutes
