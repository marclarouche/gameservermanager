BeforeAll {
    Import-Module "$PSScriptRoot/../Core/Update.psm1" -Force

    function New-FakeGSMRootForUpdate {
        param(
            [string]$FolderName = 'FakeGame',
            [string]$AppID = '1',
            [switch]$WithConfig
        )

        $root = Join-Path $TestDrive ('update-root-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $root 'Config') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root "Servers/$FolderName") -Force | Out-Null

        if ($WithConfig) {
            Set-Content -Path (Join-Path $root "Config/$FolderName.json") -Value (@{ GameName = 'FakeGame'; AppID = $AppID } | ConvertTo-Json)
        }

        return $root
    }
}

Describe 'Core/Update.psm1' {

    BeforeEach {
        Mock -ModuleName Update -CommandName Write-GSMLog -MockWith { }
        Mock -ModuleName Update -CommandName Stop-GSMServer -MockWith { $true }
        Mock -ModuleName Update -CommandName Update-SteamApp -MockWith { }
        Mock -ModuleName Update -CommandName Start-GSMServer -MockWith { $true }

        $script:FakeRoot = New-FakeGSMRootForUpdate -FolderName 'FakeGame' -AppID '1' -WithConfig
        Mock -ModuleName Update -CommandName Get-GSMRootPath -MockWith { $script:FakeRoot }
    }

    Context 'successful update lifecycle' {
        It 'stops the server before updating' {
            Update-GSMServer -FolderName 'FakeGame' -Executable 'srcds.exe' -GetLaunchArgsFunctionName 'Get-FakeGameLaunchArgs' | Out-Null

            Should -Invoke -ModuleName Update -CommandName Stop-GSMServer -Times 1 -ParameterFilter { $FolderName -eq 'FakeGame' }
        }

        It 'calls Update-SteamApp with the config''s AppID and the Servers/<FolderName> install directory' {
            Update-GSMServer -FolderName 'FakeGame' -Executable 'srcds.exe' -GetLaunchArgsFunctionName 'Get-FakeGameLaunchArgs' | Out-Null

            $expectedInstallDirectory = Join-Path $script:FakeRoot 'Servers/FakeGame'
            Should -Invoke -ModuleName Update -CommandName Update-SteamApp -Times 1 -ParameterFilter {
                $AppID -eq '1' -and $InstallDirectory -eq $expectedInstallDirectory
            }
        }

        It 'restarts the server via Start-GSMServer with the given Executable, launch-args function, and AccountName, after a successful update' {
            $result = Update-GSMServer -FolderName 'FakeGame' -Executable 'srcds.exe' -GetLaunchArgsFunctionName 'Get-FakeGameLaunchArgs' -AccountName 'CustomAccount'

            $result | Should -Be $true
            Should -Invoke -ModuleName Update -CommandName Start-GSMServer -Times 1 -ParameterFilter {
                $FolderName -eq 'FakeGame' -and $Executable -eq 'srcds.exe' -and $GetLaunchArgsFunctionName -eq 'Get-FakeGameLaunchArgs' -and $AccountName -eq 'CustomAccount'
            }
        }

        It 'defaults AccountName to GSM-ServiceAccount when not specified' {
            Update-GSMServer -FolderName 'FakeGame' -Executable 'srcds.exe' -GetLaunchArgsFunctionName 'Get-FakeGameLaunchArgs' | Out-Null

            Should -Invoke -ModuleName Update -CommandName Start-GSMServer -Times 1 -ParameterFilter { $AccountName -eq 'GSM-ServiceAccount' }
        }

        It 'performs the lifecycle in order: stop, then update, then restart' {
            $script:callOrder = [System.Collections.Generic.List[string]]::new()
            Mock -ModuleName Update -CommandName Stop-GSMServer -MockWith { $script:callOrder.Add('Stop'); $true }
            Mock -ModuleName Update -CommandName Update-SteamApp -MockWith { $script:callOrder.Add('Update') }
            Mock -ModuleName Update -CommandName Start-GSMServer -MockWith { $script:callOrder.Add('Start'); $true }

            Update-GSMServer -FolderName 'FakeGame' -Executable 'srcds.exe' -GetLaunchArgsFunctionName 'Get-FakeGameLaunchArgs' | Out-Null

            ($script:callOrder -join ',') | Should -Be 'Stop,Update,Start'
        }
    }

    Context 'update failure' {
        It 'never calls Start-GSMServer when Update-SteamApp throws, leaving the server stopped' {
            Mock -ModuleName Update -CommandName Update-SteamApp -MockWith { throw 'simulated steamcmd failure' }

            { Update-GSMServer -FolderName 'FakeGame' -Executable 'srcds.exe' -GetLaunchArgsFunctionName 'Get-FakeGameLaunchArgs' } | Should -Throw '*Update failed*'

            Should -Invoke -ModuleName Update -CommandName Start-GSMServer -Times 0
        }

        It 'still stops the server before the update attempt, even though it later fails' {
            Mock -ModuleName Update -CommandName Update-SteamApp -MockWith { throw 'simulated steamcmd failure' }

            { Update-GSMServer -FolderName 'FakeGame' -Executable 'srcds.exe' -GetLaunchArgsFunctionName 'Get-FakeGameLaunchArgs' } | Should -Throw

            Should -Invoke -ModuleName Update -CommandName Stop-GSMServer -Times 1
        }

        It 'includes the underlying SteamCMD error message in the thrown error' {
            Mock -ModuleName Update -CommandName Update-SteamApp -MockWith { throw 'steamcmd.exe exited with code 7' }

            { Update-GSMServer -FolderName 'FakeGame' -Executable 'srcds.exe' -GetLaunchArgsFunctionName 'Get-FakeGameLaunchArgs' } | Should -Throw '*exited with code 7*'
        }
    }

    Context 'missing config' {
        It 'throws, and never calls Stop-GSMServer, Update-SteamApp, or Start-GSMServer, when Config/<FolderName>.json does not exist' {
            $script:FakeRoot = New-FakeGSMRootForUpdate -FolderName 'NoConfigGame'
            Mock -ModuleName Update -CommandName Get-GSMRootPath -MockWith { $script:FakeRoot }

            { Update-GSMServer -FolderName 'NoConfigGame' -Executable 'srcds.exe' -GetLaunchArgsFunctionName 'Get-FakeGameLaunchArgs' } | Should -Throw '*No config found*'

            Should -Invoke -ModuleName Update -CommandName Stop-GSMServer -Times 0
            Should -Invoke -ModuleName Update -CommandName Update-SteamApp -Times 0
            Should -Invoke -ModuleName Update -CommandName Start-GSMServer -Times 0
        }
    }
}
