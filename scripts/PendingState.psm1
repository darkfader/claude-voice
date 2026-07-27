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

function Set-PendingStatePath {
    param([Parameter(Mandatory)][string]$Path)
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
    # Atomic write (Fix 4, final review): write to a temp file in the SAME
    # directory, then swap it into place. The previous direct `Set-Content`
    # truncates the file and streams new content into it in place, so an
    # unlocked Get-PendingState reader (readers deliberately don't take the
    # lock -- only writers serialise against each other) landing mid-write
    # sees truncated/invalid JSON, which ConvertFrom-Json fails to parse,
    # which Get-PendingState then silently treats as an empty state -- a
    # reader can transiently believe nothing is pending while a session is
    # still waiting on the user.
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
    # [System.IO.File]::Replace uses the Win32 ReplaceFile API, which IS a
    # genuine atomic swap -- verified empirically with the same stress
    # harness (tens of thousands of concurrent reads during a background
    # write-storm, including 200KB payloads to widen the write window):
    # zero windows where the destination was missing or its content
    # invalid. It requires the destination to already exist, so the very
    # first write (file doesn't exist yet) falls back to a plain Move --
    # nothing exists yet to race a reader against in that case, and
    # Get-PendingState already treats "file doesn't exist" as legitimate
    # empty state.
    $tempPath = Join-Path $dir "pending.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $State | ConvertTo-Json -Depth 5 | Set-Content -Path $tempPath
        if (Test-Path $script:StatePath) {
            # [NullString]::Value, NOT a bare $null -- confirmed empirically
            # that PowerShell's method-argument binder coerces a bare $null
            # into an EMPTY STRING for this particular 3-arg overload, and
            # File.Replace then throws "The path is empty" for the backup
            # parameter even though passing no backup file is the whole
            # point of that argument being nullable.
            [System.IO.File]::Replace($tempPath, $script:StatePath, [NullString]::Value)
        } else {
            [System.IO.File]::Move($tempPath, $script:StatePath)
        }
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

function New-EmptyPendingState { @{ sessions = @{}; cursor = $null; activeSession = $null; activeSince = $null; displayedSession = $null } }

function Get-PendingState {
    if (-not (Test-Path $script:StatePath)) { return New-EmptyPendingState }

    # Fix 4 (final review) hardening: Save-PendingState's atomic swap
    # ([System.IO.File]::Replace) guarantees a reader never sees TORN
    # content, but it does not guarantee a concurrent OPEN call never
    # transiently collides with the swap in progress -- verified
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
    if ($state.cursor -and -not $state.sessions.ContainsKey($state.cursor)) { $state.cursor = $null }
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

Export-ModuleMember -Function Set-PendingStatePath, Set-PendingStateMutexName, Set-PendingStateExpiryHours, Get-PendingState, Set-PendingSession, Clear-PendingSession, Set-PendingCursor, Set-ActiveSession, Clear-ActiveSession, Set-DisplayedSession, Clear-DisplayedSession, Register-PendingNotification, Resolve-PendingSession, Invoke-WithPendingStateLock
