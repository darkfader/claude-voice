# claude-voice/scripts/dictation/overlay_indicator.py
"""Transparent, click-through, always-on-top mic-status dot for Windows.

Sits top-center of the screen, hidden until dictation is actually in
progress -- listening (recording audio, blinking green) or processing
(faster-whisper transcribing, solid amber) -- then hides again once
dispatch is done. Mirrors this repo's existing state-feedback conventions
(play-dictation-tone.ps1's start/stop/error tones) but visually. Colours
match the physical ring's PTT indication (see overlay.yaml's
claude_ptt_hold_check) so the two read as the same signal.

Tk is not thread-safe: widgets may only be touched from the thread running
mainloop(). Both the hotkey and UDP paths call into this from their own
threads, so state changes go through a thread-safe queue that the Tk thread
drains via root.after() polling, rather than touching the canvas directly.
"""
import queue
import threading
import tkinter as tk

_STATE_COLORS = {
    'listening': '#34c759',   # green while capturing audio -- matches the ring
    'processing': '#ffcc00',  # amber while whisper transcribes
}

_SIZE = 20
_TOP_MARGIN = 8
_BLINK_MS = 400
_POLL_MS = 50


class OverlayIndicator:
    def __init__(self):
        self._queue = queue.Queue()
        self._ready = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()
        self._ready.wait(timeout=5)

    def show(self, state):
        self._queue.put(('show', state))

    def hide(self):
        self._queue.put(('hide', None))

    def _run(self):
        root = tk.Tk()
        root.overrideredirect(True)
        root.attributes('-topmost', True)
        # -transparentcolor (Windows-only Tk attribute) makes every pixel
        # painted this colour see-through, so only the dot itself is visible
        # -- this is what makes the overlay click-through/non-blocking too,
        # since there's no opaque window surface to intercept clicks.
        transparent_key = 'magenta'
        root.attributes('-transparentcolor', transparent_key)
        root.config(bg=transparent_key)

        screen_w = root.winfo_screenwidth()
        x = (screen_w - _SIZE) // 2
        root.geometry(f'{_SIZE}x{_SIZE}+{x}+{_TOP_MARGIN}')

        canvas = tk.Canvas(root, width=_SIZE, height=_SIZE, bg=transparent_key, highlightthickness=0)
        canvas.pack()
        dot = canvas.create_oval(2, 2, _SIZE - 2, _SIZE - 2, fill=_STATE_COLORS['listening'], outline='')

        root.withdraw()
        state = {'current': None, 'blink_on': True}

        def apply_state(new_state):
            state['current'] = new_state
            canvas.itemconfig(dot, fill=_STATE_COLORS.get(new_state, _STATE_COLORS['listening']))
            canvas.itemconfig(dot, state='normal')
            state['blink_on'] = True

        def poll():
            try:
                while True:
                    cmd, payload = self._queue.get_nowait()
                    if cmd == 'show':
                        apply_state(payload)
                        root.deiconify()
                    elif cmd == 'hide':
                        state['current'] = None
                        root.withdraw()
            except queue.Empty:
                pass
            root.after(_POLL_MS, poll)

        def blink():
            # Only "listening" blinks -- processing stays solid so the two
            # states read as visually distinct at a glance, not just by hue.
            if state['current'] == 'listening':
                state['blink_on'] = not state['blink_on']
                canvas.itemconfig(dot, state='normal' if state['blink_on'] else 'hidden')
            root.after(_BLINK_MS, blink)

        root.after(_POLL_MS, poll)
        root.after(_BLINK_MS, blink)
        self._ready.set()
        root.mainloop()
