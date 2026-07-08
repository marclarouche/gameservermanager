BeforeAll {
    Import-Module "$PSScriptRoot/../Core/Scheduler.psm1" -Force

    function New-FakeGSMRootForScheduler {
        param(
            [string]$FolderName = 'FakeGame',
            [string]$Executable = 'srcds.exe',
            [switch]$WithConfig,
            [switch]$WithoutPlugin,
            [string]$RestartTime,
            [string]$UpdateCheckTime
        )

        $root = Join-Path $TestDrive ('scheduler-root-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $root 'Config') -Force | Out-Null

        if (-not $WithoutPlugin) {
            New-Item -ItemType Directory -Path (Join-Path $root "Plugins/$FolderName") -Force | Out-Null
            $pluginJson = [ordered]@{
                GameName         = 'FakeGame'
                Version          = '1'
                AppID            = '1'
                Engine           = 'Source'
                Executable       = $Executable
                DefaultPort      = 27015
                SupportsWorkshop = $false
                SupportsRCON     = $true
            }
            $pluginJson | ConvertTo-Json | Set-Content -Path (Join-Path $root "Plugins/$FolderName/Plugin.json")
        }

        if ($WithConfig) {
            $config = [ordered]@{ GameName = 'FakeGame'; AppID = '1' }
            if ($RestartTime) { $config['RestartTime'] = $RestartTime }
            if ($UpdateCheckTime) { $config['UpdateCheckTime'] = $UpdateCheckTime }
            $config | ConvertTo-Json | Set-Content -Path (Join-Path $root "Config/$FolderName.json")
        }

        return $root
    }

    # Built via AppendChar rather than ConvertTo-SecureString -AsPlainText,
    # matching Tests/ProcessManager.Tests.ps1's established pattern:
    # PSScriptAnalyzer's PSAvoidUsingConvertToSecureStringWithPlainText rule
    # flags that cmdlet unconditionally, even in test-only fixture code.
    function New-TestSecureStringForScheduler([string]$PlainText) {
        $secureString = [System.Security.SecureString]::new()
        foreach ($char in $PlainText.ToCharArray()) {
            $secureString.AppendChar($char)
        }
        return $secureString
    }
}

Describe 'Core/Scheduler.psm1' {

    BeforeEach {
        Mock -ModuleName Scheduler -CommandName Write-GSMLog -MockWith { }
    }

    Context 'Register-GSMScheduledMaintenance - preconditions' {
        It 'throws a clear error when Config/<FolderName>.json does not exist' {
            $fakeRoot = New-FakeGSMRootForScheduler -FolderName 'FakeGame'
            Mock -ModuleName Scheduler -CommandName Get-GSMRootPath -MockWith { $fakeRoot }

            { Register-GSMScheduledMaintenance -FolderName 'FakeGame' } | Should -Throw '*Configure*'
        }

        It 'throws a clear error when Plugin.json does not exist' {
            $fakeRoot = New-FakeGSMRootForScheduler -FolderName 'FakeGame' -WithConfig -WithoutPlugin
            Mock -ModuleName Scheduler -CommandName Get-GSMRootPath -MockWith { $fakeRoot }

            { Register-GSMScheduledMaintenance -FolderName 'FakeGame' } | Should -Throw '*Plugin.json*'
        }
    }

    Context 'Register-GSMScheduledMaintenance - happy path' {
        BeforeEach {
            $script:FakeRoot = New-FakeGSMRootForScheduler -FolderName 'FakeGame' -Executable 'srcds.exe' -WithConfig
            Mock -ModuleName Scheduler -CommandName Get-GSMRootPath -MockWith { $script:FakeRoot }

            $fakeCredential = [pscredential]::new('GSM-ServiceAccount', (New-TestSecureStringForScheduler -PlainText 'fakepassword'))
            Mock -ModuleName Scheduler -CommandName Get-GSMServiceAccountCredential -MockWith { $fakeCredential }

            Mock -ModuleName Scheduler -CommandName Unregister-ScheduledTask -MockWith { }
            # New-ScheduledTaskAction/Trigger/SettingsSet call through to the
            # real ScheduledTasks module cmdlets so Register-ScheduledTask's
            # -Action/-Trigger/-Settings parameters (typed as genuine
            # CimInstance objects) can bind - matching the identical pattern
            # in Tests/ProcessManager.Tests.ps1.
            Mock -ModuleName Scheduler -CommandName New-ScheduledTaskAction -MockWith { ScheduledTasks\New-ScheduledTaskAction -Execute $Execute -Argument $Argument }
            Mock -ModuleName Scheduler -CommandName New-ScheduledTaskTrigger -MockWith { ScheduledTasks\New-ScheduledTaskTrigger -Daily -At $At }
            Mock -ModuleName Scheduler -CommandName New-ScheduledTaskSettingsSet -MockWith { ScheduledTasks\New-ScheduledTaskSettingsSet -ExecutionTimeLimit $ExecutionTimeLimit -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries }
            Mock -ModuleName Scheduler -CommandName Register-ScheduledTask -MockWith { }
        }

        It 'registers both a nightly restart and nightly update-check task using default times' {
            Register-GSMScheduledMaintenance -FolderName 'FakeGame' | Out-Null

            Should -Invoke -ModuleName Scheduler -CommandName Register-ScheduledTask -Times 1 -ParameterFilter { $TaskName -eq 'GSM-FakeGame-NightlyRestart' }
            Should -Invoke -ModuleName Scheduler -CommandName Register-ScheduledTask -Times 1 -ParameterFilter { $TaskName -eq 'GSM-FakeGame-NightlyUpdateCheck' }
            Should -Invoke -ModuleName Scheduler -CommandName New-ScheduledTaskTrigger -Times 1 -ParameterFilter { $At.ToString('HH:mm') -eq '04:00' }
            Should -Invoke -ModuleName Scheduler -CommandName New-ScheduledTaskTrigger -Times 1 -ParameterFilter { $At.ToString('HH:mm') -eq '04:15' }
        }

        It 'uses RestartTime/UpdateCheckTime from config when present' {
            $script:FakeRoot = New-FakeGSMRootForScheduler -FolderName 'FakeGame' -Executable 'srcds.exe' -WithConfig -RestartTime '02:30' -UpdateCheckTime '02:45'
            Mock -ModuleName Scheduler -CommandName Get-GSMRootPath -MockWith { $script:FakeRoot }

            Register-GSMScheduledMaintenance -FolderName 'FakeGame' | Out-Null

            Should -Invoke -ModuleName Scheduler -CommandName New-ScheduledTaskTrigger -Times 1 -ParameterFilter { $At.ToString('HH:mm') -eq '02:30' }
            Should -Invoke -ModuleName Scheduler -CommandName New-ScheduledTaskTrigger -Times 1 -ParameterFilter { $At.ToString('HH:mm') -eq '02:45' }
        }

        It 'unregisters any pre-existing task of the same name before registering fresh' {
            Register-GSMScheduledMaintenance -FolderName 'FakeGame' | Out-Null

            Should -Invoke -ModuleName Scheduler -CommandName Unregister-ScheduledTask -Times 1 -ParameterFilter { $TaskName -eq 'GSM-FakeGame-NightlyRestart' }
            Should -Invoke -ModuleName Scheduler -CommandName Unregister-ScheduledTask -Times 1 -ParameterFilter { $TaskName -eq 'GSM-FakeGame-NightlyUpdateCheck' }
        }

        It 'registers the restart task using the service account credential and Limited run level' {
            Register-GSMScheduledMaintenance -FolderName 'FakeGame' | Out-Null

            Should -Invoke -ModuleName Scheduler -CommandName Register-ScheduledTask -Times 2 -ParameterFilter {
                $User -eq 'GSM-ServiceAccount' -and $Password -eq 'fakepassword' -and $RunLevel -eq 'Limited'
            }
        }

        It 'never logs the plaintext service account password' {
            Register-GSMScheduledMaintenance -FolderName 'FakeGame' | Out-Null

            Should -Invoke -ModuleName Scheduler -CommandName Write-GSMLog -Times 0 -ParameterFilter { $Message -match 'fakepassword' }
        }

        It 'returns $true on success' {
            $result = Register-GSMScheduledMaintenance -FolderName 'FakeGame'

            $result | Should -Be $true
        }

        It 'throws and logs an error when Register-ScheduledTask fails' {
            Mock -ModuleName Scheduler -CommandName Register-ScheduledTask -MockWith { throw 'simulated registration failure' }

            { Register-GSMScheduledMaintenance -FolderName 'FakeGame' } | Should -Throw

            Should -Invoke -ModuleName Scheduler -CommandName Write-GSMLog -Times 1 -ParameterFilter { $Level -eq 'Error' }
        }
    }

    Context 'Get-GSMSchedulerMaintenanceCommandText (internal)' {
        It 'builds command text that imports the plugin and calls the right dispatch function with the right identity' {
            InModuleScope Scheduler {
                Mock -CommandName Get-GSMRootPath -MockWith { 'C:\GSM' }

                $commandText = Get-GSMSchedulerMaintenanceCommandText -FolderName 'FakeGame' -Executable 'srcds.exe' `
                    -GetLaunchArgsFunctionName 'Get-FakeGameLaunchArgs' -AccountName 'GSM-ServiceAccount' `
                    -ActionModulePath 'C:\GSM\Core\Service.psm1' -ActionFunctionName 'Restart-GSMServer' -Kind 'NightlyRestart'

                $commandText | Should -BeLike "*Import-GSMPlugin -FolderName 'FakeGame'*"
                $commandText | Should -BeLike "*Restart-GSMServer -FolderName 'FakeGame' -Executable 'srcds.exe' -GetLaunchArgsFunctionName 'Get-FakeGameLaunchArgs' -AccountName 'GSM-ServiceAccount'*"
                $commandText | Should -BeLike "*Import-Module 'C:\GSM\Core\Service.psm1'*"
            }
        }

        It 'round-trips cleanly through the base64 -EncodedCommand New-GSMSchedulerTaskAction builds' {
            InModuleScope Scheduler {
                $commandText = "Write-Output 'hello'"
                Mock -CommandName New-ScheduledTaskAction -MockWith { [PSCustomObject]@{ Execute = $Execute; Argument = $Argument } }

                $action = New-GSMSchedulerTaskAction -CommandText $commandText

                $action.Execute | Should -BeLike '*pwsh.exe'
                $encodedToken = ($action.Argument -split '-EncodedCommand ')[1].Trim()
                $decoded = [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encodedToken))
                $decoded | Should -Be $commandText
            }
        }
    }

    Context 'Unregister-GSMScheduledMaintenance' {
        It 'is a no-op returning $true and logs info when neither task is registered' {
            Mock -ModuleName Scheduler -CommandName Get-ScheduledTask -MockWith { $null }
            Mock -ModuleName Scheduler -CommandName Unregister-ScheduledTask -MockWith { }

            $result = Unregister-GSMScheduledMaintenance -FolderName 'FakeGame'

            $result | Should -Be $true
            Should -Invoke -ModuleName Scheduler -CommandName Unregister-ScheduledTask -Times 0
        }

        It 'removes both tasks when they exist' {
            Mock -ModuleName Scheduler -CommandName Get-ScheduledTask -MockWith { [PSCustomObject]@{ TaskName = 'x' } }
            Mock -ModuleName Scheduler -CommandName Unregister-ScheduledTask -MockWith { }

            $result = Unregister-GSMScheduledMaintenance -FolderName 'FakeGame'

            $result | Should -Be $true
            Should -Invoke -ModuleName Scheduler -CommandName Unregister-ScheduledTask -Times 2
        }

        It 'warns rather than throws when removing one task fails, and still processes the other' {
            Mock -ModuleName Scheduler -CommandName Get-ScheduledTask -MockWith { [PSCustomObject]@{ TaskName = 'x' } }
            Mock -ModuleName Scheduler -CommandName Unregister-ScheduledTask -MockWith {
                param($TaskName)
                if ($TaskName -eq 'GSM-FakeGame-NightlyRestart') {
                    throw 'simulated failure'
                }
            }

            { Unregister-GSMScheduledMaintenance -FolderName 'FakeGame' } | Should -Not -Throw

            Should -Invoke -ModuleName Scheduler -CommandName Write-GSMLog -Times 1 -ParameterFilter { $Level -eq 'Warning' }
            Should -Invoke -ModuleName Scheduler -CommandName Unregister-ScheduledTask -Times 2
        }
    }

    Context 'Get-GSMScheduledMaintenanceStatus' {
        It 'returns an empty array when neither task is registered' {
            Mock -ModuleName Scheduler -CommandName Get-ScheduledTask -MockWith { $null }

            $result = @(Get-GSMScheduledMaintenanceStatus -FolderName 'FakeGame')

            $result.Count | Should -Be 0
        }

        It 'returns one status object per registered task' {
            Mock -ModuleName Scheduler -CommandName Get-ScheduledTask -MockWith {
                param($TaskName)
                [PSCustomObject]@{ TaskName = $TaskName; State = 'Ready' }
            }
            Mock -ModuleName Scheduler -CommandName Get-ScheduledTaskInfo -MockWith {
                [PSCustomObject]@{ NextRunTime = (Get-Date '2026-07-09T04:00:00'); LastRunTime = (Get-Date '2026-07-08T04:00:00'); LastTaskResult = 0 }
            }

            $result = @(Get-GSMScheduledMaintenanceStatus -FolderName 'FakeGame')

            $result.Count | Should -Be 2
            ($result | Where-Object { $_.Kind -eq 'NightlyRestart' }).TaskName | Should -Be 'GSM-FakeGame-NightlyRestart'
            ($result | Where-Object { $_.Kind -eq 'NightlyUpdateCheck' }).State | Should -Be 'Ready'
            ($result | Where-Object { $_.Kind -eq 'NightlyRestart' }).LastTaskResult | Should -Be 0
        }
    }
}
