# Register-PendingNotification (below) calls Resolve-SessionColorSlot /
# Get-SessionOrdinal / ConvertFrom-HueSlot from SessionColor.psm1, but this
# module DELIBERATELY does not `Import-Module` it itself -- the caller must
# import SessionColor.psm1 before calling Register-PendingNotification (both
# ha-bridge.ps1 and notify-ha.ps1 already do, and so must any test file that
# exercises it). See RingDisplay.psm1's top comment for why: a nested
# `Import-Module -Force` here could fork a second, orphaned module instance
# rather than reusing whichever one the caller already has loaded.

$script:StatePath = Join-Path $PSScriptRoot '..\state\pending.json'
$script:MutexName = 'Global\ClaudeVoicePendingState'
$script:ExpiryHours = 4

# `known` expires on a much longer clock than `sessions`, and mostly does not
# rely on the clock at all.
#
# A pending session is "waiting on you right now", so a few hours is the right
# staleness bound. A KNOWN session is "a thread you could switch to", and that
# stays true for as long as the thread exists -- a session you left this
# morning is still resumable this evening, and dropping it off the ring after
# four hours was just wrong.
#
# The real signal is the transcript file: Claude Code writes one per session,
# so its absence means the session was genuinely deleted, not merely quiet.
# That is what actually retires an entry. The 24h clock is only a backstop for
# entries whose transcript path was never recorded.
$script:KnownExpiryHours = 24

function Set-KnownExpiryHours {
    param([Parameter(Mandatory)][double]$Hours)
    $script:KnownExpiryHours = $Hours
}

# Idle-fade: a known session that hasn't been touched in this long loses its
# ring slot and colour (both set to $null) but stays in `known` -- it still
# shows in the VS Code threads list, just with no ring presence. This is what
# actually frees slots for other sessions; a thread you're still "in" keeps
# its slot indefinitely (see KnownExpiryHours/transcript-deletion above),
# but with only 12 physical ring positions, a thread nobody has touched in an
# hour should give its slot back.
$script:KnownIdleFadeHours = 1

function Set-KnownIdleFadeHours {
    param([Parameter(Mandatory)][double]$Hours)
    $script:KnownIdleFadeHours = $Hours
}

# Hard expiry: unlike KnownExpiryHours (a backstop for entries with no
# transcript path, effectively never fires otherwise), this ALWAYS removes
# the entry once idle this long, transcript or no. A thread untouched for two
# days is not "still resumable tonight" territory any more.
$script:KnownHardExpiryHours = 48

function Set-KnownHardExpiryHours {
    param([Parameter(Mandatory)][double]$Hours)
    $script:KnownHardExpiryHours = $Hours
}

function Set-PendingStatePath {
    param([Parameter(Mandatory)][string]$Path)
    # Deliberately NOT resolved to an absolute path here. $script:StatePath
    # is consumed exclusively via .NET path APIs now (File.Move, File.Exists
    # in the strengthened atomicity test) rather than PowerShell cmdlets, and
    # .NET resolves a relative path against [Environment]::CurrentDirectory,
    # which silently diverges from PowerShell's own $PWD the moment anything
    # does a provider-level `cd`/`Set-Location` without also calling
    # [Environment]::CurrentDirectory = ... to match. Every current caller
    # (the production default above, `..\state\pending.json` relative to
    # $PSScriptRoot which Join-Path already resolves absolute, and every
    # test via Pester's $TestDrive, which is itself an absolute path) already
    # passes an absolute path, so this has never actually bitten anything --
    # left as a documented caller contract rather than defensively resolved,
    # so a future relative-path caller fails loudly (wrong file, easy to
    # spot) instead of silently succeeding today and only breaking once some
    # unrelated code elsewhere changes the process's current directory.
    $script:StatePath = $Path
}

# Test seam, mirroring Set-PendingStatePath. The default mutex name is
# process-wide-shared by design -- that's the whole point in production, where
# concurrent Claude Code hooks in different processes must serialise writes to
# pending.json. But it means a test suite that takes the real mutex also blocks
# live hooks, and live hooks can make the suite fail spuriously by holding the
# mutex when a test expects to. Tests point this at a unique throwaway name so
# the two never contend.
function Set-PendingStateMutexName {
    param([Parameter(Mandatory)][string]$Name)
    $script:MutexName = $Name
}

function Save-PendingState {
    param([hashtable]$State)
    $dir = Split-Path $script:StatePath -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    # Atomic write (Fix 4, final review; corrected in a later final-review
    # pass -- see below). Write to a temp file in the SAME directory, then
    # swap it into place. The previous direct `Set-Content` truncates the
    # file and streams new content into it in place, so an unlocked
    # Get-PendingState reader (readers deliberately don't take the lock --
    # only writers serialise against each other) landing mid-write sees
    # truncated/invalid JSON, which ConvertFrom-Json fails to parse, which
    # Get-PendingState then silently treats as an empty state -- a reader
    # can transiently believe nothing is pending while a session is still
    # waiting on the user.
    #
    # `Move-Item -Force` was tried first and REJECTED after empirical
    # testing: it is NOT atomic on this system. A stress test (background
    # writer looping Move-Item -Force while the foreground polled
    # Test-Path) showed the destination file transiently MISSING in ~18%
    # of ~30,000 checks -- Move-Item -Force apparently deletes the
    # destination before moving the source into place rather than doing a
    # single atomic rename. That reproduces the exact bug this fix exists
    # to close (a reader believing nothing is pending), just relocated from
    # "invalid JSON" to "file doesn't exist yet" as the trigger --
    # Get-PendingState's `if (-not (Test-Path ...)) { return
    # New-EmptyPendingState }` guard treats a momentarily-missing file
    # exactly like a legitimately-absent one.
    #
    # `[System.IO.File]::Replace` (Win32 ReplaceFile) was tried next and
    # SHIPPED as the fix -- but a LATER, higher-volume stress probe (direct
    # `[System.IO.File]::Exists` polling in a tight loop against a
    # background writer, ~100k samples per run, rather than probing through
    # Get-PendingState) found it is NOT actually atomic either: the
    # destination was transiently MISSING in 5.45% of one run and 5.71% of
    # another. ReplaceFile with a NULL backup renames the destination OUT
    # before renaming the replacement IN, leaving a real window where the
    # file doesn't exist -- which lands on the exact same
    # `if (-not (Test-Path ...)) { return New-EmptyPendingState }` guard
    # this fix exists to defeat. (The comment that used to live here claimed
    # "zero windows where the destination was missing" -- that was measured
    # by probing THROUGH Get-PendingState, whose own retry loop and repeated
    # file-handle opens happened to phase-shift the sampling window away
    # from the writer and masked the gap. Probing Test-Path/File.Exists
    # directly, with nothing else in between, is what actually surfaces it.)
    #
    # `[System.IO.File]::Move($tempPath, $script:StatePath, $true)` --
    # MoveFileEx with MOVEFILE_REPLACE_EXISTING -- is the current
    # implementation. Verified empirically with the same direct-Exists
    # stress harness: 0 misses out of 99,773 samples. It also succeeds when
    # the destination does not exist yet, so unlike File.Replace it needs no
    # separate first-write fallback (and the [NullString]::Value workaround
    # File.Replace's backup-path argument required no longer applies).
    $tempPath = Join-Path $dir "pending.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $State | ConvertTo-Json -Depth 5 | Set-Content -Path $tempPath
        [System.IO.File]::Move($tempPath, $script:StatePath, $true)
    } finally {
        if (Test-Path $tempPath) { Remove-Item -Path $tempPath -Force -ErrorAction SilentlyContinue }
    }
}

function Invoke-WithPendingStateLock {
    param([scriptblock]$Body)
    $mutex = New-Object System.Threading.Mutex($false, $script:MutexName)
    $acquired = $false
    try {
        if (-not $mutex.WaitOne(5000)) {
            throw "Timed out waiting for pending-state lock"
        }
        $acquired = $true
        & $Body
    } finally {
        if ($acquired) {
            $mutex.ReleaseMutex()
        }
    }
}

function Set-PendingStateExpiryHours {
    param([Parameter(Mandatory)][double]$Hours)
    $script:ExpiryHours = $Hours
}

function New-EmptyPendingState { @{ sessions = @{}; known = @{}; cursor = $null; activeSession = $null; activeSince = $null; displayedSession = $null } }

function Get-PendingState {
    if (-not (Test-Path $script:StatePath)) { return New-EmptyPendingState }

    # Fix 4 (final review) hardening: Save-PendingState's atomic swap
    # ([System.IO.File]::Move with MOVEFILE_REPLACE_EXISTING) guarantees a
    # reader never sees TORN content, but it does not guarantee a
    # concurrent OPEN call never transiently collides with the swap in
    # progress -- verified
    # empirically under a tight write/read stress loop, where a single-shot
    # unretried Get-Content routinely failed with a sharing violation
    # ("being used by another process") purely from timing, not corruption.
    # Get-Content's failure here is NON-terminating by default, so without
    # -ErrorAction Stop it would silently leave $raw empty/null and fall
    # through to `New-EmptyPendingState` below -- i.e. the exact "reader
    # believes nothing is pending" bug this whole fix exists to close,
    # just relocated one line down. A short bounded retry absorbs the
    # transient case; a genuinely missing/corrupt file still falls through
    # to empty state exactly as before, unchanged from prior behaviour.
    # 40 attempts * 5ms = a 200ms budget -- empirically zero failures across
    # several thousand reads racing a writer on a realistic ~2-5ms cadence
    # (real hooks write once and exit; even rapid button/dial events are
    # milliseconds apart, not a zero-delay loop). An adversarial writer that
    # NEVER pauses can still occasionally exhaust this budget -- that residual
    # is accepted, not chased further: it degrades to the same "treated as
    # empty" fallback already established for corrupt/old-format files, every
    # caller already wraps state reads in try/catch, and no real hook-firing
    # pattern sustains that kind of unbroken write pressure.
    $raw = $null
    $maxAttempts = 40
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            $raw = Get-Content $script:StatePath -Raw -ErrorAction Stop
            break
        } catch {
            if ($attempt -eq $maxAttempts) { return New-EmptyPendingState }
            Start-Sleep -Milliseconds 5
        }
    }
    if ([string]::IsNullOrWhiteSpace($raw)) { return New-EmptyPendingState }

    try { $state = $raw | ConvertFrom-Json -AsHashtable } catch { return New-EmptyPendingState }

    # A file from the old account-keyed format (or any other shape) is
    # runtime state, not data worth migrating -- treat it as empty rather
    # than letting one stale file wedge every future hook. `-isnot
    # [System.Collections.IDictionary]` closes the gap where `{"sessions":
    # []}` passed this guard as written: an empty JSON array deserialises to
    # an Object[], not a dictionary, and the very next `.ContainsKey` call
    # anywhere in this module throws -- wedging every hook that reads state,
    # exactly what this guard exists to prevent.
    if (-not $state -or -not $state.ContainsKey('sessions') -or $null -eq $state.sessions -or
        $state.sessions -isnot [System.Collections.IDictionary]) {
        return New-EmptyPendingState
    }

    # Expire stale entries on read. A terminal closed while Claude was
    # waiting never fires a clearing hook, so without this an abandoned
    # session would sit in the dial rotation forever.
    $cutoff = (Get-Date).AddHours(-1 * $script:ExpiryHours)
    foreach ($id in @($state.sessions.Keys)) {
        [datetime]$since = [datetime]::MinValue
        if ([datetime]::TryParse($state.sessions[$id].since, [ref]$since)) {
            if ($since -lt $cutoff) { $state.sessions.Remove($id) | Out-Null }
        }
    }
    # `known` outlives `sessions`: the dial cycles every session seen
    # recently, not just the ones currently waiting on the user, or it would
    # be inert whenever fewer than two things are pending -- strictly worse
    # than the volume knob it replaces. Defaulted rather than migrated: a
    # pending.json written before this field existed is runtime state, not
    # data worth preserving. Must be defaulted BEFORE the cursor check
    # below, which dereferences it.
    if (-not $state.ContainsKey('known') -or $null -eq $state.known -or
        $state.known -isnot [System.Collections.IDictionary]) {
        $state.known = @{}
    }
    foreach ($id in @($state.known.Keys)) {
        # Defaults for entries written before these fields existed. Runtime
        # state, so defaulted rather than migrated -- same reasoning as the
        # `known` map itself.
        if (-not $state.known[$id].ContainsKey('activity') -or -not $state.known[$id].activity) {
            $state.known[$id].activity = 'idle'
        }
        if (-not $state.known[$id].ContainsKey('activitySince') -or -not $state.known[$id].activitySince) {
            $state.known[$id].activitySince = $state.known[$id].lastSeen
        }
        if (-not $state.known[$id].ContainsKey('ringSlot') -or $null -eq $state.known[$id].ringSlot) {
            $state.known[$id].ringSlot = Resolve-RingSlot -ProjectPath ([string]$state.known[$id].cwd)
        }
        # A thread must ALWAYS have a visible colour. A missing, short or
        # all-zero colour renders as black -- i.e. the thread silently
        # vanishes from the ring while still occupying an LED, which looks
        # exactly like a bug and is impossible to diagnose by eye. Recompute
        # from the project path, which is what a fresh registration would
        # have produced anyway.
        $col = @($state.known[$id].color)
        if ($col.Count -lt 3 -or (($col | Measure-Object -Sum).Sum -eq 0)) {
            $state.known[$id].color = ConvertFrom-HueSlot -Slot (
                Resolve-SessionColorSlot -ProjectPath ([string]$state.known[$id].cwd))
        }
        # Idle basis for both new rules below: time since the session's last
        # hook activity, regardless of activity state or transcript
        # existence.
        [datetime]$lastSeenAt = [datetime]::MinValue
        [void][datetime]::TryParse([string]$state.known[$id].lastSeen, [ref]$lastSeenAt)

        # Hard expiry: 48h idle removes the entry ALWAYS, transcript or not.
        # Checked first and unconditionally -- this is the one rule that
        # overrides "keep forever if transcript exists" below. A thread
        # untouched for two days is gone from the ring regardless of whether
        # its transcript file still happens to exist on disk.
        if ($lastSeenAt -ne [datetime]::MinValue -and
            $lastSeenAt -lt (Get-Date).AddHours(-1 * $script:KnownHardExpiryHours)) {
            $state.known.Remove($id) | Out-Null
            continue
        }

        # Idle-fade: 1h idle releases the ring slot and colour (both set to
        # $null) so Resolve-RingSlot/Resolve-SessionColorSlot can hand them
        # to another session, but the entry itself stays in `known` -- it
        # still shows in the VS Code threads list. Only touches fields that
        # are not already $null, so this is a no-op on every read after the
        # first fade.
        if ($lastSeenAt -ne [datetime]::MinValue -and
            $lastSeenAt -lt (Get-Date).AddHours(-1 * $script:KnownIdleFadeHours) -and
            ($null -ne $state.known[$id].ringSlot -or $null -ne $state.known[$id].slot -or
             $null -ne $state.known[$id].color)) {
            $state.known[$id].ringSlot = $null
            $state.known[$id].slot     = $null
            $state.known[$id].color    = $null
        }

        # Retire on DELETION, not on silence. Claude Code writes a transcript
        # file per session, so its absence is the real "this thread is gone"
        # signal -- far better than guessing from a clock. A session you left
        # this morning is still resumable tonight and belongs on the ring, up
        # to the 48h hard expiry above; one whose transcript you deleted does
        # not, however recently you used it.
        $transcript = [string]$state.known[$id].transcriptPath
        if ($transcript) {
            if (-not (Test-Path -LiteralPath $transcript)) {
                $state.known.Remove($id) | Out-Null
            }
            continue
        }

        # Backstop only, for entries registered before a transcript path was
        # recorded (or by a hook payload that omitted it). 24h, not 4. Fires
        # strictly before the 48h hard expiry above would for this same
        # subset of entries, so it remains the operative rule for them.
        [datetime]$seen = [datetime]::MinValue
        if ([datetime]::TryParse($state.known[$id].lastSeen, [ref]$seen)) {
            if ($seen -lt (Get-Date).AddHours(-1 * $script:KnownExpiryHours)) {
                $state.known.Remove($id) | Out-Null
            }
        }
    }

    # Widened to `known` (was `sessions` only). The cursor now legitimately
    # points at sessions that are merely known -- that is the whole point of
    # the dial being a session switcher rather than a pending-list switcher
    # -- so validating against the pending map alone would erase the dial's
    # position on every single read.
    if ($state.cursor -and -not $state.sessions.ContainsKey($state.cursor) -and
        -not $state.known.ContainsKey($state.cursor)) { $state.cursor = $null }
    if (-not $state.ContainsKey('activeSession')) { $state.activeSession = $null }
    if (-not $state.ContainsKey('activeSince'))   { $state.activeSince = $null }
    # Deliberately NOT reset to $null when it no longer matches a live
    # session (unlike cursor above) -- displayedSession's whole purpose
    # (Fix 3, final review) is to keep tracking what the physical ring is
    # showing even after the session it names has left `sessions` (resolved
    # elsewhere, or expired by the read-time cutoff above). Invoke-IdleCheck
    # is what notices the mismatch and turns the ring off; if this getter
    # nulled it out first, that orphan would become undetectable.
    if (-not $state.ContainsKey('displayedSession')) { $state.displayedSession = $null }
    $state
}

function Set-PendingSession {
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$Cwd,
        [AllowEmptyString()][string]$Message = '',
        [Parameter(Mandatory)][int[]]$Color,
        [Parameter(Mandatory)][int]$Slot,
        [Parameter(Mandatory)][int]$Ordinal
    )
    Invoke-WithPendingStateLock {
        $state = Get-PendingState
        $state.sessions[$SessionId] = @{
            project = $Project
            cwd     = $Cwd
            message = $Message
            color   = $Color
            slot    = $Slot
            ordinal = $Ordinal
            since   = (Get-Date).ToString('o')
        }
        Save-PendingState -State $state
    }
}

function Clear-PendingSession {
    param([Parameter(Mandatory)][string]$SessionId)
    Invoke-WithPendingStateLock {
        $state = Get-PendingState
        $state.sessions.Remove($SessionId) | Out-Null
        if ($state.cursor -eq $SessionId) { $state.cursor = $null }
        Save-PendingState -State $state
    }
}

function Set-PendingCursor {
    param([Parameter(Mandatory)][string]$SessionId)
    Invoke-WithPendingStateLock {
        $state = Get-PendingState
        $state.cursor = $SessionId
        Save-PendingState -State $state
    }
}

function Set-ActiveSession {
    param([Parameter(Mandatory)][string]$SessionId)
    Invoke-WithPendingStateLock {
        $state = Get-PendingState
        $state.activeSession = $SessionId
        $state.activeSince   = (Get-Date).ToString('o')
        Save-PendingState -State $state
    }
}

function Clear-ActiveSession {
    Invoke-WithPendingStateLock {
        $state = Get-PendingState
        $state.activeSession = $null
        $state.activeSince   = $null
        Save-PendingState -State $state
    }
}

function Set-DisplayedSession {
    param([Parameter(Mandatory)][string]$SessionId)
    Invoke-WithPendingStateLock {
        $state = Get-PendingState
        $state.displayedSession = $SessionId
        Save-PendingState -State $state
    }
}

function Clear-DisplayedSession {
    Invoke-WithPendingStateLock {
        $state = Get-PendingState
        $state.displayedSession = $null
        Save-PendingState -State $state
    }
}

function Register-KnownSession {
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$Cwd,
        # Pid of the window this session runs inside (VS Code, Windows
        # Terminal, ...), resolved by the hook walking its own process tree.
        # Refreshed on every registration, not just the first: the session
        # outlives its window if the editor is restarted, and a stale pid
        # would focus nothing or, worse, whatever process reused the number.
        [int]$WindowPid = 0,
        # Short spoken name derived from the session's opening message. Set
        # once, on first registration: it describes what the thread is about,
        # which does not change, and re-deriving it per hook would both cost a
        # transcript read every time and risk the name drifting mid-session.
        [AllowEmptyString()][string]$Title = '',
        # What the thread is doing, derived by the caller from which hook
        # fired. Refreshed on every registration -- unlike title and ringSlot,
        # this is the field that is meant to change.
        [ValidateSet('idle','working','attention')][string]$Activity = 'idle',
        # Path to Claude Code's transcript for this session. Refreshed every
        # registration, because it is the liveness signal: once recorded, the
        # entry is retired when this file disappears rather than on a timer.
        [AllowEmptyString()][string]$TranscriptPath = ''
    )
    Invoke-WithPendingStateLock {
        $state = Get-PendingState
        $now   = (Get-Date).ToString('o')
        if ($state.known.ContainsKey($SessionId)) {
            $state.known[$SessionId].lastSeen = $now
            if ($WindowPid -gt 0) { $state.known[$SessionId].windowPid = $WindowPid }
            # Backfill only. Claude Code generates its title a few turns in, so
            # a session registered on its very first hook has none yet; once
            # set, it is left alone so the spoken name cannot drift mid-thread.
            if ($Title -and -not $state.known[$SessionId].title) {
                $state.known[$SessionId].title = $Title
            }
            $state.known[$SessionId].activity      = $Activity
            $state.known[$SessionId].activitySince = $now
            if ($TranscriptPath) { $state.known[$SessionId].transcriptPath = $TranscriptPath }
        } else {
            # Nudge against every OTHER known session's slot. Without this,
            # two sessions in the same folder hash to the same slot and are
            # indistinguishable on the ring -- which defeats the dial, since
            # colour is the only thing identifying what you have selected.
            # The first session in a project still gets that project's base
            # colour (stable across restarts, as required); only siblings are
            # pushed off it, and the hue slots are golden-angle spaced so a
            # nudged sibling is obviously a different colour, not a near-miss.
            $takenSlots = @($state.known.Values | Where-Object { $null -ne $_.slot } | ForEach-Object { $_.slot })
            $slot = Resolve-SessionColorSlot -ProjectPath $Cwd -TakenSlots $takenSlots
            $ords = @($state.known.Values | Where-Object { $_.project -eq $Project } | ForEach-Object { $_.ordinal })
            $takenRing = @($state.known.Values | Where-Object { $null -ne $_.ringSlot } | ForEach-Object { $_.ringSlot })
            $ringSlot  = Resolve-RingSlot -ProjectPath $Cwd -TakenSlots $takenRing
            $state.known[$SessionId] = @{
                project       = $Project
                cwd           = $Cwd
                color         = ConvertFrom-HueSlot -Slot $slot
                slot          = $slot
                ordinal       = Get-SessionOrdinal -TakenOrdinals $ords
                windowPid     = $WindowPid
                title         = $Title
                firstSeen     = $now
                lastSeen      = $now
                ringSlot       = $ringSlot
                activity       = $Activity
                activitySince  = $now
                transcriptPath = $TranscriptPath
            }
        }
        Save-PendingState -State $state
    }
}

function Register-PendingNotification {
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$Cwd,
        [AllowEmptyString()][string]$Message = ''
    )
    # Compound mutator (Fix 4, final review). notify-ha.ps1 used to read
    # $before, then derive othersCount / taken-slots / ordinal OUTSIDE any
    # lock, and only take the lock later and separately inside
    # Set-PendingSession. Two hooks firing at the same instant could both
    # read othersCount=0 (both take the ring and announce) and both resolve
    # the SAME colour slot -- defeating the collision-avoidance that is the
    # whole point of slot resolution. Doing the read, the slot/ordinal
    # derivation, and the write inside one lock acquisition closes that
    # window. System.Threading.Mutex is reentrant for the owning thread, so
    # nesting calls to the already-locking Set-PendingSession/
    # Set-PendingCursor below is safe and still just one critical section.
    Invoke-WithPendingStateLock {
        $state = Get-PendingState
        $othersCount = @($state.sessions.Keys | Where-Object { $_ -ne $SessionId }).Count
        if (-not $state.sessions.ContainsKey($SessionId)) {
            # Filter out entries with no slot recorded (e.g. a stale or
            # hand-edited entry) before letting [int[]] coerce them -- a
            # bare $null coerces to 0, which would spuriously mark slot 0
            # taken forever.
            $taken   = @($state.sessions.Values | Where-Object { $null -ne $_.slot } | ForEach-Object { $_.slot })
            $slot    = Resolve-SessionColorSlot -ProjectPath $Cwd -TakenSlots $taken
            $ords    = @($state.sessions.Values | Where-Object { $_.project -eq $Project } | ForEach-Object { $_.ordinal })
            $ordinal = Get-SessionOrdinal -TakenOrdinals $ords
            $rgb     = ConvertFrom-HueSlot -Slot $slot
            Set-PendingSession -SessionId $SessionId -Project $Project -Cwd $Cwd -Message $Message -Color $rgb -Slot $slot -Ordinal $ordinal
            if ($othersCount -eq 0) { Set-PendingCursor -SessionId $SessionId }
        }
        [PSCustomObject]@{ OthersCount = $othersCount }
    }
}

function Resolve-PendingSession {
    param([Parameter(Mandatory)][string]$SessionId)
    # Compound mutator (Fix 4, final review): clear the resolved session,
    # mark it active (drives the dim ambient indicator/idle timer), and
    # count what's left -- all as one locked critical section, so the
    # OthersCount handed to Get-NotifyPlan can never be stale relative to a
    # concurrent hook's write landing in between the clear and the count.
    Invoke-WithPendingStateLock {
        Clear-PendingSession -SessionId $SessionId
        Set-ActiveSession    -SessionId $SessionId
        $state = Get-PendingState
        [PSCustomObject]@{ OthersCount = $state.sessions.Count }
    }
}

Export-ModuleMember -Function Set-PendingStatePath, Set-KnownExpiryHours, Set-KnownIdleFadeHours, Set-KnownHardExpiryHours, Set-PendingStateMutexName, Set-PendingStateExpiryHours, Get-PendingState, Set-PendingSession, Clear-PendingSession, Set-PendingCursor, Set-ActiveSession, Clear-ActiveSession, Set-DisplayedSession, Clear-DisplayedSession, Register-KnownSession, Register-PendingNotification, Resolve-PendingSession, Invoke-WithPendingStateLock
