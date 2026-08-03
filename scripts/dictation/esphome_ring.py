# claude-voice/scripts/dictation/esphome_ring.py
"""Direct (no-HA) signal to the Voice PE: flips the claude_ptt_processing
switch (firmware/overlay.yaml) so the physical ring shows yellow while
faster-whisper transcribes, mirroring the desktop overlay dot.

Talks to the device's ESPHome native API directly rather than going through
Home Assistant -- PTT audio itself only flows device->PC (see claude_ptt.h),
so there's no other PC->device channel, and round-tripping through HA would
mean giving this service its own HA credentials for what is purely a local
visual signal.

Runs its own asyncio event loop on a dedicated thread: dictation_service.py
is otherwise fully synchronous/callback-based (same reasoning as
overlay_indicator.py's dedicated Tk thread), so set_processing() schedules
onto that loop rather than requiring callers to be async themselves.
Best-effort throughout -- a connection failure here must never interrupt
actual dictation, only skip the ring's visual feedback.
"""
import asyncio
import sys
import threading

from aioesphomeapi import APIClient

SWITCH_OBJECT_ID = 'claude_ptt_processing'


class RingProcessingSignal:
    def __init__(self, host, port, noise_psk):
        self._host = host
        self._port = port
        self._noise_psk = noise_psk
        self._client = None
        self._switch_key = None
        self._loop = asyncio.new_event_loop()
        self._thread = threading.Thread(target=self._loop.run_forever, daemon=True)
        self._thread.start()

    def set_processing(self, is_on):
        asyncio.run_coroutine_threadsafe(self._set_processing(is_on), self._loop)

    async def _set_processing(self, is_on):
        try:
            await self._ensure_connected()
            self._client.switch_command(self._switch_key, is_on)
        except Exception as exc:
            print(f'esphome_ring: set_processing({is_on!r}) failed: {exc}', file=sys.stderr)

    async def _ensure_connected(self):
        if self._switch_key is not None:
            return
        client = APIClient(self._host, self._port, None, noise_psk=self._noise_psk)
        await client.connect(login=True)
        entities, _services = await client.list_entities_services()
        for entity in entities:
            if entity.object_id == SWITCH_OBJECT_ID:
                self._client = client
                self._switch_key = entity.key
                return
        await client.disconnect()
        raise RuntimeError(f'no "{SWITCH_OBJECT_ID}" entity found on device -- flash the current firmware')


def make_from_config(config):
    """None if no host/key configured -- callers must treat that as "skip", not an error."""
    if not config.esphome_host or not config.esphome_noise_psk:
        return None
    return RingProcessingSignal(config.esphome_host, config.esphome_port, config.esphome_noise_psk)
