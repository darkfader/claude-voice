# claude-voice/scripts/ButtonAction.psm1
function Get-DialCycleTarget {
    param(
        [Parameter(Mandatory)][hashtable]$PendingAccounts,
        [string]$Cursor
    )
    $names = @($PendingAccounts.Keys | Sort-Object)
    if ($names.Count -eq 0) { return $null }
    $idx = [array]::IndexOf($names, $Cursor)
    $names[($idx + 1) % $names.Count]
}

function Get-ButtonAction {
    param(
        [Parameter(Mandatory)][ValidateSet('double_press','long_press','triple_press','easter_egg_press')]
        [string]$EventType,
        [Parameter(Mandatory)][hashtable]$PendingAccounts,
        [string]$Cursor
    )
    $names = @($PendingAccounts.Keys | Sort-Object)

    if ($EventType -eq 'easter_egg_press') {
        return @{ Action = 'none'; Account = $null; Speak = $null }
    }

    if ($names.Count -eq 0) {
        return @{ Action = 'none'; Account = $null; Speak = 'Nothing pending' }
    }

    switch ($EventType) {
        'double_press' {
            $next = Get-DialCycleTarget -PendingAccounts $PendingAccounts -Cursor $Cursor
            return @{ Action = 'select'; Account = $next; Speak = "$next selected" }
        }
        'long_press' {
            $effectiveCursor = $Cursor
            if ((-not $effectiveCursor -or $names -notcontains $effectiveCursor) -and $names.Count -eq 1) {
                $effectiveCursor = $names[0]
            }
            if (-not $effectiveCursor -or $names -notcontains $effectiveCursor) {
                return @{ Action = 'none'; Account = $null; Speak = 'Nothing selected' }
            }
            return @{ Action = 'confirm'; Account = $effectiveCursor; Speak = $null }
        }
        'triple_press' {
            $effectiveCursor = $Cursor
            if ((-not $effectiveCursor -or $names -notcontains $effectiveCursor) -and $names.Count -eq 1) {
                $effectiveCursor = $names[0]
            }
            if (-not $effectiveCursor -or $names -notcontains $effectiveCursor) {
                return @{ Action = 'none'; Account = $null; Speak = 'Nothing selected' }
            }
            return @{ Action = 'dismiss'; Account = $effectiveCursor; Speak = $null }
        }
    }
}

Export-ModuleMember -Function Get-ButtonAction, Get-DialCycleTarget
