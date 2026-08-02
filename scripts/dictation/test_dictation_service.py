# claude-voice/scripts/dictation/test_dictation_service.py
from unittest.mock import MagicMock
from dictation_service import transcribe_and_dispatch

def test_skips_dispatch_on_empty_transcript():
    whisper_model = MagicMock()
    whisper_model.transcribe.return_value = ([], None)  # faster-whisper returns (segments, info)
    run_subprocess = MagicMock()

    transcribe_and_dispatch(
        audio=b'\x00' * 100,
        dictate_type_script='dictate-type.ps1',
        whisper_model=whisper_model,
        run_subprocess=run_subprocess,
    )

    run_subprocess.assert_not_called()

def test_dispatches_nonempty_transcript_to_powershell():
    whisper_model = MagicMock()
    segment = MagicMock(text=' hello world ')
    whisper_model.transcribe.return_value = ([segment], None)
    run_subprocess = MagicMock()

    transcribe_and_dispatch(
        audio=b'\x00' * 100,
        dictate_type_script='dictate-type.ps1',
        whisper_model=whisper_model,
        run_subprocess=run_subprocess,
    )

    run_subprocess.assert_called_once_with(
        ['pwsh', '-File', 'dictate-type.ps1', '-Text', 'hello world']
    )

def test_joins_multiple_segments_with_spaces():
    whisper_model = MagicMock()
    segments = [MagicMock(text='hello'), MagicMock(text='world')]
    whisper_model.transcribe.return_value = (segments, None)
    run_subprocess = MagicMock()

    transcribe_and_dispatch(
        audio=b'\x00' * 100,
        dictate_type_script='dictate-type.ps1',
        whisper_model=whisper_model,
        run_subprocess=run_subprocess,
    )

    run_subprocess.assert_called_once_with(
        ['pwsh', '-File', 'dictate-type.ps1', '-Text', 'hello world']
    )
