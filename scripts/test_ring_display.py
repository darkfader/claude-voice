# claude-voice/scripts/test_ring_display.py
"""Mirrors the pure-predicate cases from RingDisplay.Tests.ps1's
'Test-ShouldHandOffRing' Describe block -- see ring_display.py's top
comment for why set_remaining_led itself isn't ported (and tested) yet."""
from ring_display import should_hand_off_ring


def test_false_when_resolved_session_is_not_the_one_displayed_even_with_survivors():
    # The discarded-dial-selection regression: N1/N2 pending, dial moved to
    # N2, then an unrelated session X resolves. X resolving must not hand
    # the ring to N1 just because survivors remain.
    assert should_hand_off_ring('clear', 2, 'n2', 'x') is False


def test_true_when_resolved_session_is_the_one_displayed_and_survivors_remain():
    assert should_hand_off_ring('clear', 1, 'n2', 'n2') is True


def test_false_when_resolved_session_was_displayed_but_nothing_survives():
    assert should_hand_off_ring('stop', 0, 'n2', 'n2') is False


def test_false_when_nothing_has_ever_been_displayed():
    assert should_hand_off_ring('clear', 2, None, 'x') is False


def test_false_for_a_notification_event_regardless_of_other_inputs():
    assert should_hand_off_ring('notification', 2, 'n2', 'n2') is False
