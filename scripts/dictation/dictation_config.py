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
    udp_port: int
    udp_idle_timeout_s: float
    esphome_host: str
    esphome_port: int
    esphome_noise_psk: str


def load_config(dotenv_path: str = None) -> DictationConfig:
    load_dotenv(dotenv_path)
    return DictationConfig(
        whisper_model=os.environ.get('DICTATION_WHISPER_MODEL', 'large-v3-turbo'),
        whisper_device=os.environ.get('DICTATION_WHISPER_DEVICE', 'cuda'),
        hotkey=os.environ.get('DICTATION_HOTKEY', 'ctrl+alt+space'),
        dictate_type_script=Path(__file__).resolve().parent.parent / 'dictate-type.ps1',
        # Must match firmware/custom-voice-pe.yaml's claude_ptt_udp_port substitution.
        udp_port=int(os.environ.get('DICTATION_UDP_PORT', '6056')),
        # Fallback only: claude_ptt.h sends an explicit end-of-utterance marker on
        # button release, which is the primary stop signal. This just bounds how
        # long a stream sits open if that marker is lost (WiFi drop).
        udp_idle_timeout_s=float(os.environ.get('DICTATION_UDP_IDLE_TIMEOUT_S', '2.0')),
        # Direct-to-device ESPHome native API connection (see esphome_ring.py) --
        # empty noise_psk means the ring-processing signal is silently skipped,
        # not an error, since it's a visual nice-to-have, not core functionality.
        esphome_host=os.environ.get('CLAUDE_PTT_ESPHOME_HOST', ''),
        esphome_port=int(os.environ.get('CLAUDE_PTT_ESPHOME_PORT', '6053')),
        esphome_noise_psk=os.environ.get('CLAUDE_PTT_ESPHOME_NOISE_PSK', ''),
    )
