BeforeAll {
    # See Tests/TeamFortress2.Install.Tests.ps1 for why this Remove-Module
    # is needed: every plugin's Maps.psm1 shares the same bare module name.
    Remove-Module -Name 'Maps' -Force -ErrorAction SilentlyContinue
    Import-Module "$PSScriptRoot/../Plugins/TeamFortress2/Maps.psm1" -Force

    function New-FakeGSMRootForMaps {
        $root = Join-Path $TestDrive ('teamfortress2-maps-root-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $root 'Config') -Force | Out-Null
        return $root
    }
}

Describe 'Plugins/TeamFortress2/Maps.psm1' {

    BeforeEach {
        # Isolate every test from the real (gitignored) Config/CustomMaps.json:
        # by default the fake root has no CustomMaps.json at all, so custom-map
        # behavior is opt-in per test via Set-Content below.
        $script:FakeRoot = New-FakeGSMRootForMaps
        Mock -ModuleName Maps -CommandName Get-GSMRootPath -MockWith { $script:FakeRoot }
        Mock -ModuleName Maps -CommandName Write-GSMLog -MockWith { }
    }

    Context 'Get-TeamFortress2Maps' {
        It 'returns all 26 curated stock maps' {
            $maps = Get-TeamFortress2Maps

            $maps.Count | Should -Be 26

            $expectedMaps = @(
                'ctf_2fort', 'ctf_well', 'ctf_doublecross', 'ctf_sawmill',
                'cp_granary', 'cp_well', 'cp_badlands', 'cp_gullywash',
                'cp_dustbowl', 'cp_gravelpit', 'cp_egypt', 'cp_junction',
                'tc_hydro',
                'pl_goldrush', 'pl_badwater', 'pl_thundermountain', 'pl_upward',
                'arena_granary', 'arena_well', 'arena_badlands', 'arena_lumberyard',
                'plr_pipeline', 'plr_hightower',
                'koth_nucleus', 'koth_viaduct', 'koth_sawmill'
            )
            ($maps | Sort-Object) | Should -Be ($expectedMaps | Sort-Object)
        }
    }

    Context 'Test-TeamFortress2Map' {
        It 'returns $true for a known stock map, case-insensitively' {
            Test-TeamFortress2Map -MapName 'cp_dustbowl' | Should -Be $true
            Test-TeamFortress2Map -MapName 'CP_Dustbowl' | Should -Be $true
            Test-TeamFortress2Map -MapName 'CP_DUSTBOWL' | Should -Be $true
        }

        It 'returns $true for every curated stock map' {
            foreach ($map in Get-TeamFortress2Maps) {
                Test-TeamFortress2Map -MapName $map | Should -Be $true -Because "map '$map' should validate"
            }
        }

        It 'returns $false for an unrecognized or Workshop map name' {
            Test-TeamFortress2Map -MapName 'some_custom_workshop_map' | Should -Be $false
        }
    }

    Context 'Test-TeamFortress2Map - Config/CustomMaps.json' {
        It 'falls back to the curated list only when CustomMaps.json does not exist' {
            Test-TeamFortress2Map -MapName 'koth_some_tf2_map' | Should -Be $false
        }

        It 'accepts a custom map registered under this plugin''s own key, case-insensitively' {
            @{
                Insurgency2014      = @()
                TeamFortress2       = @('koth_some_tf2_map')
                CounterStrikeSource = @()
                L4D                 = @()
                L4D2                = @()
            } | ConvertTo-Json | Set-Content -Path (Join-Path $script:FakeRoot 'Config/CustomMaps.json')

            Test-TeamFortress2Map -MapName 'koth_some_tf2_map' | Should -Be $true
            Test-TeamFortress2Map -MapName 'KOTH_SOME_TF2_MAP' | Should -Be $true
        }

        It 'falls back to the curated list when this plugin''s key is missing from the file' {
            @{ Insurgency2014 = @('coop_custommap') } | ConvertTo-Json | Set-Content -Path (Join-Path $script:FakeRoot 'Config/CustomMaps.json')

            Test-TeamFortress2Map -MapName 'koth_some_tf2_map' | Should -Be $false
        }

        It 'falls back to the curated list when this plugin''s key is present but empty' {
            @{ TeamFortress2 = @() } | ConvertTo-Json | Set-Content -Path (Join-Path $script:FakeRoot 'Config/CustomMaps.json')

            Test-TeamFortress2Map -MapName 'koth_some_tf2_map' | Should -Be $false
        }

        It 'only reads its own key and ignores other games'' custom map entries' {
            @{
                Insurgency2014      = @('coop_custommap')
                TeamFortress2       = @()
                CounterStrikeSource = @('cs_some_css_map')
                L4D                 = @('l4d_some_map')
                L4D2                = @('l4d2_some_map')
            } | ConvertTo-Json | Set-Content -Path (Join-Path $script:FakeRoot 'Config/CustomMaps.json')

            Test-TeamFortress2Map -MapName 'coop_custommap' | Should -Be $false
            Test-TeamFortress2Map -MapName 'cs_some_css_map' | Should -Be $false
            Test-TeamFortress2Map -MapName 'l4d_some_map' | Should -Be $false
            Test-TeamFortress2Map -MapName 'l4d2_some_map' | Should -Be $false

            # Still validates its own official maps normally.
            Test-TeamFortress2Map -MapName 'cp_dustbowl' | Should -Be $true
        }

        It 'falls back to the curated list and logs a warning when CustomMaps.json is malformed' {
            Set-Content -Path (Join-Path $script:FakeRoot 'Config/CustomMaps.json') -Value '{ not valid json ]'

            Test-TeamFortress2Map -MapName 'cp_dustbowl' | Should -Be $true
            Test-TeamFortress2Map -MapName 'koth_some_tf2_map' | Should -Be $false

            Should -Invoke -ModuleName Maps -CommandName Write-GSMLog -Times 1 -ParameterFilter { $Level -eq 'Warning' }
        }
    }
}
