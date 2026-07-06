BeforeAll {
    # See Tests/Insurgency2014.Install.Tests.ps1 for why this Remove-Module
    # is needed: every plugin's Modes.psm1 shares the same bare module name.
    Remove-Module -Name 'Modes' -Force -ErrorAction SilentlyContinue
    Import-Module "$PSScriptRoot/../Plugins/Insurgency2014/Modes.psm1" -Force
}

Describe 'Plugins/Insurgency2014/Modes.psm1' {

    Context 'Get-Insurgency2014Modes' {
        It 'returns all 13 confirmed game modes' {
            $modes = Get-Insurgency2014Modes

            $modes.Count | Should -Be 13

            $expectedModes = @(
                'checkpoint', 'push', 'firefight', 'skirmish', 'ambush', 'strike',
                'occupy', 'elimination', 'conquer', 'hunt', 'outpost', 'survival',
                'flashpoint'
            )
            ($modes | Sort-Object) | Should -Be ($expectedModes | Sort-Object)
        }
    }

    Context 'Test-Insurgency2014Mode' {
        It 'returns $true for a known mode, case-insensitively' {
            Test-Insurgency2014Mode -ModeName 'checkpoint' | Should -Be $true
            Test-Insurgency2014Mode -ModeName 'Checkpoint' | Should -Be $true
            Test-Insurgency2014Mode -ModeName 'CHECKPOINT' | Should -Be $true
        }

        It 'returns $true for every confirmed mode' {
            foreach ($mode in Get-Insurgency2014Modes) {
                Test-Insurgency2014Mode -ModeName $mode | Should -Be $true -Because "mode '$mode' should validate"
            }
        }

        It 'returns $false for an unrecognized mode name' {
            Test-Insurgency2014Mode -ModeName 'battle_royale' | Should -Be $false
        }

        It 'returns $false for the internal "coop" map-file suffix, which is not itself a mode identity' {
            Test-Insurgency2014Mode -ModeName 'coop' | Should -Be $false
        }
    }
}
