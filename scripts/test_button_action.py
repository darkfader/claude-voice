# claude-voice/scripts/test_button_action.py
"""Mirrors ButtonAction.Tests.ps1's cases exactly -- see button_action.py's
top comment. Kept in lockstep with the PowerShell tests during the
migration so behavioral drift between the two implementations shows up
immediately."""
from button_action import get_button_action, get_known_cycle_target


class TestGetButtonAction:
    def test_double_press_with_nothing_known_says_nothing_pending(self):
        a = get_button_action('double_press', {}, cursor=None, known_sessions={})
        assert a['Action'] == 'none'
        assert a['Speak'] == 'Nothing pending'

    def test_double_press_jumps_to_most_recently_finished_ignoring_cursor(self):
        known = {
            'work': {'firstSeen': '2026-07-26T10:00:00Z', 'activity': 'idle', 'activitySince': '2026-07-26T10:30:00Z'},
            'personal': {'firstSeen': '2026-07-26T11:00:00Z', 'activity': 'idle', 'activitySince': '2026-07-26T12:00:00Z'},
        }
        a = get_button_action('double_press', {}, cursor='work', known_sessions=known)
        assert a['Action'] == 'activate'
        assert a['SessionId'] == 'personal'

    def test_double_press_ignores_pending_state_entirely(self):
        known = {
            'browsing': {'firstSeen': '2026-07-26T10:00:00Z', 'activity': 'idle', 'activitySince': '2026-07-26T10:05:00Z'},
            'waiting': {'firstSeen': '2026-07-26T11:00:00Z', 'activity': 'idle', 'activitySince': '2026-07-26T11:05:00Z'},
        }
        pending = {'waiting': {'since': '2026-07-26T11:00:00Z'}}
        a = get_button_action('double_press', pending, cursor='browsing', known_sessions=known)
        assert a['Action'] == 'activate'
        assert a['SessionId'] == 'waiting'

    def test_double_press_with_one_known_session_activates_that_one(self):
        known = {'solo': {'firstSeen': '2026-07-26T10:00:00Z'}}
        a = get_button_action('double_press', {}, cursor=None, known_sessions=known)
        assert a['Action'] == 'activate'
        assert a['SessionId'] == 'solo'

    def test_double_press_skips_working_thread_even_if_only_recent_activity(self):
        known = {
            'working': {'firstSeen': '2026-07-26T11:00:00Z', 'activity': 'working', 'activitySince': '2026-07-26T12:00:00Z'},
            'idle': {'firstSeen': '2026-07-26T10:00:00Z', 'activity': 'idle', 'activitySince': '2026-07-26T10:05:00Z'},
        }
        a = get_button_action('double_press', {}, cursor=None, known_sessions=known)
        assert a['Action'] == 'activate'
        assert a['SessionId'] == 'idle'

    def test_double_press_with_only_working_threads_known_does_nothing(self):
        known = {'work': {'firstSeen': '2026-07-26T11:00:00Z', 'activity': 'working', 'activitySince': '2026-07-26T12:00:00Z'}}
        a = get_button_action('double_press', {}, cursor=None, known_sessions=known)
        assert a['Action'] == 'none'
        assert a['Speak'] == 'Nothing pending'

    def test_single_press_replies_continue_to_idle_session(self):
        pending = {'personal': {'since': '2026-07-26T10:00:00Z'}}
        known = {'personal': {'activity': 'idle'}}
        a = get_button_action('single_press', pending, cursor='personal', known_sessions=known)
        assert a['Action'] == 'reply'
        assert a['SessionId'] == 'personal'
        assert a['Text'] == 'continue'

    def test_single_press_replies_okay_when_activity_is_working(self):
        pending = {'personal': {'since': '2026-07-26T10:00:00Z'}}
        known = {'personal': {'activity': 'working'}}
        a = get_button_action('single_press', pending, cursor='personal', known_sessions=known)
        assert a['Action'] == 'reply'
        assert a['Text'] == 'okay'

    def test_single_press_replies_okay_when_session_not_in_known_sessions(self):
        pending = {'personal': {'since': '2026-07-26T10:00:00Z'}}
        a = get_button_action('single_press', pending, cursor='personal', known_sessions={})
        assert a['Action'] == 'reply'
        assert a['Text'] == 'okay'

    def test_single_press_on_attention_session_focuses_instead_of_replying(self):
        pending = {'personal': {'since': '2026-07-26T10:00:00Z'}}
        known = {'personal': {'activity': 'attention'}}
        a = get_button_action('single_press', pending, cursor='personal', known_sessions=known)
        assert a['Action'] == 'focus'
        assert a['SessionId'] == 'personal'

    def test_single_press_with_no_cursor_but_one_pending_resolves_it(self):
        pending = {'personal': {'since': '2026-07-26T10:00:00Z'}}
        known = {'personal': {'activity': 'idle'}}
        a = get_button_action('single_press', pending, cursor=None, known_sessions=known)
        assert a['Action'] == 'reply'
        assert a['SessionId'] == 'personal'

    def test_single_press_with_stale_cursor_and_multiple_pending_does_nothing(self):
        pending = {
            'personal': {'since': '2026-07-26T10:00:00Z'},
            'work': {'since': '2026-07-26T11:00:00Z'},
        }
        a = get_button_action('single_press', pending, cursor='someone-else')
        assert a['Action'] == 'none'

    def test_single_press_with_nothing_pending_does_nothing(self):
        a = get_button_action('single_press', {}, cursor=None)
        assert a['Action'] == 'none'
        assert a['Speak'] == 'Nothing pending'

    def test_long_press_with_selected_cursor_confirms_that_session(self):
        pending = {'personal': {'since': '2026-07-26T10:00:00Z'}}
        a = get_button_action('long_press', pending, cursor='personal')
        assert a['Action'] == 'focus'
        assert a['SessionId'] == 'personal'

    def test_long_press_with_stale_cursor_and_multiple_pending_does_nothing(self):
        pending = {
            'personal': {'since': '2026-07-26T10:00:00Z'},
            'work': {'since': '2026-07-26T11:00:00Z'},
        }
        a = get_button_action('long_press', pending, cursor='someone-else')
        assert a['Action'] == 'none'

    def test_long_press_with_no_cursor_but_one_pending_confirms_that_session(self):
        pending = {'personal': {'since': '2026-07-26T10:00:00Z'}}
        a = get_button_action('long_press', pending, cursor=None)
        assert a['Action'] == 'focus'
        assert a['SessionId'] == 'personal'

    def test_long_press_with_no_cursor_and_two_pending_still_does_nothing(self):
        pending = {
            'personal': {'since': '2026-07-26T10:00:00Z'},
            'work': {'since': '2026-07-26T11:00:00Z'},
        }
        a = get_button_action('long_press', pending, cursor=None)
        assert a['Action'] == 'none'

    def test_triple_press_dismisses_the_selected_session(self):
        pending = {'personal': {'since': '2026-07-26T10:00:00Z'}}
        a = get_button_action('triple_press', pending, cursor='personal')
        assert a['Action'] == 'dismiss'
        assert a['SessionId'] == 'personal'

    def test_easter_egg_press_always_does_nothing(self):
        pending = {'personal': {'since': '2026-07-26T10:00:00Z'}}
        a = get_button_action('easter_egg_press', pending, cursor='personal')
        assert a['Action'] == 'none'


class TestGetKnownCycleTarget:
    known = {
        'b': {'firstSeen': '2026-07-27T10:01:00.0000000+02:00'},
        'a': {'firstSeen': '2026-07-27T10:00:00.0000000+02:00'},
        'c': {'firstSeen': '2026-07-27T10:02:00.0000000+02:00'},
    }

    def test_returns_none_when_nothing_is_known(self):
        assert get_known_cycle_target({}, None, 'cw') is None
        assert get_known_cycle_target({}, None, 'ccw') is None

    def test_enters_at_same_thread_regardless_of_direction_when_nothing_has_asked(self):
        assert get_known_cycle_target(self.known, None, 'cw') == 'a'
        assert get_known_cycle_target(self.known, None, 'ccw') == 'a'

    def test_advances_in_firstseen_order_clockwise(self):
        assert get_known_cycle_target(self.known, 'a', 'cw') == 'b'
        assert get_known_cycle_target(self.known, 'b', 'cw') == 'c'

    def test_retreats_in_firstseen_order_anticlockwise(self):
        assert get_known_cycle_target(self.known, 'c', 'ccw') == 'b'
        assert get_known_cycle_target(self.known, 'b', 'ccw') == 'a'

    def test_wraps_forward_past_newest_to_oldest(self):
        assert get_known_cycle_target(self.known, 'c', 'cw') == 'a'

    def test_wraps_backward_past_oldest_to_newest(self):
        assert get_known_cycle_target(self.known, 'a', 'ccw') == 'c'

    def test_treats_unrecognised_cursor_as_no_cursor(self):
        assert get_known_cycle_target(self.known, 'gone', 'cw') == 'a'
        assert get_known_cycle_target(self.known, 'gone', 'ccw') == 'a'

    def test_returns_only_session_regardless_of_direction(self):
        one = {'solo': {'firstSeen': '2026-07-27T10:00:00.0000000+02:00'}}
        assert get_known_cycle_target(one, 'solo', 'cw') == 'solo'
        assert get_known_cycle_target(one, 'solo', 'ccw') == 'solo'


class TestGetKnownCycleTargetEntryPoint:
    # b finished most recently; c is still working; a finished a while ago.
    by_attention = {
        'a': {'firstSeen': '2026-07-29T10:00:00Z', 'activity': 'idle', 'activitySince': '2026-07-29T10:30:00Z'},
        'b': {'firstSeen': '2026-07-29T10:01:00Z', 'activity': 'idle', 'activitySince': '2026-07-29T11:00:00Z'},
        'c': {'firstSeen': '2026-07-29T10:02:00Z', 'activity': 'working', 'activitySince': '2026-07-29T11:59:00Z'},
    }

    def test_enters_on_whatever_last_wanted_you_not_end_of_list(self):
        assert get_known_cycle_target(self.by_attention, None, 'cw') == 'b'
        assert get_known_cycle_target(self.by_attention, None, 'ccw') == 'b'

    def test_prefers_attention_thread_over_older_finished_one(self):
        k = {
            'fin': {'firstSeen': '2026-07-29T10:00:00Z', 'activity': 'idle', 'activitySince': '2026-07-29T11:00:00Z'},
            'ask': {'firstSeen': '2026-07-29T10:01:00Z', 'activity': 'attention', 'activitySince': '2026-07-29T11:30:00Z'},
        }
        assert get_known_cycle_target(k, None, 'cw') == 'ask'

    def test_finds_nothing_to_enter_on_when_every_known_thread_is_working(self):
        k = {
            'old': {'firstSeen': '2026-07-29T10:00:00Z', 'activity': 'working', 'activitySince': '2026-07-29T10:10:00Z'},
            'new': {'firstSeen': '2026-07-29T10:01:00Z', 'activity': 'working', 'activitySince': '2026-07-29T10:20:00Z'},
        }
        assert get_known_cycle_target(k, None, 'cw') is None

    def test_still_cycles_in_stable_firstseen_order_skipping_working_threads(self):
        assert get_known_cycle_target(self.by_attention, 'a', 'cw') == 'b'
        assert get_known_cycle_target(self.by_attention, 'b', 'cw') == 'a'

    def test_never_lands_on_a_working_thread_when_cycling(self):
        assert get_known_cycle_target(self.by_attention, 'c', 'cw') == 'b'

    def test_returns_none_when_every_known_thread_is_working(self):
        all_working = {
            'old': {'firstSeen': '2026-07-29T10:00:00Z', 'activity': 'working', 'activitySince': '2026-07-29T10:10:00Z'},
            'new': {'firstSeen': '2026-07-29T10:01:00Z', 'activity': 'working', 'activitySince': '2026-07-29T10:20:00Z'},
        }
        assert get_known_cycle_target(all_working, None, 'cw') is None
