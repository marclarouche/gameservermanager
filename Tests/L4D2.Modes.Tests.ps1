BeforeAll {
    # See Tests/L4D2.Install.Tests.ps1 for why this Remove-Module is needed:
    # every plugin's Modes.psm1 shares the same bare module name.
    Remove-Module -Name 'Modes' -Force -ErrorAction SilentlyContinue
    Import-Module "$PSScriptRoot/../Plugins/L4D2/Modes.psm1" -Force
}

Describe 'Plugins/L4D2/Modes.psm1' {

    Context 'Get-L4D2Modes' {
        It 'returns all 5 confirmed stable game modes' {
            $modes = Get-L4D2Modes

            $modes.Count | Should -Be 5

            $expectedModes = @('coop', 'realism', 'survival', 'versus', 'scavenge')
            ($modes | Sort-Object) | Should -Be ($expectedModes | Sort-Object)
        }
    }

    Context 'Test-L4D2Mode' {
        It 'returns $true for a known mode, case-insensitively' {
            Test-L4D2Mode -ModeName 'versus' | Should -Be $true
            Test-L4D2Mode -ModeName 'Versus' | Should -Be $true
            Test-L4D2Mode -ModeName 'VERSUS' | Should -Be $true
        }

        It 'returns $true for every confirmed mode' {
            foreach ($mode in Get-L4D2Modes) {
                Test-L4D2Mode -ModeName $mode | Should -Be $true -Because "mode '$mode' should validate"
            }
        }

        It 'returns $true for Scavenge and Realism, which are Left 4 Dead 2-exclusive' {
            Test-L4D2Mode -ModeName 'scavenge' | Should -Be $true
            Test-L4D2Mode -ModeName 'realism' | Should -Be $true
        }

        It 'returns $false for an unrecognized mode name' {
            Test-L4D2Mode -ModeName 'deathmatch' | Should -Be $false
        }

        It 'returns $false for the numbered Mutation slots that back Realism Versus and Versus Survival' {
            Test-L4D2Mode -ModeName 'mutation12' | Should -Be $false
            Test-L4D2Mode -ModeName 'mutation15' | Should -Be $false
        }

        It 'returns $false for friendly names of graduated Mutation modes not exposed as their own mp_gamemode value' {
            Test-L4D2Mode -ModeName 'realismversus' | Should -Be $false
            Test-L4D2Mode -ModeName 'versussurvival' | Should -Be $false
        }
    }
}
