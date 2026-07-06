BeforeAll {
    # See Tests/Insurgency2014.Install.Tests.ps1 for why this Remove-Module
    # is needed: every plugin's Maps.psm1 shares the same bare module name.
    Remove-Module -Name 'Maps' -Force -ErrorAction SilentlyContinue
    Import-Module "$PSScriptRoot/../Plugins/Insurgency2014/Maps.psm1" -Force
}

Describe 'Plugins/Insurgency2014/Maps.psm1' {

    Context 'Get-Insurgency2014Maps' {
        It 'returns all 16 confirmed official stock maps' {
            $maps = Get-Insurgency2014Maps

            $maps.Count | Should -Be 16

            $expectedMaps = @(
                'market', 'siege', 'contact', 'uprising', 'ministry', 'district',
                'peak', 'heights', 'tell', 'sinjar', 'panj', 'buhriz', 'revolt',
                'station', 'drycanal', 'kandagal'
            )
            ($maps | Sort-Object) | Should -Be ($expectedMaps | Sort-Object)
        }
    }

    Context 'Test-Insurgency2014Map' {
        It 'returns $true for a known stock map, case-insensitively' {
            Test-Insurgency2014Map -MapName 'market' | Should -Be $true
            Test-Insurgency2014Map -MapName 'Market' | Should -Be $true
            Test-Insurgency2014Map -MapName 'MARKET' | Should -Be $true
        }

        It 'returns $true for every confirmed stock map' {
            foreach ($map in Get-Insurgency2014Maps) {
                Test-Insurgency2014Map -MapName $map | Should -Be $true -Because "map '$map' should validate"
            }
        }

        It 'returns $false for an unrecognized or Workshop map name' {
            Test-Insurgency2014Map -MapName 'some_custom_workshop_map' | Should -Be $false
        }

        It 'returns $false for a Sandstorm-only map name, not an Insurgency (2014) stock map' {
            Test-Insurgency2014Map -MapName 'precinct' | Should -Be $false
        }
    }
}
