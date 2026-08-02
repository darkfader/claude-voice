# claude-voice/scripts/dictation/dictation_config.py
import os
from dataclasses import dataclass
from pathlib import Path
from dotenv import load_dotenv


@dataclass
class DictationConfig:
    whisper_model: str
    whisper_device: str
    hotkey: str
    dictate_type_script: Path


def load_config(dotenv_path: str = None) -> DictationConfig:
    load_dotenv(dotenv_path)
    return DictationConfig(
        whisper_model=os.environ.get('DICTATION_WHISPER_MODEL', 'large-v3-turbo'),
        whisper_device=os.environ.get('DICTATION_WHISPER_DEVICE', 'cuda'),
        hotkey=os.environ.get('DICTATION_HOTKEY', 'ctrl+alt+space'),
        dictate_type_script=Path(__file__).resolve().parent.parent / 'dictate-type.ps1',
    )
