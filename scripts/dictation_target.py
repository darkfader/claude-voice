# claude-voice/scripts/dictation_target.py
"""Ported from DictationTarget.psm1 (kept alongside during the migration).
Pure: decide where dictated text should go -- the tracked active Claude
Code session's window, or (if none tracked, or it's since expired out of
`known`) whatever window currently has OS focus."""


def resolve_dictation_target(state):
    active_id = state.get('activeSession')
    if active_id and active_id in state.get('known', {}):
        entry = state['known'][active_id]
        return {
            'mode': 'session',
            'sessionId': active_id,
            'project': entry.get('project'),
            'windowPid': int(entry['windowPid']) if entry.get('windowPid') else 0,
        }
    return {'mode': 'focused'}
