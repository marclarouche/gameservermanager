BeforeAll {
    # Every plugin's Install/Server/Maps/Modes modules share these same bare
    # names (see Core/PluginLoader.psm1's Import-GSMPlugin), so a stale copy
    # left loaded by another test file/run in this same session has to be
    # removed first, or Pester's -ModuleName resolution fails with
    # "Multiple script or manifest modules named 'Install' are currently
    # loaded."
    Remove-Module -Name 'Install' -Force -ErrorAction SilentlyContinue
    Import-Module "$PSScriptRoot/../Plugins/Insurgency2014/Install.psm1" -Force
}

Describe 'Plugins/Insurgency2014/Install.psm1' {

    Context 'Install-Insurgency2014Server' {
        BeforeEach {
            Mock -ModuleName Install -CommandName Get-GSMRootPath -MockWith { 'D:\Fake\GSM' }
            Mock -ModuleName Install -CommandName Update-SteamApp -MockWith { }
            Mock -ModuleName Install -CommandName Write-GSMLog -MockWith { }
        }

        It 'calls Update-SteamApp with AppID 237410 and the Servers/Insurgency2014 install directory' {
            Install-Insurgency2014Server

            Should -Invoke -ModuleName Install -CommandName Update-SteamApp -Times 1 -ParameterFilter {
                $AppID -eq '237410' -and
                $InstallDirectory -eq (Join-Path 'D:\Fake\GSM' 'Servers/Insurgency2014')
            }
        }

        It 'returns $true on success' {
            $result = Install-Insurgency2014Server

            $result | Should -Be $true
        }

        It 'does not hit the network or SteamCMD directly (only through Update-SteamApp)' {
            Install-Insurgency2014Server | Out-Null

            Should -Invoke -ModuleName Install -CommandName Update-SteamApp -Times 1
        }

        It 'logs and rethrows when Update-SteamApp fails' {
            Mock -ModuleName Install -CommandName Update-SteamApp -MockWith { throw 'simulated steamcmd failure' }

            { Install-Insurgency2014Server } | Should -Throw '*simulated steamcmd failure*'

            Should -Invoke -ModuleName Install -CommandName Write-GSMLog -Times 1 -ParameterFilter { $Level -eq 'Error' }
        }
    }

    Context 'Add-Insurgency2014WorkshopItem' {
        BeforeEach {
            $script:FakeRoot = Join-Path $TestDrive ('insurgency-install-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $script:FakeRoot -Force | Out-Null
            Mock -ModuleName Install -CommandName Get-GSMRootPath -MockWith { $script:FakeRoot }

            $script:ContentPath = Join-Path $script:FakeRoot 'SteamCMD/steamapps/workshop/content/237410/123'
            New-Item -ItemType Directory -Path $script:ContentPath -Force | Out-Null
            Set-Content -Path (Join-Path $script:ContentPath 'map.bsp') -Value 'fake map content'
        }

        It 'throws when ContentPath does not exist' {
            $missingPath = Join-Path $script:FakeRoot 'no-such-content'

            { Add-Insurgency2014WorkshopItem -WorkshopID '123' -ContentPath $missingPath } | Should -Throw '*not found*'
        }

        It 'links the addons folder to ContentPath as a directory junction' {
            $result = Add-Insurgency2014WorkshopItem -WorkshopID '123' -ContentPath $script:ContentPath

            $result | Should -Be $true

            $destinationPath = Join-Path $script:FakeRoot 'Servers/Insurgency2014/insurgency/addons/123'
            (Get-Item -Path $destinationPath).LinkType | Should -Be 'Junction'
            Get-Content -Path (Join-Path $destinationPath 'map.bsp') | Should -Be 'fake map content'
        }

        It 're-adding the same WorkshopID replaces the junction rather than layering on top of it' {
            Add-Insurgency2014WorkshopItem -WorkshopID '123' -ContentPath $script:ContentPath | Out-Null

            $updatedContentPath = Join-Path $script:FakeRoot 'SteamCMD/steamapps/workshop/content/237410/123-updated'
            New-Item -ItemType Directory -Path $updatedContentPath -Force | Out-Null
            Set-Content -Path (Join-Path $updatedContentPath 'map.bsp') -Value 'updated map content'

            Add-Insurgency2014WorkshopItem -WorkshopID '123' -ContentPath $updatedContentPath | Out-Null

            $destinationPath = Join-Path $script:FakeRoot 'Servers/Insurgency2014/insurgency/addons/123'
            Get-Content -Path (Join-Path $destinationPath 'map.bsp') | Should -Be 'updated map content'
        }
    }

    Context 'Remove-Insurgency2014WorkshopItem' {
        BeforeEach {
            $script:FakeRoot = Join-Path $TestDrive ('insurgency-install-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $script:FakeRoot -Force | Out-Null
            Mock -ModuleName Install -CommandName Get-GSMRootPath -MockWith { $script:FakeRoot }
            Mock -ModuleName Install -CommandName Write-GSMLog -MockWith { }
        }

        It 'removes a placed Workshop item' {
            $contentPath = Join-Path $script:FakeRoot 'SteamCMD/steamapps/workshop/content/237410/123'
            New-Item -ItemType Directory -Path $contentPath -Force | Out-Null
            Add-Insurgency2014WorkshopItem -WorkshopID '123' -ContentPath $contentPath | Out-Null

            $result = Remove-Insurgency2014WorkshopItem -WorkshopID '123'

            $result | Should -Be $true
            Test-Path -Path (Join-Path $script:FakeRoot 'Servers/Insurgency2014/insurgency/addons/123') | Should -Be $false
        }

        It 'is a no-op that still returns $true when nothing is placed for that WorkshopID' {
            $result = Remove-Insurgency2014WorkshopItem -WorkshopID 'never-placed'

            $result | Should -Be $true
            Should -Invoke -ModuleName Install -CommandName Write-GSMLog -Times 1 -ParameterFilter { $Level -eq 'Info' }
        }
    }
}
