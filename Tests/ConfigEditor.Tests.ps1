BeforeAll {
    Import-Module "$PSScriptRoot/../Core/ConfigEditor.psm1" -Force

    function New-FakeGSMRootForConfigEditor {
        $root = Join-Path $TestDrive ('configeditor-root-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $root 'Config') -Force | Out-Null
        return $root
    }

    # Real, globally-available stand-ins for a plugin's own Get-<Game>Maps /
    # Get-<Game>Modes / Test-<Game>ServerConfig, resolved by name via
    # Get-Command inside ConfigEditor.psm1, matching Menu.psm1's dispatch
    # pattern - not something Mock -ModuleName can intercept from outside
    # the plugin.
    #
    # Must be defined with the global: scope modifier, not just a bare
    # "function" (which only reaches script scope of this test file):
    # Get-Command, called from inside the ConfigEditor module - a sibling
    # scope, not a descendant of this BeforeAll - can only resolve Global
    # scope or another module's exported members.
    function global:Get-FakeGameMaps { return @('map_one', 'map_two') }
    function global:Get-FakeGameModes { return @('mode_one', 'mode_two') }

    $script:FakeGameConfigShouldThrow = $false
    function global:Test-FakeGameServerConfig {
        param($Config)
        if ($script:FakeGameConfigShouldThrow) {
            $script:FakeGameConfigShouldThrow = $false
            throw "MaxPlayers value '$($Config.MaxPlayers)' is out of range."
        }
    }
}

AfterAll {
    # Global function fixtures must not leak into whichever test file runs
    # next in the same Pester process.
    Remove-Item -Path 'function:global:Get-FakeGameMaps', 'function:global:Get-FakeGameModes', 'function:global:Test-FakeGameServerConfig' -Force -ErrorAction SilentlyContinue
}

Describe 'Core/ConfigEditor.psm1' {

    BeforeEach {
        $script:FakeGameConfigShouldThrow = $false
        Mock -ModuleName ConfigEditor -CommandName Write-GSMLog -MockWith { }
    }

    Context 'New-GSMServerConfig - preconditions' {
        It 'throws when -RequiresMode is set without GetModesFunctionName' {
            {
                New-GSMServerConfig -FolderName 'FakeGame' -GameName 'FakeGame' -AppID '1' -DefaultPort 27015 `
                    -GetMapsFunctionName 'Get-FakeGameMaps' -TestServerConfigFunctionName 'Test-FakeGameServerConfig' -RequiresMode
            } | Should -Throw '*GetModesFunctionName*'
        }

        It 'throws when GetMapsFunctionName does not resolve to a real command' {
            {
                New-GSMServerConfig -FolderName 'FakeGame' -GameName 'FakeGame' -AppID '1' -DefaultPort 27015 `
                    -GetMapsFunctionName 'Get-NoSuchMapsFunction' -TestServerConfigFunctionName 'Test-FakeGameServerConfig'
            } | Should -Throw '*not available*'
        }

        It 'throws when TestServerConfigFunctionName does not resolve to a real command' {
            {
                New-GSMServerConfig -FolderName 'FakeGame' -GameName 'FakeGame' -AppID '1' -DefaultPort 27015 `
                    -GetMapsFunctionName 'Get-FakeGameMaps' -TestServerConfigFunctionName 'Test-NoSuchValidationFunction'
            } | Should -Throw '*not available*'
        }

        It 'throws when RequiresMode is set and GetModesFunctionName does not resolve' {
            {
                New-GSMServerConfig -FolderName 'FakeGame' -GameName 'FakeGame' -AppID '1' -DefaultPort 27015 `
                    -GetMapsFunctionName 'Get-FakeGameMaps' -TestServerConfigFunctionName 'Test-FakeGameServerConfig' `
                    -RequiresMode -GetModesFunctionName 'Get-NoSuchModesFunction'
            } | Should -Throw '*not available*'
        }
    }

    Context 'New-GSMServerConfig - happy path, no Mode, no Workshop' {
        BeforeEach {
            $script:FakeRoot = New-FakeGSMRootForConfigEditor
            Mock -ModuleName ConfigEditor -CommandName Get-GSMRootPath -MockWith { $script:FakeRoot }

            Mock -ModuleName ConfigEditor -CommandName Read-GSMPrompt -ParameterFilter { $Message -like 'Map*' } -MockWith { 'map_one' }
            Mock -ModuleName ConfigEditor -CommandName Read-Host -ParameterFilter { $Prompt -like 'DefaultPort*' } -MockWith { '27015' }
            Mock -ModuleName ConfigEditor -CommandName Read-Host -ParameterFilter { $Prompt -like 'MaxPlayers*' } -MockWith { '24' }
            Mock -ModuleName ConfigEditor -CommandName Read-Host -ParameterFilter { $Prompt -like 'RCONPassword*' } -MockWith { '' }
        }

        It 'writes a valid config to Config/<FolderName>.json' {
            $result = New-GSMServerConfig -FolderName 'FakeGame' -GameName 'FakeGame' -AppID '1' -DefaultPort 27015 `
                -GetMapsFunctionName 'Get-FakeGameMaps' -TestServerConfigFunctionName 'Test-FakeGameServerConfig'

            $result | Should -Be $true

            $configPath = Join-Path $script:FakeRoot 'Config/FakeGame.json'
            Test-Path -Path $configPath | Should -Be $true

            $written = Get-Content -Path $configPath -Raw | ConvertFrom-Json
            $written.GameName | Should -Be 'FakeGame'
            $written.AppID | Should -Be '1'
            $written.DefaultPort | Should -Be 27015
            $written.Map | Should -Be 'map_one'
            $written.MaxPlayers | Should -Be 24
            $written.PSObject.Properties['Mode'] | Should -BeNullOrEmpty
            $written.PSObject.Properties['WorkshopItems'] | Should -BeNullOrEmpty
        }

        It 'does not create a backup when no config existed yet' {
            New-GSMServerConfig -FolderName 'FakeGame' -GameName 'FakeGame' -AppID '1' -DefaultPort 27015 `
                -GetMapsFunctionName 'Get-FakeGameMaps' -TestServerConfigFunctionName 'Test-FakeGameServerConfig' | Out-Null

            $backupsDirectory = Join-Path $script:FakeRoot 'Backups'
            (Test-Path -Path $backupsDirectory) -and (Get-ChildItem -Path $backupsDirectory -ErrorAction SilentlyContinue) | Should -BeFalse
        }

        It 'reprompts the entire config when the validation function rejects the first attempt' {
            $script:FakeGameConfigShouldThrow = $true

            $result = New-GSMServerConfig -FolderName 'FakeGame' -GameName 'FakeGame' -AppID '1' -DefaultPort 27015 `
                -GetMapsFunctionName 'Get-FakeGameMaps' -TestServerConfigFunctionName 'Test-FakeGameServerConfig'

            $result | Should -Be $true
            Should -Invoke -ModuleName ConfigEditor -CommandName Read-GSMPrompt -Times 2 -ParameterFilter { $Message -like 'Map*' }
        }
    }

    Context 'New-GSMServerConfig - RequiresMode' {
        It 'also prompts for Mode and includes it in the written config' {
            $fakeRoot = New-FakeGSMRootForConfigEditor
            Mock -ModuleName ConfigEditor -CommandName Get-GSMRootPath -MockWith { $fakeRoot }
            Mock -ModuleName ConfigEditor -CommandName Read-GSMPrompt -ParameterFilter { $Message -like 'Map*' } -MockWith { 'map_one' }
            Mock -ModuleName ConfigEditor -CommandName Read-GSMPrompt -ParameterFilter { $Message -like 'Mode*' } -MockWith { 'mode_two' }
            Mock -ModuleName ConfigEditor -CommandName Read-Host -ParameterFilter { $Prompt -like 'DefaultPort*' } -MockWith { '27015' }
            Mock -ModuleName ConfigEditor -CommandName Read-Host -ParameterFilter { $Prompt -like 'MaxPlayers*' } -MockWith { '8' }
            Mock -ModuleName ConfigEditor -CommandName Read-Host -ParameterFilter { $Prompt -like 'RCONPassword*' } -MockWith { '' }

            New-GSMServerConfig -FolderName 'FakeGame' -GameName 'FakeGame' -AppID '1' -DefaultPort 27015 `
                -GetMapsFunctionName 'Get-FakeGameMaps' -TestServerConfigFunctionName 'Test-FakeGameServerConfig' `
                -RequiresMode -GetModesFunctionName 'Get-FakeGameModes' | Out-Null

            $written = Get-Content -Path (Join-Path $fakeRoot 'Config/FakeGame.json') -Raw | ConvertFrom-Json
            $written.Mode | Should -Be 'mode_two'
        }
    }

    Context 'New-GSMServerConfig - SupportsWorkshop' {
        BeforeEach {
            $script:FakeRoot = New-FakeGSMRootForConfigEditor
            Mock -ModuleName ConfigEditor -CommandName Get-GSMRootPath -MockWith { $script:FakeRoot }
            Mock -ModuleName ConfigEditor -CommandName Read-GSMPrompt -ParameterFilter { $Message -like 'Map*' } -MockWith { 'map_one' }
            Mock -ModuleName ConfigEditor -CommandName Read-Host -ParameterFilter { $Prompt -like 'DefaultPort*' } -MockWith { '27015' }
            Mock -ModuleName ConfigEditor -CommandName Read-Host -ParameterFilter { $Prompt -like 'MaxPlayers*' } -MockWith { '24' }
            Mock -ModuleName ConfigEditor -CommandName Read-Host -ParameterFilter { $Prompt -like 'RCONPassword*' } -MockWith { '' }
        }

        It 'parses a comma-separated WorkshopItems response into a trimmed string array' {
            Mock -ModuleName ConfigEditor -CommandName Read-Host -ParameterFilter { $Prompt -like 'WorkshopItems*' } -MockWith { '111111, 222222 ,333333' }

            New-GSMServerConfig -FolderName 'FakeGame' -GameName 'FakeGame' -AppID '1' -DefaultPort 27015 `
                -GetMapsFunctionName 'Get-FakeGameMaps' -TestServerConfigFunctionName 'Test-FakeGameServerConfig' -SupportsWorkshop | Out-Null

            $written = Get-Content -Path (Join-Path $script:FakeRoot 'Config/FakeGame.json') -Raw | ConvertFrom-Json
            @($written.WorkshopItems) | Should -Be @('111111', '222222', '333333')
        }

        It 'writes an empty WorkshopItems array when left blank' {
            Mock -ModuleName ConfigEditor -CommandName Read-Host -ParameterFilter { $Prompt -like 'WorkshopItems*' } -MockWith { '' }

            New-GSMServerConfig -FolderName 'FakeGame' -GameName 'FakeGame' -AppID '1' -DefaultPort 27015 `
                -GetMapsFunctionName 'Get-FakeGameMaps' -TestServerConfigFunctionName 'Test-FakeGameServerConfig' -SupportsWorkshop | Out-Null

            $written = Get-Content -Path (Join-Path $script:FakeRoot 'Config/FakeGame.json') -Raw | ConvertFrom-Json
            @($written.WorkshopItems).Count | Should -Be 0
        }
    }

    Context 'New-GSMServerConfig - existing config' {
        It 'pre-populates prompt text with the current value and backs up the old file before overwriting' {
            $fakeRoot = New-FakeGSMRootForConfigEditor
            Mock -ModuleName ConfigEditor -CommandName Get-GSMRootPath -MockWith { $fakeRoot }

            $existingConfigPath = Join-Path $fakeRoot 'Config/FakeGame.json'
            [PSCustomObject]@{ GameName = 'FakeGame'; AppID = '1'; DefaultPort = 27015; Map = 'map_two'; MaxPlayers = 16; RCONPassword = '' } |
                ConvertTo-Json | Set-Content -Path $existingConfigPath

            Mock -ModuleName ConfigEditor -CommandName Read-GSMPrompt -ParameterFilter { $Message -like 'Map (current: map_two)*' } -MockWith { 'map_one' }
            Mock -ModuleName ConfigEditor -CommandName Read-Host -ParameterFilter { $Prompt -like 'DefaultPort (current: 27015)*' } -MockWith { '27015' }
            Mock -ModuleName ConfigEditor -CommandName Read-Host -ParameterFilter { $Prompt -like 'MaxPlayers (current: 16)*' } -MockWith { '32' }
            Mock -ModuleName ConfigEditor -CommandName Read-Host -ParameterFilter { $Prompt -like 'RCONPassword*' } -MockWith { '' }

            New-GSMServerConfig -FolderName 'FakeGame' -GameName 'FakeGame' -AppID '1' -DefaultPort 27015 `
                -GetMapsFunctionName 'Get-FakeGameMaps' -TestServerConfigFunctionName 'Test-FakeGameServerConfig' | Out-Null

            $written = Get-Content -Path $existingConfigPath -Raw | ConvertFrom-Json
            $written.Map | Should -Be 'map_one'
            $written.MaxPlayers | Should -Be 32

            $backupFiles = Get-ChildItem -Path (Join-Path $fakeRoot 'Backups') -Filter 'FakeGame-*.json'
            $backupFiles.Count | Should -Be 1
            (Get-Content -Path $backupFiles[0].FullName -Raw | ConvertFrom-Json).Map | Should -Be 'map_two'
        }
    }
}
