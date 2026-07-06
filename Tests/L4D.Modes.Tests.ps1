BeforeAll {
    # See Tests/L4D.Install.Tests.ps1 for why this Remove-Module is needed:
    # every plugin's Modes.psm1 shares the same bare module name.
    Remove-Module -Name 'Modes' -Force -ErrorAction SilentlyContinue
    Import-Module "$PSScriptRoot/../Plugins/L4D/Modes.psm1" -Force
}

Describe 'Plugins/L4D/Modes.psm1' {

    Context 'Get-L4DModes' {
        It 'returns all 3 confirmed official game modes' {
            $modes = Get-L4DModes

            $modes.Count | Should -Be 3

            $expectedModes = @('coop', 'versus', 'survival')
            ($modes | Sort-Object) | Should -Be ($expectedModes | Sort-Object)
        }
    }

    Context 'Test-L4DMode' {
        It 'returns $true for a known mode, case-insensitively' {
            Test-L4DMode -ModeName 'versus' | Should -Be $true
            Test-L4DMode -ModeName 'Versus' | Should -Be $true
            Test-L4DMode -ModeName 'VERSUS' | Should -Be $true
        }

        It 'returns $true for every confirmed mode' {
            foreach ($mode in Get-L4DModes) {
                Test-L4DMode -ModeName $mode | Should -Be $true -Because "mode '$mode' should validate"
            }
        }

        It 'returns $false for an unrecognized mode name' {
            Test-L4DMode -ModeName 'scavenge' | Should -Be $false
        }

        It 'returns $false for Scavenge, which is Left 4 Dead 2-exclusive' {
            Test-L4DMode -ModeName 'scavenge' | Should -Be $false
        }
    }
}
