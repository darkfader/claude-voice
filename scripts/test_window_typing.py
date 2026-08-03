# claude-voice/scripts/test_window_typing.py
"""window_typing.py has no equivalent of ConvertTo-SendKeysLiteral to unit
test -- there's no escaping mini-language in the SendInput/KEYEVENTF_UNICODE
approach it uses instead (see that file's top comment for why). What IS
worth guarding here is the ctypes struct layout, since a wrong size was the
actual bug caught during manual verification (SendInput failing with
ERROR_INVALID_PARAMETER until the union was padded to its real Win32 size)
-- a regression there would silently break all window typing without
raising anything Python-visible on its own."""
import ctypes

from window_typing import _INPUT, _KEYBDINPUT, send_text_to_foreground, set_window_foreground


def test_input_struct_is_the_real_win32_size():
    # 4 (type) + 4 (padding to 8-byte union alignment) + 32 (union, sized
    # for the largest member, MOUSEINPUT, not just KEYBDINPUT) = 40 on x64.
    assert ctypes.sizeof(_INPUT) == 40


def test_keybdinput_struct_matches_win32_layout():
    assert ctypes.sizeof(_KEYBDINPUT) == 24


def test_module_exports_the_expected_functions():
    assert callable(set_window_foreground)
    assert callable(send_text_to_foreground)
