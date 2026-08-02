# claude-voice/scripts/dictation/test_udp_receiver.py
import socket
from unittest.mock import MagicMock

import numpy as np

from udp_receiver import UdpPttReceiver, pcm16_bytes_to_float32


def test_pcm16_bytes_to_float32_empty():
    assert pcm16_bytes_to_float32(b'').size == 0


def test_pcm16_bytes_to_float32_converts_and_scales():
    raw = np.array([0, 16384, -32768, 32767], dtype='<i2').tobytes()
    out = pcm16_bytes_to_float32(raw)
    np.testing.assert_allclose(out, [0.0, 0.5, -1.0, 32767 / 32768.0], atol=1e-6)


def _receiver(recvfrom_results, on_start=None, on_stop=None, idle_timeout_s=0.6):
    sock = MagicMock()
    outcomes = iter(recvfrom_results)

    def recvfrom(_bufsize):
        result = next(outcomes)
        if result is None:
            raise socket.timeout()
        return result

    sock.recvfrom.side_effect = recvfrom
    return UdpPttReceiver(
        port=0, idle_timeout_s=idle_timeout_s,
        on_start=on_start or MagicMock(), on_stop=on_stop or MagicMock(),
        bind_socket=sock,
    )


def test_first_packet_triggers_start_and_buffers():
    on_start = MagicMock()
    receiver = _receiver([(b'\x01\x00', ('pe', 1))], on_start=on_start)

    frames, active, last_packet = receiver.run_once([], False, 0.0, now_fn=lambda: 100.0)

    on_start.assert_called_once()
    assert active is True
    assert frames == [b'\x01\x00']
    assert last_packet == 100.0


def test_idle_gap_past_timeout_triggers_stop_with_joined_audio():
    on_stop = MagicMock()
    receiver = _receiver([None], on_stop=on_stop, idle_timeout_s=0.6)

    frames, active, last_packet = receiver.run_once(
        [b'\x01\x00', b'\x02\x00'], active=True, last_packet=100.0, now_fn=lambda: 100.7,
    )

    on_stop.assert_called_once()
    sent_audio = on_stop.call_args[0][0]
    np.testing.assert_allclose(sent_audio, pcm16_bytes_to_float32(b'\x01\x00\x02\x00'))
    assert active is False
    assert frames == []


def test_end_marker_triggers_stop_immediately_regardless_of_idle_timeout():
    on_stop = MagicMock()
    receiver = _receiver([(b'\x00', ('pe', 1))], on_stop=on_stop, idle_timeout_s=999)

    frames, active, last_packet = receiver.run_once(
        [b'\x01\x00', b'\x02\x00'], active=True, last_packet=100.0, now_fn=lambda: 100.05,
    )

    on_stop.assert_called_once()
    sent_audio = on_stop.call_args[0][0]
    np.testing.assert_allclose(sent_audio, pcm16_bytes_to_float32(b'\x01\x00\x02\x00'))
    assert active is False
    assert frames == []


def test_end_marker_while_inactive_is_a_noop():
    on_stop = MagicMock()
    receiver = _receiver([(b'\x00', ('pe', 1))], on_stop=on_stop)

    frames, active, last_packet = receiver.run_once([], active=False, last_packet=0.0, now_fn=lambda: 100.0)

    on_stop.assert_not_called()
    assert active is False


def test_gap_within_timeout_does_not_trigger_stop():
    on_stop = MagicMock()
    receiver = _receiver([None], on_stop=on_stop, idle_timeout_s=0.6)

    frames, active, last_packet = receiver.run_once(
        [b'\x01\x00'], active=True, last_packet=100.0, now_fn=lambda: 100.2,
    )

    on_stop.assert_not_called()
    assert active is True
    assert frames == [b'\x01\x00']
    assert last_packet == 100.0
