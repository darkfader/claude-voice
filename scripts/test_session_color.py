# claude-voice/scripts/test_session_color.py
"""Mirrors SessionColor.Tests.ps1's cases exactly -- see session_color.py's top comment."""
from session_color import (
    convert_from_hue_slot,
    get_normalised_project_path,
    get_project_color_slot,
    get_session_display_name,
    get_session_ordinal,
    resolve_ring_slot,
    resolve_session_color_slot,
)


def test_normalised_path_lowercases_converts_separators_strips_trailing_slash():
    assert get_normalised_project_path(r'C:\Users\darkf\git\HomeAssistant') == 'c:/users/darkf/git/homeassistant'
    assert get_normalised_project_path('c:/users/darkf/git/homeassistant/') == 'c:/users/darkf/git/homeassistant'


def test_pins_the_actual_sha256_derived_slot_golden_value():
    # Derivation, reproducible independently of this module:
    #   norm  = 'c:/users/darkf/git/homeassistant'   (lowercased, /-separated, no trailing /)
    #   bytes = SHA256(UTF8(norm))
    #   slot  = int.from_bytes(bytes[0:4], 'little') % 16
    assert get_project_color_slot(r'C:\Users\darkf\git\HomeAssistant') == 3


def test_gives_the_same_slot_regardless_of_path_spelling():
    a = get_project_color_slot(r'C:\Users\darkf\git\HomeAssistant')
    b = get_project_color_slot('c:/users/darkf/git/homeassistant/')
    assert a == b


def test_always_returns_a_slot_in_range():
    for p in (r'C:\a', r'C:\b', r'C:\c', r'C:\some\deep\path', r'C:\x'):
        s = get_project_color_slot(p)
        assert 0 <= s < 16


def test_convert_from_hue_slot_returns_three_bytes_in_range():
    for slot in range(16):
        rgb = convert_from_hue_slot(slot)
        assert len(rgb) == 3
        for c in rgb:
            assert 0 <= c <= 255


def test_slot_0_is_red():
    assert convert_from_hue_slot(0) == [255, 0, 0]


def test_gives_visibly_different_colours_for_different_slots():
    assert convert_from_hue_slot(0) != convert_from_hue_slot(8)


def test_resolve_uses_the_preferred_slot_when_free():
    pref = get_project_color_slot(r'C:\git\Foo')
    assert resolve_session_color_slot(r'C:\git\Foo', taken_slots=()) == pref


def test_resolve_nudges_to_next_free_slot_when_preferred_is_taken():
    pref = get_project_color_slot(r'C:\git\Foo')
    assert resolve_session_color_slot(r'C:\git\Foo', taken_slots=(pref,)) == (pref + 1) % 16


def test_resolve_skips_over_several_taken_slots():
    pref = get_project_color_slot(r'C:\git\Foo')
    taken = (pref, (pref + 1) % 16, (pref + 2) % 16)
    assert resolve_session_color_slot(r'C:\git\Foo', taken_slots=taken) == (pref + 3) % 16


def test_resolve_falls_back_to_preferred_slot_when_every_slot_is_taken():
    pref = get_project_color_slot(r'C:\git\Foo')
    assert resolve_session_color_slot(r'C:\git\Foo', taken_slots=range(16)) == pref


def test_ordinal_is_1_when_nothing_is_taken():
    assert get_session_ordinal(taken_ordinals=()) == 1


def test_ordinal_is_2_when_1_is_taken():
    assert get_session_ordinal(taken_ordinals=(1,)) == 2


def test_ordinal_fills_a_gap_left_by_a_departed_session():
    assert get_session_ordinal(taken_ordinals=(1, 3)) == 2


def test_display_name_omits_ordinal_for_first_session():
    assert get_session_display_name('HomeAssistant', ordinal=1) == 'HomeAssistant'


def test_display_name_appends_ordinal_for_later_sessions():
    assert get_session_display_name('HomeAssistant', ordinal=2) == 'HomeAssistant 2'


def test_ring_slot_returns_a_slot_in_0_to_11():
    s = resolve_ring_slot('C:/git/HomeAssistant')
    assert 0 <= s <= 11


def test_ring_slot_is_stable_for_the_same_path_across_calls():
    a = resolve_ring_slot('C:/git/HomeAssistant')
    b = resolve_ring_slot('C:/git/HomeAssistant')
    assert a == b


def test_ring_slot_normalises_separators_and_case_like_hue_slot_does():
    a = resolve_ring_slot(r'C:\git\HomeAssistant')
    b = resolve_ring_slot('c:/GIT/homeassistant/')
    assert a == b


def test_ring_slot_nudges_off_a_taken_slot():
    base = resolve_ring_slot('C:/git/HomeAssistant')
    next_slot = resolve_ring_slot('C:/git/HomeAssistant', taken_slots=(base,))
    assert next_slot != base


def test_ring_slot_gives_twelve_same_path_sessions_twelve_distinct_slots():
    taken = []
    for _ in range(12):
        s = resolve_ring_slot('C:/git/P', taken_slots=taken)
        taken.append(s)
    assert len(set(taken)) == 12


def test_ring_slot_falls_back_to_base_slot_when_all_twelve_are_taken():
    # Thirteenth thread: there is no free seat. Returning the base slot
    # (rather than looping forever or erroring) is what lets the encoder
    # simply cap the drawn list at twelve.
    base = resolve_ring_slot('C:/git/P')
    assert resolve_ring_slot('C:/git/P', taken_slots=range(12)) == base
