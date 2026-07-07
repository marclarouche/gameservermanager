BeforeAll {
    # See Tests/L4D2.Install.Tests.ps1 for why this Remove-Module is needed:
    # every plugin's Maps.psm1 shares the same bare module name.
    Remove-Module -Name 'Maps' -Force -ErrorAction SilentlyContinue
    Import-Module "$PSScriptRoot/../Plugins/L4D2/Maps.psm1" -Force

    function New-FakeGSMRootForMaps {
        $root = Join-Path $TestDrive ('l4d2-maps-root-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $root 'Config') -Force | Out-Null
        return $root
    }
}

Describe 'Plugins/L4D2/Maps.psm1' {

    BeforeEach {
        # Isolate every test from the real (gitignored) Config/CustomMaps.json:
        # by default the fake root has no CustomMaps.json at all, so custom-map
        # behavior is opt-in per test via Set-Content below.
        $script:FakeRoot = New-FakeGSMRootForMaps
        Mock -ModuleName Maps -CommandName Get-GSMRootPath -MockWith { $script:FakeRoot }
        Mock -ModuleName Maps -CommandName Write-GSMLog -MockWith { }
    }

    Context 'Get-L4D2Maps' {
        It 'returns all 55 official campaign maps across all 13 Valve in-house campaigns' {
            $maps = Get-L4D2Maps

            $maps.Count | Should -Be 55

            $expectedMaps = @(
                'c1m1_hotel', 'c1m2_streets', 'c1m3_mall', 'c1m4_atrium',
                'c2m1_highway', 'c2m2_fairgrounds', 'c2m3_coaster', 'c2m4_barns', 'c2m5_concert',
                'c3m1_plankcountry', 'c3m2_swamp', 'c3m3_shantytown', 'c3m4_plantation',
                'c4m1_milltown_a', 'c4m2_sugarmill_a', 'c4m3_sugarmill_b', 'c4m4_milltown_b', 'c4m5_milltown_escape',
                'c5m1_waterfront', 'c5m2_park', 'c5m3_cemetery', 'c5m4_quarter', 'c5m5_bridge',
                'c6m1_riverbank', 'c6m2_bedlam', 'c6m3_port',
                'c7m1_docks', 'c7m2_barge', 'c7m3_port',
                'c8m1_apartment', 'c8m2_subway', 'c8m3_sewers', 'c8m4_interior', 'c8m5_rooftop',
                'c9m1_alleys', 'c9m2_lots',
                'c10m1_caves', 'c10m2_drainage', 'c10m3_ranchhouse', 'c10m4_mainstreet', 'c10m5_houseboat',
                'c11m1_greenhouse', 'c11m2_offices', 'c11m3_garage', 'c11m4_terminal', 'c11m5_runway',
                'c12m1_hilltop', 'c12m2_traintunnel', 'c12m3_bridge', 'c12m4_barn', 'c12m5_cornfield',
                'c13m1_alpinecreek', 'c13m2_southpinestream', 'c13m3_memorialbridge', 'c13m4_cutthroatcreek'
            )
            ($maps | Sort-Object) | Should -Be ($expectedMaps | Sort-Object)
        }
    }

    Context 'Test-L4D2Map' {
        It 'returns $true for a known stock map, case-insensitively' {
            Test-L4D2Map -MapName 'c1m1_hotel' | Should -Be $true
            Test-L4D2Map -MapName 'C1M1_Hotel' | Should -Be $true
            Test-L4D2Map -MapName 'C1M1_HOTEL' | Should -Be $true
        }

        It 'returns $true for every confirmed official campaign map' {
            foreach ($map in Get-L4D2Maps) {
                Test-L4D2Map -MapName $map | Should -Be $true -Because "map '$map' should validate"
            }
        }

        It 'returns $true for a ported Left 4 Dead campaign map using the L4D2 c#m# naming' {
            Test-L4D2Map -MapName 'c8m1_apartment' | Should -Be $true
        }

        It 'returns $false for the original Left 4 Dead (2008) internal map name of the same chapter' {
            Test-L4D2Map -MapName 'l4d_hospital01_apartment' | Should -Be $false
        }

        It 'returns $false for an unrecognized or custom-campaign map name' {
            Test-L4D2Map -MapName 'some_custom_campaign_map' | Should -Be $false
        }

        It 'returns $false for "The Last Stand" maps by default, since it is community-authored, not Valve in-house' {
            Test-L4D2Map -MapName 'c14m1_junkyard' | Should -Be $false
            Test-L4D2Map -MapName 'c14m2_lighthouse' | Should -Be $false
        }
    }

    Context 'Test-L4D2Map - Config/CustomMaps.json' {
        It 'falls back to the official list only when CustomMaps.json does not exist' {
            Test-L4D2Map -MapName 'c99m1_custommap' | Should -Be $false
        }

        It 'accepts a custom map registered under this plugin''s own key, case-insensitively' {
            @{
                Insurgency2014      = @()
                TeamFortress2       = @()
                CounterStrikeSource = @()
                L4D                 = @()
                L4D2                = @('c99m1_custommap')
            } | ConvertTo-Json | Set-Content -Path (Join-Path $script:FakeRoot 'Config/CustomMaps.json')

            Test-L4D2Map -MapName 'c99m1_custommap' | Should -Be $true
            Test-L4D2Map -MapName 'C99M1_CUSTOMMAP' | Should -Be $true
        }

        It 'falls back to the official list when this plugin''s key is missing from the file' {
            @{ Insurgency2014 = @('coop_custommap') } | ConvertTo-Json | Set-Content -Path (Join-Path $script:FakeRoot 'Config/CustomMaps.json')

            Test-L4D2Map -MapName 'c99m1_custommap' | Should -Be $false
        }

        It 'falls back to the official list when this plugin''s key is present but empty' {
            @{ L4D2 = @() } | ConvertTo-Json | Set-Content -Path (Join-Path $script:FakeRoot 'Config/CustomMaps.json')

            Test-L4D2Map -MapName 'c99m1_custommap' | Should -Be $false
        }

        It 'only reads its own key and ignores other games'' custom map entries' {
            @{
                Insurgency2014      = @('coop_custommap')
                TeamFortress2       = @('koth_some_tf2_map')
                CounterStrikeSource = @('cs_some_css_map')
                L4D                 = @('l4d_some_map')
                L4D2                = @()
            } | ConvertTo-Json | Set-Content -Path (Join-Path $script:FakeRoot 'Config/CustomMaps.json')

            Test-L4D2Map -MapName 'coop_custommap' | Should -Be $false
            Test-L4D2Map -MapName 'koth_some_tf2_map' | Should -Be $false
            Test-L4D2Map -MapName 'cs_some_css_map' | Should -Be $false
            Test-L4D2Map -MapName 'l4d_some_map' | Should -Be $false

            # Still validates its own official maps normally.
            Test-L4D2Map -MapName 'c1m1_hotel' | Should -Be $true
        }

        It 'falls back to the official list and logs a warning when CustomMaps.json is malformed' {
            Set-Content -Path (Join-Path $script:FakeRoot 'Config/CustomMaps.json') -Value '{ not valid json ]'

            Test-L4D2Map -MapName 'c1m1_hotel' | Should -Be $true
            Test-L4D2Map -MapName 'c99m1_custommap' | Should -Be $false

            Should -Invoke -ModuleName Maps -CommandName Write-GSMLog -Times 1 -ParameterFilter { $Level -eq 'Warning' }
        }
    }
}
