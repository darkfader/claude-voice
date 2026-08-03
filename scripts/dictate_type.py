# claude-voice/scripts/dictate_type.py
"""Ported from dictate-type.ps1 (kept alongside during the migration).
Called by dictation_service.py (both the hotkey and PE-button PTT paths)
with the transcribed text; types it into the tracked active session's
window, or whatever currently has OS focus if none is tracked."""
import argparse
import sys

import psutil

import pending_state as ps
from dictation_target import resolve_dictation_target
from window_focus import find_session_window, list_top_level_windows
from window_typing import send_text_to_foreground, set_window_foreground


def dictate_type(text):
    state = ps.get_pending_state()
    target = resolve_dictation_target(state)

    if target['mode'] == 'session':
        window = None
        window_pid = target.get('windowPid', 0)
        if window_pid > 0:
            try:
                psutil.Process(window_pid)
                windows = list_top_level_windows()
                handle = next((w['handle'] for w in windows if w['pid'] == window_pid), None)
                if handle:
                    window = {'pid': window_pid, 'handle': handle}
            except psutil.NoSuchProcess:
                pass
        if not window:
            window = find_session_window(target['project'], list_top_level_windows())
        if window:
            set_window_foreground(window['handle'])
        else:
            print(f"Active session '{target['sessionId']}' has no resolvable window; "
                  f"typing into whatever currently has focus.", file=sys.stderr)
    # else: no active session tracked; type into whatever currently has focus.

    send_text_to_foreground(text)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--text', required=True)
    args = parser.parse_args()
    dictate_type(args.text)


if __name__ == '__main__':
    main()
