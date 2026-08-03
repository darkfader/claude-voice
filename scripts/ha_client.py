# claude-voice/scripts/ha_client.py
"""Ported from HaClient.psm1 (kept alongside during the migration) -- see
that file's comments for the reasoning behind each entity id/timeout
choice. Talks to Home Assistant over its REST API using `requests`."""
import os
from pathlib import Path

import requests
from dotenv import dotenv_values

_LED_ENTITY = 'light.home_assistant_voice_0932b4_led_ring'
_MEDIA_PLAYER_ENTITY = 'media_player.home_assistant_voice_0932b4_media_player'
_SATELLITE_ENTITY = 'assist_satellite.home_assistant_voice_0932b4_assist_satellite'
_MUTE_ENTITY = 'switch.home_assistant_voice_0932b4_mute'
_KILL_SWITCH_ENTITY = 'input_boolean.claude_notifications_enabled'
_CHIME_MEDIA_ID = 'media-source://media_source/local/claude-voice/chime.wav'
# Two short descending low tones, deliberately blunt and nothing like the
# bright glass chime -- a failure must not sound like a success.
_ERROR_MEDIA_ID = 'media-source://media_source/local/claude-voice/error.wav'
# Area-prefixed: this device's HA entity ids are not predictable from the
# ESPHome name. Confirmed live -- do not "fix" back to the unprefixed
# form, that entity does not exist.
RING_STATE_ENTITY_ID = 'text.bedroom_home_assistant_voice_0932b4_claude_ring_state'


def get_ha_connection():
    env_file = Path(__file__).resolve().parent.parent / '.env'
    if env_file.exists():
        vars_ = dotenv_values(env_file)
        url = vars_.get('HA_URL')
        token = vars_.get('HA_TOKEN')
    else:
        url = os.environ.get('CLAUDE_VOICE_HA_URL')
        token = os.environ.get('CLAUDE_VOICE_HA_TOKEN')
    if not url or not token:
        raise RuntimeError(
            'HA credentials not found - create claude-voice/.env (see claude-voice/.env.example) '
            'or set CLAUDE_VOICE_HA_URL/CLAUDE_VOICE_HA_TOKEN.')
    return {'url': url, 'headers': {'Authorization': f'Bearer {token}', 'Content-Type': 'application/json'}}


def invoke_ha_service(connection, domain, service, body, timeout_sec=2):
    try:
        requests.post(f"{connection['url']}/api/services/{domain}/{service}",
                       headers=connection['headers'], json=body, timeout=timeout_sec).raise_for_status()
        return True
    except requests.RequestException as exc:
        print(f'HA service call {domain}.{service} failed: {exc}')
        return False


def get_ha_state(connection, entity_id):
    try:
        resp = requests.get(f"{connection['url']}/api/states/{entity_id}",
                             headers=connection['headers'], timeout=2)
        resp.raise_for_status()
        return resp.json()
    except requests.RequestException as exc:
        print(f'HA state fetch for {entity_id} failed: {exc}')
        return None


def is_ha_muted(connection):
    s = get_ha_state(connection, _MUTE_ENTITY)
    return bool(s) and s.get('state') == 'on'


def is_ha_notifications_enabled(connection):
    s = get_ha_state(connection, _KILL_SWITCH_ENTITY)
    # fail open if the helper doesn't exist yet or HA is unreachable.
    return (not s) or s.get('state') == 'on'


def invoke_ha_led(connection, rgb=None, brightness=255, flash=False, off=False,
                   transition_sec=0.3, flash_delay_ms=800):
    """RETIRED -- see HaClient.psm1's Invoke-HaLed comment. The per-thread
    ring display now owns the LEDs; `led_ring` and `voice_assistant_leds`
    are two ESPHome partitions over the SAME physical LEDs, and both
    writing the same hardware made every hook paint the ring solid and
    leave it that way. Neutered (returns True immediately) rather than
    removed at every call site, matching the PS original's own approach."""
    return True


def invoke_ha_chime(connection):
    return invoke_ha_service(connection, 'media_player', 'play_media', {
        'entity_id': _MEDIA_PLAYER_ENTITY,
        'media_content_id': _CHIME_MEDIA_ID,
        'media_content_type': 'music',
    })


def invoke_ha_error_sound(connection):
    """A short error tone, in place of speaking a failure aloud -- speaking
    a failure routes through assist_satellite.announce, which drives the
    device into its replying phase, whose LED animation outranks the
    thread display and wipes the ring. play_media does not touch the
    voice assistant's state at all."""
    return invoke_ha_service(connection, 'media_player', 'play_media', {
        'entity_id': _MEDIA_PLAYER_ENTITY,
        'media_content_id': _ERROR_MEDIA_ID,
        'media_content_type': 'music',
    })


def invoke_ha_announce(connection, text):
    # 10s, not the default 2s: assist_satellite.announce legitimately takes
    # a few seconds for real TTS generation -- confirmed empirically that a
    # 2s timeout reports failure even though the device successfully spoke.
    return invoke_ha_service(connection, 'assist_satellite', 'announce', {
        'entity_id': _SATELLITE_ENTITY,
        'message': text,
    }, timeout_sec=10)


def invoke_ha_ring_state(connection, value):
    """Push the per-thread ring state to the device. State only, never
    frames: all animation runs on-device, so this is called when something
    changes, not on a timer."""
    return invoke_ha_service(connection, 'text', 'set_value', {
        'entity_id': RING_STATE_ENTITY_ID,
        'value': value,
    })
