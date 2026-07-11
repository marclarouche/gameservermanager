BeforeAll {
    Import-Module "$PSScriptRoot/../Core/Workshop.psm1" -Force

    function New-FakeGSMWorkshopPlugin {
        param(
            [string]$FolderName = 'FakeGame',
            [string]$AppID = '11111',
            [bool]$SupportsWorkshop = $true
        )

        return [PSCustomObject]@{
            GameName         = 'FakeGame'
            Version          = '1'
            AppID            = $AppID
            Engine           = 'Source'
            Executable       = 'srcds.exe'
            DefaultPort      = 27015
            SupportsWorkshop = $SupportsWorkshop
            SupportsRCON     = $false
            FolderName       = $FolderName
        }
    }

    function New-FakeGSMWorkshopRoot {
        param(
            [string]$FolderName = 'FakeGame',
            [string]$AppID = '11111',
            [string[]]$WorkshopItems,
            [switch]$WithoutConfig
        )

        $root = Join-Path $TestDrive ('workshop-root-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $root 'Config') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root 'SteamCMD') -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $root 'SteamCMD/steamcmd.exe') -Force | Out-Null

        if (-not $WithoutConfig) {
            $config = [ordered]@{
                GameName      = 'FakeGame'
                AppID         = $AppID
                WorkshopItems = @($WorkshopItems)
            }
            $config | ConvertTo-Json | Set-Content -Path (Join-Path $root "Config/$FolderName.json")
        }

        return $root
    }

    function Get-FakeGSMWorkshopConfig {
        param(
            [string]$Root,
            [string]$FolderName
        )

        return Get-Content -Path (Join-Path $Root "Config/$FolderName.json") -Raw | ConvertFrom-Json
    }

    # Fixture placement/removal functions live in Global scope so Get-Command
    # (unmocked, real dispatch) finds them from inside Core/Workshop.psm1 the
    # same way it would find a real plugin's Add-<FolderName>WorkshopItem /
    # Remove-<FolderName>WorkshopItem - matches Tests/Menu.Tests.ps1's
    # identical use of global fixture functions for the same reason.
    function Set-FakeGSMWorkshopPlacementFunctions {
        param(
            [string]$FolderName = 'FakeGame',
            [scriptblock]$OnAdd = { param($WorkshopID, $ContentPath) $null = $WorkshopID, $ContentPath; $true },
            [scriptblock]$OnRemove = { param($WorkshopID) $null = $WorkshopID; $true }
        )

        Set-Item -Path "Function:global:Add-${FolderName}WorkshopItem" -Value $OnAdd
        Set-Item -Path "Function:global:Remove-${FolderName}WorkshopItem" -Value $OnRemove
    }

    function Remove-FakeGSMWorkshopPlacementFunctions {
        param(
            [string]$FolderName = 'FakeGame'
        )

        Remove-Item -Path "Function:global:Add-${FolderName}WorkshopItem" -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "Function:global:Remove-${FolderName}WorkshopItem" -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Core/Workshop.psm1' {

    BeforeEach {
        Mock -ModuleName Workshop -CommandName Write-GSMLog -MockWith { }
        Mock -ModuleName Workshop -CommandName Import-GSMPlugin -MockWith { }
        Mock -ModuleName Workshop -CommandName Test-SteamCMDPresent -MockWith { $true }
    }

    AfterEach {
        Remove-FakeGSMWorkshopPlacementFunctions -FolderName 'FakeGame'
    }

    Context 'Unsupported plugin rejection' {
        BeforeEach {
            $script:FakeRoot = New-FakeGSMWorkshopRoot -FolderName 'FakeGame'
            Mock -ModuleName Workshop -CommandName Get-GSMRootPath -MockWith { $script:FakeRoot }
            Mock -ModuleName Workshop -CommandName Find-GSMPlugins -MockWith {
                @(New-FakeGSMWorkshopPlugin -FolderName 'FakeGame' -SupportsWorkshop $false)
            }
            Mock -ModuleName Workshop -CommandName Start-Process -MockWith { [PSCustomObject]@{ ExitCode = 0 } }
        }

        It 'Add-GSMWorkshopItem throws and never touches SteamCMD' {
            { Add-GSMWorkshopItem -FolderName 'FakeGame' -WorkshopID '999' } | Should -Throw '*does not support Steam Workshop*'
            Should -Invoke -ModuleName Workshop -CommandName Start-Process -Times 0
        }

        It 'Remove-GSMWorkshopItem throws' {
            { Remove-GSMWorkshopItem -FolderName 'FakeGame' -WorkshopID '999' } | Should -Throw '*does not support Steam Workshop*'
        }

        It 'Get-GSMWorkshopItems throws' {
            { Get-GSMWorkshopItems -FolderName 'FakeGame' } | Should -Throw '*does not support Steam Workshop*'
        }

        It 'Update-GSMWorkshopItems throws' {
            { Update-GSMWorkshopItems -FolderName 'FakeGame' } | Should -Throw '*does not support Steam Workshop*'
        }
    }

    Context 'Add-GSMWorkshopItem' {
        BeforeEach {
            $script:FakeRoot = New-FakeGSMWorkshopRoot -FolderName 'FakeGame' -AppID '11111' -WorkshopItems @()
            Mock -ModuleName Workshop -CommandName Get-GSMRootPath -MockWith { $script:FakeRoot }
            Mock -ModuleName Workshop -CommandName Find-GSMPlugins -MockWith {
                @(New-FakeGSMWorkshopPlugin -FolderName 'FakeGame' -AppID '11111')
            }
        }

        It 'downloads, places, and records a new Workshop item' {
            Mock -ModuleName Workshop -CommandName Start-Process -MockWith {
                $contentPath = Join-Path $script:FakeRoot "SteamCMD/steamapps/workshop/content/$($ArgumentList[3])/$($ArgumentList[4])"
                New-Item -ItemType Directory -Path $contentPath -Force | Out-Null
                [PSCustomObject]@{ ExitCode = 0 }
            }
            $script:PlacementCalledWith = $null
            Set-FakeGSMWorkshopPlacementFunctions -FolderName 'FakeGame' -OnAdd {
                param($WorkshopID, $ContentPath)
                $script:PlacementCalledWith = @{ WorkshopID = $WorkshopID; ContentPath = $ContentPath }
                $true
            }

            $result = Add-GSMWorkshopItem -FolderName 'FakeGame' -WorkshopID '123'

            $result | Should -Be $true
            $script:PlacementCalledWith.WorkshopID | Should -Be '123'
            $script:PlacementCalledWith.ContentPath | Should -Match '11111.*123$'

            $config = Get-FakeGSMWorkshopConfig -Root $script:FakeRoot -FolderName 'FakeGame'
            @($config.WorkshopItems) | Should -Contain '123'
        }

        It 'passes the AppID and WorkshopID to steamcmd.exe as +workshop_download_item arguments' {
            Mock -ModuleName Workshop -CommandName Start-Process -MockWith {
                $contentPath = Join-Path $script:FakeRoot "SteamCMD/steamapps/workshop/content/$($ArgumentList[3])/$($ArgumentList[4])"
                New-Item -ItemType Directory -Path $contentPath -Force | Out-Null
                [PSCustomObject]@{ ExitCode = 0 }
            }
            Set-FakeGSMWorkshopPlacementFunctions -FolderName 'FakeGame'

            Add-GSMWorkshopItem -FolderName 'FakeGame' -WorkshopID '123' | Out-Null

            Should -Invoke -ModuleName Workshop -CommandName Start-Process -Times 1 -ParameterFilter {
                $ArgumentList -contains '+workshop_download_item' -and
                $ArgumentList -contains '11111' -and
                $ArgumentList -contains '123'
            }
        }

        It 'does not record the item when steamcmd.exe exits non-zero' {
            Mock -ModuleName Workshop -CommandName Start-Process -MockWith { [PSCustomObject]@{ ExitCode = 1 } }
            Set-FakeGSMWorkshopPlacementFunctions -FolderName 'FakeGame'

            { Add-GSMWorkshopItem -FolderName 'FakeGame' -WorkshopID '123' } | Should -Throw '*exited with code 1*'

            $config = Get-FakeGSMWorkshopConfig -Root $script:FakeRoot -FolderName 'FakeGame'
            @($config.WorkshopItems).Count | Should -Be 0
        }

        It 'does not record the item when steamcmd.exe reports success but downloads no content' {
            Mock -ModuleName Workshop -CommandName Start-Process -MockWith { [PSCustomObject]@{ ExitCode = 0 } }
            Set-FakeGSMWorkshopPlacementFunctions -FolderName 'FakeGame'

            { Add-GSMWorkshopItem -FolderName 'FakeGame' -WorkshopID '123' } | Should -Throw '*could not be found*'

            $config = Get-FakeGSMWorkshopConfig -Root $script:FakeRoot -FolderName 'FakeGame'
            @($config.WorkshopItems).Count | Should -Be 0
        }

        It 'does not record the item when the plugin placement function fails' {
            Mock -ModuleName Workshop -CommandName Start-Process -MockWith {
                $contentPath = Join-Path $script:FakeRoot "SteamCMD/steamapps/workshop/content/$($ArgumentList[3])/$($ArgumentList[4])"
                New-Item -ItemType Directory -Path $contentPath -Force | Out-Null
                [PSCustomObject]@{ ExitCode = 0 }
            }
            Set-FakeGSMWorkshopPlacementFunctions -FolderName 'FakeGame' -OnAdd {
                param($WorkshopID, $ContentPath)
                $null = $WorkshopID, $ContentPath
                throw 'simulated placement failure'
            }

            { Add-GSMWorkshopItem -FolderName 'FakeGame' -WorkshopID '123' } | Should -Throw '*simulated placement failure*'

            $config = Get-FakeGSMWorkshopConfig -Root $script:FakeRoot -FolderName 'FakeGame'
            @($config.WorkshopItems).Count | Should -Be 0
        }

        It 'throws when no config exists yet for the instance' {
            $script:FakeRoot = New-FakeGSMWorkshopRoot -FolderName 'FakeGame' -WithoutConfig
            Mock -ModuleName Workshop -CommandName Get-GSMRootPath -MockWith { $script:FakeRoot }
            Mock -ModuleName Workshop -CommandName Start-Process -MockWith { [PSCustomObject]@{ ExitCode = 0 } }

            { Add-GSMWorkshopItem -FolderName 'FakeGame' -WorkshopID '123' } | Should -Throw '*Run the Configure action first*'
        }
    }

    Context 'Add-GSMWorkshopItem duplicate handling' {
        It 'does not duplicate an already-subscribed WorkshopID' {
            $script:FakeRoot = New-FakeGSMWorkshopRoot -FolderName 'FakeGame' -AppID '11111' -WorkshopItems @('123')
            Mock -ModuleName Workshop -CommandName Get-GSMRootPath -MockWith { $script:FakeRoot }
            Mock -ModuleName Workshop -CommandName Find-GSMPlugins -MockWith {
                @(New-FakeGSMWorkshopPlugin -FolderName 'FakeGame' -AppID '11111')
            }
            Mock -ModuleName Workshop -CommandName Start-Process -MockWith {
                $contentPath = Join-Path $script:FakeRoot "SteamCMD/steamapps/workshop/content/$($ArgumentList[3])/$($ArgumentList[4])"
                New-Item -ItemType Directory -Path $contentPath -Force | Out-Null
                [PSCustomObject]@{ ExitCode = 0 }
            }
            Set-FakeGSMWorkshopPlacementFunctions -FolderName 'FakeGame'

            Add-GSMWorkshopItem -FolderName 'FakeGame' -WorkshopID '123' | Out-Null

            $config = Get-FakeGSMWorkshopConfig -Root $script:FakeRoot -FolderName 'FakeGame'
            @($config.WorkshopItems | Where-Object { $_ -eq '123' }).Count | Should -Be 1
        }
    }

    Context 'Remove-GSMWorkshopItem' {
        BeforeEach {
            Mock -ModuleName Workshop -CommandName Find-GSMPlugins -MockWith {
                @(New-FakeGSMWorkshopPlugin -FolderName 'FakeGame' -AppID '11111')
            }
        }

        It 'throws a clear error when the WorkshopID is not currently subscribed' {
            $script:FakeRoot = New-FakeGSMWorkshopRoot -FolderName 'FakeGame' -WorkshopItems @()
            Mock -ModuleName Workshop -CommandName Get-GSMRootPath -MockWith { $script:FakeRoot }
            Set-FakeGSMWorkshopPlacementFunctions -FolderName 'FakeGame'

            { Remove-GSMWorkshopItem -FolderName 'FakeGame' -WorkshopID '123' } | Should -Throw '*not currently subscribed*'
        }

        It 'removes a subscribed item and drops it from WorkshopItems' {
            $script:FakeRoot = New-FakeGSMWorkshopRoot -FolderName 'FakeGame' -WorkshopItems @('123', '456')
            Mock -ModuleName Workshop -CommandName Get-GSMRootPath -MockWith { $script:FakeRoot }
            $script:RemovalCalledWith = $null
            Set-FakeGSMWorkshopPlacementFunctions -FolderName 'FakeGame' -OnRemove {
                param($WorkshopID)
                $script:RemovalCalledWith = $WorkshopID
                $true
            }

            $result = Remove-GSMWorkshopItem -FolderName 'FakeGame' -WorkshopID '123'

            $result | Should -Be $true
            $script:RemovalCalledWith | Should -Be '123'

            $config = Get-FakeGSMWorkshopConfig -Root $script:FakeRoot -FolderName 'FakeGame'
            @($config.WorkshopItems) | Should -Not -Contain '123'
            @($config.WorkshopItems) | Should -Contain '456'
        }

        It 'leaves WorkshopItems unchanged when the plugin removal function fails' {
            $script:FakeRoot = New-FakeGSMWorkshopRoot -FolderName 'FakeGame' -WorkshopItems @('123')
            Mock -ModuleName Workshop -CommandName Get-GSMRootPath -MockWith { $script:FakeRoot }
            Set-FakeGSMWorkshopPlacementFunctions -FolderName 'FakeGame' -OnRemove {
                param($WorkshopID)
                $null = $WorkshopID
                throw 'simulated removal failure'
            }

            { Remove-GSMWorkshopItem -FolderName 'FakeGame' -WorkshopID '123' } | Should -Throw '*simulated removal failure*'

            $config = Get-FakeGSMWorkshopConfig -Root $script:FakeRoot -FolderName 'FakeGame'
            @($config.WorkshopItems) | Should -Contain '123'
        }
    }

    Context 'Get-GSMWorkshopItems' {
        BeforeEach {
            Mock -ModuleName Workshop -CommandName Find-GSMPlugins -MockWith {
                @(New-FakeGSMWorkshopPlugin -FolderName 'FakeGame' -AppID '11111')
            }
            Mock -ModuleName Workshop -CommandName Start-Process -MockWith { throw 'Get-GSMWorkshopItems must never invoke steamcmd.exe' }
        }

        It 'returns the WorkshopItems array from config without touching SteamCMD' {
            $script:FakeRoot = New-FakeGSMWorkshopRoot -FolderName 'FakeGame' -WorkshopItems @('123', '456')
            Mock -ModuleName Workshop -CommandName Get-GSMRootPath -MockWith { $script:FakeRoot }

            $result = Get-GSMWorkshopItems -FolderName 'FakeGame'

            $result | Should -Be @('123', '456')
            Should -Invoke -ModuleName Workshop -CommandName Start-Process -Times 0
        }

        It 'returns an empty array when WorkshopItems is empty' {
            $script:FakeRoot = New-FakeGSMWorkshopRoot -FolderName 'FakeGame' -WorkshopItems @()
            Mock -ModuleName Workshop -CommandName Get-GSMRootPath -MockWith { $script:FakeRoot }

            $result = Get-GSMWorkshopItems -FolderName 'FakeGame'

            $result.Count | Should -Be 0
        }
    }

    Context 'Update-GSMWorkshopItems' {
        BeforeEach {
            Mock -ModuleName Workshop -CommandName Find-GSMPlugins -MockWith {
                @(New-FakeGSMWorkshopPlugin -FolderName 'FakeGame' -AppID '11111')
            }
        }

        It 'refreshes every subscribed item without duplicating or mutating WorkshopItems' {
            $script:FakeRoot = New-FakeGSMWorkshopRoot -FolderName 'FakeGame' -WorkshopItems @('123', '456')
            Mock -ModuleName Workshop -CommandName Get-GSMRootPath -MockWith { $script:FakeRoot }
            Mock -ModuleName Workshop -CommandName Start-Process -MockWith {
                $contentPath = Join-Path $script:FakeRoot "SteamCMD/steamapps/workshop/content/$($ArgumentList[3])/$($ArgumentList[4])"
                New-Item -ItemType Directory -Path $contentPath -Force | Out-Null
                [PSCustomObject]@{ ExitCode = 0 }
            }
            $script:PlacementCalls = [System.Collections.Generic.List[string]]::new()
            Set-FakeGSMWorkshopPlacementFunctions -FolderName 'FakeGame' -OnAdd {
                param($WorkshopID, $ContentPath)
                $null = $ContentPath
                $script:PlacementCalls.Add($WorkshopID)
                $true
            }

            $result = Update-GSMWorkshopItems -FolderName 'FakeGame'

            $result | Should -Be $true
            $script:PlacementCalls | Should -Be @('123', '456')

            $config = Get-FakeGSMWorkshopConfig -Root $script:FakeRoot -FolderName 'FakeGame'
            @($config.WorkshopItems) | Should -Be @('123', '456')
        }

        It 'is a no-op when WorkshopItems is empty' {
            $script:FakeRoot = New-FakeGSMWorkshopRoot -FolderName 'FakeGame' -WorkshopItems @()
            Mock -ModuleName Workshop -CommandName Get-GSMRootPath -MockWith { $script:FakeRoot }
            Mock -ModuleName Workshop -CommandName Start-Process -MockWith { throw 'must not be invoked' }

            $result = Update-GSMWorkshopItems -FolderName 'FakeGame'

            $result | Should -Be $true
            Should -Invoke -ModuleName Workshop -CommandName Start-Process -Times 0
        }

        It 'throws and stops refreshing at the first item that fails to download' {
            $script:FakeRoot = New-FakeGSMWorkshopRoot -FolderName 'FakeGame' -WorkshopItems @('123', '456')
            Mock -ModuleName Workshop -CommandName Get-GSMRootPath -MockWith { $script:FakeRoot }
            Mock -ModuleName Workshop -CommandName Start-Process -MockWith { [PSCustomObject]@{ ExitCode = 1 } }
            Set-FakeGSMWorkshopPlacementFunctions -FolderName 'FakeGame'

            { Update-GSMWorkshopItems -FolderName 'FakeGame' } | Should -Throw '*exited with code 1*'

            Should -Invoke -ModuleName Workshop -CommandName Start-Process -Times 1
        }
    }
}
