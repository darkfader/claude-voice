# claude-voice/scripts/dictation/udp_receiver.py
"""UDP listener for the HA Voice PE's push-to-talk button.

Firmware side: claude-voice/firmware/claude_ptt.h streams raw 16kHz/16-bit/
mono PCM frames over UDP while the center button is held, then sends a
1-byte end-of-utterance marker (distinguishable from real audio -- every
PCM packet is a multi-sample batch, always >=2 bytes) the instant the
button releases. That marker is the primary signal an utterance is done.
The idle-timeout fallback below only matters if the marker itself is lost
(WiFi drop) -- treating it as the primary signal (an earlier version of
this file did) means any natural mid-sentence pause gets misread as the
end of the utterance just as easily as an actual release.
"""
import socket
import sys
import threading
import time

import numpy as np


def pcm16_bytes_to_float32(raw_bytes):
    """Convert little-endian int16 PCM bytes to the float32 [-1, 1] array faster-whisper expects."""
    if not raw_bytes:
        return np.zeros(0, dtype='float32')
    # A trailing odd byte shouldn't be possible (every real audio packet is
    # a whole number of 16-bit samples) but stale/mixed protocol versions
    # have produced one before (see git history) -- drop it rather than
    # raising, since a slightly short utterance beats crashing the listener
    # thread mid-stream.
    usable = len(raw_bytes) - (len(raw_bytes) % 2)
    ints = np.frombuffer(raw_bytes[:usable], dtype='<i2')
    return ints.astype('float32') / 32768.0


class UdpPttReceiver:
    """Binds a UDP socket and turns bursts of packets into start/stop events."""

    def __init__(self, port, idle_timeout_s, on_start, on_stop, bind_socket=None):
        self._idle_timeout_s = idle_timeout_s
        self._on_start = on_start
        self._on_stop = on_stop
        self._sock = bind_socket
        if self._sock is None:
            self._sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            self._sock.bind(('0.0.0.0', port))
        # Bounded so the receive loop can periodically notice an idle stream
        # even with no packets arriving at all.
        self._sock.settimeout(0.1)

    def run_once(self, frames, active, last_packet, now_fn=time.monotonic):
        """Process a single receive attempt; pure-ish for testability.

        Returns the updated (frames, active, last_packet) state. Split out of
        run() so the start/idle-timeout logic can be exercised without a real
        socket.
        """
        try:
            data, _addr = self._sock.recvfrom(4096)
        except socket.timeout:
            data = None
        now = now_fn()
        if data is not None and len(data) <= 1:
            # End-of-utterance marker -- takes priority over the idle-timeout
            # fallback below, and ends the utterance immediately regardless
            # of how recently a real audio packet arrived.
            if active:
                active = False
                audio = pcm16_bytes_to_float32(b''.join(frames))
                frames = []
                self._on_stop(audio)
        elif data:
            if not active:
                active = True
                frames = []
                self._on_start()
            frames.append(data)
            last_packet = now
        elif active and (now - last_packet) >= self._idle_timeout_s:
            active = False
            audio = pcm16_bytes_to_float32(b''.join(frames))
            frames = []
            self._on_stop(audio)
        return frames, active, last_packet

    def run(self):
        # A single bad iteration must not take the whole listener thread down
        # -- it's a daemon thread with nothing supervising it, so an uncaught
        # exception here previously meant total, silent silence: no more
        # start/stop events, ever, including the stop that would have
        # cleared the overlay. Log and keep going instead.
        frames, active, last_packet = [], False, 0.0
        while True:
            try:
                frames, active, last_packet = self.run_once(frames, active, last_packet)
            except Exception as exc:
                print(f'UdpPttReceiver.run_once failed: {exc}', file=sys.stderr)
                if active:
                    # Best-effort: an utterance was in progress when this
                    # broke, and on_stop is also what clears the overlay
                    # indicator -- without this the dot is stuck showing
                    # "listening" forever with nothing left alive to fix it.
                    try:
                        self._on_stop(np.zeros(0, dtype='float32'))
                    except Exception as stop_exc:
                        print(f'UdpPttReceiver on_stop cleanup failed: {stop_exc}', file=sys.stderr)
                frames, active, last_packet = [], False, last_packet

    def start_in_background(self):
        thread = threading.Thread(target=self.run, daemon=True)
        thread.start()
        return thread
