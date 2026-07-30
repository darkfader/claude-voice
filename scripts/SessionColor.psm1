# claude-voice/scripts/SessionColor.psm1
# Colours must be BOTH stable (a project looks the same every day, so it is
# learnable) and distinct (two sessions pending at once must never look
# alike). A pure hash gives the first, arrival-order assignment gives the
# second. Quantising into fixed slots and nudging on collision gives both.
$script:SlotCount = 16

function Get-NormalisedProjectPath {
    param([Parameter(Mandatory)][string]$Path)
    (($Path -replace '\\', '/').TrimEnd('/')).ToLowerInvariant()
}

function Get-ProjectColorSlot {
    param([Parameter(Mandatory)][string]$ProjectPath)
    # SHA256, NOT String.GetHashCode(): .NET Core randomises string hashing
    # per process, so GetHashCode would give a different colour every run --
    # exactly the instability this design exists to avoid.
    $norm = Get-NormalisedProjectPath -Path $ProjectPath
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($norm)) }
    finally { $sha.Dispose() }
    [int]([BitConverter]::ToUInt32($bytes, 0) % [uint32]$script:SlotCount)
}

function ConvertFrom-HueSlot {
    param([Parameter(Mandatory)][int]$Slot)
    # Full saturation and value, so sessions read as distinct hues rather
    # than as shades that are hard to tell apart on a small ring.
    #
    # The slot is SCATTERED around the wheel rather than mapped linearly.
    # Linear mapping put consecutive slots 22.5 degrees apart, and
    # Resolve-SessionColorSlot resolves a collision by taking the NEXT slot --
    # so two threads in the same project reliably ended up on adjacent hues.
    # Observed live: three sessions in one repo rendered as 223,255,0 /
    # 128,255,0 / 32,255,0, three near-identical greens, which defeats the
    # entire point of colour-as-identity.
    #
    # 5 is coprime with 16, so slot -> hue stays a bijection: every slot still
    # gets its own hue, each slot's hue is still fixed forever, but successive
    # slots now land 112.5 degrees apart instead of 22.5.
    $scattered = ($Slot * 5) % $script:SlotCount
    $hue = (360.0 / $script:SlotCount) * $scattered
    $x = 1.0 - [math]::Abs((($hue / 60.0) % 2.0) - 1.0)
    switch ([int][math]::Floor($hue / 60.0)) {
        0       { $r = 1.0; $g = $x;  $b = 0.0 }
        1       { $r = $x;  $g = 1.0; $b = 0.0 }
        2       { $r = 0.0; $g = 1.0; $b = $x  }
        3       { $r = 0.0; $g = $x;  $b = 1.0 }
        4       { $r = $x;  $g = 0.0; $b = 1.0 }
        default { $r = 1.0; $g = 0.0; $b = $x  }
    }
    @([int][math]::Round($r * 255), [int][math]::Round($g * 255), [int][math]::Round($b * 255))
}

function Resolve-SessionColorSlot {
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [int[]]$TakenSlots = @()
    )
    $preferred = Get-ProjectColorSlot -ProjectPath $ProjectPath
    for ($i = 0; $i -lt $script:SlotCount; $i++) {
        $candidate = ($preferred + $i) % $script:SlotCount
        if ($TakenSlots -notcontains $candidate) { return $candidate }
    }
    # Everything taken (16+ pending). Repeat rather than fail; the spoken
    # name is the identifier at that point anyway.
    $preferred
}

$script:RingSlotCount = 12

function Resolve-RingSlot {
    <#
    .SYNOPSIS
    A thread's home position on the 12-LED ring, 0-11.

    .DESCRIPTION
    Separate from the hue slot deliberately. Hue is mod 16, position is mod
    12, and the two are nudged against different occupancy sets -- deriving
    one from the other would couple a thread's colour to how many threads
    happen to share the ring.

    Same hashing as Resolve-SessionColorSlot: SHA256, never String.GetHashCode,
    because .NET Core randomises string hashing per process and a thread's
    seat must survive a restart.
    #>
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [int[]]$TakenSlots = @()
    )
    $norm = Get-NormalisedProjectPath -Path $ProjectPath
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($norm)) } finally { $sha.Dispose() }
    $base = [int]([BitConverter]::ToUInt32($bytes, 0) % [uint32]$script:RingSlotCount)

    if ($TakenSlots -notcontains $base) { return $base }
    for ($i = 1; $i -lt $script:RingSlotCount; $i++) {
        $candidate = ($base + $i) % $script:RingSlotCount
        if ($TakenSlots -notcontains $candidate) { return $candidate }
    }
    # Every seat taken. The encoder caps the drawn list at twelve, so this
    # thread simply will not be drawn; returning the base keeps the value
    # deterministic instead of erroring in a hook.
    $base
}

function Get-SessionOrdinal {
    param([int[]]$TakenOrdinals = @())
    $n = 1
    while ($TakenOrdinals -contains $n) { $n++ }
    $n
}

function Get-SessionDisplayName {
    param([Parameter(Mandatory)][string]$Project, [int]$Ordinal = 1)
    if ($Ordinal -le 1) { $Project } else { "$Project $Ordinal" }
}

Export-ModuleMember -Function Get-NormalisedProjectPath, Get-ProjectColorSlot, ConvertFrom-HueSlot, Resolve-SessionColorSlot, Resolve-RingSlot, Get-SessionOrdinal, Get-SessionDisplayName
