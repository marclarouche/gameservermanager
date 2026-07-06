BeforeAll {
    # See Tests/TeamFortress2.Install.Tests.ps1 for why these Remove-Module
    # calls are needed: every plugin's Server/Maps/Modes modules share the
    # same bare module names.
    Remove-Module -Name 'Server', 'Maps', 'Modes' -Force -ErrorAction SilentlyContinue
    Import-Module "$PSScriptRoot/../Plugins/TeamFortress2/Server.psm1" -Force

    # Server.psm1 imports Maps.psm1/Modes.psm1 itself, but only into its own
    # module scope, so this test file also imports them directly to call
    # Get-TeamFortress2Maps/Get-TeamFortress2Modes at the Describe/It level.
    Import-Module "$PSScriptRoot/../Plugins/TeamFortress2/Maps.psm1" -Force
    Import-Module "$PSScriptRoot/../Plugins/TeamFortress2/Modes.psm1" -Force

    Import-Module "$PSScriptRoot/../Core/Config.psm1" -Force

    $script:ConfigTemplatePath = "$PSScriptRoot/../Plugins/TeamFortress2/Config.template.json"

    function New-ValidTeamFortress2Config {
        [PSCustomObject]@{
            GameName      = 'TeamFortress'
            AppID         = '232250'
            DefaultPort   = 27015
            Map           = 'cp_dustbowl'
            MaxPlayers    = 24
            RCONPassword  = ''
            WorkshopItems = @()
        }
    }
}

Describe 'Plugins/TeamFortress2/Server.psm1' {

    Context 'Config.template.json' {
        It 'round-trips through Core/Config.psm1''s Test-GSMConfig without any changes to that module' {
            $rawJson = Get-Content -Path $script:ConfigTemplatePath -Raw
            $config = $rawJson | ConvertFrom-Json

            { Test-GSMConfig -Config $config -RawJson $rawJson } | Should -Not -Throw
        }

        It 'also passes Team Fortress 2-specific validation (Map, MaxPlayers, etc.)' {
            $config = Get-Content -Path $script:ConfigTemplatePath -Raw | ConvertFrom-Json

            { Test-TeamFortress2ServerConfig -Config $config } | Should -Not -Throw
        }

        It 'builds the confirmed launch arguments from the template as-is' {
            $config = Get-Content -Path $script:ConfigTemplatePath -Raw | ConvertFrom-Json

            $launchArgs = Get-TeamFortress2LaunchArgs -Config $config

            ($launchArgs -join '|') | Should -Be (@('-console', '-port', '27015', '+map', 'cp_dustbowl', '+maxplayers', '24') -join '|')
        }
    }

    Context 'Test-TeamFortress2ServerConfig - valid config' {
        It 'does not throw for a fully valid config' {
            { Test-TeamFortress2ServerConfig -Config (New-ValidTeamFortress2Config) } | Should -Not -Throw
        }

        It 'accepts every confirmed curated stock map without throwing' {
            foreach ($map in Get-TeamFortress2Maps) {
                $config = New-ValidTeamFortress2Config
                $config.Map = $map

                { Test-TeamFortress2ServerConfig -Config $config } | Should -Not -Throw -Because "map '$map' should be valid"
            }
        }
    }

    Context 'Test-TeamFortress2ServerConfig - invalid config' {
        It 'throws when Map is missing' {
            $config = New-ValidTeamFortress2Config
            $config.PSObject.Properties.Remove('Map')

            { Test-TeamFortress2ServerConfig -Config $config } | Should -Throw '*Map*'
        }

        It 'throws when Map is not a recognized stock map' {
            $config = New-ValidTeamFortress2Config
            $config.Map = 'not_a_real_map'

            { Test-TeamFortress2ServerConfig -Config $config } | Should -Throw '*Map*'
        }

        It 'throws when DefaultPort is out of range' {
            $config = New-ValidTeamFortress2Config
            $config.DefaultPort = 99999

            { Test-TeamFortress2ServerConfig -Config $config } | Should -Throw '*DefaultPort*'
        }

        It 'throws when MaxPlayers is missing' {
            $config = New-ValidTeamFortress2Config
            $config.PSObject.Properties.Remove('MaxPlayers')

            { Test-TeamFortress2ServerConfig -Config $config } | Should -Throw '*MaxPlayers*'
        }

        It 'throws when MaxPlayers is out of range' {
            $config = New-ValidTeamFortress2Config
            $config.MaxPlayers = 100

            { Test-TeamFortress2ServerConfig -Config $config } | Should -Throw '*MaxPlayers*'
        }

        It 'throws when RCONPassword is not a string' {
            $config = New-ValidTeamFortress2Config
            $config.RCONPassword = 12345

            { Test-TeamFortress2ServerConfig -Config $config } | Should -Throw '*RCONPassword*'
        }

        It 'throws when WorkshopItems is not an array' {
            $config = New-ValidTeamFortress2Config
            $config.WorkshopItems = 'not-an-array'

            { Test-TeamFortress2ServerConfig -Config $config } | Should -Throw '*WorkshopItems*'
        }
    }

    Context 'Get-TeamFortress2LaunchArgs' {
        It 'builds the confirmed -console/-port/+map/+maxplayers arguments for the default template values' {
            $launchArgs = Get-TeamFortress2LaunchArgs -Config (New-ValidTeamFortress2Config)

            ($launchArgs -join '|') | Should -Be (@('-console', '-port', '27015', '+map', 'cp_dustbowl', '+maxplayers', '24') -join '|')
        }

        It 'passes the map name through as-is, with no mode-suffix logic' {
            $config = New-ValidTeamFortress2Config
            $config.Map = 'ctf_2fort'

            $launchArgs = Get-TeamFortress2LaunchArgs -Config $config

            $launchArgs | Should -Contain 'ctf_2fort'
        }

        It 'appends +rcon_password only when RCONPassword is set' {
            $configWithout = New-ValidTeamFortress2Config
            $argsWithout = Get-TeamFortress2LaunchArgs -Config $configWithout
            $argsWithout | Should -Not -Contain '+rcon_password'

            $configWith = New-ValidTeamFortress2Config
            $configWith.RCONPassword = 'sup3rSecret'
            $argsWith = Get-TeamFortress2LaunchArgs -Config $configWith

            $argsWith | Should -Contain '+rcon_password'
            $argsWith | Should -Contain 'sup3rSecret'
        }

        It 'appends +sv_workshop_enabled 1 only when WorkshopItems is non-empty' {
            $configWithout = New-ValidTeamFortress2Config
            $argsWithout = Get-TeamFortress2LaunchArgs -Config $configWithout
            $argsWithout | Should -Not -Contain '+sv_workshop_enabled'

            $configWith = New-ValidTeamFortress2Config
            $configWith.WorkshopItems = @('123456789')
            $argsWith = Get-TeamFortress2LaunchArgs -Config $configWith

            $argsWith | Should -Contain '+sv_workshop_enabled'
        }

        It 'validates the config before building, throwing rather than returning a malformed launch string' {
            $config = New-ValidTeamFortress2Config
            $config.Map = 'not_a_real_map'

            { Get-TeamFortress2LaunchArgs -Config $config } | Should -Throw '*Map*'
        }
    }
}
