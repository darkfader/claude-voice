# claude-voice/scripts/test_window_focus.py
"""Mirrors WindowFocus.Tests.ps1's cases -- see window_focus.py's top comment."""
import os

from window_focus import (
    find_session_window,
    get_owning_window_pid,
    get_project_window_pattern,
    select_owning_window_pid,
)


def test_builds_a_vscode_title_pattern_from_the_project_name():
    assert get_project_window_pattern('HomeAssistant') == '*HomeAssistant*Visual Studio Code*'


def test_finds_the_window_whose_title_contains_the_project_name():
    windows = [
        {'title': 'a.ps1 - HomeAssistant - Visual Studio Code', 'handle': 1, 'pid': 100},
        {'title': 'b.ts - other-repo - Visual Studio Code', 'handle': 2, 'pid': 200},
    ]
    assert find_session_window('HomeAssistant', windows)['pid'] == 100
    assert find_session_window('other-repo', windows)['pid'] == 200


def test_ignores_windows_with_no_handle():
    windows = [{'title': 'HomeAssistant - Visual Studio Code', 'handle': None, 'pid': 1}]
    assert find_session_window('HomeAssistant', windows) is None


def test_returns_none_when_nothing_matches():
    windows = [{'title': 'unrelated', 'handle': 1, 'pid': 1}]
    assert find_session_window('HomeAssistant', windows) is None


def test_does_not_match_a_non_vscode_window_containing_the_project_name():
    windows = [{'title': 'HomeAssistant - Notepad', 'handle': 1, 'pid': 1}]
    assert find_session_window('HomeAssistant', windows) is None


def test_matches_a_project_whose_name_contains_wildcard_metacharacters():
    windows = [{'title': 'x.ps1 - my[test]proj - Visual Studio Code', 'handle': 1, 'pid': 42}]
    assert find_session_window('my[test]proj', windows)['pid'] == 42


def test_select_owning_window_pid_returns_the_nearest_ancestor_that_owns_a_window():
    chain = [
        {'pid': 100, 'name': 'pwsh.exe', 'has_window': False},
        {'pid': 200, 'name': 'claude.exe', 'has_window': False},
        {'pid': 300, 'name': 'Code.exe', 'has_window': False},
        {'pid': 400, 'name': 'Code.exe', 'has_window': True},
        {'pid': 500, 'name': 'explorer.exe', 'has_window': True},
    ]
    assert select_owning_window_pid(chain) == 400


def test_does_not_skip_past_a_windowed_terminal_to_reach_explorer():
    # A session in Windows Terminal has no Code.exe ancestor at all, and
    # explorer.exe is an ancestor of nearly everything -- a "prefer
    # Code.exe" or last-match rule would focus the desktop instead.
    chain = [
        {'pid': 100, 'name': 'pwsh.exe', 'has_window': False},
        {'pid': 200, 'name': 'WindowsTerminal.exe', 'has_window': True},
        {'pid': 300, 'name': 'explorer.exe', 'has_window': True},
    ]
    assert select_owning_window_pid(chain) == 200


def test_select_owning_window_pid_returns_none_when_no_ancestor_owns_a_window():
    chain = [
        {'pid': 100, 'name': 'pwsh.exe', 'has_window': False},
        {'pid': 200, 'name': 'claude.exe', 'has_window': False},
    ]
    assert select_owning_window_pid(chain) is None


def test_select_owning_window_pid_returns_none_for_an_empty_chain():
    assert select_owning_window_pid([]) is None


def test_get_owning_window_pid_finds_a_real_windowed_ancestor_of_this_test_process():
    # Integration check: the walk must work against real process data, not
    # just the pure selection rule. pytest runs under a console or editor,
    # so some ancestor owns a window.
    found = get_owning_window_pid(os.getpid())
    assert found is not None
