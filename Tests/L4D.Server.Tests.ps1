BeforeAll {
    # See Tests/L4D.Install.Tests.ps1 for why these Remove-Module calls are
    # needed: every plugin's Server/Maps/Modes modules share the same bare
    # module names.
    Remove-Module -Name 'Server', 'Maps', 'Modes' -Force -ErrorAction SilentlyContinue
    Import-Module "$PSScriptRoot/../Plugins/L4D/Server.psm1" -Force

    # Server.psm1 imports Maps.psm1/Modes.psm1 itself, but only into its own
    # module scope, so this test file also imports them directly to call
    # Get-L4DMaps/Get-L4DModes at the Describe/It level.
    Import-Module "$PSScriptRoot/../Plugins/L4D/Maps.psm1" -Force
    Import-Module "$PSScriptRoot/../Plugins/L4D/Modes.psm1" -Force

    Import-Module "$PSScriptRoot/../Core/Config.psm1" -Force

    $script:ConfigTemplatePath = "$PSScriptRoot/../Plugins/L4D/Config.template.json"

    function New-ValidL4DConfig {
        [PSCustomObject]@{
            GameName     = 'Left4Dead'
            AppID        = '222840'
            DefaultPort  = 27015
            Map          = 'l4d_hospital01_apartment'
            Mode         = 'coop'
            MaxPlayers   = 8
            RCONPassword = ''
        }
    }
}

Describe 'Plugins/L4D/Server.psm1' {

    Context 'Config.template.json' {
        It 'round-trips through Core/Config.psm1''s Test-GSMConfig without any changes to that module' {
            $rawJson = Get-Content -Path $script:ConfigTemplatePath -Raw
            $config = $rawJson | ConvertFrom-Json

            { Test-GSMConfig -Config $config -RawJson $rawJson } | Should -Not -Throw
        }

        It 'also passes Left 4 Dead-specific validation (Map, Mode, MaxPlayers, etc.)' {
            $config = Get-Content -Path $script:ConfigTemplatePath -Raw | ConvertFrom-Json

            { Test-L4DServerConfig -Config $config } | Should -Not -Throw
        }

        It 'builds the confirmed launch arguments from the template as-is' {
            $config = Get-Content -Path $script:ConfigTemplatePath -Raw | ConvertFrom-Json

            $launchArgs = Get-L4DLaunchArgs -Config $config

            ($launchArgs -join '|') | Should -Be (@('-console', '-port', '27015', '+map', 'l4d_hospital01_apartment', '+maxplayers', '8', '+mp_gamemode', 'coop') -join '|')
        }

        It 'does not contain a WorkshopItems field, since this plugin does not support Workshop' {
            $config = Get-Content -Path $script:ConfigTemplatePath -Raw | ConvertFrom-Json

            $config.PSObject.Properties['WorkshopItems'] | Should -BeNullOrEmpty
        }
    }

    Context 'Test-L4DServerConfig - valid config' {
        It 'does not throw for a fully valid config' {
            { Test-L4DServerConfig -Config (New-ValidL4DConfig) } | Should -Not -Throw
        }

        It 'accepts every confirmed map and mode combination without throwing' {
            foreach ($map in Get-L4DMaps) {
                foreach ($mode in Get-L4DModes) {
                    $config = New-ValidL4DConfig
                    $config.Map = $map
                    $config.Mode = $mode

                    { Test-L4DServerConfig -Config $config } | Should -Not -Throw -Because "map '$map' + mode '$mode' should be valid"
                }
            }
        }
    }

    Context 'Test-L4DServerConfig - invalid config' {
        It 'throws when Map is missing' {
            $config = New-ValidL4DConfig
            $config.PSObject.Properties.Remove('Map')

            { Test-L4DServerConfig -Config $config } | Should -Throw '*Map*'
        }

        It 'throws when Map is not a recognized campaign map' {
            $config = New-ValidL4DConfig
            $config.Map = 'not_a_real_map'

            { Test-L4DServerConfig -Config $config } | Should -Throw '*Map*'
        }

        It 'throws when Mode is missing' {
            $config = New-ValidL4DConfig
            $config.PSObject.Properties.Remove('Mode')

            { Test-L4DServerConfig -Config $config } | Should -Throw '*Mode*'
        }

        It 'throws when Mode is not a recognized game mode' {
            $config = New-ValidL4DConfig
            $config.Mode = 'scavenge'

            { Test-L4DServerConfig -Config $config } | Should -Throw '*Mode*'
        }

        It 'throws when DefaultPort is out of range' {
            $config = New-ValidL4DConfig
            $config.DefaultPort = 99999

            { Test-L4DServerConfig -Config $config } | Should -Throw '*DefaultPort*'
        }

        It 'throws when MaxPlayers is missing' {
            $config = New-ValidL4DConfig
            $config.PSObject.Properties.Remove('MaxPlayers')

            { Test-L4DServerConfig -Config $config } | Should -Throw '*MaxPlayers*'
        }

        It 'throws when MaxPlayers is out of range' {
            $config = New-ValidL4DConfig
            $config.MaxPlayers = 100

            { Test-L4DServerConfig -Config $config } | Should -Throw '*MaxPlayers*'
        }

        It 'throws when MaxPlayers exceeds L4D''s 8-player ceiling' {
            $config = New-ValidL4DConfig
            $config.MaxPlayers = 9

            { Test-L4DServerConfig -Config $config } | Should -Throw '*MaxPlayers*'
        }

        It 'throws when RCONPassword is not a string' {
            $config = New-ValidL4DConfig
            $config.RCONPassword = 12345

            { Test-L4DServerConfig -Config $config } | Should -Throw '*RCONPassword*'
        }
    }

    Context 'Get-L4DLaunchArgs' {
        It 'builds the confirmed -console/-port/+map/+maxplayers/+mp_gamemode arguments for the default template values' {
            $launchArgs = Get-L4DLaunchArgs -Config (New-ValidL4DConfig)

            ($launchArgs -join '|') | Should -Be (@('-console', '-port', '27015', '+map', 'l4d_hospital01_apartment', '+maxplayers', '8', '+mp_gamemode', 'coop') -join '|')
        }

        It 'passes the map name through as-is, with no mode-suffix logic on the map itself' {
            $config = New-ValidL4DConfig
            $config.Map = 'l4d_farm01_hilltop'

            $launchArgs = Get-L4DLaunchArgs -Config $config

            $launchArgs | Should -Contain 'l4d_farm01_hilltop'
        }

        It 'builds +mp_gamemode from the Mode field' {
            $config = New-ValidL4DConfig
            $config.Mode = 'versus'

            $launchArgs = Get-L4DLaunchArgs -Config $config

            $launchArgs | Should -Contain '+mp_gamemode'
            $launchArgs | Should -Contain 'versus'
        }

        It 'appends +rcon_password only when RCONPassword is set' {
            $configWithout = New-ValidL4DConfig
            $argsWithout = Get-L4DLaunchArgs -Config $configWithout
            $argsWithout | Should -Not -Contain '+rcon_password'

            $configWith = New-ValidL4DConfig
            $configWith.RCONPassword = 'sup3rSecret'
            $argsWith = Get-L4DLaunchArgs -Config $configWith

            $argsWith | Should -Contain '+rcon_password'
            $argsWith | Should -Contain 'sup3rSecret'
        }

        It 'validates the config before building, throwing rather than returning a malformed launch string' {
            $config = New-ValidL4DConfig
            $config.Map = 'not_a_real_map'

            { Get-L4DLaunchArgs -Config $config } | Should -Throw '*Map*'
        }

        It 'never emits a Workshop-related argument, since this plugin does not support Workshop' {
            $launchArgs = Get-L4DLaunchArgs -Config (New-ValidL4DConfig)

            $launchArgs | Should -Not -Contain '+sv_workshop_enabled'
            ($launchArgs -join ' ') | Should -Not -Match 'workshop'
        }
    }
}
