BeforeAll {
    # See Tests/CounterStrikeSource.Install.Tests.ps1 for why these
    # Remove-Module calls are needed: every plugin's Server/Maps/Modes
    # modules share the same bare module names.
    Remove-Module -Name 'Server', 'Maps', 'Modes' -Force -ErrorAction SilentlyContinue
    Import-Module "$PSScriptRoot/../Plugins/CounterStrikeSource/Server.psm1" -Force

    # Server.psm1 imports Maps.psm1/Modes.psm1 itself, but only into its own
    # module scope, so this test file also imports them directly to call
    # Get-CounterStrikeSourceMaps/Get-CounterStrikeSourceModes at the
    # Describe/It level.
    Import-Module "$PSScriptRoot/../Plugins/CounterStrikeSource/Maps.psm1" -Force
    Import-Module "$PSScriptRoot/../Plugins/CounterStrikeSource/Modes.psm1" -Force

    Import-Module "$PSScriptRoot/../Core/Config.psm1" -Force

    $script:ConfigTemplatePath = "$PSScriptRoot/../Plugins/CounterStrikeSource/Config.template.json"

    function New-ValidCounterStrikeSourceConfig {
        [PSCustomObject]@{
            GameName     = 'CounterStrike'
            AppID        = '232330'
            DefaultPort  = 27015
            Map          = 'de_dust2'
            MaxPlayers   = 24
            RCONPassword = ''
        }
    }
}

Describe 'Plugins/CounterStrikeSource/Server.psm1' {

    Context 'Config.template.json' {
        It 'round-trips through Core/Config.psm1''s Test-GSMConfig without any changes to that module' {
            $rawJson = Get-Content -Path $script:ConfigTemplatePath -Raw
            $config = $rawJson | ConvertFrom-Json

            { Test-GSMConfig -Config $config -RawJson $rawJson } | Should -Not -Throw
        }

        It 'also passes Counter-Strike: Source-specific validation (Map, MaxPlayers, etc.)' {
            $config = Get-Content -Path $script:ConfigTemplatePath -Raw | ConvertFrom-Json

            { Test-CounterStrikeSourceServerConfig -Config $config } | Should -Not -Throw
        }

        It 'builds the confirmed launch arguments from the template as-is' {
            $config = Get-Content -Path $script:ConfigTemplatePath -Raw | ConvertFrom-Json

            $launchArgs = Get-CounterStrikeSourceLaunchArgs -Config $config

            ($launchArgs -join '|') | Should -Be (@('-console', '-port', '27015', '+map', 'de_dust2', '+maxplayers', '24') -join '|')
        }

        It 'does not contain a WorkshopItems field, since this plugin does not support Workshop' {
            $config = Get-Content -Path $script:ConfigTemplatePath -Raw | ConvertFrom-Json

            $config.PSObject.Properties['WorkshopItems'] | Should -BeNullOrEmpty
        }

        It 'does not contain a Mode field, since Map already encodes objective type via prefix' {
            $config = Get-Content -Path $script:ConfigTemplatePath -Raw | ConvertFrom-Json

            $config.PSObject.Properties['Mode'] | Should -BeNullOrEmpty
        }
    }

    Context 'Test-CounterStrikeSourceServerConfig - valid config' {
        It 'does not throw for a fully valid config' {
            { Test-CounterStrikeSourceServerConfig -Config (New-ValidCounterStrikeSourceConfig) } | Should -Not -Throw
        }

        It 'accepts every confirmed official stock map without throwing' {
            foreach ($map in Get-CounterStrikeSourceMaps) {
                $config = New-ValidCounterStrikeSourceConfig
                $config.Map = $map

                { Test-CounterStrikeSourceServerConfig -Config $config } | Should -Not -Throw -Because "map '$map' should be valid"
            }
        }
    }

    Context 'Test-CounterStrikeSourceServerConfig - invalid config' {
        It 'throws when Map is missing' {
            $config = New-ValidCounterStrikeSourceConfig
            $config.PSObject.Properties.Remove('Map')

            { Test-CounterStrikeSourceServerConfig -Config $config } | Should -Throw '*Map*'
        }

        It 'throws when Map is not a recognized stock map' {
            $config = New-ValidCounterStrikeSourceConfig
            $config.Map = 'not_a_real_map'

            { Test-CounterStrikeSourceServerConfig -Config $config } | Should -Throw '*Map*'
        }

        It 'throws when DefaultPort is out of range' {
            $config = New-ValidCounterStrikeSourceConfig
            $config.DefaultPort = 99999

            { Test-CounterStrikeSourceServerConfig -Config $config } | Should -Throw '*DefaultPort*'
        }

        It 'throws when MaxPlayers is missing' {
            $config = New-ValidCounterStrikeSourceConfig
            $config.PSObject.Properties.Remove('MaxPlayers')

            { Test-CounterStrikeSourceServerConfig -Config $config } | Should -Throw '*MaxPlayers*'
        }

        It 'throws when MaxPlayers is out of range' {
            $config = New-ValidCounterStrikeSourceConfig
            $config.MaxPlayers = 100

            { Test-CounterStrikeSourceServerConfig -Config $config } | Should -Throw '*MaxPlayers*'
        }

        It 'throws when RCONPassword is not a string' {
            $config = New-ValidCounterStrikeSourceConfig
            $config.RCONPassword = 12345

            { Test-CounterStrikeSourceServerConfig -Config $config } | Should -Throw '*RCONPassword*'
        }
    }

    Context 'Get-CounterStrikeSourceLaunchArgs' {
        It 'builds the confirmed -console/-port/+map/+maxplayers arguments for the default template values' {
            $launchArgs = Get-CounterStrikeSourceLaunchArgs -Config (New-ValidCounterStrikeSourceConfig)

            ($launchArgs -join '|') | Should -Be (@('-console', '-port', '27015', '+map', 'de_dust2', '+maxplayers', '24') -join '|')
        }

        It 'passes the map name through as-is, with no mode-suffix logic' {
            $config = New-ValidCounterStrikeSourceConfig
            $config.Map = 'cs_office'

            $launchArgs = Get-CounterStrikeSourceLaunchArgs -Config $config

            $launchArgs | Should -Contain 'cs_office'
        }

        It 'appends +rcon_password only when RCONPassword is set' {
            $configWithout = New-ValidCounterStrikeSourceConfig
            $argsWithout = Get-CounterStrikeSourceLaunchArgs -Config $configWithout
            $argsWithout | Should -Not -Contain '+rcon_password'

            $configWith = New-ValidCounterStrikeSourceConfig
            $configWith.RCONPassword = 'sup3rSecret'
            $argsWith = Get-CounterStrikeSourceLaunchArgs -Config $configWith

            $argsWith | Should -Contain '+rcon_password'
            $argsWith | Should -Contain 'sup3rSecret'
        }

        It 'validates the config before building, throwing rather than returning a malformed launch string' {
            $config = New-ValidCounterStrikeSourceConfig
            $config.Map = 'not_a_real_map'

            { Get-CounterStrikeSourceLaunchArgs -Config $config } | Should -Throw '*Map*'
        }

        It 'never emits a Workshop-related argument, since this plugin does not support Workshop' {
            $launchArgs = Get-CounterStrikeSourceLaunchArgs -Config (New-ValidCounterStrikeSourceConfig)

            $launchArgs | Should -Not -Contain '+sv_workshop_enabled'
            ($launchArgs -join ' ') | Should -Not -Match 'workshop'
        }
    }
}

Describe 'Plugins/CounterStrikeSource/Server.psm1 - lifecycle wrappers' {
    BeforeEach {
        Mock -ModuleName Server -CommandName Start-GSMServer -MockWith { $true }
        Mock -ModuleName Server -CommandName Stop-GSMServer -MockWith { $true }
        Mock -ModuleName Server -CommandName Restart-GSMServer -MockWith { $true }
        Mock -ModuleName Server -CommandName Get-GSMServerStatus -MockWith { 'Running' }
        Mock -ModuleName Server -CommandName New-GSMServerConfig -MockWith { $true }
    }

    It 'Start-CounterStrikeSourceServer delegates to Start-GSMServer with this plugin''s FolderName, Executable, and launch-args function name' {
        $result = Start-CounterStrikeSourceServer

        $result | Should -Be $true
        Should -Invoke -ModuleName Server -CommandName Start-GSMServer -Times 1 -ParameterFilter {
            $FolderName -eq 'CounterStrikeSource' -and $Executable -eq 'srcds.exe' -and $GetLaunchArgsFunctionName -eq 'Get-CounterStrikeSourceLaunchArgs'
        }
    }

    It 'Stop-CounterStrikeSourceServer delegates to Stop-GSMServer with this plugin''s FolderName' {
        $result = Stop-CounterStrikeSourceServer

        $result | Should -Be $true
        Should -Invoke -ModuleName Server -CommandName Stop-GSMServer -Times 1 -ParameterFilter { $FolderName -eq 'CounterStrikeSource' }
    }

    It 'Restart-CounterStrikeSourceServer delegates to Restart-GSMServer with this plugin''s FolderName, Executable, and launch-args function name' {
        $result = Restart-CounterStrikeSourceServer

        $result | Should -Be $true
        Should -Invoke -ModuleName Server -CommandName Restart-GSMServer -Times 1 -ParameterFilter {
            $FolderName -eq 'CounterStrikeSource' -and $Executable -eq 'srcds.exe' -and $GetLaunchArgsFunctionName -eq 'Get-CounterStrikeSourceLaunchArgs'
        }
    }

    It 'Get-CounterStrikeSourceServerStatus delegates to Get-GSMServerStatus with this plugin''s FolderName' {
        $result = Get-CounterStrikeSourceServerStatus

        $result | Should -Be 'Running'
        Should -Invoke -ModuleName Server -CommandName Get-GSMServerStatus -Times 1 -ParameterFilter { $FolderName -eq 'CounterStrikeSource' }
    }

    It 'New-CounterStrikeSourceConfig delegates to New-GSMServerConfig with this plugin''s config metadata, without RequiresMode or SupportsWorkshop' {
        $result = New-CounterStrikeSourceConfig

        $result | Should -Be $true
        Should -Invoke -ModuleName Server -CommandName New-GSMServerConfig -Times 1 -ParameterFilter {
            $FolderName -eq 'CounterStrikeSource' -and $GameName -eq 'CounterStrike' -and $AppID -eq '232330' -and $DefaultPort -eq 27015 -and
            $GetMapsFunctionName -eq 'Get-CounterStrikeSourceMaps' -and $TestServerConfigFunctionName -eq 'Test-CounterStrikeSourceServerConfig' -and
            -not $RequiresMode -and -not $SupportsWorkshop
        }
    }
}
