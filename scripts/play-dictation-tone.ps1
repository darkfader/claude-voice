# claude-voice/scripts/play-dictation-tone.ps1
#
# Thin wrapper so the Python dictation service (a separate process with no
# PowerShell module loaded) can play the same HA chime/error tones the rest
# of claude-voice uses for state feedback, by shelling out to this script.
#
# HaClient.psm1 does NOT expose a generic "play this media id" function --
# only two purpose-built ones, each hardcoded to its own file:
#   Invoke-HaChime       -> $script:ChimeMediaId (media/chime.wav)
#   Invoke-HaErrorSound  -> $script:ErrorMediaId (media/error.wav)
# There is nothing to parameterise by media id, so start/stop both reuse the
# existing chime and error reuses the existing error sound -- the same two
# sounds already used for notification feedback elsewhere in this repo.
param(
    [Parameter(Mandatory)][ValidateSet('start', 'stop', 'error')][string]$Tone
)

Import-Module (Join-Path $PSScriptRoot 'HaClient.psm1') -Force

$connection = Get-HaConnection

switch ($Tone) {
    'start' { Invoke-HaChime -Connection $connection | Out-Null }
    'stop'  { Invoke-HaChime -Connection $connection | Out-Null }
    'error' { Invoke-HaErrorSound -Connection $connection | Out-Null }
}
