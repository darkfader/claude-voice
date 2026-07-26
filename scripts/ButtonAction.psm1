# claude-voice/scripts/ButtonAction.psm1
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
            $idx = [array]::IndexOf($names, $Cursor)
            $next = $names[($idx + 1) % $names.Count]
            return @{ Action = 'select'; Account = $next; Speak = "$next selected" }
        }
        'long_press' {
            if (-not $Cursor -or $names -notcontains $Cursor) {
                return @{ Action = 'none'; Account = $null; Speak = 'Nothing selected' }
            }
            return @{ Action = 'confirm'; Account = $Cursor; Speak = $null }
        }
        'triple_press' {
            if (-not $Cursor -or $names -notcontains $Cursor) {
                return @{ Action = 'none'; Account = $null; Speak = 'Nothing selected' }
            }
            return @{ Action = 'dismiss'; Account = $Cursor; Speak = $null }
        }
    }
}

Export-ModuleMember -Function Get-ButtonAction
