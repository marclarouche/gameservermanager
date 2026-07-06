BeforeAll {
    # See Tests/L4D.Install.Tests.ps1 for why this Remove-Module is needed:
    # every plugin's Maps.psm1 shares the same bare module name.
    Remove-Module -Name 'Maps' -Force -ErrorAction SilentlyContinue
    Import-Module "$PSScriptRoot/../Plugins/L4D/Maps.psm1" -Force

    function New-FakeGSMRootForMaps {
        $root = Join-Path $TestDrive ('l4d-maps-root-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $root 'Config') -Force | Out-Null
        return $root
    }
}

Describe 'Plugins/L4D/Maps.psm1' {

    BeforeEach {
        # Isolate every test from the real (gitignored) Config/CustomMaps.json:
        # by default the fake root has no CustomMaps.json at all, so custom-map
        # behavior is opt-in per test via Set-Content below.
        $script:FakeRoot = New-FakeGSMRootForMaps
        Mock -ModuleName Maps -CommandName Get-GSMRootPath -MockWith { $script:FakeRoot }
        Mock -ModuleName Maps -CommandName Write-GSMLog -MockWith { }
    }

    Context 'Get-L4DMaps' {
        It 'returns all 22 official campaign maps' {
            $maps = Get-L4DMaps

            $maps.Count | Should -Be 22

            $expectedMaps = @(
                'l4d_hospital01_apartment', 'l4d_hospital02_subway', 'l4d_hospital03_sewers',
                'l4d_hospital04_interior', 'l4d_hospital05_rooftop',
                'l4d_garage01_alleys', 'l4d_garage02_lots',
                'l4d_smalltown01_caves', 'l4d_smalltown02_drainage', 'l4d_smalltown03_ranchhouse',
                'l4d_smalltown04_mainstreet', 'l4d_smalltown05_houseboat',
                'l4d_airport01_greenhouse', 'l4d_airport02_offices', 'l4d_airport03_garage',
                'l4d_airport04_terminal', 'l4d_airport05_runway',
                'l4d_farm01_hilltop', 'l4d_farm02_traintunnel', 'l4d_farm03_bridge',
                'l4d_farm04_barn', 'l4d_farm05_cornfield'
            )
            ($maps | Sort-Object) | Should -Be ($expectedMaps | Sort-Object)
        }
    }

    Context 'Test-L4DMap' {
        It 'returns $true for a known stock map, case-insensitively' {
            Test-L4DMap -MapName 'l4d_hospital01_apartment' | Should -Be $true
            Test-L4DMap -MapName 'L4D_Hospital01_Apartment' | Should -Be $true
            Test-L4DMap -MapName 'L4D_HOSPITAL01_APARTMENT' | Should -Be $true
        }

        It 'returns $true for every confirmed official campaign map' {
            foreach ($map in Get-L4DMaps) {
                Test-L4DMap -MapName $map | Should -Be $true -Because "map '$map' should validate"
            }
        }

        It 'returns $false for an unrecognized or custom-campaign map name' {
            Test-L4DMap -MapName 'some_custom_campaign_map' | Should -Be $false
        }
    }

    Context 'Test-L4DMap - Config/CustomMaps.json' {
        It 'falls back to the official list only when CustomMaps.json does not exist' {
            Test-L4DMap -MapName 'l4d_custom01_map' | Should -Be $false
        }

        It 'accepts a custom map registered under this plugin''s own key, case-insensitively' {
            @{
                Insurgency2014      = @()
                TeamFortress2       = @()
                CounterStrikeSource = @()
                L4D                 = @('l4d_custom01_map')
                L4D2                = @()
            } | ConvertTo-Json | Set-Content -Path (Join-Path $script:FakeRoot 'Config/CustomMaps.json')

            Test-L4DMap -MapName 'l4d_custom01_map' | Should -Be $true
            Test-L4DMap -MapName 'L4D_CUSTOM01_MAP' | Should -Be $true
        }

        It 'falls back to the official list when this plugin''s key is missing from the file' {
            @{ Insurgency2014 = @('coop_custommap') } | ConvertTo-Json | Set-Content -Path (Join-Path $script:FakeRoot 'Config/CustomMaps.json')

            Test-L4DMap -MapName 'l4d_custom01_map' | Should -Be $false
        }

        It 'falls back to the official list when this plugin''s key is present but empty' {
            @{ L4D = @() } | ConvertTo-Json | Set-Content -Path (Join-Path $script:FakeRoot 'Config/CustomMaps.json')

            Test-L4DMap -MapName 'l4d_custom01_map' | Should -Be $false
        }

        It 'only reads its own key and ignores other games'' custom map entries' {
            @{
                Insurgency2014      = @('coop_custommap')
                TeamFortress2       = @('koth_some_tf2_map')
                CounterStrikeSource = @('cs_some_css_map')
                L4D                 = @()
                L4D2                = @('l4d2_some_map')
            } | ConvertTo-Json | Set-Content -Path (Join-Path $script:FakeRoot 'Config/CustomMaps.json')

            Test-L4DMap -MapName 'coop_custommap' | Should -Be $false
            Test-L4DMap -MapName 'koth_some_tf2_map' | Should -Be $false
            Test-L4DMap -MapName 'cs_some_css_map' | Should -Be $false
            Test-L4DMap -MapName 'l4d2_some_map' | Should -Be $false

            # Still validates its own official maps normally.
            Test-L4DMap -MapName 'l4d_hospital01_apartment' | Should -Be $true
        }

        It 'falls back to the official list and logs a warning when CustomMaps.json is malformed' {
            Set-Content -Path (Join-Path $script:FakeRoot 'Config/CustomMaps.json') -Value '{ not valid json ]'

            Test-L4DMap -MapName 'l4d_hospital01_apartment' | Should -Be $true
            Test-L4DMap -MapName 'l4d_custom01_map' | Should -Be $false

            Should -Invoke -ModuleName Maps -CommandName Write-GSMLog -Times 1 -ParameterFilter { $Level -eq 'Warning' }
        }
    }
}
