# claude-voice/scripts/dictation/test_dictation_config.py
import os
from pathlib import Path
import tempfile
from dictation_config import load_config

def test_load_config_uses_defaults_when_env_absent(monkeypatch):
    monkeypatch.delenv('DICTATION_WHISPER_MODEL', raising=False)
    monkeypatch.delenv('DICTATION_WHISPER_DEVICE', raising=False)
    monkeypatch.delenv('DICTATION_HOTKEY', raising=False)
    cfg = load_config()
    assert cfg.whisper_model == 'large-v3-turbo'
    assert cfg.whisper_device == 'cuda'
    assert cfg.hotkey == 'ctrl+alt+space'

def test_load_config_reads_env_overrides(monkeypatch):
    monkeypatch.setenv('DICTATION_WHISPER_MODEL', 'medium')
    monkeypatch.setenv('DICTATION_WHISPER_DEVICE', 'cpu')
    monkeypatch.setenv('DICTATION_HOTKEY', 'ctrl+alt+d')
    cfg = load_config()
    assert cfg.whisper_model == 'medium'
    assert cfg.whisper_device == 'cpu'
    assert cfg.hotkey == 'ctrl+alt+d'

def test_dictate_type_script_path_resolves_next_to_dictation_dir():
    cfg = load_config()
    assert cfg.dictate_type_script.name == 'dictate-type.ps1'
    assert cfg.dictate_type_script.parent.name == 'scripts'

def test_load_config_reads_dotenv_file(monkeypatch, tmp_path):
    # Create a temporary .env file with a test value
    env_file = tmp_path / '.env'
    env_file.write_text('DICTATION_WHISPER_MODEL=from-dotenv-file\n')

    # Clean up environment to ensure we're reading from .env
    monkeypatch.delenv('DICTATION_WHISPER_MODEL', raising=False)
    cfg = load_config(str(env_file))
    assert cfg.whisper_model == 'from-dotenv-file'
