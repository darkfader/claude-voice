# claude-voice/scripts/SessionColor.Tests.ps1
BeforeAll { Import-Module "$PSScriptRoot/SessionColor.psm1" -Force }

Describe 'Get-NormalisedProjectPath' {
    It 'lowercases, converts separators, and strips a trailing slash' {
        Get-NormalisedProjectPath -Path 'C:\Users\darkf\git\HomeAssistant' |
            Should -Be 'c:/users/darkf/git/homeassistant'
        Get-NormalisedProjectPath -Path 'c:/users/darkf/git/homeassistant/' |
            Should -Be 'c:/users/darkf/git/homeassistant'
    }
}

Describe 'Get-ProjectColorSlot' {
    It 'is deterministic for the same path' {
        $a = Get-ProjectColorSlot -ProjectPath 'C:\git\Foo'
        $b = Get-ProjectColorSlot -ProjectPath 'C:\git\Foo'
        $a | Should -Be $b
    }
    It 'gives the same slot regardless of path spelling' {
        (Get-ProjectColorSlot -ProjectPath 'C:\Users\darkf\git\HomeAssistant') |
            Should -Be (Get-ProjectColorSlot -ProjectPath 'c:/users/darkf/git/homeassistant/')
    }
    It 'always returns a slot in range' {
        foreach ($p in @('C:\a','C:\b','C:\c','C:\some\deep\path','C:\x')) {
            $s = Get-ProjectColorSlot -ProjectPath $p
            $s | Should -BeGreaterOrEqual 0
            $s | Should -BeLessThan 16
        }
    }
}

Describe 'ConvertFrom-HueSlot' {
    It 'returns three bytes in range' {
        foreach ($slot in 0..15) {
            $rgb = ConvertFrom-HueSlot -Slot $slot
            $rgb.Count | Should -Be 3
            foreach ($c in $rgb) { $c | Should -BeGreaterOrEqual 0; $c | Should -BeLessOrEqual 255 }
        }
    }
    It 'slot 0 is red' { (ConvertFrom-HueSlot -Slot 0) | Should -Be @(255,0,0) }
    It 'gives visibly different colours for different slots' {
        (ConvertFrom-HueSlot -Slot 0) | Should -Not -Be (ConvertFrom-HueSlot -Slot 8)
    }
}

Describe 'Resolve-SessionColorSlot' {
    It 'uses the preferred slot when it is free' {
        $pref = Get-ProjectColorSlot -ProjectPath 'C:\git\Foo'
        Resolve-SessionColorSlot -ProjectPath 'C:\git\Foo' -TakenSlots @() | Should -Be $pref
    }
    It 'nudges to the next free slot when the preferred one is taken' {
        $pref = Get-ProjectColorSlot -ProjectPath 'C:\git\Foo'
        Resolve-SessionColorSlot -ProjectPath 'C:\git\Foo' -TakenSlots @($pref) |
            Should -Be (($pref + 1) % 16)
    }
    It 'skips over several taken slots' {
        $pref = Get-ProjectColorSlot -ProjectPath 'C:\git\Foo'
        $taken = @($pref, (($pref+1)%16), (($pref+2)%16))
        Resolve-SessionColorSlot -ProjectPath 'C:\git\Foo' -TakenSlots $taken |
            Should -Be (($pref + 3) % 16)
    }
    It 'falls back to the preferred slot when every slot is taken' {
        $pref = Get-ProjectColorSlot -ProjectPath 'C:\git\Foo'
        Resolve-SessionColorSlot -ProjectPath 'C:\git\Foo' -TakenSlots (0..15) | Should -Be $pref
    }
}

Describe 'Get-SessionOrdinal' {
    It 'is 1 when nothing is taken' { Get-SessionOrdinal -TakenOrdinals @() | Should -Be 1 }
    It 'is 2 when 1 is taken' { Get-SessionOrdinal -TakenOrdinals @(1) | Should -Be 2 }
    It 'fills a gap left by a departed session' { Get-SessionOrdinal -TakenOrdinals @(1,3) | Should -Be 2 }
}

Describe 'Get-SessionDisplayName' {
    It 'omits the ordinal for the first session' {
        Get-SessionDisplayName -Project 'HomeAssistant' -Ordinal 1 | Should -Be 'HomeAssistant'
    }
    It 'appends the ordinal for later sessions' {
        Get-SessionDisplayName -Project 'HomeAssistant' -Ordinal 2 | Should -Be 'HomeAssistant 2'
    }
}
