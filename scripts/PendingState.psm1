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
    $State | ConvertTo-Json -Depth 5 | Set-Content $script:StatePath
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

function New-EmptyPendingState { @{ sessions = @{}; cursor = $null; activeSession = $null; activeSince = $null } }

function Get-PendingState {
    if (-not (Test-Path $script:StatePath)) { return New-EmptyPendingState }
    $raw = Get-Content $script:StatePath -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) { return New-EmptyPendingState }

    try { $state = $raw | ConvertFrom-Json -AsHashtable } catch { return New-EmptyPendingState }

    # A file from the old account-keyed format (or any other shape) is
    # runtime state, not data worth migrating -- treat it as empty rather
    # than letting one stale file wedge every future hook.
    if (-not $state -or -not $state.ContainsKey('sessions') -or $null -eq $state.sessions) {
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

Export-ModuleMember -Function Set-PendingStatePath, Set-PendingStateMutexName, Set-PendingStateExpiryHours, Get-PendingState, Set-PendingSession, Clear-PendingSession, Set-PendingCursor, Set-ActiveSession, Clear-ActiveSession
