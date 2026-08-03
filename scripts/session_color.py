# claude-voice/scripts/session_color.py
"""Colours must be BOTH stable (a project looks the same every day, so it
is learnable) and distinct (two sessions pending at once must never look
alike). A pure hash gives the first, arrival-order assignment gives the
second. Quantising into fixed slots and nudging on collision gives both.

Ported from SessionColor.psm1 (kept alongside during the migration) -- see
that file's comments for the reasoning behind each rule.
"""
import hashlib

_SLOT_COUNT = 16
_RING_SLOT_COUNT = 12


def get_normalised_project_path(path):
    return path.replace('\\', '/').rstrip('/').lower()


def _hash_uint32(norm):
    # SHA256, NOT Python's built-in hash()/str hashing: PYTHONHASHSEED
    # randomizes str hashing per process by default, same instability
    # .NET Core's String.GetHashCode has -- this needs to survive a
    # restart. First 4 bytes read little-endian, matching .NET's
    # BitConverter.ToUInt32 default (verified against the golden-value test
    # this module's test file carries over from SessionColor.Tests.ps1).
    digest = hashlib.sha256(norm.encode('utf-8')).digest()
    return int.from_bytes(digest[0:4], byteorder='little')


def get_project_color_slot(project_path):
    norm = get_normalised_project_path(project_path)
    return _hash_uint32(norm) % _SLOT_COUNT


def convert_from_hue_slot(slot):
    """Full saturation and value, so sessions read as distinct hues rather
    than shades that are hard to tell apart on a small ring.

    The slot is SCATTERED around the wheel rather than mapped linearly.
    Linear mapping put consecutive slots 22.5 degrees apart, and
    resolve_session_color_slot resolves a collision by taking the NEXT
    slot -- so two threads in the same project reliably ended up on
    adjacent hues (observed live: three near-identical greens in one repo).
    5 is coprime with 16, so slot -> hue stays a bijection: every slot
    still gets its own hue, each slot's hue is still fixed forever, but
    successive slots now land 112.5 degrees apart instead of 22.5."""
    scattered = (slot * 5) % _SLOT_COUNT
    hue = (360.0 / _SLOT_COUNT) * scattered
    x = 1.0 - abs((hue / 60.0) % 2.0 - 1.0)
    sector = int(hue // 60.0)
    if sector == 0:
        r, g, b = 1.0, x, 0.0
    elif sector == 1:
        r, g, b = x, 1.0, 0.0
    elif sector == 2:
        r, g, b = 0.0, 1.0, x
    elif sector == 3:
        r, g, b = 0.0, x, 1.0
    elif sector == 4:
        r, g, b = x, 0.0, 1.0
    else:
        r, g, b = 1.0, 0.0, x
    return [round(r * 255), round(g * 255), round(b * 255)]


def resolve_session_color_slot(project_path, taken_slots=()):
    preferred = get_project_color_slot(project_path)
    taken_slots = set(taken_slots)
    for i in range(_SLOT_COUNT):
        candidate = (preferred + i) % _SLOT_COUNT
        if candidate not in taken_slots:
            return candidate
    # Everything taken (16+ pending). Repeat rather than fail; the spoken
    # name is the identifier at that point anyway.
    return preferred


def resolve_ring_slot(project_path, taken_slots=()):
    """A thread's home position on the 12-LED ring, 0-11.

    Separate from the hue slot deliberately. Hue is mod 16, position is
    mod 12, and the two are nudged against different occupancy sets --
    deriving one from the other would couple a thread's colour to how many
    threads happen to share the ring. Same hashing as
    resolve_session_color_slot: SHA256, so a thread's seat survives a
    restart."""
    norm = get_normalised_project_path(project_path)
    base = _hash_uint32(norm) % _RING_SLOT_COUNT
    taken_slots = set(taken_slots)
    if base not in taken_slots:
        return base
    for i in range(1, _RING_SLOT_COUNT):
        candidate = (base + i) % _RING_SLOT_COUNT
        if candidate not in taken_slots:
            return candidate
    # Every seat taken. The encoder caps the drawn list at twelve, so this
    # thread simply will not be drawn; returning the base keeps the value
    # deterministic instead of erroring in a hook.
    return base


def get_session_ordinal(taken_ordinals=()):
    taken_ordinals = set(taken_ordinals)
    n = 1
    while n in taken_ordinals:
        n += 1
    return n


def get_session_display_name(project, ordinal=1):
    return project if ordinal <= 1 else f'{project} {ordinal}'
