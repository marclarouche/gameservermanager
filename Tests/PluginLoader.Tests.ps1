BeforeAll {
    Import-Module "$PSScriptRoot/../Core/PluginLoader.psm1" -Force
    $script:TestDir = Join-Path $TestDrive 'pluginloader-tests'
    New-Item -ItemType Directory -Path $script:TestDir -Force | Out-Null
    $script:RealPluginsDirectory = (Resolve-Path "$PSScriptRoot/../Plugins").Path

    function New-TestPluginFolder {
        param(
            [string]$RootDirectory,
            [string]$FolderName,
            [string]$PluginJsonContent
        )

        $folderPath = Join-Path $RootDirectory $FolderName
        New-Item -ItemType Directory -Path $folderPath -Force | Out-Null

        if ($null -ne $PluginJsonContent) {
            Set-Content -Path (Join-Path $folderPath 'Plugin.json') -Value $PluginJsonContent
        }

        return $folderPath
    }

    $script:ValidPluginJson = '{"GameName":"TestGame","Version":"1","AppID":"999999","Engine":"Source","Executable":"srcds.exe","DefaultPort":27015,"SupportsWorkshop":true,"SupportsRCON":true}'
}

Describe 'Core/PluginLoader.psm1' {

    Context 'Find-GSMPlugins' {
        It 'finds and validates all 5 real Phase 1 plugins' {
            $plugins = Find-GSMPlugins -PluginsDirectory $script:RealPluginsDirectory

            $plugins.Count | Should -Be 5

            $expectedFolders = @('Insurgency2014', 'TeamFortress2', 'CounterStrikeSource', 'L4D', 'L4D2')
            ($plugins.FolderName | Sort-Object) | Should -Be ($expectedFolders | Sort-Object)

            $expectedAppIds = @('237410', '232250', '232330', '222840', '222860')
            ($plugins.AppID | Sort-Object) | Should -Be ($expectedAppIds | Sort-Object)
        }

        It 'skips a folder with no Plugin.json and continues scanning the rest' {
            $dir = Join-Path $script:TestDir 'no-json'
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            New-TestPluginFolder -RootDirectory $dir -FolderName 'GoodPlugin' -PluginJsonContent $script:ValidPluginJson
            New-TestPluginFolder -RootDirectory $dir -FolderName 'NoJsonPlugin' -PluginJsonContent $null

            Mock -ModuleName PluginLoader -CommandName Write-GSMLog -MockWith { }

            $plugins = Find-GSMPlugins -PluginsDirectory $dir

            $plugins.Count | Should -Be 1
            $plugins[0].FolderName | Should -Be 'GoodPlugin'
            Should -Invoke -ModuleName PluginLoader -CommandName Write-GSMLog -Times 1 -ParameterFilter { $Level -eq 'Warning' }
        }

        It 'skips a folder whose Plugin.json is missing a required field' {
            $dir = Join-Path $script:TestDir 'missing-field'
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            New-TestPluginFolder -RootDirectory $dir -FolderName 'GoodPlugin' -PluginJsonContent $script:ValidPluginJson
            $missingEngine = '{"GameName":"TestGame","Version":"1","AppID":"999999","Executable":"srcds.exe","DefaultPort":27015,"SupportsWorkshop":true,"SupportsRCON":true}'
            New-TestPluginFolder -RootDirectory $dir -FolderName 'MissingEnginePlugin' -PluginJsonContent $missingEngine

            Mock -ModuleName PluginLoader -CommandName Write-GSMLog -MockWith { }

            $plugins = Find-GSMPlugins -PluginsDirectory $dir

            $plugins.Count | Should -Be 1
            $plugins[0].FolderName | Should -Be 'GoodPlugin'
            Should -Invoke -ModuleName PluginLoader -CommandName Write-GSMLog -Times 1 -ParameterFilter { $Level -eq 'Warning' }
        }

        It 'skips a folder whose Plugin.json has an invalid DefaultPort' {
            $dir = Join-Path $script:TestDir 'bad-port'
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            New-TestPluginFolder -RootDirectory $dir -FolderName 'GoodPlugin' -PluginJsonContent $script:ValidPluginJson
            $badPort = '{"GameName":"TestGame","Version":"1","AppID":"999999","Engine":"Source","Executable":"srcds.exe","DefaultPort":99999,"SupportsWorkshop":true,"SupportsRCON":true}'
            New-TestPluginFolder -RootDirectory $dir -FolderName 'BadPortPlugin' -PluginJsonContent $badPort

            Mock -ModuleName PluginLoader -CommandName Write-GSMLog -MockWith { }

            $plugins = Find-GSMPlugins -PluginsDirectory $dir

            $plugins.Count | Should -Be 1
            $plugins[0].FolderName | Should -Be 'GoodPlugin'
            Should -Invoke -ModuleName PluginLoader -CommandName Write-GSMLog -Times 1 -ParameterFilter { $Level -eq 'Warning' }
        }
    }

    Context 'Test-GSMPlugin' {
        It 'rejects a non-boolean SupportsWorkshop value' {
            $pluginJson = $script:ValidPluginJson | ConvertFrom-Json
            $pluginJson.SupportsWorkshop = 'true'

            { Test-GSMPlugin -PluginJson $pluginJson } | Should -Throw '*SupportsWorkshop*'
        }

        It 'rejects a non-boolean SupportsRCON value' {
            $pluginJson = $script:ValidPluginJson | ConvertFrom-Json
            $pluginJson.SupportsRCON = 1

            { Test-GSMPlugin -PluginJson $pluginJson } | Should -Throw '*SupportsRCON*'
        }
    }

    Context 'Import-GSMPlugin' {
        It 'imports a real plugin''s Install/Server/Maps/Modes modules' {
            { Import-GSMPlugin -FolderName 'Insurgency2014' -PluginsDirectory $script:RealPluginsDirectory } | Should -Not -Throw

            (Get-Module -Name 'Install').Path | Should -Match 'Insurgency2014'
            (Get-Module -Name 'Server').Path | Should -Match 'Insurgency2014'
            (Get-Module -Name 'Maps').Path | Should -Match 'Insurgency2014'
            (Get-Module -Name 'Modes').Path | Should -Match 'Insurgency2014'
        }

        It 'replaces a previously loaded plugin''s modules instead of keeping them stale' {
            Import-GSMPlugin -FolderName 'Insurgency2014' -PluginsDirectory $script:RealPluginsDirectory
            (Get-Module -Name 'Install').Path | Should -Match 'Insurgency2014'

            Import-GSMPlugin -FolderName 'TeamFortress2' -PluginsDirectory $script:RealPluginsDirectory

            (Get-Module -Name 'Install').Path | Should -Match 'TeamFortress2'
            (Get-Module -Name 'Install').Path | Should -Not -Match 'Insurgency2014'
            (Get-Module -Name 'Server').Path | Should -Match 'TeamFortress2'
            (Get-Module -Name 'Maps').Path | Should -Match 'TeamFortress2'
            (Get-Module -Name 'Modes').Path | Should -Match 'TeamFortress2'
        }
    }
}
