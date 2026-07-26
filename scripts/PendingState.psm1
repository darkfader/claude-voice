$script:StatePath = Join-Path $PSScriptRoot '..\state\pending.json'
$script:MutexName = 'Global\ClaudeVoicePendingState'

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

function Get-PendingState {
    if (-not (Test-Path $script:StatePath)) {
        return @{ accounts = @{}; cursor = $null }
    }
    $raw = Get-Content $script:StatePath -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @{ accounts = @{}; cursor = $null }
    }
    $raw | ConvertFrom-Json -AsHashtable
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

function Set-PendingAccount {
    param(
        [Parameter(Mandatory)][string]$Account,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$Message
    )
    Invoke-WithPendingStateLock {
        $state = Get-PendingState
        $state.accounts[$Account] = @{
            project = $Project
            message = $Message
            since   = (Get-Date).ToString('o')
        }
        Save-PendingState -State $state
    }
}

function Clear-PendingAccount {
    param([Parameter(Mandatory)][string]$Account)
    Invoke-WithPendingStateLock {
        $state = Get-PendingState
        $state.accounts.Remove($Account) | Out-Null
        if ($state.cursor -eq $Account) { $state.cursor = $null }
        Save-PendingState -State $state
    }
}

function Set-PendingCursor {
    param([Parameter(Mandatory)][string]$Account)
    Invoke-WithPendingStateLock {
        $state = Get-PendingState
        $state.cursor = $Account
        Save-PendingState -State $state
    }
}

Export-ModuleMember -Function Set-PendingStatePath, Set-PendingStateMutexName, Get-PendingState, Set-PendingAccount, Clear-PendingAccount, Set-PendingCursor
