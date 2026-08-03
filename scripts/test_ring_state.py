# claude-voice/scripts/test_ring_state.py
"""Mirrors RingState.Tests.ps1's cases exactly -- see ring_state.py's top comment."""
from datetime import datetime, timedelta

from ring_state import get_ring_state_string

NOW = datetime.fromisoformat('2026-07-28T12:00:00+02:00')


def mk(slot, rgb, activity, since_minutes_ago=1):
    since = (NOW - timedelta(minutes=since_minutes_ago)).isoformat()
    return {
        'ringSlot': slot,
        'color': rgb,
        'activity': activity,
        'activitySince': since,
        'lastSeen': since,
    }


def test_returns_empty_string_when_nothing_is_known():
    assert get_ring_state_string({}, now=NOW) == ''


def test_encodes_slot_colour_and_state():
    k = {'a': mk(3, [223, 255, 0], 'working')}
    assert get_ring_state_string(k, now=NOW) == '3,dfff00,w'


def test_pads_colour_components_to_two_hex_digits():
    k = {'a': mk(0, [0, 10, 255], 'idle')}
    assert get_ring_state_string(k, now=NOW) == '0,000aff,i'


def test_joins_several_threads_with_semicolons_ordered_by_slot():
    k = {
        'b': mk(7, [128, 255, 0], 'idle'),
        'a': mk(3, [223, 255, 0], 'working'),
    }
    assert get_ring_state_string(k, now=NOW) == '3,dfff00,w;7,80ff00,i'


def test_marks_the_cursor_session_as_selected():
    k = {'a': mk(3, [223, 255, 0], 'idle')}
    assert get_ring_state_string(k, cursor='a', now=NOW) == '3,dfff00,s'


def test_lets_attention_outrank_selected():
    k = {'a': mk(3, [223, 255, 0], 'attention')}
    assert get_ring_state_string(k, cursor='a', now=NOW) == '3,dfff00,a'


def test_marks_the_arriving_session_with_a():
    k = {'a': mk(3, [223, 255, 0], 'attention')}
    assert get_ring_state_string(k, arriving_session_id='a', now=NOW) == '3,dfff00,A'


def test_expires_working_to_idle_after_the_timeout():
    k = {'a': mk(3, [223, 255, 0], 'working', 31)}
    assert get_ring_state_string(k, now=NOW, working_expiry_minutes=30) == '3,dfff00,i'


def test_keeps_working_inside_the_timeout():
    k = {'a': mk(3, [223, 255, 0], 'working', 29)}
    assert get_ring_state_string(k, now=NOW, working_expiry_minutes=30) == '3,dfff00,w'


def test_does_not_expire_attention_only_working():
    k = {'a': mk(3, [223, 255, 0], 'attention', 120)}
    assert get_ring_state_string(k, now=NOW, working_expiry_minutes=30) == '3,dfff00,a'


def test_treats_an_unparseable_activity_since_as_already_expired():
    k = {'a': {
        'ringSlot': 3,
        'color': [223, 255, 0],
        'activity': 'working',
        'activitySince': 'not-a-date',
        'lastSeen': NOW.isoformat(),
    }}
    assert get_ring_state_string(k, now=NOW, working_expiry_minutes=30) == '3,dfff00,i'


def test_treats_a_missing_activity_since_as_already_expired():
    k = {'a': {
        'ringSlot': 3,
        'color': [223, 255, 0],
        'activity': 'working',
        'lastSeen': NOW.isoformat(),
    }}
    assert get_ring_state_string(k, now=NOW, working_expiry_minutes=30) == '3,dfff00,i'


def test_pads_a_short_colour_array_to_a_full_six_digit_hex_field():
    k = {'a': {
        'ringSlot': 3,
        'color': [255, 0],
        'activity': 'idle',
        'activitySince': NOW.isoformat(),
        'lastSeen': NOW.isoformat(),
    }}
    assert get_ring_state_string(k, now=NOW) == '3,ff0000,i'


def test_treats_a_missing_colour_as_black_rather_than_a_short_hex_field():
    k = {'a': {
        'ringSlot': 3,
        'activity': 'idle',
        'activitySince': NOW.isoformat(),
        'lastSeen': NOW.isoformat(),
    }}
    assert get_ring_state_string(k, now=NOW) == '3,000000,i'


def test_caps_at_twelve_threads_dropping_the_least_interesting():
    # 12 idle threads seen recently, plus one that needs attention but was
    # last touched longest ago of all thirteen. Only a cap that weighs
    # priority ahead of recency keeps it -- a naive recency-only cap would
    # drop it first, since it is the oldest entry here.
    k = {}
    for i in range(12):
        k[f'idle{i}'] = mk(i, [1, 2, 3], 'idle', i)
    k['urgent'] = mk(5, [255, 0, 0], 'attention', 1000)
    s = get_ring_state_string(k, now=NOW)
    assert len(s.split(';')) == 12
    assert 'ff0000,a' in s


def test_prefers_attention_then_selected_then_working_then_recent_idle():
    k = {
        'old': mk(0, [1, 1, 1], 'idle', 300),
        'new': mk(1, [2, 2, 2], 'idle', 1),
        'work': mk(2, [3, 3, 3], 'working'),
        'sel': mk(4, [5, 5, 5], 'idle'),
        'att': mk(3, [4, 4, 4], 'attention'),
    }
    # Cap to two, with a cursor on 'sel', so priority alone decides which
    # two survive: attention and selected must outrank working outright,
    # not just idle -- the 'selected' tier is only genuinely exercised here
    # because cursor is passed.
    s = get_ring_state_string(k, cursor='sel', now=NOW, max_threads=2)
    assert '040404,a' in s
    assert '050505,s' in s
    assert '030303' not in s
    assert '020202' not in s
    assert '010101' not in s


def test_stays_within_the_255_character_text_limit_at_full_capacity():
    k = {}
    for i in range(12):
        k[f's{i}'] = mk(i, [255, 255, 255], 'working')
    assert len(get_ring_state_string(k, now=NOW)) <= 255
