# claude-voice/scripts/test_pending_state.py
"""Mirrors PendingState.Tests.ps1's cases -- see pending_state.py's top comment."""
import json
import os
import subprocess
import sys
import time
import uuid
from pathlib import Path

import pytest

import pending_state as ps
from session_color import convert_from_hue_slot, resolve_session_color_slot


@pytest.fixture(autouse=True)
def _isolated_state(tmp_path):
    # Every test gets its own state file AND its own throwaway mutex name --
    # without the latter, the suite would take the real
    # 'Global\ClaudeVoicePendingState' that live Claude Code hooks use, so a
    # hook firing mid-run could block a test, and a test run could equally
    # stall real hooks.
    state_path = tmp_path / 'pending.json'
    ps.set_pending_state_path(state_path)
    ps.set_pending_state_mutex_name(f'Global\\ClaudeVoicePendingStateTest_{uuid.uuid4().hex}')
    ps.set_pending_state_expiry_hours(4)
    ps.set_known_expiry_hours(24)
    # 1h, not the 0.5h production default (PendingState.psm1 was halved
    # from 1h earlier) -- PendingState.Tests.ps1's own BeforeEach still
    # explicitly overrides to 1h regardless of the module default, and the
    # legacy-file test below depends on its 30-minute-old fixture being
    # safely INSIDE the fade window, not sitting right at its edge.
    ps.set_known_idle_fade_hours(1)
    ps.set_known_hard_expiry_hours(48)
    yield state_path


def test_returns_empty_state_when_no_file_exists_yet():
    state = ps.get_pending_state()
    assert len(state['sessions']) == 0
    assert not state['cursor']
    assert not state['activeSession']


def test_adds_a_pending_session_with_all_its_fields():
    ps.set_pending_session('s1', 'HomeAssistant', 'C:/git/HomeAssistant', 'fix bug', [255, 0, 0], 0, 1)
    s = ps.get_pending_state()['sessions']['s1']
    assert s['project'] == 'HomeAssistant'
    assert s['cwd'] == 'C:/git/HomeAssistant'
    assert s['message'] == 'fix bug'
    assert s['color'] == [255, 0, 0]
    assert s['slot'] == 0
    assert s['ordinal'] == 1
    assert s['since']


def test_clears_a_pending_session():
    ps.set_pending_session('s1', 'p', 'c', 'm', [1, 2, 3], 0, 1)
    ps.clear_pending_session('s1')
    assert 's1' not in ps.get_pending_state()['sessions']


def test_clearing_the_cursor_session_resets_the_cursor():
    ps.set_pending_session('s1', 'p', 'c', 'm', [1, 2, 3], 0, 1)
    ps.set_pending_cursor('s1')
    ps.clear_pending_session('s1')
    assert not ps.get_pending_state()['cursor']


def test_clearing_a_different_session_leaves_the_cursor_alone():
    ps.set_pending_session('s1', 'p', 'c', 'm', [1, 2, 3], 0, 1)
    ps.set_pending_session('s2', 'q', 'd', 'm', [4, 5, 6], 1, 1)
    ps.set_pending_cursor('s2')
    ps.clear_pending_session('s1')
    assert ps.get_pending_state()['cursor'] == 's2'


def test_tracks_the_active_session_and_can_clear_it():
    ps.set_active_session('s9')
    st = ps.get_pending_state()
    assert st['activeSession'] == 's9'
    assert st['activeSince']
    ps.clear_active_session()
    assert not ps.get_pending_state()['activeSession']


def test_drops_sessions_older_than_the_expiry_window(_isolated_state):
    ps.set_pending_session('old', 'p', 'c', 'm', [1, 2, 3], 0, 1)
    raw = json.loads(_isolated_state.read_text())
    from datetime import datetime, timedelta, timezone
    raw['sessions']['old']['since'] = (datetime.now(timezone.utc) - timedelta(hours=5)).isoformat()
    _isolated_state.write_text(json.dumps(raw))
    assert 'old' not in ps.get_pending_state()['sessions']


def test_keeps_sessions_inside_the_expiry_window():
    ps.set_pending_session('fresh', 'p', 'c', 'm', [1, 2, 3], 0, 1)
    assert 'fresh' in ps.get_pending_state()['sessions']


def test_treats_an_old_account_shaped_file_as_empty(_isolated_state):
    _isolated_state.write_text('{ "accounts": { "personal": { "project": "x" } }, "cursor": null }')
    assert len(ps.get_pending_state()['sessions']) == 0


def test_treats_a_sessions_array_as_empty_rather_than_throwing(_isolated_state):
    _isolated_state.write_text('{ "sessions": [], "cursor": null }')
    state = ps.get_pending_state()  # must not raise
    assert len(state['sessions']) == 0


def test_tracks_the_displayed_session_and_can_clear_it():
    ps.set_displayed_session('s7')
    assert ps.get_pending_state()['displayedSession'] == 's7'
    ps.clear_displayed_session()
    assert not ps.get_pending_state()['displayedSession']


def test_does_not_reset_displayed_session_when_named_session_no_longer_pending():
    # displayedSession's whole purpose is to keep tracking what the ring is
    # showing even after the session it names has left `sessions` -- unlike
    # cursor, it must survive so an idle check elsewhere can detect the
    # orphan and turn the ring off.
    ps.set_pending_session('s1', 'p', 'c', 'm', [1, 2, 3], 0, 1)
    ps.set_displayed_session('s1')
    ps.clear_pending_session('s1')
    assert ps.get_pending_state()['displayedSession'] == 's1'


def test_register_pending_notification_assigns_colour_ordinal_sets_cursor_reports_count():
    result = ps.register_pending_notification('s1', 'HomeAssistant', 'C:/git/HomeAssistant', 'wants to run git push')
    assert result['OthersCount'] == 0
    state = ps.get_pending_state()
    assert state['sessions']['s1']['project'] == 'HomeAssistant'
    assert state['sessions']['s1']['message'] == 'wants to run git push'
    assert state['sessions']['s1']['color']
    assert state['sessions']['s1']['ordinal'] == 1
    assert state['cursor'] == 's1'


def test_register_pending_notification_does_not_move_cursor_when_already_pending():
    ps.register_pending_notification('s1', 'A', 'C:/git/A', 'm1')
    result = ps.register_pending_notification('s2', 'B', 'C:/git/B', 'm2')
    assert result['OthersCount'] == 1
    assert ps.get_pending_state()['cursor'] == 's1'


def test_register_pending_notification_nudges_a_colliding_colour_slot():
    ps.register_pending_notification('s1', 'HomeAssistant', 'C:/Users/darkf/git/HomeAssistant', 'm1')
    ps.register_pending_notification('s2', 'HomeAssistant2', 'C:/Users/darkf/git/HomeAssistant', 'm2')
    state = ps.get_pending_state()
    assert state['sessions']['s1']['slot'] != state['sessions']['s2']['slot']


def test_register_pending_notification_is_idempotent_for_a_session_already_pending():
    ps.register_pending_notification('s1', 'A', 'C:/git/A', 'm1')
    before = ps.get_pending_state()['sessions']['s1']['color']
    result = ps.register_pending_notification('s1', 'A', 'C:/git/A', 'm2 should be ignored')
    state = ps.get_pending_state()
    assert state['sessions']['s1']['color'] == before
    assert state['sessions']['s1']['message'] == 'm1'
    assert state['cursor'] == 's1'
    assert result['OthersCount'] == 0


def test_register_pending_notification_does_not_let_missing_slot_block_slot_0(_isolated_state):
    ps.set_pending_session('legacy', 'Legacy', 'C:/legacy', 'm', [1, 1, 1], 5, 1)
    raw = json.loads(_isolated_state.read_text())
    del raw['sessions']['legacy']['slot']
    _isolated_state.write_text(json.dumps(raw))

    # 'C:/git/proj3' is a path whose SHA256-derived preferred slot is 0 --
    # the exact slot a null-coerces-to-0 bug would spuriously mark taken.
    result = ps.register_pending_notification('s1', 'proj3', 'C:/git/proj3', 'm1')
    assert result['OthersCount'] == 1
    assert ps.get_pending_state()['sessions']['s1']['slot'] == 0


def test_resolve_pending_session_clears_marks_active_reports_others():
    ps.set_pending_session('s1', 'A', 'ca', 'm', [1, 2, 3], 0, 1)
    ps.set_pending_session('s2', 'B', 'cb', 'm', [4, 5, 6], 1, 1)
    result = ps.resolve_pending_session('s1')
    assert result['OthersCount'] == 1
    state = ps.get_pending_state()
    assert 's1' not in state['sessions']
    assert 's2' in state['sessions']
    assert state['activeSession'] == 's1'
    assert state['activeSince']


def test_resolve_pending_session_reports_zero_when_only_one_pending():
    ps.set_pending_session('s1', 'A', 'ca', 'm', [1, 2, 3], 0, 1)
    result = ps.resolve_pending_session('s1')
    assert result['OthersCount'] == 0


def test_save_pending_state_leaves_no_leftover_temp_file(tmp_path):
    ps.set_pending_session('s1', 'p', 'c', 'm', [1, 2, 3], 0, 1)
    assert list(tmp_path.glob('pending.*.tmp')) == []


def test_save_pending_state_is_atomic_under_concurrent_writes(tmp_path):
    """Direct, unmediated existence check -- no read/retry/parse in
    between -- so nothing phase-shifts the sampling window away from a
    concurrent writer's atomic swap. Mirrors the PS version's own
    (empirically-motivated) test, which found two prior implementations
    both had a real "destination transiently missing" window under load
    before landing on os.replace()'s Win32 equivalent."""
    state_path = tmp_path / 'pending.json'
    mutex_name = f'Global\\ClaudeVoicePendingStateTest_{uuid.uuid4().hex}'
    ps.set_pending_state_path(state_path)
    ps.set_pending_state_mutex_name(mutex_name)
    ps.set_pending_session('seed', 'p', 'c', 'm', [1, 2, 3], 0, 1)

    writer_script = f'''
import sys, time
sys.path.insert(0, {str(Path(__file__).resolve().parent)!r})
import pending_state as ps
ps.set_pending_state_path({str(state_path)!r})
ps.set_pending_state_mutex_name({mutex_name!r})
msg = "wants to run a fairly long shell command that needs approval " * 5
i = 0
while True:
    try:
        ps.set_pending_session(f"writer{{i % 5}}", f"p{{i}}", f"c{{i}}", msg, [1, 2, 3], i % 16, 1)
    except Exception:
        pass
    i += 1
    time.sleep(0.005)
'''
    proc = subprocess.Popen([sys.executable, '-c', writer_script])
    try:
        deadline = time.monotonic() + 5
        probes = 0
        misses = 0
        while time.monotonic() < deadline:
            probes += 1
            if not os.path.exists(state_path):
                misses += 1
        assert probes > 0, 'the test is meaningless if it never actually raced a concurrent write'
        print(f'save_pending_state atomicity probe: {misses} / {probes} direct exists() misses')
        assert misses == 0, f'os.replace must never leave the destination transiently missing ({misses}/{probes} misses)'
    finally:
        proc.terminate()
        proc.wait(timeout=15)


def test_throws_when_unable_to_acquire_lock_within_timeout(tmp_path):
    mutex_name = f'Global\\ClaudeVoicePendingStateTest_{uuid.uuid4().hex}'
    ps.set_pending_state_mutex_name(mutex_name)
    ready_file = tmp_path / 'lock-held.flag'
    release_file = tmp_path / 'lock-release.flag'

    locker_script = f'''
import ctypes, time
from ctypes import wintypes
kernel32 = ctypes.WinDLL('kernel32', use_last_error=True)
kernel32.CreateMutexW.restype = wintypes.HANDLE
kernel32.CreateMutexW.argtypes = [wintypes.LPVOID, wintypes.BOOL, wintypes.LPCWSTR]
handle = kernel32.CreateMutexW(None, False, {mutex_name!r})
result = kernel32.WaitForSingleObject(handle, 30000)
if result in (0, 0x80):
    with open({str(ready_file)!r}, 'w') as f:
        f.write('held')
    deadline = time.monotonic() + 60
    while not __import__('os').path.exists({str(release_file)!r}) and time.monotonic() < deadline:
        time.sleep(0.05)
    kernel32.ReleaseMutex(handle)
kernel32.CloseHandle(handle)
'''
    proc = subprocess.Popen([sys.executable, '-c', locker_script])
    try:
        deadline = time.monotonic() + 30
        while not ready_file.exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        assert ready_file.exists(), 'the background process must actually hold the lock before the timeout assertion means anything'

        with pytest.raises(ps.PendingStateLockTimeout):
            ps.set_pending_session('test', 'p', 'c', 'm', [1, 2, 3], 0, 1)
    finally:
        release_file.write_text('go')
        proc.wait(timeout=15)


# ------------------------------------------------------- known session registry

def test_registers_a_session_with_base_colour_ordinal_1_matching_seen():
    ps.register_known_session('s1', 'HomeAssistant', 'C:/Users/darkf/git/HomeAssistant')
    k = ps.get_pending_state()['known']['s1']
    assert k['project'] == 'HomeAssistant'
    assert k['cwd'] == 'C:/Users/darkf/git/HomeAssistant'
    assert k['ordinal'] == 1
    assert len(k['color']) == 3
    assert k['firstSeen'] == k['lastSeen']


def test_reregistering_bumps_last_seen_but_preserves_first_seen_colour_ordinal():
    ps.register_known_session('s1', 'HomeAssistant', 'C:/git/HomeAssistant')
    before = ps.get_pending_state()['known']['s1']
    time.sleep(0.02)
    ps.register_known_session('s1', 'HomeAssistant', 'C:/git/HomeAssistant')
    after = ps.get_pending_state()['known']['s1']
    assert after['firstSeen'] == before['firstSeen']
    assert after['lastSeen'] > before['lastSeen']
    assert after['color'] == before['color']
    assert after['ordinal'] == before['ordinal']


def test_reassigns_fresh_ring_slot_when_a_faded_session_reregisters():
    ps.register_known_session('s1', 'P', 'C:/git/P')
    ps.set_known_idle_fade_hours(0.001)  # 3.6s
    time.sleep(4)
    faded = ps.get_pending_state()['known']['s1']
    assert faded['ringSlot'] is None
    assert faded['color'] is None

    ps.register_known_session('s1', 'P', 'C:/git/P')
    reactivated = ps.get_pending_state()['known']['s1']
    assert reactivated['ringSlot'] is not None
    assert reactivated['slot'] is not None
    assert reactivated['color'] is not None


def test_does_not_collide_ring_slots_when_reactivating_one_of_two():
    ps.register_known_session('s1', 'P1', 'C:/git/P1')
    ps.register_known_session('s2', 'P2', 'C:/git/P2')
    ps.set_known_idle_fade_hours(0.001)
    time.sleep(4)
    ps.get_pending_state()  # trigger the fade for both

    ps.register_known_session('s1', 'P1', 'C:/git/P1')
    state = ps.get_pending_state()
    assert state['known']['s1']['ringSlot'] is not None


def test_gives_a_second_session_in_the_same_project_ordinal_2():
    ps.register_known_session('s1', 'HomeAssistant', 'C:/git/HomeAssistant')
    ps.register_known_session('s2', 'HomeAssistant', 'C:/git/HomeAssistant')
    assert ps.get_pending_state()['known']['s2']['ordinal'] == 2


def test_expires_known_entries_with_no_transcript_after_backstop_window():
    ps.register_known_session('s1', 'Old', 'C:/git/Old')
    ps.set_known_expiry_hours(0.0001)
    time.sleep(0.5)
    assert 's1' not in ps.get_pending_state()['known']


def test_allows_overriding_idle_fade_and_hard_expiry_windows():
    ps.set_known_idle_fade_hours(0.0001)  # must not raise
    ps.set_known_hard_expiry_hours(0.0002)  # must not raise


def test_does_not_expire_a_known_entry_on_the_pending_clock():
    ps.register_known_session('s1', 'Old', 'C:/git/Old')
    ps.set_pending_state_expiry_hours(0.0001)
    time.sleep(0.5)
    assert 's1' in ps.get_pending_state()['known']


def test_defaults_known_to_empty_map_for_legacy_file(tmp_path):
    legacy = tmp_path / 'legacy.json'
    ps.set_pending_state_path(legacy)
    legacy.write_text('{"sessions":{},"cursor":null,"activeSession":null,"activeSince":null,"displayedSession":null}')
    state = ps.get_pending_state()
    assert 'known' in state
    assert len(state['known']) == 0


def test_keeps_a_cursor_that_names_a_known_but_non_pending_session():
    ps.register_known_session('s1', 'HomeAssistant', 'C:/git/HomeAssistant')
    ps.set_pending_cursor('s1')
    assert ps.get_pending_state()['cursor'] == 's1'


def test_clears_a_cursor_that_names_neither_pending_nor_known():
    ps.register_known_session('s1', 'HomeAssistant', 'C:/git/HomeAssistant')
    ps.set_pending_cursor('s1')
    ps.set_known_expiry_hours(0.0001)
    time.sleep(0.5)
    assert not ps.get_pending_state()['cursor']


def test_removes_a_known_session_at_hard_expiry_even_with_transcript(tmp_path):
    t = tmp_path / f'hardexpire-{uuid.uuid4().hex}.jsonl'
    t.write_text('x')
    ps.register_known_session('s1', 'P', 'C:/git/P', transcript_path=str(t))
    assert 's1' in ps.get_pending_state()['known']

    ps.set_known_hard_expiry_hours(0.0001)
    time.sleep(0.5)
    assert 's1' not in ps.get_pending_state()['known']
    assert t.exists()  # transcript itself untouched


def test_keeps_a_known_session_alive_while_transcript_exists_within_hard_expiry(tmp_path):
    t = tmp_path / f'alive-{uuid.uuid4().hex}.jsonl'
    t.write_text('x')
    ps.register_known_session('s1', 'P', 'C:/git/P', transcript_path=str(t))
    ps.set_known_expiry_hours(0.0001)
    time.sleep(0.5)
    assert 's1' in ps.get_pending_state()['known']


def test_retires_a_known_session_once_its_transcript_is_deleted(tmp_path):
    t = tmp_path / f'gone-{uuid.uuid4().hex}.jsonl'
    t.write_text('x')
    ps.register_known_session('s1', 'P', 'C:/git/P', transcript_path=str(t))
    assert 's1' in ps.get_pending_state()['known']
    t.unlink()
    assert 's1' not in ps.get_pending_state()['known']


def test_records_the_transcript_path_on_registration_and_refreshes_it(tmp_path):
    a = tmp_path / f'a-{uuid.uuid4().hex}.jsonl'
    b = tmp_path / f'b-{uuid.uuid4().hex}.jsonl'
    a.write_text('x')
    b.write_text('x')
    ps.register_known_session('s1', 'P', 'C:/git/P', transcript_path=str(a))
    assert ps.get_pending_state()['known']['s1']['transcriptPath'] == str(a)
    ps.register_known_session('s1', 'P', 'C:/git/P', transcript_path=str(b))
    assert ps.get_pending_state()['known']['s1']['transcriptPath'] == str(b)


def test_clears_ring_slot_for_idle_past_fade_window_but_keeps_the_entry(tmp_path):
    t = tmp_path / f'fade-{uuid.uuid4().hex}.jsonl'
    t.write_text('x')
    ps.register_known_session('s1', 'P', 'C:/git/P', transcript_path=str(t))
    before = ps.get_pending_state()['known']['s1']
    assert before['ringSlot'] is not None
    assert before['color'] is not None

    ps.set_known_idle_fade_hours(0.0001)
    time.sleep(0.5)
    after = ps.get_pending_state()['known']['s1']
    assert after['ringSlot'] is None
    assert after['slot'] is None
    assert after['color'] is None
    assert 's1' in ps.get_pending_state()['known']


def test_does_not_fade_a_known_session_inside_the_idle_fade_window():
    ps.register_known_session('s1', 'P', 'C:/git/P')
    after = ps.get_pending_state()['known']['s1']
    assert after['ringSlot'] is not None
    assert after['color'] is not None


def test_keeps_slot_and_colour_in_sync_after_a_fade():
    ps.register_known_session('s1', 'P', 'C:/git/P')
    ps.set_known_idle_fade_hours(0.0001)
    time.sleep(0.5)
    faded = ps.get_pending_state()['known']['s1']
    assert faded['slot'] is None and faded['ringSlot'] is None and faded['color'] is None

    still_faded = ps.get_pending_state()['known']['s1']
    assert still_faded['slot'] is None and still_faded['ringSlot'] is None and still_faded['color'] is None


def test_still_resolves_ring_slot_normally_for_a_legitimately_missing_entry(_isolated_state):
    ps.register_known_session('s1', 'P', 'C:/git/P')
    raw = json.loads(_isolated_state.read_text())
    raw['known']['s1']['ringSlot'] = None
    raw['known']['s1']['color'] = None
    _isolated_state.write_text(json.dumps(raw))

    after = ps.get_pending_state()['known']['s1']
    assert after['ringSlot'] is not None
    assert after['color'] is not None
    assert after['color'] == convert_from_hue_slot(after['slot'])


def test_does_not_fade_a_working_session_whose_transcript_is_still_being_written(tmp_path):
    t = tmp_path / f'working-live-{uuid.uuid4().hex}.jsonl'
    t.write_text('x')
    ps.register_known_session('s1', 'P', 'C:/git/P', activity='working', transcript_path=str(t))
    ps.set_known_idle_fade_hours(0.0001)
    time.sleep(0.3)
    t.write_text('x\nstill writing')
    time.sleep(0.05)

    after = ps.get_pending_state()['known']['s1']
    assert after['ringSlot'] is not None
    assert after['color'] is not None


def test_still_fades_a_working_session_whose_transcript_also_went_stale(tmp_path):
    t = tmp_path / f'working-crashed-{uuid.uuid4().hex}.jsonl'
    t.write_text('x')
    ps.register_known_session('s1', 'P', 'C:/git/P', activity='working', transcript_path=str(t))
    ps.set_known_idle_fade_hours(0.0001)
    time.sleep(0.5)

    after = ps.get_pending_state()['known']['s1']
    assert after['ringSlot'] is None
    assert after['color'] is None


# --------------------------------------------------- known colour distinctness

def test_gives_two_sessions_in_the_same_folder_different_colours():
    ps.register_known_session('s1', 'HomeAssistant', 'C:/git/HomeAssistant')
    ps.register_known_session('s2', 'HomeAssistant', 'C:/git/HomeAssistant')
    k = ps.get_pending_state()['known']
    assert k['s1']['slot'] != k['s2']['slot']
    assert k['s1']['color'] != k['s2']['color']


def test_still_gives_the_first_session_of_a_project_its_stable_base_colour():
    base = convert_from_hue_slot(resolve_session_color_slot('C:/git/HomeAssistant'))
    ps.register_known_session('s1', 'HomeAssistant', 'C:/git/HomeAssistant')
    assert ps.get_pending_state()['known']['s1']['color'] == base


def test_gives_three_same_folder_sessions_three_distinct_colours():
    ps.register_known_session('s1', 'P', 'C:/git/P')
    ps.register_known_session('s2', 'P', 'C:/git/P')
    ps.register_known_session('s3', 'P', 'C:/git/P')
    k = ps.get_pending_state()['known']
    assert len({k['s1']['slot'], k['s2']['slot'], k['s3']['slot']}) == 3


# ------------------------------------------------------ ring slot / activity

def test_assigns_a_ring_slot_and_records_activity():
    ps.register_known_session('s1', 'P', 'C:/git/P', activity='working')
    k = ps.get_pending_state()['known']['s1']
    assert 0 <= k['ringSlot'] <= 11
    assert k['activity'] == 'working'
    assert k['activitySince']


def test_gives_two_same_folder_sessions_different_ring_slots():
    ps.register_known_session('s1', 'P', 'C:/git/P', activity='idle')
    ps.register_known_session('s2', 'P', 'C:/git/P', activity='idle')
    k = ps.get_pending_state()['known']
    assert k['s1']['ringSlot'] != k['s2']['ringSlot']


def test_keeps_the_same_ring_slot_when_a_session_reregisters():
    ps.register_known_session('s1', 'P', 'C:/git/P', activity='working')
    first = ps.get_pending_state()['known']['s1']['ringSlot']
    ps.register_known_session('s1', 'P', 'C:/git/P', activity='idle')
    assert ps.get_pending_state()['known']['s1']['ringSlot'] == first


def test_updates_activity_and_its_timestamp_on_reregistration():
    ps.register_known_session('s1', 'P', 'C:/git/P', activity='working')
    before = ps.get_pending_state()['known']['s1']['activitySince']
    time.sleep(0.02)
    ps.register_known_session('s1', 'P', 'C:/git/P', activity='attention')
    after = ps.get_pending_state()['known']['s1']
    assert after['activity'] == 'attention'
    assert after['activitySince'] > before


def test_defaults_activity_to_idle_for_legacy_file(tmp_path):
    legacy = tmp_path / 'legacy-ring.json'
    ps.set_pending_state_path(legacy)
    from datetime import datetime, timedelta, timezone
    recent_iso = (datetime.now(timezone.utc) - timedelta(minutes=30)).isoformat()
    legacy.write_text(json.dumps({
        'sessions': {}, 'cursor': None, 'activeSession': None, 'activeSince': None, 'displayedSession': None,
        'known': {'old': {'project': 'P', 'cwd': 'C:/git/P', 'firstSeen': recent_iso, 'lastSeen': recent_iso}},
    }))
    k = ps.get_pending_state()['known']['old']
    assert k['activity'] == 'idle'
    assert k['ringSlot'] >= 0
