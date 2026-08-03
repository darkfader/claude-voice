# claude-voice/scripts/test_ambient_state.py
"""Mirrors AmbientState.Tests.ps1's cases -- see ambient_state.py's top comment."""
from datetime import datetime

from ambient_state import is_ambient_idle_expired


def test_false_when_a_session_is_pending_no_matter_how_stale_active_since_is():
    state = {
        'sessions': {'s1': {'since': '2026-07-26T10:00:00Z'}},
        'activeSession': 'old',
        'activeSince': '2020-01-01T00:00:00+00:00',
    }
    now = datetime.fromisoformat('2026-07-26T12:00:00+00:00')
    assert is_ambient_idle_expired(state, now, 10) is False


def test_false_when_active_session_and_active_since_are_absent():
    state = {'sessions': {}, 'activeSession': None, 'activeSince': None}
    assert is_ambient_idle_expired(state, datetime.now(), 10) is False


def test_false_when_active_since_does_not_parse_as_a_date():
    state = {'sessions': {}, 'activeSession': 's1', 'activeSince': 'not-a-date'}
    assert is_ambient_idle_expired(state, datetime.now(), 10) is False


def test_true_only_when_nothing_pending_and_active_since_is_at_least_idle_minutes_old():
    state = {
        'sessions': {},
        'activeSession': 's1',
        'activeSince': '2026-07-26T10:00:00+00:00',
    }
    just_under = datetime.fromisoformat('2026-07-26T10:09:59+00:00')
    at_threshold = datetime.fromisoformat('2026-07-26T10:10:00+00:00')
    well_past = datetime.fromisoformat('2026-07-26T11:00:00+00:00')
    assert is_ambient_idle_expired(state, just_under, 10) is False, 'just under the threshold must not expire yet'
    assert is_ambient_idle_expired(state, at_threshold, 10) is True, 'exactly at the threshold must expire'
    assert is_ambient_idle_expired(state, well_past, 10) is True, 'well past the threshold must expire'
