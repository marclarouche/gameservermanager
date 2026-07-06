BeforeAll {
    # See Tests/CounterStrikeSource.Install.Tests.ps1 for why this
    # Remove-Module is needed: every plugin's Modes.psm1 shares the same
    # bare module name.
    Remove-Module -Name 'Modes' -Force -ErrorAction SilentlyContinue
    Import-Module "$PSScriptRoot/../Plugins/CounterStrikeSource/Modes.psm1" -Force
}

Describe 'Plugins/CounterStrikeSource/Modes.psm1' {

    Context 'Get-CounterStrikeSourceModes' {
        It 'returns both confirmed official objective types' {
            $modes = Get-CounterStrikeSourceModes

            $modes.Count | Should -Be 2

            $expectedModes = @('bomb-defusal', 'hostage-rescue')
            ($modes | Sort-Object) | Should -Be ($expectedModes | Sort-Object)
        }
    }

    Context 'Test-CounterStrikeSourceMode' {
        It 'returns $true for a known mode, case-insensitively' {
            Test-CounterStrikeSourceMode -ModeName 'bomb-defusal' | Should -Be $true
            Test-CounterStrikeSourceMode -ModeName 'Bomb-Defusal' | Should -Be $true
            Test-CounterStrikeSourceMode -ModeName 'BOMB-DEFUSAL' | Should -Be $true
        }

        It 'returns $true for every confirmed mode' {
            foreach ($mode in Get-CounterStrikeSourceModes) {
                Test-CounterStrikeSourceMode -ModeName $mode | Should -Be $true -Because "mode '$mode' should validate"
            }
        }

        It 'returns $false for an unrecognized mode name' {
            Test-CounterStrikeSourceMode -ModeName 'assassination' | Should -Be $false
        }
    }
}
