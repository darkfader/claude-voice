# claude-voice/scripts/SessionTitle.Tests.ps1
BeforeAll {
    Import-Module "$PSScriptRoot/SessionTitle.psm1" -Force
}

Describe 'ConvertTo-SpokenTitle' {
    It 'keeps a short question intact apart from trailing punctuation' {
        ConvertTo-SpokenTitle -Text 'I have a Home Assistant Voice. What can I do with it?' |
            Should -Be 'I have a Home Assistant Voice'
    }

    It 'truncates to the word limit' {
        $t = ConvertTo-SpokenTitle -Text 'one two three four five six seven eight nine ten' -MaxWords 4
        $t | Should -Be 'one two three four'
    }

    It 'hard-caps pathological input with no sentence break' {
        $t = ConvertTo-SpokenTitle -Text ('x' * 300) -MaxChars 20
        $t.Length | Should -BeLessOrEqual 20
    }

    It 'collapses newlines and repeated whitespace' {
        ConvertTo-SpokenTitle -Text "fix   the`n`n bridge please" -MaxWords 8 |
            Should -Be 'fix the bridge please'
    }

    It 'returns empty for empty input' {
        ConvertTo-SpokenTitle -Text '' | Should -Be ''
    }
}

Describe 'Remove-IdeContextWrapper' {
    It 'strips a complete ide block and keeps the human text' {
        $raw = '<ide_selection>The user selected lines 3 to 3</ide_selection>I want them to be different colors'
        Remove-IdeContextWrapper -Text $raw | Should -Be 'I want them to be different colors'
    }

    It 'strips an unterminated ide block' {
        # Observed live: a session whose opening turn was an ide_opened_file
        # block produced the title "The user opened the file Untitled-1".
        $raw = 'real question here<ide_opened_file>The user opened the file Untitled-1 in the IDE. This'
        Remove-IdeContextWrapper -Text $raw | Should -Be 'real question here'
    }
}

Describe 'Test-IsMachineTurn' {
    It 'rejects task notifications and system reminders' {
        Test-IsMachineTurn -Text '<task-notification>x</task-notification>' | Should -BeTrue
        Test-IsMachineTurn -Text '[SYSTEM NOTIFICATION - NOT USER INPUT]'   | Should -BeTrue
        Test-IsMachineTurn -Text '<command-name>/loop</command-name>'       | Should -BeTrue
    }

    It 'accepts a genuine human turn' {
        Test-IsMachineTurn -Text 'can you fix the dial' | Should -BeFalse
    }
}

Describe 'Get-SessionTitle' {
    BeforeEach {
        $script:t = Join-Path $TestDrive "t-$([guid]::NewGuid().ToString('N')).jsonl"
    }

    It 'returns the first genuine human message' {
        @(
            '{"type":"user","message":{"role":"user","content":"<task-notification>noise</task-notification>"}}'
            '{"type":"assistant","message":{"role":"assistant","content":"hi"}}'
            '{"type":"user","message":{"role":"user","content":"I have a Home Assistant Voice. What can I do?"}}'
            '{"type":"user","message":{"role":"user","content":"later message"}}'
        ) | Set-Content -Path $script:t
        Get-SessionTitle -TranscriptPath $script:t | Should -Be 'I have a Home Assistant Voice'
    }

    It 'skips an ide-context-only opening turn and finds the real one' {
        @(
            '{"type":"user","message":{"role":"user","content":"<ide_opened_file>The user opened Untitled-1</ide_opened_file>"}}'
            '{"type":"user","message":{"role":"user","content":"fix the charger automation"}}'
        ) | Set-Content -Path $script:t
        Get-SessionTitle -TranscriptPath $script:t | Should -Be 'fix the charger automation'
    }

    It 'handles content given as typed blocks rather than a string' {
        @(
            '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"pair the zigbee bulb"}]}}'
        ) | Set-Content -Path $script:t
        Get-SessionTitle -TranscriptPath $script:t | Should -Be 'pair the zigbee bulb'
    }

    It 'returns null for a missing transcript' {
        Get-SessionTitle -TranscriptPath (Join-Path $TestDrive 'nope.jsonl') | Should -BeNullOrEmpty
    }

    It 'returns null when the transcript holds only machine turns' {
        @(
            '{"type":"user","message":{"role":"user","content":"<task-notification>a</task-notification>"}}'
            '{"type":"user","message":{"role":"user","content":"[SYSTEM NOTIFICATION - NOT USER INPUT]"}}'
        ) | Set-Content -Path $script:t
        Get-SessionTitle -TranscriptPath $script:t | Should -BeNullOrEmpty
    }

    It 'stops reading after MaxLines so a huge transcript stays cheap' {
        # 11 MB transcripts are normal here; an unbounded read would make
        # every hook pay for the whole file.
        $lines = 1..50 | ForEach-Object { '{"type":"user","message":{"role":"user","content":"<task-notification>n</task-notification>"}}' }
        $lines += '{"type":"user","message":{"role":"user","content":"the real question"}}'
        $lines | Set-Content -Path $script:t
        Get-SessionTitle -TranscriptPath $script:t -MaxLines 10 | Should -BeNullOrEmpty
        Get-SessionTitle -TranscriptPath $script:t -MaxLines 100 | Should -Be 'the real question'
    }
}

Describe 'Get-SessionTitle prefers Claude Code ai-title' {
    BeforeEach {
        $script:t2 = Join-Path $TestDrive "ai-$([guid]::NewGuid().ToString('N')).jsonl"
    }

    It 'uses aiTitle over the first human message' {
        @(
            '{"type":"user","message":{"role":"user","content":"I have a Home Assistant Voice. What can I do?"}}'
            '{"type":"ai-title","aiTitle":"Explore Home Assistant Voice capabilities","sessionId":"abc"}'
        ) | Set-Content -Path $script:t2
        Get-SessionTitle -TranscriptPath $script:t2 | Should -Be 'Explore Home Assistant Voice capabilities'
    }

    It 'uses the LAST aiTitle, since it is rewritten as the thread develops' {
        @(
            '{"type":"ai-title","aiTitle":"Early guess","sessionId":"abc"}'
            '{"type":"ai-title","aiTitle":"Explore Home Assistant Voice capabilities","sessionId":"abc"}'
        ) | Set-Content -Path $script:t2
        Get-SessionTitle -TranscriptPath $script:t2 | Should -Be 'Explore Home Assistant Voice capabilities'
    }

    It 'falls back to the first human message when not yet titled' {
        @(
            '{"type":"user","message":{"role":"user","content":"pair the zigbee bulb please"}}'
        ) | Set-Content -Path $script:t2
        Get-SessionTitle -TranscriptPath $script:t2 | Should -Be 'pair the zigbee bulb please'
    }
}
