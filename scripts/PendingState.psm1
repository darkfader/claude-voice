$script:StatePath = Join-Path $PSScriptRoot '..\state\pending.json'
$script:MutexName = 'Global\ClaudeVoicePendingState'

function Set-PendingStatePath {
    param([Parameter(Mandatory)][string]$Path)
    $script:StatePath = $Path
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

Export-ModuleMember -Function Set-PendingStatePath, Get-PendingState, Set-PendingAccount, Clear-PendingAccount, Set-PendingCursor
