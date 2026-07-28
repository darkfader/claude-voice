# claude-voice/scripts/RingState.psm1
#
# Turns the known-session map into the compact string the firmware renders.
# Pure: every display decision worth testing (precedence, the cap, the
# working expiry, colour formatting) lives here and is testable with no
# device attached. The firmware renders exactly what it is told and makes
# no decisions of its own.
#
# Encoding, one group per thread, semicolons between:
#   <ringSlot>,<rrggbb>,<state>     e.g.  3,dfff00,w;7,80ff00,i
# States: i idle, w working, s selected, a attention, A arriving.

# Lower number sorts first, i.e. survives the cap.
# A plain @{} literal won't do here: PowerShell hashtables (both the literal
# and runtime indexer assignment) compare string keys case-INsensitively by
# default, so 'A' and 'a' collide -- verified empirically, `@{ 'A' = 0;
# 'a' = 1 }` is a parse-time "Duplicate keys" error. State codes 'A'
# (arriving) and 'a' (attention) must stay distinct, so this uses a
# Dictionary[string,int], whose default comparer is ordinal case-sensitive.
$script:StatePriority = [System.Collections.Generic.Dictionary[string,int]]::new()
$script:StatePriority['A'] = 0
$script:StatePriority['a'] = 1
$script:StatePriority['s'] = 2
$script:StatePriority['w'] = 3
$script:StatePriority['i'] = 4

function ConvertTo-RingHex {
    param([Parameter(Mandatory)][int[]]$Rgb)
    '{0:x2}{1:x2}{2:x2}' -f $Rgb[0], $Rgb[1], $Rgb[2]
}

function Get-RingStateString {
    param(
        [Parameter(Mandatory)][hashtable]$KnownSessions,
        [string]$Cursor,
        [string]$ArrivingSessionId,
        [datetime]$Now = (Get-Date),
        [int]$WorkingExpiryMinutes = 30,
        [int]$MaxThreads = 12
    )
    if ($KnownSessions.Count -eq 0) { return '' }

    $rows = @()
    foreach ($id in $KnownSessions.Keys) {
        $e = $KnownSessions[$id]
        if ($null -eq $e.ringSlot) { continue }

        $activity = [string]$e.activity
        if (-not $activity) { $activity = 'idle' }

        # A crashed terminal never fires Stop. Without this the dot orbits
        # forever. Deliberately applies to `working` only -- something waiting
        # on you stays waiting however long you ignore it.
        if ($activity -eq 'working') {
            [datetime]$since = [datetime]::MinValue
            if ([datetime]::TryParse([string]$e.activitySince, [ref]$since)) {
                if ($since -lt $Now.AddMinutes(-1 * $WorkingExpiryMinutes)) { $activity = 'idle' }
            }
        }

        # Precedence: attention > selected > working > idle. Resolved here,
        # never in firmware, so it stays unit-testable off-device.
        $state = switch ($activity) {
            'attention' { 'a' }
            'working'   { 'w' }
            default     { 'i' }
        }
        if ($state -ne 'a' -and $Cursor -and $id -eq $Cursor) { $state = 's' }
        if ($ArrivingSessionId -and $id -eq $ArrivingSessionId) { $state = 'A' }

        [datetime]$seen = [datetime]::MinValue
        [void][datetime]::TryParse([string]$e.lastSeen, [ref]$seen)

        $rows += [PSCustomObject]@{
            Slot     = [int]$e.ringSlot
            Hex      = ConvertTo-RingHex -Rgb @($e.color)
            State    = $state
            Priority = $script:StatePriority[$state]
            LastSeen = $seen
        }
    }
    if ($rows.Count -eq 0) { return '' }

    # Cap by interest, then draw in slot order so the string reads around the
    # ring rather than in priority order.
    $kept = @($rows | Sort-Object Priority, @{ Expression = 'LastSeen'; Descending = $true } |
        Select-Object -First $MaxThreads)

    (@($kept | Sort-Object Slot | ForEach-Object { '{0},{1},{2}' -f $_.Slot, $_.Hex, $_.State }) -join ';')
}

Export-ModuleMember -Function Get-RingStateString, ConvertTo-RingHex
