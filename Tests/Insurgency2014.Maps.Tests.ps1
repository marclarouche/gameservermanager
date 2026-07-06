BeforeAll {
    # See Tests/Insurgency2014.Install.Tests.ps1 for why this Remove-Module
    # is needed: every plugin's Maps.psm1 shares the same bare module name.
    Remove-Module -Name 'Maps' -Force -ErrorAction SilentlyContinue
    Import-Module "$PSScriptRoot/../Plugins/Insurgency2014/Maps.psm1" -Force

    function New-FakeGSMRootForMaps {
        $root = Join-Path $TestDrive ('insurgency2014-maps-root-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $root 'Config') -Force | Out-Null
        return $root
    }
}

Describe 'Plugins/Insurgency2014/Maps.psm1' {

    BeforeEach {
        # Isolate every test from the real (gitignored) Config/CustomMaps.json:
        # by default the fake root has no CustomMaps.json at all, so custom-map
        # behavior is opt-in per test via Set-Content below.
        $script:FakeRoot = New-FakeGSMRootForMaps
        Mock -ModuleName Maps -CommandName Get-GSMRootPath -MockWith { $script:FakeRoot }
        Mock -ModuleName Maps -CommandName Write-GSMLog -MockWith { }
    }

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

    Context 'Test-Insurgency2014Map - Config/CustomMaps.json' {
        It 'falls back to the official list only when CustomMaps.json does not exist' {
            Test-Insurgency2014Map -MapName 'coop_custommap' | Should -Be $false
        }

        It 'accepts a custom map registered under this plugin''s own key, case-insensitively' {
            @{
                Insurgency2014      = @('coop_custommap')
                TeamFortress2       = @()
                CounterStrikeSource = @()
                L4D                 = @()
                L4D2                = @()
            } | ConvertTo-Json | Set-Content -Path (Join-Path $script:FakeRoot 'Config/CustomMaps.json')

            Test-Insurgency2014Map -MapName 'coop_custommap' | Should -Be $true
            Test-Insurgency2014Map -MapName 'COOP_CUSTOMMAP' | Should -Be $true
        }

        It 'falls back to the official list when this plugin''s key is missing from the file' {
            @{ TeamFortress2 = @('some_tf2_map') } | ConvertTo-Json | Set-Content -Path (Join-Path $script:FakeRoot 'Config/CustomMaps.json')

            Test-Insurgency2014Map -MapName 'coop_custommap' | Should -Be $false
        }

        It 'falls back to the official list when this plugin''s key is present but empty' {
            @{ Insurgency2014 = @() } | ConvertTo-Json | Set-Content -Path (Join-Path $script:FakeRoot 'Config/CustomMaps.json')

            Test-Insurgency2014Map -MapName 'coop_custommap' | Should -Be $false
        }

        It 'only reads its own key and ignores other games'' custom map entries' {
            @{
                Insurgency2014      = @()
                TeamFortress2       = @('koth_some_tf2_map')
                CounterStrikeSource = @('cs_some_css_map')
                L4D                 = @('l4d_some_map')
                L4D2                = @('l4d2_some_map')
            } | ConvertTo-Json | Set-Content -Path (Join-Path $script:FakeRoot 'Config/CustomMaps.json')

            Test-Insurgency2014Map -MapName 'koth_some_tf2_map' | Should -Be $false
            Test-Insurgency2014Map -MapName 'cs_some_css_map' | Should -Be $false
            Test-Insurgency2014Map -MapName 'l4d_some_map' | Should -Be $false
            Test-Insurgency2014Map -MapName 'l4d2_some_map' | Should -Be $false

            # Still validates its own official maps normally.
            Test-Insurgency2014Map -MapName 'market' | Should -Be $true
        }

        It 'falls back to the official list and logs a warning when CustomMaps.json is malformed' {
            Set-Content -Path (Join-Path $script:FakeRoot 'Config/CustomMaps.json') -Value '{ not valid json ]'

            Test-Insurgency2014Map -MapName 'market' | Should -Be $true
            Test-Insurgency2014Map -MapName 'coop_custommap' | Should -Be $false

            Should -Invoke -ModuleName Maps -CommandName Write-GSMLog -Times 1 -ParameterFilter { $Level -eq 'Warning' }
        }
    }
}
