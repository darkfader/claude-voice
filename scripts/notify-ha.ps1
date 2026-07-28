# claude-voice/scripts/notify-ha.ps1
param(
    [Parameter(Mandatory)][ValidateSet('notification','stop','clear')][string]$Event,
    [Parameter(ValueFromPipeline = $true)][object]$InputObject
)

# Nothing below may ever throw out of this script: it runs as a Claude Code
# hook, and a non-zero exit would surface as a hook failure in the user's
# session. Belt and braces -- the try/catch below plus this trap.
trap { Write-Warning "notify-ha.ps1 trapped: $_"; exit 0 }

function Get-PayloadValue {
    param($Payload, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Payload) { return $null }
    # A hashtable's dictionary entries are NOT PSObject properties, so the
    # two shapes need different access paths.
    if ($Payload -is [System.Collections.IDictionary]) { return $Payload[$Name] }
    $prop = $Payload.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    $null
}

try {
    Import-Module (Join-Path $PSScriptRoot 'PendingState.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'HaClient.psm1')     -Force
    Import-Module (Join-Path $PSScriptRoot 'NotifyPlan.psm1')   -Force
    Import-Module (Join-Path $PSScriptRoot 'SessionColor.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'RingDisplay.psm1')  -Force
    Import-Module (Join-Path $PSScriptRoot 'WindowFocus.psm1')  -Force
    Import-Module (Join-Path $PSScriptRoot 'SessionTitle.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'RingState.psm1')    -Force

    # --- read the hook payload -------------------------------------------------
    $payload = $null
    if ($InputObject) {
        if ($InputObject -is [string]) { try { $payload = $InputObject | ConvertFrom-Json } catch { } }
        else { $payload = $InputObject }
    }
    if (-not $payload) {
        try {
            if ([Console]::IsInputRedirected) {
                $stdin = [Console]::In.ReadToEnd()
                if ($stdin) { $payload = $stdin | ConvertFrom-Json }
            }
        } catch { }
    }

    $sessionId = Get-PayloadValue -Payload $payload -Name 'session_id'
    $cwd       = Get-PayloadValue -Payload $payload -Name 'cwd'
    $message   = [string](Get-PayloadValue -Payload $payload -Name 'message')

    # Fall back to the working directory so a notification is never lost outright
    # just because a payload field was missing.
    if (-not $cwd)       { $cwd = (Get-Location).Path }
    if (-not $sessionId) { $sessionId = 'cwd:' + (Get-NormalisedProjectPath -Path $cwd) }
    $project = Split-Path $cwd -Leaf

    $before    = Get-PendingState
    # Captured BEFORE the switch mutates state: for stop/clear the entry is gone
    # by the time we need its colour/ordinal, and recomputing is not equivalent --
    # Resolve-SessionColorSlot without -TakenSlots can pick a different slot than
    # the one originally assigned, so the dim ambient colour would not match what
    # was shown while the session was pending. Reading this session's OWN entry
    # ahead of the lock is not the race Fix 4 closes -- only one hook process
    # ever writes a given session_id's entry, so there is no concurrent writer
    # to race against here.
    $prevEntry = $before.sessions[$sessionId]

    # --- local bookkeeping first, before any network call --------------------
    # Doing this ahead of the kill-switch check means toggling the switch off
    # can never strand an entry that can then never be cleared.
    #
    # Fix 4 (final review): $othersCount, and for 'notification' the colour
    # slot/ordinal, all now come from a single locked critical section in
    # PendingState.psm1 (Register-PendingNotification / Resolve-PendingSession)
    # instead of being derived here from an unlocked $before read and applied
    # later inside a separately-locked setter. Two hooks firing at once could
    # previously both read othersCount=0 (both take the ring) and both resolve
    # the same colour slot -- defeating the collision-avoidance the whole
    # design exists for.
    # Every event registers the session as known, including 'stop' and
    # 'clear'. The dial cycles KNOWN sessions, not pending ones, so a session
    # you have merely typed in has to be reachable -- not only one that is
    # currently waiting on you. Runs before the kill-switch check for the same
    # reason the pending bookkeeping does: local state should stay accurate
    # even while notifications are switched off.
    # Resolve the window THIS session lives in by walking up from this hook
    # process. Only the session itself can know this -- the bridge runs in a
    # different tree entirely -- which is why it is captured here and stored,
    # rather than searched for at focus time. Window titles were tried first
    # and are not usable: VS Code names the window after the workspace, which
    # often is not the project folder (see WindowFocus.psm1).
    $windowPid = 0
    try {
        $resolved = Get-OwningWindowPid
        if ($resolved) { $windowPid = [int]$resolved }
    } catch { }

    # Claude Code's own title for this thread ("Explore Home Assistant Voice
    # capabilities"), read from the transcript the hook payload points at.
    # Far more use than "HomeAssistant 2" when the device says it aloud.
    $title = ''
    try {
        $transcript = Get-PayloadValue -Payload $payload -Name 'transcript_path'
        if ($transcript) {
            $derived = Get-SessionTitle -TranscriptPath $transcript
            if ($derived) { $title = [string]$derived }
        }
    } catch { }

    # The three wired hooks already carry activity -- no new signal needed.
    # UserPromptSubmit ('clear') means a turn just started, Stop means it
    # finished, Notification means it is waiting on the human.
    $activity = switch ($Event) {
        'notification' { 'attention' }
        'clear'        { 'working' }
        default        { 'idle' }
    }
    Register-KnownSession -SessionId $sessionId -Project $project -Cwd $cwd -WindowPid $windowPid -Title $title -Activity $activity

    $othersCount = 0
    switch ($Event) {
        'notification' {
            $result = Register-PendingNotification -SessionId $sessionId -Project $project -Cwd $cwd -Message $message
            $othersCount = $result.OthersCount
        }
        'stop'  {
            # Also marks this the active session: 'stop' lights the ring dim,
            # and Invoke-IdleCheck fades based on activeSession/activeSince.
            # Without this the dim ring a finished turn leaves behind has no
            # timer attached and would glow indefinitely -- the exact
            # overnight-glow case the idle timeout exists to prevent.
            $result = Resolve-PendingSession -SessionId $sessionId
            $othersCount = $result.OthersCount
        }
        'clear' {
            $result = Resolve-PendingSession -SessionId $sessionId
            $othersCount = $result.OthersCount
        }
    }

    $after   = Get-PendingState
    # Prefer the still-pending entry; fall back to the one just cleared (stop/clear
    # always land here since the switch above already removed it) rather than
    # recomputing, which would drop -TakenSlots collision-avoidance and could show
    # a colour that never matched what was actually displayed while pending.
    $entry   = if ($after.sessions.ContainsKey($sessionId)) { $after.sessions[$sessionId] } else { $prevEntry }
    $ordinal = if ($entry) { $entry.ordinal } else { 1 }
    $rgb     = if ($entry) { $entry.color } else { (ConvertFrom-HueSlot -Slot (Resolve-SessionColorSlot -ProjectPath $cwd)) }
    # Prefer Claude Code's thread title in spoken announcements too, so the
    # device says "Explore Home Assistant Voice capabilities needs input"
    # rather than "HomeAssistant 2 needs input".
    $display = if ($title) { $title } else { Get-SessionDisplayName -Project $project -Ordinal $ordinal }

    $conn = Get-HaConnection
    if (-not (Test-HaNotificationsEnabled -Connection $conn)) { exit 0 }

    $muted = if ($Event -eq 'notification') { Test-HaMuted -Connection $conn } else { $false }
    $plan  = Get-NotifyPlan -Event $Event -DisplayName $display -Message $message -Muted $muted -OtherPendingCount $othersCount

    switch ($plan.Led.Action) {
        'set' {
            # 255 = a session needs you; 100 = the dim ambient "you're working
            # here" marker. The GAP between them is load-bearing: both states
            # use the same per-session colour, so brightness is the only thing
            # distinguishing them. Ambient must stay clearly below pending --
            # much above ~140 and the two become hard to tell apart at a
            # glance. (Was 60, raised to 100: at 24% a mid-hue read as a murky
            # smudge rather than a colour.)
            $brightness = if ($plan.Led.Bright) { 255 } else { 100 }
            Invoke-HaLed -Connection $conn -Rgb $rgb -Brightness $brightness -Flash:$plan.Led.Flash | Out-Null
            Set-DisplayedSession -SessionId $sessionId
        }
        'off'  { Invoke-HaLed -Connection $conn -Off | Out-Null; Clear-DisplayedSession }
        'none' {
            # Fix 2 (final review), spec Notification precedence rule 3
            # (Resolved): if replying/stopping resolved this session and
            # others are still pending, the ring must move to the oldest
            # remaining one, solid at full brightness, no flash -- it is a
            # hand-off, not a new arrival. Get-NotifyPlan stays pure and has
            # no notion of *other* sessions' colours, so its 'none' here
            # covers two different real outcomes: rule 2 (a second
            # notification must leave the ring strictly alone) and rule 3
            # (a resolution with survivors, which this hook -- the only
            # place that knows both "did something resolve" and "what else
            # is pending" -- must actively act on). Only stop/clear reach
            # rule 3; a second notification must never trigger this branch.
            #
            # Later final-review pass: Test-ShouldHandOffRing (RingDisplay.psm1)
            # additionally requires that THIS session was the one actually
            # displayed ($before.displayedSession, read before the switch
            # above mutated state) -- otherwise an unrelated session's
            # stop/clear could steal the ring away from whatever the user
            # had just selected with the dial, even though nothing about
            # what was on display actually resolved. See that function's
            # comment for the full scenario this closes.
            if (Test-ShouldHandOffRing -Event $Event -OthersCount $othersCount -DisplayedSession $before.displayedSession -SessionId $sessionId) {
                Set-RemainingLed -Connection $conn
            }
        }
    }

    switch ($plan.Sound) {
        'chime'    { Invoke-HaChime    -Connection $conn | Out-Null }
        'announce' { Invoke-HaAnnounce -Connection $conn -Text $plan.AnnounceText | Out-Null }
    }

    # Push the whole-ring picture last, after every state mutation above has
    # landed, so the string reflects final state rather than an intermediate.
    # 'A' (arriving) is sent only for a genuinely new notification -- it is
    # what makes the firmware run its 2s whole-ring flash, and repeating it on
    # every hook would re-flash the ring constantly.
    try {
        $ringState = Get-PendingState
        $arriving = if ($Event -eq 'notification' -and $plan.Led.Flash) { $sessionId } else { $null }
        $ringValue = Get-RingStateString -KnownSessions $ringState.known -Cursor $ringState.cursor -ArrivingSessionId $arriving
        Invoke-HaRingState -Connection $conn -Value $ringValue | Out-Null
    } catch {
        Write-Warning "ring state publish failed (non-fatal): $_"
    }
} catch {
    Write-Warning "notify-ha.ps1 failed non-fatally: $_"
}

exit 0
