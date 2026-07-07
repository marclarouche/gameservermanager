BeforeAll {
    # See Tests/L4D2.Install.Tests.ps1 for why these Remove-Module calls are
    # needed: every plugin's Server/Maps/Modes modules share the same bare
    # module names.
    Remove-Module -Name 'Server', 'Maps', 'Modes' -Force -ErrorAction SilentlyContinue
    Import-Module "$PSScriptRoot/../Plugins/L4D2/Server.psm1" -Force

    # Server.psm1 imports Maps.psm1/Modes.psm1 itself, but only into its own
    # module scope, so this test file also imports them directly to call
    # Get-L4D2Maps/Get-L4D2Modes at the Describe/It level.
    Import-Module "$PSScriptRoot/../Plugins/L4D2/Maps.psm1" -Force
    Import-Module "$PSScriptRoot/../Plugins/L4D2/Modes.psm1" -Force

    Import-Module "$PSScriptRoot/../Core/Config.psm1" -Force

    $script:ConfigTemplatePath = "$PSScriptRoot/../Plugins/L4D2/Config.template.json"

    function New-ValidL4D2Config {
        [PSCustomObject]@{
            GameName      = 'Left4Dead'
            AppID         = '222860'
            DefaultPort   = 27015
            Map           = 'c1m1_hotel'
            Mode          = 'coop'
            MaxPlayers    = 8
            RCONPassword  = ''
            WorkshopItems = @()
        }
    }
}

Describe 'Plugins/L4D2/Server.psm1' {

    Context 'Config.template.json' {
        It 'round-trips through Core/Config.psm1''s Test-GSMConfig without any changes to that module' {
            $rawJson = Get-Content -Path $script:ConfigTemplatePath -Raw
            $config = $rawJson | ConvertFrom-Json

            { Test-GSMConfig -Config $config -RawJson $rawJson } | Should -Not -Throw
        }

        It 'also passes Left 4 Dead 2-specific validation (Map, Mode, MaxPlayers, etc.)' {
            $config = Get-Content -Path $script:ConfigTemplatePath -Raw | ConvertFrom-Json

            { Test-L4D2ServerConfig -Config $config } | Should -Not -Throw
        }

        It 'builds the confirmed launch arguments from the template as-is' {
            $config = Get-Content -Path $script:ConfigTemplatePath -Raw | ConvertFrom-Json

            $launchArgs = Get-L4D2LaunchArgs -Config $config

            ($launchArgs -join '|') | Should -Be (@('-console', '-port', '27015', '+map', 'c1m1_hotel', '+maxplayers', '8', '+mp_gamemode', 'coop') -join '|')
        }

        It 'includes a WorkshopItems field defaulting to an empty array, since this plugin supports Workshop' {
            $config = Get-Content -Path $script:ConfigTemplatePath -Raw | ConvertFrom-Json

            $config.PSObject.Properties['WorkshopItems'] | Should -Not -BeNullOrEmpty
            $config.WorkshopItems.Count | Should -Be 0
        }
    }

    Context 'Test-L4D2ServerConfig - valid config' {
        It 'does not throw for a fully valid config' {
            { Test-L4D2ServerConfig -Config (New-ValidL4D2Config) } | Should -Not -Throw
        }

        It 'accepts every confirmed map and mode combination without throwing' {
            foreach ($map in Get-L4D2Maps) {
                foreach ($mode in Get-L4D2Modes) {
                    $config = New-ValidL4D2Config
                    $config.Map = $map
                    $config.Mode = $mode

                    { Test-L4D2ServerConfig -Config $config } | Should -Not -Throw -Because "map '$map' + mode '$mode' should be valid"
                }
            }
        }
    }

    Context 'Test-L4D2ServerConfig - invalid config' {
        It 'throws when Map is missing' {
            $config = New-ValidL4D2Config
            $config.PSObject.Properties.Remove('Map')

            { Test-L4D2ServerConfig -Config $config } | Should -Throw '*Map*'
        }

        It 'throws when Map is not a recognized campaign map' {
            $config = New-ValidL4D2Config
            $config.Map = 'not_a_real_map'

            { Test-L4D2ServerConfig -Config $config } | Should -Throw '*Map*'
        }

        It 'throws when Map is the original Left 4 Dead (2008) internal map name, not the L4D2 c#m# equivalent' {
            $config = New-ValidL4D2Config
            $config.Map = 'l4d_hospital01_apartment'

            { Test-L4D2ServerConfig -Config $config } | Should -Throw '*Map*'
        }

        It 'throws when Mode is missing' {
            $config = New-ValidL4D2Config
            $config.PSObject.Properties.Remove('Mode')

            { Test-L4D2ServerConfig -Config $config } | Should -Throw '*Mode*'
        }

        It 'throws when Mode is not a recognized game mode' {
            $config = New-ValidL4D2Config
            $config.Mode = 'deathmatch'

            { Test-L4D2ServerConfig -Config $config } | Should -Throw '*Mode*'
        }

        It 'throws when Mode is a numbered Mutation slot rather than a stable mode name' {
            $config = New-ValidL4D2Config
            $config.Mode = 'mutation12'

            { Test-L4D2ServerConfig -Config $config } | Should -Throw '*Mode*'
        }

        It 'throws when DefaultPort is out of range' {
            $config = New-ValidL4D2Config
            $config.DefaultPort = 99999

            { Test-L4D2ServerConfig -Config $config } | Should -Throw '*DefaultPort*'
        }

        It 'throws when MaxPlayers is missing' {
            $config = New-ValidL4D2Config
            $config.PSObject.Properties.Remove('MaxPlayers')

            { Test-L4D2ServerConfig -Config $config } | Should -Throw '*MaxPlayers*'
        }

        It 'throws when MaxPlayers is out of range' {
            $config = New-ValidL4D2Config
            $config.MaxPlayers = 100

            { Test-L4D2ServerConfig -Config $config } | Should -Throw '*MaxPlayers*'
        }

        It 'throws when MaxPlayers exceeds L4D2''s 8-player ceiling' {
            $config = New-ValidL4D2Config
            $config.MaxPlayers = 9

            { Test-L4D2ServerConfig -Config $config } | Should -Throw '*MaxPlayers*'
        }

        It 'throws when RCONPassword is not a string' {
            $config = New-ValidL4D2Config
            $config.RCONPassword = 12345

            { Test-L4D2ServerConfig -Config $config } | Should -Throw '*RCONPassword*'
        }

        It 'throws when WorkshopItems is not an array' {
            $config = New-ValidL4D2Config
            $config.WorkshopItems = 'not-an-array'

            { Test-L4D2ServerConfig -Config $config } | Should -Throw '*WorkshopItems*'
        }
    }

    Context 'Get-L4D2LaunchArgs' {
        It 'builds the confirmed -console/-port/+map/+maxplayers/+mp_gamemode arguments for the default template values' {
            $launchArgs = Get-L4D2LaunchArgs -Config (New-ValidL4D2Config)

            ($launchArgs -join '|') | Should -Be (@('-console', '-port', '27015', '+map', 'c1m1_hotel', '+maxplayers', '8', '+mp_gamemode', 'coop') -join '|')
        }

        It 'passes the map name through as-is, with no mode-suffix logic on the map itself' {
            $config = New-ValidL4D2Config
            $config.Map = 'c8m1_apartment'

            $launchArgs = Get-L4D2LaunchArgs -Config $config

            $launchArgs | Should -Contain 'c8m1_apartment'
        }

        It 'builds +mp_gamemode from the Mode field' {
            $config = New-ValidL4D2Config
            $config.Mode = 'versus'

            $launchArgs = Get-L4D2LaunchArgs -Config $config

            $launchArgs | Should -Contain '+mp_gamemode'
            $launchArgs | Should -Contain 'versus'
        }

        It 'appends +rcon_password only when RCONPassword is set' {
            $configWithout = New-ValidL4D2Config
            $argsWithout = Get-L4D2LaunchArgs -Config $configWithout
            $argsWithout | Should -Not -Contain '+rcon_password'

            $configWith = New-ValidL4D2Config
            $configWith.RCONPassword = 'sup3rSecret'
            $argsWith = Get-L4D2LaunchArgs -Config $configWith

            $argsWith | Should -Contain '+rcon_password'
            $argsWith | Should -Contain 'sup3rSecret'
        }

        It 'appends +sv_workshop_enabled 1 only when WorkshopItems is non-empty' {
            $configWithout = New-ValidL4D2Config
            $argsWithout = Get-L4D2LaunchArgs -Config $configWithout
            $argsWithout | Should -Not -Contain '+sv_workshop_enabled'

            $configWith = New-ValidL4D2Config
            $configWith.WorkshopItems = @('123456789')
            $argsWith = Get-L4D2LaunchArgs -Config $configWith

            $argsWith | Should -Contain '+sv_workshop_enabled'
        }

        It 'validates the config before building, throwing rather than returning a malformed launch string' {
            $config = New-ValidL4D2Config
            $config.Map = 'not_a_real_map'

            { Get-L4D2LaunchArgs -Config $config } | Should -Throw '*Map*'
        }
    }
}

Describe 'Plugins/L4D2/Server.psm1 - lifecycle wrappers' {
    BeforeEach {
        Mock -ModuleName Server -CommandName Start-GSMServer -MockWith { $true }
        Mock -ModuleName Server -CommandName Stop-GSMServer -MockWith { $true }
        Mock -ModuleName Server -CommandName Restart-GSMServer -MockWith { $true }
        Mock -ModuleName Server -CommandName Get-GSMServerStatus -MockWith { 'Running' }
        Mock -ModuleName Server -CommandName New-GSMServerConfig -MockWith { $true }
    }

    It 'Start-L4D2Server delegates to Start-GSMServer with this plugin''s FolderName, Executable, and launch-args function name' {
        $result = Start-L4D2Server

        $result | Should -Be $true
        Should -Invoke -ModuleName Server -CommandName Start-GSMServer -Times 1 -ParameterFilter {
            $FolderName -eq 'L4D2' -and $Executable -eq 'srcds.exe' -and $GetLaunchArgsFunctionName -eq 'Get-L4D2LaunchArgs'
        }
    }

    It 'Stop-L4D2Server delegates to Stop-GSMServer with this plugin''s FolderName' {
        $result = Stop-L4D2Server

        $result | Should -Be $true
        Should -Invoke -ModuleName Server -CommandName Stop-GSMServer -Times 1 -ParameterFilter { $FolderName -eq 'L4D2' }
    }

    It 'Restart-L4D2Server delegates to Restart-GSMServer with this plugin''s FolderName, Executable, and launch-args function name' {
        $result = Restart-L4D2Server

        $result | Should -Be $true
        Should -Invoke -ModuleName Server -CommandName Restart-GSMServer -Times 1 -ParameterFilter {
            $FolderName -eq 'L4D2' -and $Executable -eq 'srcds.exe' -and $GetLaunchArgsFunctionName -eq 'Get-L4D2LaunchArgs'
        }
    }

    It 'Get-L4D2ServerStatus delegates to Get-GSMServerStatus with this plugin''s FolderName' {
        $result = Get-L4D2ServerStatus

        $result | Should -Be 'Running'
        Should -Invoke -ModuleName Server -CommandName Get-GSMServerStatus -Times 1 -ParameterFilter { $FolderName -eq 'L4D2' }
    }

    It 'New-L4D2Config delegates to New-GSMServerConfig with this plugin''s config metadata' {
        $result = New-L4D2Config

        $result | Should -Be $true
        Should -Invoke -ModuleName Server -CommandName New-GSMServerConfig -Times 1 -ParameterFilter {
            $FolderName -eq 'L4D2' -and $GameName -eq 'Left4Dead' -and $AppID -eq '222860' -and $DefaultPort -eq 27015 -and
            $GetMapsFunctionName -eq 'Get-L4D2Maps' -and $TestServerConfigFunctionName -eq 'Test-L4D2ServerConfig' -and
            $RequiresMode -eq $true -and $GetModesFunctionName -eq 'Get-L4D2Modes' -and $SupportsWorkshop -eq $true
        }
    }
}
