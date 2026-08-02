BeforeAll { Import-Module "$PSScriptRoot/WindowTyping.psm1" -Force }

Describe 'WindowTyping module surface' {
    It 'exports Set-WindowForeground and Send-TextToForeground' {
        $exported = (Get-Module WindowTyping).ExportedFunctions.Keys
        $exported | Should -Contain 'Set-WindowForeground'
        $exported | Should -Contain 'Send-TextToForeground'
    }
}

Describe 'ConvertTo-SendKeysLiteral' {
    It 'escapes percent signs' {
        ConvertTo-SendKeysLiteral -Text 'increase it by 50%' | Should -Be 'increase it by 50{%}'
    }
    It 'escapes parentheses' {
        ConvertTo-SendKeysLiteral -Text '(roughly)' | Should -Be '{(}roughly{)}'
    }
    It 'escapes plus, caret, and tilde' {
        ConvertTo-SendKeysLiteral -Text 'a+b^c~d' | Should -Be 'a{+}b{^}c{~}d'
    }
    It 'escapes brackets and braces' {
        ConvertTo-SendKeysLiteral -Text 'list[0] {x}' | Should -Be 'list{[}0{]} {{}x{}}'
    }
    It 'leaves plain text unchanged' {
        ConvertTo-SendKeysLiteral -Text 'hello world' | Should -Be 'hello world'
    }
    It 'handles empty string' {
        ConvertTo-SendKeysLiteral -Text '' | Should -Be ''
    }
}
