BeforeAll {
    Import-Module "$PSScriptRoot/../Core/Reports.psm1" -Force
}

Describe 'Core/Reports.psm1 - data gathering (internal)' {

    Context 'Get-GSMReportSystemInfo' {
        It 'computes CPU average, memory percent, disk GB, and GSM root size from CIM/filesystem data' {
            InModuleScope Reports {
                $fakeRoot = Join-Path $TestDrive ('reports-root-' + [guid]::NewGuid().ToString('N'))
                New-Item -ItemType Directory -Path $fakeRoot -Force | Out-Null
                Set-Content -Path (Join-Path $fakeRoot 'file1.bin') -Value ('x' * 1024)
                Set-Content -Path (Join-Path $fakeRoot 'file2.bin') -Value ('y' * 2048)

                Mock -CommandName Get-GSMRootPath -MockWith { $fakeRoot }
                Mock -CommandName Get-CimInstance -ParameterFilter { $ClassName -eq 'Win32_OperatingSystem' } -MockWith {
                    [PSCustomObject]@{ Caption = 'Windows 11 Pro'; Version = '10.0.22631'; TotalVisibleMemorySize = 16777216; FreePhysicalMemory = 8388608 }
                }
                Mock -CommandName Get-CimInstance -ParameterFilter { $ClassName -eq 'Win32_Processor' } -MockWith {
                    @(
                        [PSCustomObject]@{ LoadPercentage = 20 }
                        [PSCustomObject]@{ LoadPercentage = 40 }
                    )
                }
                Mock -CommandName Get-CimInstance -ParameterFilter { $ClassName -eq 'Win32_LogicalDisk' } -MockWith {
                    [PSCustomObject]@{ FreeSpace = 100GB; Size = 500GB }
                }

                $result = Get-GSMReportSystemInfo

                $result.WindowsCaption | Should -Be 'Windows 11 Pro'
                $result.CpuUsagePercent | Should -Be 30
                $result.MemoryUsagePercent | Should -Be 50
                $result.TotalMemoryGB | Should -Be 16
                $result.DiskFreeGB | Should -Be 100
                $result.DiskTotalGB | Should -Be 500
                # Rounded to 2 decimal GB; the tiny test fixture files (a
                # few KB) legitimately round to 0.00, so this only checks
                # that a size was computed at all (non-null), not $null as
                # it would be if the root had no files/didn't exist.
                $result.GSMRootSizeGB | Should -Not -BeNullOrEmpty
            }
        }

        It 'leaves fields $null rather than throwing when CIM data is unavailable' {
            InModuleScope Reports {
                $fakeRoot = Join-Path $TestDrive ('reports-root-' + [guid]::NewGuid().ToString('N'))
                New-Item -ItemType Directory -Path $fakeRoot -Force | Out-Null

                Mock -CommandName Get-GSMRootPath -MockWith { $fakeRoot }
                Mock -CommandName Get-CimInstance -MockWith { $null }

                { Get-GSMReportSystemInfo } | Should -Not -Throw

                $result = Get-GSMReportSystemInfo
                $result.WindowsCaption | Should -BeNullOrEmpty
                $result.CpuUsagePercent | Should -BeNullOrEmpty
            }
        }
    }

    Context 'Get-GSMReportSteamCMDInfo' {
        It 'reports installed status and pinned verification metadata' {
            InModuleScope Reports {
                $fakeRoot = Join-Path $TestDrive ('reports-root-' + [guid]::NewGuid().ToString('N'))
                New-Item -ItemType Directory -Path (Join-Path $fakeRoot 'Config') -Force | Out-Null
                @{ InstallerUrl = 'https://example.invalid'; PinnedSHA256 = 'abc'; VerifiedBy = 'Marc Larouche'; VerifiedDate = '2026-07-05' } |
                    ConvertTo-Json | Set-Content -Path (Join-Path $fakeRoot 'Config/SteamCMD.json')

                Mock -CommandName Get-GSMRootPath -MockWith { $fakeRoot }
                Mock -CommandName Test-SteamCMDPresent -MockWith { $true }

                $result = Get-GSMReportSteamCMDInfo

                $result.Installed | Should -Be $true
                $result.VerifiedBy | Should -Be 'Marc Larouche'
                $result.VerifiedDate | Should -Be '2026-07-05'
            }
        }

        It 'reports not-installed with null metadata when SteamCMD.json is missing' {
            InModuleScope Reports {
                $fakeRoot = Join-Path $TestDrive ('reports-root-' + [guid]::NewGuid().ToString('N'))
                New-Item -ItemType Directory -Path $fakeRoot -Force | Out-Null

                Mock -CommandName Get-GSMRootPath -MockWith { $fakeRoot }
                Mock -CommandName Test-SteamCMDPresent -MockWith { $false }

                $result = Get-GSMReportSteamCMDInfo

                $result.Installed | Should -Be $false
                $result.VerifiedBy | Should -BeNullOrEmpty
            }
        }
    }

    Context 'Get-GSMReportInstanceSummary' {
        It 'reports Installed=$false and no server status when the executable is not installed' {
            InModuleScope Reports {
                $fakeRoot = Join-Path $TestDrive ('reports-root-' + [guid]::NewGuid().ToString('N'))
                New-Item -ItemType Directory -Path (Join-Path $fakeRoot 'Config') -Force | Out-Null
                Mock -CommandName Get-GSMRootPath -MockWith { $fakeRoot }
                Mock -CommandName Get-GSMFirewallRuleStatus -MockWith { @() }
                Mock -CommandName Get-GSMBackupList -MockWith { @() }

                $plugin = [PSCustomObject]@{ FolderName = 'FakeGame'; GameName = 'Fake'; Version = '1'; AppID = '1'; Executable = 'srcds.exe' }

                $result = Get-GSMReportInstanceSummary -Plugin $plugin

                $result.Installed | Should -Be $false
                $result.ServerStatus | Should -BeNullOrEmpty
                $result.ConfigSummary | Should -BeNullOrEmpty
            }
        }

        It 'reports server status when installed, and redacts RCONPassword in the config summary' {
            InModuleScope Reports {
                $fakeRoot = Join-Path $TestDrive ('reports-root-' + [guid]::NewGuid().ToString('N'))
                New-Item -ItemType Directory -Path (Join-Path $fakeRoot "Servers/FakeGame") -Force | Out-Null
                New-Item -ItemType Directory -Path (Join-Path $fakeRoot 'Config') -Force | Out-Null
                Set-Content -Path (Join-Path $fakeRoot 'Servers/FakeGame/srcds.exe') -Value 'fake-binary'
                '{"GameName":"Fake","AppID":"1","RCONPassword":"hunter2"}' | Set-Content -Path (Join-Path $fakeRoot 'Config/FakeGame.json')

                Mock -CommandName Get-GSMRootPath -MockWith { $fakeRoot }
                Mock -CommandName Get-GSMServerStatus -MockWith { 'Running' }
                Mock -CommandName Get-GSMFirewallRuleStatus -MockWith { @() }
                Mock -CommandName Get-GSMBackupList -MockWith { @() }

                $plugin = [PSCustomObject]@{ FolderName = 'FakeGame'; GameName = 'Fake'; Version = '1'; AppID = '1'; Executable = 'srcds.exe' }

                $result = Get-GSMReportInstanceSummary -Plugin $plugin

                $result.Installed | Should -Be $true
                $result.ServerStatus | Should -Be 'Running'
                $result.ConfigSummary['RCONPassword'] | Should -Be '(set, redacted)'
                $result.ConfigSummary['RCONPassword'] | Should -Not -Be 'hunter2'
            }
        }

        It 'reports only this instance''s custom maps, and backup count/timestamp from Get-GSMBackupList' {
            InModuleScope Reports {
                $fakeRoot = Join-Path $TestDrive ('reports-root-' + [guid]::NewGuid().ToString('N'))
                New-Item -ItemType Directory -Path (Join-Path $fakeRoot 'Config') -Force | Out-Null
                '{"FakeGame":["map_one"],"OtherGame":["map_two"]}' | Set-Content -Path (Join-Path $fakeRoot 'Config/CustomMaps.json')

                Mock -CommandName Get-GSMRootPath -MockWith { $fakeRoot }
                Mock -CommandName Get-GSMFirewallRuleStatus -MockWith { @() }
                Mock -CommandName Get-GSMBackupList -MockWith {
                    @(
                        [PSCustomObject]@{ Timestamp = '20260702-040000' }
                        [PSCustomObject]@{ Timestamp = '20260701-040000' }
                    )
                }

                $plugin = [PSCustomObject]@{ FolderName = 'FakeGame'; GameName = 'Fake'; Version = '1'; AppID = '1'; Executable = 'srcds.exe' }

                $result = Get-GSMReportInstanceSummary -Plugin $plugin

                $result.CustomMaps | Should -Be @('map_one')
                $result.BackupCount | Should -Be 2
                $result.LastBackupTimestamp | Should -Be '20260702-040000'
            }
        }
    }

    Context 'Get-GSMServerHealthReportData' {
        It 'combines system info, SteamCMD info, and one summary per discovered plugin' {
            InModuleScope Reports {
                Mock -CommandName Find-GSMPlugins -MockWith {
                    @(
                        [PSCustomObject]@{ FolderName = 'GameA'; GameName = 'A'; Version = '1'; AppID = '1'; Executable = 'a.exe' }
                        [PSCustomObject]@{ FolderName = 'GameB'; GameName = 'B'; Version = '1'; AppID = '2'; Executable = 'b.exe' }
                    )
                }
                Mock -CommandName Get-GSMReportInstanceSummary -MockWith { [PSCustomObject]@{ FolderName = $Plugin.FolderName } }
                Mock -CommandName Get-GSMReportSystemInfo -MockWith { [PSCustomObject]@{ WindowsCaption = 'Fake OS' } }
                Mock -CommandName Get-GSMReportSteamCMDInfo -MockWith { [PSCustomObject]@{ Installed = $true } }

                $result = Get-GSMServerHealthReportData

                $result.Instances.Count | Should -Be 2
                $result.System.WindowsCaption | Should -Be 'Fake OS'
                $result.SteamCMD.Installed | Should -Be $true
                $result.UpdateHistoryNote | Should -Not -BeNullOrEmpty
                $result.GeneratedAtUtc | Should -BeOfType [datetime]
            }
        }
    }
}

Describe 'Core/Reports.psm1 - ConvertTo-GSMServerHealthReportHtml (internal)' {
    It 'renders instance status, config, and the update-history gap note into the HTML' {
        InModuleScope Reports {
            $reportData = [PSCustomObject]@{
                GeneratedAtUtc    = Get-Date '2026-07-08T12:00:00Z'
                System            = [PSCustomObject]@{ WindowsCaption = 'Windows 11 Pro'; WindowsVersion = '10.0'; CpuUsagePercent = 10; TotalMemoryGB = 16; FreeMemoryGB = 8; MemoryUsagePercent = 50; DiskFreeGB = 100; DiskTotalGB = 500; GSMRootSizeGB = 5 }
                SteamCMD          = [PSCustomObject]@{ Installed = $true; VerifiedBy = 'Marc'; VerifiedDate = '2026-07-05' }
                Instances         = @(
                    [PSCustomObject]@{
                        FolderName = 'FakeGame'; GameName = 'Fake'; Version = '1'; AppID = '1'
                        Installed = $true; ServerStatus = 'Running'
                        ConfigSummary = [ordered]@{ DefaultPort = 27015 }
                        CustomMaps = @('custom_map')
                        FirewallRules = @([PSCustomObject]@{ RuleName = 'GSM-FakeGame-27015-TCP'; Protocol = 'TCP'; Port = '27015'; Enabled = $true })
                        BackupCount = 3
                        LastBackupTimestamp = '20260708-040000'
                    }
                )
                UpdateHistoryNote = 'Update history is not tracked as structured data.'
            }

            $htmlText = ConvertTo-GSMServerHealthReportHtml -ReportData $reportData

            $htmlText | Should -BeLike '*FakeGame*'
            $htmlText | Should -BeLike '*badge-running*'
            $htmlText | Should -BeLike '*27015*'
            $htmlText | Should -BeLike '*custom_map*'
            $htmlText | Should -BeLike '*Update history is not tracked as structured data.*'
        }
    }

    It 'renders a "no installed plugins" message when there are no instances' {
        InModuleScope Reports {
            $reportData = [PSCustomObject]@{
                GeneratedAtUtc    = Get-Date '2026-07-08T12:00:00Z'
                System            = [PSCustomObject]@{ WindowsCaption = $null; WindowsVersion = $null; CpuUsagePercent = $null; TotalMemoryGB = $null; FreeMemoryGB = $null; MemoryUsagePercent = $null; DiskFreeGB = $null; DiskTotalGB = $null; GSMRootSizeGB = $null }
                SteamCMD          = [PSCustomObject]@{ Installed = $false; VerifiedBy = $null; VerifiedDate = $null }
                Instances         = @()
                UpdateHistoryNote = 'note'
            }

            $htmlText = ConvertTo-GSMServerHealthReportHtml -ReportData $reportData

            $htmlText | Should -BeLike '*No installed plugins found.*'
        }
    }
}

Describe 'Core/Reports.psm1 - New-GSMServerHealthReport' {
    BeforeEach {
        Mock -ModuleName Reports -CommandName Write-GSMLog -MockWith { }
    }

    It 'writes Reports/ServerHealth-<timestamp>.html and returns its path' {
        $fakeRoot = Join-Path $TestDrive ('reports-root-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $fakeRoot -Force | Out-Null
        Mock -ModuleName Reports -CommandName Get-GSMRootPath -MockWith { $fakeRoot }
        Mock -ModuleName Reports -CommandName Get-GSMServerHealthReportData -MockWith {
            [PSCustomObject]@{
                GeneratedAtUtc    = Get-Date
                System            = [PSCustomObject]@{ WindowsCaption = $null; WindowsVersion = $null; CpuUsagePercent = $null; TotalMemoryGB = $null; FreeMemoryGB = $null; MemoryUsagePercent = $null; DiskFreeGB = $null; DiskTotalGB = $null; GSMRootSizeGB = $null }
                SteamCMD          = [PSCustomObject]@{ Installed = $false; VerifiedBy = $null; VerifiedDate = $null }
                Instances         = @()
                UpdateHistoryNote = 'note'
            }
        }

        $result = New-GSMServerHealthReport

        Test-Path -Path $result | Should -Be $true
        Split-Path -Path $result -Leaf | Should -Match '^ServerHealth-\d{8}-\d{6}\.html$'
        Split-Path -Path $result -Parent | Should -Be (Join-Path $fakeRoot 'Reports')
        (Get-Content -Path $result -Raw) | Should -BeLike '*GSM Server Health Report*'
    }

    It 'throws and logs an error when the report file cannot be written' {
        $fakeRoot = Join-Path $TestDrive ('reports-root-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $fakeRoot -Force | Out-Null
        Mock -ModuleName Reports -CommandName Get-GSMRootPath -MockWith { $fakeRoot }
        Mock -ModuleName Reports -CommandName Get-GSMServerHealthReportData -MockWith {
            [PSCustomObject]@{
                GeneratedAtUtc    = Get-Date
                System            = [PSCustomObject]@{ WindowsCaption = $null; WindowsVersion = $null; CpuUsagePercent = $null; TotalMemoryGB = $null; FreeMemoryGB = $null; MemoryUsagePercent = $null; DiskFreeGB = $null; DiskTotalGB = $null; GSMRootSizeGB = $null }
                SteamCMD          = [PSCustomObject]@{ Installed = $false; VerifiedBy = $null; VerifiedDate = $null }
                Instances         = @()
                UpdateHistoryNote = 'note'
            }
        }
        Mock -ModuleName Reports -CommandName Set-Content -MockWith { throw 'simulated disk failure' }

        { New-GSMServerHealthReport } | Should -Throw

        Should -Invoke -ModuleName Reports -CommandName Write-GSMLog -Times 1 -ParameterFilter { $Level -eq 'Error' }
    }
}
