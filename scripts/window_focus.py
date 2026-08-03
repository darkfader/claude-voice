# claude-voice/scripts/window_focus.py
"""Two ways to find a session's window, in preference order:

1. get_owning_window_pid -- the session's OWN window, resolved by walking
   up the process tree from the hook that the session itself ran. Exact,
   works for several sessions in one folder, works across separate VS Code
   instances. This is the one that should normally be used.

2. find_session_window -- matches the project name against window TITLES.
   Kept only as a fallback for sessions registered before a window pid was
   recorded, or whose recorded window has since closed. Unreliable: VS
   Code titles the window after the workspace, which frequently is not the
   folder name the project is derived from.

Ported from WindowFocus.psm1 (kept alongside during the migration) -- see
that file's comments for the reasoning behind each rule. Uses psutil
(already a dependency of the dictation service) for process-tree walking
instead of Get-CimInstance Win32_Process, and ctypes/user32 for the
window-enumeration half, which has no equivalent in psutil.
"""
import ctypes
import fnmatch
import os
from ctypes import wintypes

import psutil

_user32 = ctypes.WinDLL('user32', use_last_error=True)


def _glob_escape(s):
    """fnmatch has no stdlib escape() (unlike re.escape) -- bracket each of
    its metacharacters so it matches literally, same purpose
    WildcardPattern::Escape serves for -like in the PS original (a project
    named e.g. "my[test]proj" must not have [test] read as a character
    class). Single-pass character scan, NOT sequential str.replace calls --
    replacing '[' with '[[]' first would introduce new ']' characters that
    a later ']' -> '[]]' pass would then corrupt a second time."""
    return ''.join(f'[{c}]' if c in '*?[]' else c for c in s)


def get_project_window_pattern(project):
    return f'*{_glob_escape(project)}*Visual Studio Code*'


def find_session_window(project, windows):
    """windows: iterable of dicts with at least 'title' and 'handle' keys
    (handle falsy/None = no window, same as MainWindowHandle == IntPtr.Zero
    excluding a process from consideration). Returns the first match, or
    None. Takes an explicit windows list (rather than calling
    list_top_level_windows() itself) so the matching RULE stays testable
    without real windows, same seam Find-SessionWindow's -Processes
    parameter provides."""
    pattern = get_project_window_pattern(project)
    for w in windows:
        if w.get('handle') and fnmatch.fnmatchcase(w.get('title') or '', pattern):
            return w
    return None


def select_owning_window_pid(chain):
    """Pick the session's window from an ordered ancestry chain (nearest-
    ancestor-first, each entry {'pid', 'name', 'has_window'}).

    The rule is "first ancestor that owns a window". Walking outward from
    the hook, that is the terminal or editor the session is running inside
    -- VS Code, Windows Terminal, whatever. Anything further out
    (explorer.exe, the shell) also owns a window, which is why the FIRST
    match matters and a last-match or "prefer Code.exe" rule would be
    wrong: a session running in Windows Terminal has no Code.exe ancestor
    at all, and explorer.exe is an ancestor of practically everything."""
    for link in chain:
        if link.get('has_window'):
            return link.get('pid')
    return None


def _enum_top_level_windows():
    """pid -> (hwnd, title) for the first visible, titled top-level window
    found per pid (Z-order first match) -- close enough to .NET's
    Process.MainWindowHandle heuristic for this use case."""
    result = {}
    WNDENUMPROC = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)

    def callback(hwnd, _lparam):
        if not _user32.IsWindowVisible(hwnd):
            return True
        length = _user32.GetWindowTextLengthW(hwnd)
        if length == 0:
            return True
        pid = wintypes.DWORD()
        _user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
        if pid.value in result:
            return True
        buf = ctypes.create_unicode_buffer(length + 1)
        _user32.GetWindowTextW(hwnd, buf, length + 1)
        result[pid.value] = (hwnd, buf.value)
        return True

    _user32.EnumWindows(WNDENUMPROC(callback), 0)
    return result


def list_top_level_windows():
    """Live enumeration, for production callers -- find_session_window
    itself stays pure/testable and does not call this directly."""
    return [{'pid': pid, 'handle': hwnd, 'title': title}
            for pid, (hwnd, title) in _enum_top_level_windows().items()]


def get_process_ancestry(start_pid, max_depth=12):
    """Ordered ancestry of a process, nearest first, for
    select_owning_window_pid."""
    windows_by_pid = _enum_top_level_windows()
    chain = []
    current_pid = start_pid
    for _ in range(max_depth):
        try:
            proc = psutil.Process(current_pid)
            name = proc.name()
        except psutil.Error:
            break
        chain.append({'pid': current_pid, 'name': name, 'has_window': current_pid in windows_by_pid})
        try:
            parent_pid = proc.ppid()
        except psutil.Error:
            break
        if not parent_pid:
            break
        current_pid = parent_pid
    return chain


def get_owning_window_pid(start_pid=None):
    """The pid of the window this process is running inside, or None."""
    # Skip self: the hook process itself never owns a window, and
    # including it costs nothing, but starting the walk at the parent
    # would break the (testable) invariant that the chain begins where it
    # was asked to.
    if start_pid is None:
        start_pid = os.getpid()
    return select_owning_window_pid(get_process_ancestry(start_pid))
