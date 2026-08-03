# claude-voice/scripts/confirm_session.py
"""Ported from confirm-session.ps1 (kept alongside during the migration).

Exposes confirm_session() for direct in-process use (ha_bridge.py) and a
CLI entry point with the same parameter surface as the original, for
anything that still shells out to it (e.g. a Stream Deck button)."""
import argparse
import sys

import psutil

import pending_state as ps
from window_focus import find_session_window, get_project_window_pattern, list_top_level_windows
from window_typing import send_text_to_foreground, set_window_foreground


def confirm_session(session_id, project, text='continue', focus_only=False, keep_pending=False, window_pid=0):
    """Returns True on success, False if no window was found for the session."""
    target = None
    if window_pid > 0:
        try:
            candidate = psutil.Process(window_pid)
            windows = list_top_level_windows()
            handle = next((w['handle'] for w in windows if w['pid'] == window_pid), None)
            if handle:
                target = {'pid': window_pid, 'handle': handle}
        except psutil.NoSuchProcess:
            pass

    if not target:
        # Fallback only -- see window_focus.py for why this is unreliable.
        target = find_session_window(project, list_top_level_windows())

    if not target:
        print(f"No window found for session '{session_id}' (windowPid={window_pid}, "
              f"title pattern: {get_project_window_pattern(project)})", file=sys.stderr)
        return False

    set_window_foreground(target['handle'])

    if not focus_only:
        send_text_to_foreground(text, submit_enter=True)

    if not keep_pending:
        ps.clear_pending_session(session_id)
    return True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--session-id', required=True)
    parser.add_argument('--project', required=True)
    parser.add_argument('--text', default='continue')
    parser.add_argument('--focus-only', action='store_true')
    parser.add_argument('--keep-pending', action='store_true')
    parser.add_argument('--window-pid', type=int, default=0)
    args = parser.parse_args()

    ok = confirm_session(args.session_id, args.project, text=args.text, focus_only=args.focus_only,
                          keep_pending=args.keep_pending, window_pid=args.window_pid)
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
