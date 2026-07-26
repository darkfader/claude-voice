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
    $hue = (360.0 / $script:SlotCount) * ($Slot % $script:SlotCount)
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

Export-ModuleMember -Function Get-NormalisedProjectPath, Get-ProjectColorSlot, ConvertFrom-HueSlot, Resolve-SessionColorSlot, Get-SessionOrdinal, Get-SessionDisplayName
