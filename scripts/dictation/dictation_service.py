# claude-voice/scripts/dictation/dictation_service.py
import subprocess
import sys
import threading
from pathlib import Path

import numpy as np
import sounddevice as sd
from faster_whisper import WhisperModel

from dictation_config import load_config

SAMPLE_RATE = 16000

PLAY_TONE_SCRIPT = Path(__file__).resolve().parent.parent / 'play-dictation-tone.ps1'


def play_tone(tone, run_subprocess=subprocess.run):
    """Shell out to play-dictation-tone.ps1 for audio feedback.

    Best-effort: a tone failure (e.g. HA unreachable) must never take down
    the long-running service, so any exception is swallowed after logging.
    """
    try:
        run_subprocess(['pwsh', '-File', str(PLAY_TONE_SCRIPT), '-Tone', tone])
    except Exception as exc:
        print(f'play_tone({tone!r}) failed: {exc}', file=sys.stderr)


def transcribe_and_dispatch(audio, dictate_type_script, whisper_model, run_subprocess=subprocess.run):
    """Transcribe recorded audio and, if non-empty, type it via dictate-type.ps1."""
    try:
        segments, _info = whisper_model.transcribe(audio, language='en')
        text = ' '.join(seg.text.strip() for seg in segments).strip()
    except Exception as exc:
        print(f'Transcription failed: {exc}', file=sys.stderr)
        play_tone('error', run_subprocess=run_subprocess)
        return
    if not text:
        return
    run_subprocess(['pwsh', '-File', str(dictate_type_script), '-Text', text])


class Recorder:
    """Accumulates mic frames between start() and stop()."""

    def __init__(self):
        self._frames = []
        self._stream = None

    def start(self):
        self._frames = []
        self._stream = sd.InputStream(
            samplerate=SAMPLE_RATE, channels=1, dtype='float32',
            callback=lambda indata, *_: self._frames.append(indata.copy()),
        )
        self._stream.start()

    def stop(self):
        self._stream.stop()
        self._stream.close()
        if not self._frames:
            return np.zeros(0, dtype='float32')
        return np.concatenate(self._frames, axis=0).flatten()


def main():
    import keyboard  # imported here so tests never need a real keyboard hook

    config = load_config()
    print(f'Loading faster-whisper model "{config.whisper_model}" on {config.whisper_device}...')
    compute_type = 'float16' if config.whisper_device == 'cuda' else 'int8'
    whisper_model = WhisperModel(config.whisper_model, device=config.whisper_device, compute_type=compute_type)
    print(f'Ready. Hold {config.hotkey} to dictate.')

    recorder = Recorder()
    state_lock = threading.Lock()
    recording = {'active': False}

    def on_press():
        with state_lock:
            if recording['active']:
                return
            recording['active'] = True
        recorder.start()
        play_tone('start')

    def on_release():
        with state_lock:
            if not recording['active']:
                return
            recording['active'] = False
        audio = recorder.stop()
        play_tone('stop')
        if audio.size == 0:
            return
        transcribe_and_dispatch(audio, config.dictate_type_script, whisper_model)

    keyboard.add_hotkey(config.hotkey, on_press, trigger_on_release=False)
    keyboard.add_hotkey(config.hotkey, on_release, trigger_on_release=True)
    keyboard.wait()


if __name__ == '__main__':
    main()
