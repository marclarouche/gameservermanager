BeforeAll {
    # Every plugin's Install/Server/Maps/Modes modules share these same bare
    # names (see Core/PluginLoader.psm1's Import-GSMPlugin), so a stale copy
    # left loaded by another test file/run in this same session has to be
    # removed first, or Pester's -ModuleName resolution fails with
    # "Multiple script or manifest modules named 'Install' are currently
    # loaded."
    Remove-Module -Name 'Install' -Force -ErrorAction SilentlyContinue
    Import-Module "$PSScriptRoot/../Plugins/TeamFortress2/Install.psm1" -Force
}

Describe 'Plugins/TeamFortress2/Install.psm1' {

    Context 'Install-TeamFortress2Server' {
        BeforeEach {
            Mock -ModuleName Install -CommandName Get-GSMRootPath -MockWith { 'D:\Fake\GSM' }
            Mock -ModuleName Install -CommandName Update-SteamApp -MockWith { }
            Mock -ModuleName Install -CommandName Write-GSMLog -MockWith { }
        }

        It 'calls Update-SteamApp with AppID 232250 and the Servers/TeamFortress2 install directory' {
            Install-TeamFortress2Server

            Should -Invoke -ModuleName Install -CommandName Update-SteamApp -Times 1 -ParameterFilter {
                $AppID -eq '232250' -and
                $InstallDirectory -eq (Join-Path 'D:\Fake\GSM' 'Servers/TeamFortress2')
            }
        }

        It 'returns $true on success' {
            $result = Install-TeamFortress2Server

            $result | Should -Be $true
        }

        It 'does not hit the network or SteamCMD directly (only through Update-SteamApp)' {
            Install-TeamFortress2Server | Out-Null

            Should -Invoke -ModuleName Install -CommandName Update-SteamApp -Times 1
        }

        It 'logs and rethrows when Update-SteamApp fails' {
            Mock -ModuleName Install -CommandName Update-SteamApp -MockWith { throw 'simulated steamcmd failure' }

            { Install-TeamFortress2Server } | Should -Throw '*simulated steamcmd failure*'

            Should -Invoke -ModuleName Install -CommandName Write-GSMLog -Times 1 -ParameterFilter { $Level -eq 'Error' }
        }
    }

    Context 'Add-TeamFortress2WorkshopItem' {
        BeforeEach {
            $script:FakeRoot = Join-Path $TestDrive ('tf2-install-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $script:FakeRoot -Force | Out-Null
            Mock -ModuleName Install -CommandName Get-GSMRootPath -MockWith { $script:FakeRoot }

            $script:ContentPath = Join-Path $script:FakeRoot 'SteamCMD/steamapps/workshop/content/232250/123'
            New-Item -ItemType Directory -Path $script:ContentPath -Force | Out-Null
            Set-Content -Path (Join-Path $script:ContentPath 'addon.vpk') -Value 'fake vpk content'
        }

        It 'throws when ContentPath does not exist' {
            $missingPath = Join-Path $script:FakeRoot 'no-such-content'

            { Add-TeamFortress2WorkshopItem -WorkshopID '123' -ContentPath $missingPath } | Should -Throw '*not found*'
        }

        It 'copies ContentPath into tf/custom/<WorkshopID>, not a link' {
            $result = Add-TeamFortress2WorkshopItem -WorkshopID '123' -ContentPath $script:ContentPath

            $result | Should -Be $true

            $destinationPath = Join-Path $script:FakeRoot 'Servers/TeamFortress2/tf/custom/123'
            (Get-Item -Path $destinationPath).LinkType | Should -BeNullOrEmpty
            Get-Content -Path (Join-Path $destinationPath 'addon.vpk') | Should -Be 'fake vpk content'
        }

        It 're-adding the same WorkshopID replaces the copy rather than layering on top of it' {
            Add-TeamFortress2WorkshopItem -WorkshopID '123' -ContentPath $script:ContentPath | Out-Null

            $updatedContentPath = Join-Path $script:FakeRoot 'SteamCMD/steamapps/workshop/content/232250/123-updated'
            New-Item -ItemType Directory -Path $updatedContentPath -Force | Out-Null
            Set-Content -Path (Join-Path $updatedContentPath 'addon.vpk') -Value 'updated vpk content'

            Add-TeamFortress2WorkshopItem -WorkshopID '123' -ContentPath $updatedContentPath | Out-Null

            $destinationPath = Join-Path $script:FakeRoot 'Servers/TeamFortress2/tf/custom/123'
            Get-Content -Path (Join-Path $destinationPath 'addon.vpk') | Should -Be 'updated vpk content'
        }
    }

    Context 'Remove-TeamFortress2WorkshopItem' {
        BeforeEach {
            $script:FakeRoot = Join-Path $TestDrive ('tf2-install-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $script:FakeRoot -Force | Out-Null
            Mock -ModuleName Install -CommandName Get-GSMRootPath -MockWith { $script:FakeRoot }
            Mock -ModuleName Install -CommandName Write-GSMLog -MockWith { }
        }

        It 'removes a placed Workshop item' {
            $contentPath = Join-Path $script:FakeRoot 'SteamCMD/steamapps/workshop/content/232250/123'
            New-Item -ItemType Directory -Path $contentPath -Force | Out-Null
            Add-TeamFortress2WorkshopItem -WorkshopID '123' -ContentPath $contentPath | Out-Null

            $result = Remove-TeamFortress2WorkshopItem -WorkshopID '123'

            $result | Should -Be $true
            Test-Path -Path (Join-Path $script:FakeRoot 'Servers/TeamFortress2/tf/custom/123') | Should -Be $false
        }

        It 'is a no-op that still returns $true when nothing is placed for that WorkshopID' {
            $result = Remove-TeamFortress2WorkshopItem -WorkshopID 'never-placed'

            $result | Should -Be $true
            Should -Invoke -ModuleName Install -CommandName Write-GSMLog -Times 1 -ParameterFilter { $Level -eq 'Info' }
        }
    }
}
