# claude-voice/scripts/test_dictation_target.py
"""Mirrors DictationTarget.Tests.ps1's cases -- see dictation_target.py's top comment."""
from dictation_target import resolve_dictation_target


def test_targets_the_active_session_when_one_is_tracked():
    state = {'activeSession': 'sess-1', 'known': {'sess-1': {'project': 'HomeAssistant', 'windowPid': 4242}}}
    result = resolve_dictation_target(state)
    assert result['mode'] == 'session'
    assert result['sessionId'] == 'sess-1'
    assert result['project'] == 'HomeAssistant'
    assert result['windowPid'] == 4242


def test_falls_back_to_focused_when_no_active_session_tracked():
    state = {'activeSession': None, 'known': {}}
    assert resolve_dictation_target(state)['mode'] == 'focused'


def test_falls_back_to_focused_when_active_session_id_is_stale():
    state = {'activeSession': 'sess-gone', 'known': {}}
    assert resolve_dictation_target(state)['mode'] == 'focused'


def test_defaults_window_pid_to_0_when_known_entry_has_none_recorded():
    state = {'activeSession': 'sess-1', 'known': {'sess-1': {'project': 'HomeAssistant'}}}
    assert resolve_dictation_target(state)['windowPid'] == 0
