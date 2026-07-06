BeforeAll {
    # See Tests/Insurgency2014.Install.Tests.ps1 for why these Remove-Module
    # calls are needed: every plugin's Server/Maps/Modes modules share the
    # same bare module names.
    Remove-Module -Name 'Server', 'Maps', 'Modes' -Force -ErrorAction SilentlyContinue
    Import-Module "$PSScriptRoot/../Plugins/Insurgency2014/Server.psm1" -Force

    # Server.psm1 imports Maps.psm1/Modes.psm1 itself, but only into its own
    # module scope, so this test file also imports them directly to call
    # Get-Insurgency2014Maps/Get-Insurgency2014Modes at the Describe/It level.
    Import-Module "$PSScriptRoot/../Plugins/Insurgency2014/Maps.psm1" -Force
    Import-Module "$PSScriptRoot/../Plugins/Insurgency2014/Modes.psm1" -Force

    Import-Module "$PSScriptRoot/../Core/Config.psm1" -Force

    $script:ConfigTemplatePath = "$PSScriptRoot/../Plugins/Insurgency2014/Config.template.json"

    function New-ValidInsurgency2014Config {
        [PSCustomObject]@{
            GameName      = 'Insurgency'
            AppID         = '237410'
            DefaultPort   = 27015
            Map           = 'Market'
            Mode          = 'Checkpoint'
            MaxPlayers    = 32
            RCONPassword  = ''
            WorkshopItems = @()
        }
    }
}

Describe 'Plugins/Insurgency2014/Server.psm1' {

    Context 'Config.template.json' {
        It 'round-trips through Core/Config.psm1''s Test-GSMConfig without any changes to that module' {
            $rawJson = Get-Content -Path $script:ConfigTemplatePath -Raw
            $config = $rawJson | ConvertFrom-Json

            { Test-GSMConfig -Config $config -RawJson $rawJson } | Should -Not -Throw
        }

        It 'also passes Insurgency-specific validation (Map, Mode, MaxPlayers, etc.)' {
            $config = Get-Content -Path $script:ConfigTemplatePath -Raw | ConvertFrom-Json

            { Test-Insurgency2014ServerConfig -Config $config } | Should -Not -Throw
        }

        It 'builds the confirmed launch arguments from the template as-is' {
            $config = Get-Content -Path $script:ConfigTemplatePath -Raw | ConvertFrom-Json

            $launchArgs = Get-Insurgency2014LaunchArgs -Config $config

            ($launchArgs -join '|') | Should -Be (@('-console', '-port', '27015', '+map', 'market_coop', '+maxplayers', '32') -join '|')
        }
    }

    Context 'Test-Insurgency2014ServerConfig - valid config' {
        It 'does not throw for a fully valid config' {
            { Test-Insurgency2014ServerConfig -Config (New-ValidInsurgency2014Config) } | Should -Not -Throw
        }

        It 'accepts "coop" as a Mode value in addition to "Checkpoint"' {
            $config = New-ValidInsurgency2014Config
            $config.Mode = 'coop'

            { Test-Insurgency2014ServerConfig -Config $config } | Should -Not -Throw
        }

        It 'accepts every confirmed map and mode combination without throwing' {
            foreach ($map in Get-Insurgency2014Maps) {
                foreach ($mode in Get-Insurgency2014Modes) {
                    $config = New-ValidInsurgency2014Config
                    $config.Map = $map
                    $config.Mode = $mode

                    { Test-Insurgency2014ServerConfig -Config $config } | Should -Not -Throw -Because "map '$map' + mode '$mode' should be valid"
                }
            }
        }
    }

    Context 'Test-Insurgency2014ServerConfig - invalid config' {
        It 'throws when Map is missing' {
            $config = New-ValidInsurgency2014Config
            $config.PSObject.Properties.Remove('Map')

            { Test-Insurgency2014ServerConfig -Config $config } | Should -Throw '*Map*'
        }

        It 'throws when Map is not a recognized stock map' {
            $config = New-ValidInsurgency2014Config
            $config.Map = 'not_a_real_map'

            { Test-Insurgency2014ServerConfig -Config $config } | Should -Throw '*Map*'
        }

        It 'throws when Mode is missing' {
            $config = New-ValidInsurgency2014Config
            $config.PSObject.Properties.Remove('Mode')

            { Test-Insurgency2014ServerConfig -Config $config } | Should -Throw '*Mode*'
        }

        It 'throws when Mode is not a recognized game mode' {
            $config = New-ValidInsurgency2014Config
            $config.Mode = 'battle_royale'

            { Test-Insurgency2014ServerConfig -Config $config } | Should -Throw '*Mode*'
        }

        It 'throws when DefaultPort is out of range' {
            $config = New-ValidInsurgency2014Config
            $config.DefaultPort = 99999

            { Test-Insurgency2014ServerConfig -Config $config } | Should -Throw '*DefaultPort*'
        }

        It 'throws when MaxPlayers is missing' {
            $config = New-ValidInsurgency2014Config
            $config.PSObject.Properties.Remove('MaxPlayers')

            { Test-Insurgency2014ServerConfig -Config $config } | Should -Throw '*MaxPlayers*'
        }

        It 'throws when MaxPlayers is out of range' {
            $config = New-ValidInsurgency2014Config
            $config.MaxPlayers = 100

            { Test-Insurgency2014ServerConfig -Config $config } | Should -Throw '*MaxPlayers*'
        }

        It 'throws when RCONPassword is not a string' {
            $config = New-ValidInsurgency2014Config
            $config.RCONPassword = 12345

            { Test-Insurgency2014ServerConfig -Config $config } | Should -Throw '*RCONPassword*'
        }

        It 'throws when WorkshopItems is not an array' {
            $config = New-ValidInsurgency2014Config
            $config.WorkshopItems = 'not-an-array'

            { Test-Insurgency2014ServerConfig -Config $config } | Should -Throw '*WorkshopItems*'
        }
    }

    Context 'Get-Insurgency2014LaunchArgs' {
        It 'builds the confirmed -console/-port/+map/+maxplayers arguments for the default template values' {
            $launchArgs = Get-Insurgency2014LaunchArgs -Config (New-ValidInsurgency2014Config)

            ($launchArgs -join '|') | Should -Be (@('-console', '-port', '27015', '+map', 'market_coop', '+maxplayers', '32') -join '|')
        }

        It 'maps Checkpoint to the "coop" internal map suffix, not "checkpoint"' {
            $launchArgs = Get-Insurgency2014LaunchArgs -Config (New-ValidInsurgency2014Config)

            $launchArgs | Should -Contain 'market_coop'
            $launchArgs | Should -Not -Contain 'market_checkpoint'
        }

        It 'builds a 1:1 mode suffix for non-Checkpoint modes' {
            $config = New-ValidInsurgency2014Config
            $config.Map = 'Sinjar'
            $config.Mode = 'Push'

            $launchArgs = Get-Insurgency2014LaunchArgs -Config $config

            $launchArgs | Should -Contain 'sinjar_push'
        }

        It 'appends +rcon_password only when RCONPassword is set' {
            $configWithout = New-ValidInsurgency2014Config
            $argsWithout = Get-Insurgency2014LaunchArgs -Config $configWithout
            $argsWithout | Should -Not -Contain '+rcon_password'

            $configWith = New-ValidInsurgency2014Config
            $configWith.RCONPassword = 'sup3rSecret'
            $argsWith = Get-Insurgency2014LaunchArgs -Config $configWith

            $argsWith | Should -Contain '+rcon_password'
            $argsWith | Should -Contain 'sup3rSecret'
        }

        It 'appends +sv_workshop_enabled 1 only when WorkshopItems is non-empty' {
            $configWithout = New-ValidInsurgency2014Config
            $argsWithout = Get-Insurgency2014LaunchArgs -Config $configWithout
            $argsWithout | Should -Not -Contain '+sv_workshop_enabled'

            $configWith = New-ValidInsurgency2014Config
            $configWith.WorkshopItems = @('123456789')
            $argsWith = Get-Insurgency2014LaunchArgs -Config $configWith

            $argsWith | Should -Contain '+sv_workshop_enabled'
        }

        It 'validates the config before building, throwing rather than returning a malformed launch string' {
            $config = New-ValidInsurgency2014Config
            $config.Map = 'not_a_real_map'

            { Get-Insurgency2014LaunchArgs -Config $config } | Should -Throw '*Map*'
        }
    }
}
