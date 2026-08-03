# claude-voice/scripts/window_typing.py
"""Ported from WindowTyping.psm1 (kept alongside during the migration).

set_window_foreground is a faithful port (ShowWindow SW_RESTORE +
SetForegroundWindow, same 300ms settle delay). Text injection is NOT a
faithful port: WindowTyping.psm1 used .NET's System.Windows.Forms.SendKeys,
which has no Python equivalent without a new heavy dependency (pythonnet).
This uses SendInput with KEYEVENTF_UNICODE instead -- a lower-level Win32
API that injects raw Unicode codepoints directly, which is a deliberate
IMPROVEMENT, not just a substitute: SendKeys interprets a small mini-
language (+^%~(){}[] are operators), which is exactly why
ConvertTo-SendKeysLiteral existed to escape user text before sending it.
KEYEVENTF_UNICODE has no such mini-language -- every codepoint is injected
literally -- so there is nothing to escape and no escaping function in
this file at all.
"""
import ctypes
import time
from ctypes import wintypes

_user32 = ctypes.WinDLL('user32', use_last_error=True)

_SW_RESTORE = 9

_INPUT_KEYBOARD = 1
_KEYEVENTF_UNICODE = 0x0004
_KEYEVENTF_KEYUP = 0x0002
_VK_RETURN = 0x0D


class _KEYBDINPUT(ctypes.Structure):
    _fields_ = [
        ('wVk', wintypes.WORD),
        ('wScan', wintypes.WORD),
        ('dwFlags', wintypes.DWORD),
        ('time', wintypes.DWORD),
        ('dwExtraInfo', ctypes.c_void_p),
    ]


class _INPUT_UNION(ctypes.Union):
    # Real Win32 INPUT's union must be sized for its LARGEST member
    # (MOUSEINPUT, 32 bytes on x64), not just KEYBDINPUT (24 bytes) --
    # SendInput validates cbSize against ITS OWN internal struct size and
    # rejects a caller-supplied smaller one with ERROR_INVALID_PARAMETER
    # even though every individual field we actually use is correctly laid
    # out. Confirmed empirically: sizing the union to fit only KEYBDINPUT
    # made every call fail (GetLastError 87); padding to the full 32 bytes
    # fixed it immediately, no other change needed.
    _fields_ = [('ki', _KEYBDINPUT), ('_pad', ctypes.c_byte * 32)]


class _INPUT(ctypes.Structure):
    _anonymous_ = ('_u',)
    _fields_ = [('type', wintypes.DWORD), ('_u', _INPUT_UNION)]


_user32.SendInput.restype = wintypes.UINT
_user32.SendInput.argtypes = [wintypes.UINT, ctypes.POINTER(_INPUT), ctypes.c_int]


def _send_input(*inputs):
    arr = (_INPUT * len(inputs))(*inputs)
    sent = _user32.SendInput(len(inputs), arr, ctypes.sizeof(_INPUT))
    if sent != len(inputs):
        raise ctypes.WinError(ctypes.get_last_error())


def _unicode_key_input(char, key_up=False):
    flags = _KEYEVENTF_UNICODE | (_KEYEVENTF_KEYUP if key_up else 0)
    ki = _KEYBDINPUT(wVk=0, wScan=ord(char), dwFlags=flags, time=0, dwExtraInfo=None)
    return _INPUT(type=_INPUT_KEYBOARD, _u=_INPUT_UNION(ki=ki))


def _vk_key_input(vk, key_up=False):
    flags = _KEYEVENTF_KEYUP if key_up else 0
    ki = _KEYBDINPUT(wVk=vk, wScan=0, dwFlags=flags, time=0, dwExtraInfo=None)
    return _INPUT(type=_INPUT_KEYBOARD, _u=_INPUT_UNION(ki=ki))


def set_window_foreground(window_handle):
    _user32.ShowWindow(window_handle, _SW_RESTORE)
    _user32.SetForegroundWindow(window_handle)
    time.sleep(0.3)


def send_text_to_foreground(text, submit_enter=False):
    """Injects text into whatever window currently has focus -- caller must
    have already called set_window_foreground (or otherwise focused a
    window) first, same division of responsibility as the PS original."""
    for char in text:
        _send_input(_unicode_key_input(char, key_up=False))
        _send_input(_unicode_key_input(char, key_up=True))
    if submit_enter:
        time.sleep(0.1)
        _send_input(_vk_key_input(_VK_RETURN, key_up=False))
        _send_input(_vk_key_input(_VK_RETURN, key_up=True))
