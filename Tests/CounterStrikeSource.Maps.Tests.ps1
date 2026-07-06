BeforeAll {
    # See Tests/CounterStrikeSource.Install.Tests.ps1 for why this
    # Remove-Module is needed: every plugin's Maps.psm1 shares the same bare
    # module name.
    Remove-Module -Name 'Maps' -Force -ErrorAction SilentlyContinue
    Import-Module "$PSScriptRoot/../Plugins/CounterStrikeSource/Maps.psm1" -Force

    function New-FakeGSMRootForMaps {
        $root = Join-Path $TestDrive ('counterstrikesource-maps-root-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $root 'Config') -Force | Out-Null
        return $root
    }
}

Describe 'Plugins/CounterStrikeSource/Maps.psm1' {

    BeforeEach {
        # Isolate every test from the real (gitignored) Config/CustomMaps.json:
        # by default the fake root has no CustomMaps.json at all, so custom-map
        # behavior is opt-in per test via Set-Content below.
        $script:FakeRoot = New-FakeGSMRootForMaps
        Mock -ModuleName Maps -CommandName Get-GSMRootPath -MockWith { $script:FakeRoot }
        Mock -ModuleName Maps -CommandName Write-GSMLog -MockWith { }
    }

    Context 'Get-CounterStrikeSourceMaps' {
        It 'returns all 18 official stock maps' {
            $maps = Get-CounterStrikeSourceMaps

            $maps.Count | Should -Be 18

            $expectedMaps = @(
                'cs_assault', 'cs_compound', 'cs_havana', 'cs_italy', 'cs_militia', 'cs_office',
                'de_aztec', 'de_cbble', 'de_chateau', 'de_dust', 'de_dust2', 'de_inferno',
                'de_nuke', 'de_piranesi', 'de_port', 'de_prodigy', 'de_tides', 'de_train'
            )
            ($maps | Sort-Object) | Should -Be ($expectedMaps | Sort-Object)
        }
    }

    Context 'Test-CounterStrikeSourceMap' {
        It 'returns $true for a known stock map, case-insensitively' {
            Test-CounterStrikeSourceMap -MapName 'de_dust2' | Should -Be $true
            Test-CounterStrikeSourceMap -MapName 'De_Dust2' | Should -Be $true
            Test-CounterStrikeSourceMap -MapName 'DE_DUST2' | Should -Be $true
        }

        It 'returns $true for every confirmed official stock map' {
            foreach ($map in Get-CounterStrikeSourceMaps) {
                Test-CounterStrikeSourceMap -MapName $map | Should -Be $true -Because "map '$map' should validate"
            }
        }

        It 'returns $false for an unrecognized or community map name' {
            Test-CounterStrikeSourceMap -MapName 'de_some_custom_map' | Should -Be $false
        }
    }

    Context 'Test-CounterStrikeSourceMap - Config/CustomMaps.json' {
        It 'falls back to the official list only when CustomMaps.json does not exist' {
            Test-CounterStrikeSourceMap -MapName 'de_custom_map' | Should -Be $false
        }

        It 'accepts a custom map registered under this plugin''s own key, case-insensitively' {
            @{
                Insurgency2014      = @()
                TeamFortress2       = @()
                CounterStrikeSource = @('de_custom_map')
                L4D                 = @()
                L4D2                = @()
            } | ConvertTo-Json | Set-Content -Path (Join-Path $script:FakeRoot 'Config/CustomMaps.json')

            Test-CounterStrikeSourceMap -MapName 'de_custom_map' | Should -Be $true
            Test-CounterStrikeSourceMap -MapName 'DE_CUSTOM_MAP' | Should -Be $true
        }

        It 'falls back to the official list when this plugin''s key is missing from the file' {
            @{ Insurgency2014 = @('coop_custommap') } | ConvertTo-Json | Set-Content -Path (Join-Path $script:FakeRoot 'Config/CustomMaps.json')

            Test-CounterStrikeSourceMap -MapName 'de_custom_map' | Should -Be $false
        }

        It 'falls back to the official list when this plugin''s key is present but empty' {
            @{ CounterStrikeSource = @() } | ConvertTo-Json | Set-Content -Path (Join-Path $script:FakeRoot 'Config/CustomMaps.json')

            Test-CounterStrikeSourceMap -MapName 'de_custom_map' | Should -Be $false
        }

        It 'only reads its own key and ignores other games'' custom map entries' {
            @{
                Insurgency2014      = @('coop_custommap')
                TeamFortress2       = @('koth_some_tf2_map')
                CounterStrikeSource = @()
                L4D                 = @('l4d_some_map')
                L4D2                = @('l4d2_some_map')
            } | ConvertTo-Json | Set-Content -Path (Join-Path $script:FakeRoot 'Config/CustomMaps.json')

            Test-CounterStrikeSourceMap -MapName 'coop_custommap' | Should -Be $false
            Test-CounterStrikeSourceMap -MapName 'koth_some_tf2_map' | Should -Be $false
            Test-CounterStrikeSourceMap -MapName 'l4d_some_map' | Should -Be $false
            Test-CounterStrikeSourceMap -MapName 'l4d2_some_map' | Should -Be $false

            # Still validates its own official maps normally.
            Test-CounterStrikeSourceMap -MapName 'de_dust2' | Should -Be $true
        }

        It 'falls back to the official list and logs a warning when CustomMaps.json is malformed' {
            Set-Content -Path (Join-Path $script:FakeRoot 'Config/CustomMaps.json') -Value '{ not valid json ]'

            Test-CounterStrikeSourceMap -MapName 'de_dust2' | Should -Be $true
            Test-CounterStrikeSourceMap -MapName 'de_custom_map' | Should -Be $false

            Should -Invoke -ModuleName Maps -CommandName Write-GSMLog -Times 1 -ParameterFilter { $Level -eq 'Warning' }
        }
    }
}
