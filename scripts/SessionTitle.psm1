# claude-voice/scripts/SessionTitle.psm1
#
# Derives a human-meaningful name for a session from its transcript, so the
# device can say "Explore Home Assistant Voice capabilities" instead of
# "HomeAssistant 2".
#
# Two sources, in order:
#
# 1. Claude Code's own generated title, written into the transcript as
#    `{"type":"ai-title","aiTitle":"..."}` -- the same title shown in the UI
#    and in `claude --resume`. This is the right answer whenever it exists,
#    because it is what the human already recognises the thread by. It is
#    rewritten periodically, so the LAST one within the scanned window wins.
#
# 2. The first genuine human message, for sessions too new to have been
#    titled yet (the title appears only after a few turns). Stable, since the
#    opening message never changes.
#
# Note `{"type":"summary"}` is NOT a source: Claude Code only writes it when a
# session ends or compacts, so a live session -- exactly the case the dial
# cares about -- has none. Verified against real transcripts.

# Turns that are machine-generated rather than typed by the human. The whole
# point is to find what the PERSON asked, so every one of these is skipped.
$script:MachineTurnPatterns = @(
    '^\s*<(task-notification|system-reminder|command-name|command-message|local-command)'
    '^\s*\[SYSTEM NOTIFICATION'
    'Caveat: The messages below'
    '^\s*<user-prompt-submit-hook'
)

function Remove-IdeContextWrapper {
    <#
    .SYNOPSIS
    Strip IDE-injected context blocks, keeping whatever the human actually typed.

    .DESCRIPTION
    The IDE prepends <ide_opened_file>/<ide_selection> blocks to the user's
    turn. Left in, the "title" of a session becomes "The user opened the file
    Untitled-1 in the IDE" -- observed live on a real session. Only the text
    outside those blocks is the human's.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $stripped = [regex]::Replace($Text, '(?s)<ide_[a-z_]+>.*?</ide_[a-z_]+>', ' ')
    # Also drop an unterminated opening block (truncated content).
    $stripped = [regex]::Replace($stripped, '(?s)<ide_[a-z_]+>.*$', ' ')
    ($stripped -replace '\s+', ' ').Trim()
}

function Test-IsMachineTurn {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    foreach ($p in $script:MachineTurnPatterns) {
        if ($Text -match $p) { return $true }
    }
    $false
}

function ConvertTo-SpokenTitle {
    <#
    .SYNOPSIS
    Shorten a message to something worth speaking aloud.

    .DESCRIPTION
    Announcements interrupt; a whole paragraph read out is worse than no name
    at all. Cut to the first sentence, then to MaxWords, then hard-cap the
    length so a pathological one-word-wall cannot produce a 200-character
    utterance.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [int]$MaxWords = 8,
        [int]$MaxChars = 60
    )
    $t = ($Text -replace '\s+', ' ').Trim()
    if (-not $t) { return '' }

    # First sentence only, when there is a clear break.
    $break = $t.IndexOfAny([char[]]@('.', '?', '!', "`n"))
    if ($break -gt 8) { $t = $t.Substring(0, $break) }

    $words = @($t -split ' ' | Where-Object { $_ })
    if ($words.Count -gt $MaxWords) { $t = ($words[0..($MaxWords - 1)] -join ' ') }

    if ($t.Length -gt $MaxChars) { $t = $t.Substring(0, $MaxChars).TrimEnd() }
    # Trailing punctuation reads badly through TTS.
    $t.TrimEnd(@(',', ';', ':', '-', '.'))
}

function Get-SessionTitle {
    <#
    .SYNOPSIS
    A short spoken name for the session whose transcript is at TranscriptPath,
    or $null when none can be derived.
    #>
    param(
        [Parameter(Mandatory)][string]$TranscriptPath,
        # The opening human message is near the top of the file; transcripts
        # reach tens of megabytes, so never read the whole thing. ReadLines is
        # lazy, and this bound is what keeps a hook cheap.
        [int]$MaxLines = 3000,
        [int]$MaxWords = 8
    )
    if (-not (Test-Path $TranscriptPath)) { return $null }

    $aiTitle = $null
    $firstHuman = $null

    $n = 0
    foreach ($line in [System.IO.File]::ReadLines($TranscriptPath)) {
        if (++$n -gt $MaxLines) { break }

        # Claude Code's own title. Keep scanning rather than returning: it is
        # rewritten as the thread develops, and the latest is the one the
        # human sees in the UI.
        if ($line -match '"type":"ai-title"') {
            try {
                $t = ($line | ConvertFrom-Json).aiTitle
                if ($t) { $aiTitle = [string]$t }
            } catch { }
            continue
        }

        # Cheap pre-filter before the expensive JSON parse.
        if ($line -notmatch '"role":"user"') { continue }
        if ($firstHuman) { continue }

        try { $obj = $line | ConvertFrom-Json } catch { continue }
        $content = $obj.message.content
        if (-not $content) { continue }

        # content is either a plain string or an array of typed blocks.
        $text = if ($content -is [string]) {
            $content
        } else {
            (@($content | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text })) -join ' '
        }
        if (-not $text) { continue }

        $text = Remove-IdeContextWrapper -Text $text
        if (Test-IsMachineTurn -Text $text) { continue }
        if ($text.Trim().Length -lt 3) { continue }

        $candidate = ConvertTo-SpokenTitle -Text $text -MaxWords $MaxWords
        if ($candidate) { $firstHuman = $candidate }
    }

    # Claude Code's own title wins whenever there is one. Titles are already
    # short phrases, but still capped so a long one cannot produce an
    # unbearable announcement.
    if ($aiTitle) { return (ConvertTo-SpokenTitle -Text $aiTitle -MaxWords 10 -MaxChars 60) }
    $firstHuman
}

Export-ModuleMember -Function Get-SessionTitle, ConvertTo-SpokenTitle, Remove-IdeContextWrapper, Test-IsMachineTurn
