BeforeAll {
    Import-Module "$PSScriptRoot/../Core/Scheduler.psm1" -Force

    function New-FakeGSMRootForScheduler {
        param(
            [string]$FolderName = 'FakeGame',
            [string]$Executable = 'srcds.exe',
            [switch]$WithConfig,
            [switch]$WithoutPlugin,
            [string]$RestartTime,
            [string]$UpdateCheckTime,
            [bool]$SupportsWorkshop = $false,
            [string[]]$WorkshopItems,
            [string]$WorkshopRefreshTime
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
                SupportsWorkshop = $SupportsWorkshop
                SupportsRCON     = $true
            }
            $pluginJson | ConvertTo-Json | Set-Content -Path (Join-Path $root "Plugins/$FolderName/Plugin.json")
        }

        if ($WithConfig) {
            $config = [ordered]@{ GameName = 'FakeGame'; AppID = '1' }
            if ($RestartTime) { $config['RestartTime'] = $RestartTime }
            if ($UpdateCheckTime) { $config['UpdateCheckTime'] = $UpdateCheckTime }
            # ContainsKey, not just truthiness: an explicitly-passed empty
            # array must still produce a real "WorkshopItems": [] field in
            # the config (to exercise the empty-array-enumerates-to-null
            # edge case), which a simple "if ($WorkshopItems)" truthiness
            # check would silently skip.
            if ($PSBoundParameters.ContainsKey('WorkshopItems')) { $config['WorkshopItems'] = @($WorkshopItems) }
            if ($WorkshopRefreshTime) { $config['WorkshopRefreshTime'] = $WorkshopRefreshTime }
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

    Context 'Register-GSMWorkshopRefreshSchedule - preconditions' {
        BeforeEach {
            Mock -ModuleName Scheduler -CommandName Register-ScheduledTask -MockWith { }
        }

        It 'returns $false and does not register when SupportsWorkshop is false' {
            $fakeRoot = New-FakeGSMRootForScheduler -FolderName 'FakeGame' -WithConfig -SupportsWorkshop $false -WorkshopItems @('123')
            Mock -ModuleName Scheduler -CommandName Get-GSMRootPath -MockWith { $fakeRoot }

            $result = Register-GSMWorkshopRefreshSchedule -FolderName 'FakeGame'

            $result | Should -Be $false
            Should -Invoke -ModuleName Scheduler -CommandName Register-ScheduledTask -Times 0
            Should -Invoke -ModuleName Scheduler -CommandName Write-GSMLog -Times 1 -ParameterFilter { $Level -eq 'Info' -and $Message -match 'does not support' }
        }

        It 'returns $false and does not register when WorkshopItems is an empty array' {
            $fakeRoot = New-FakeGSMRootForScheduler -FolderName 'FakeGame' -WithConfig -SupportsWorkshop $true -WorkshopItems @()
            Mock -ModuleName Scheduler -CommandName Get-GSMRootPath -MockWith { $fakeRoot }

            $result = Register-GSMWorkshopRefreshSchedule -FolderName 'FakeGame'

            $result | Should -Be $false
            Should -Invoke -ModuleName Scheduler -CommandName Register-ScheduledTask -Times 0
            Should -Invoke -ModuleName Scheduler -CommandName Write-GSMLog -Times 1 -ParameterFilter { $Level -eq 'Info' -and $Message -match 'no subscribed Workshop items' }
        }

        It 'returns $false and does not register when WorkshopItems is absent from config entirely' {
            $fakeRoot = New-FakeGSMRootForScheduler -FolderName 'FakeGame' -WithConfig -SupportsWorkshop $true
            Mock -ModuleName Scheduler -CommandName Get-GSMRootPath -MockWith { $fakeRoot }

            $result = Register-GSMWorkshopRefreshSchedule -FolderName 'FakeGame'

            $result | Should -Be $false
            Should -Invoke -ModuleName Scheduler -CommandName Register-ScheduledTask -Times 0
        }

        It 'throws a clear error when Config/<FolderName>.json does not exist' {
            $fakeRoot = New-FakeGSMRootForScheduler -FolderName 'FakeGame' -SupportsWorkshop $true
            Mock -ModuleName Scheduler -CommandName Get-GSMRootPath -MockWith { $fakeRoot }

            { Register-GSMWorkshopRefreshSchedule -FolderName 'FakeGame' } | Should -Throw '*Configure*'
        }
    }

    Context 'Register-GSMWorkshopRefreshSchedule - happy path' {
        BeforeEach {
            $script:FakeRoot = New-FakeGSMRootForScheduler -FolderName 'FakeGame' -WithConfig -SupportsWorkshop $true -WorkshopItems @('123', '456')
            Mock -ModuleName Scheduler -CommandName Get-GSMRootPath -MockWith { $script:FakeRoot }

            $fakeCredential = [pscredential]::new('GSM-ServiceAccount', (New-TestSecureStringForScheduler -PlainText 'fakepassword'))
            Mock -ModuleName Scheduler -CommandName Get-GSMServiceAccountCredential -MockWith { $fakeCredential }

            Mock -ModuleName Scheduler -CommandName Unregister-ScheduledTask -MockWith { }
            Mock -ModuleName Scheduler -CommandName New-ScheduledTaskAction -MockWith { ScheduledTasks\New-ScheduledTaskAction -Execute $Execute -Argument $Argument }
            Mock -ModuleName Scheduler -CommandName New-ScheduledTaskTrigger -MockWith { ScheduledTasks\New-ScheduledTaskTrigger -Daily -At $At }
            Mock -ModuleName Scheduler -CommandName New-ScheduledTaskSettingsSet -MockWith { ScheduledTasks\New-ScheduledTaskSettingsSet -ExecutionTimeLimit $ExecutionTimeLimit -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries }
            Mock -ModuleName Scheduler -CommandName Register-ScheduledTask -MockWith { }
        }

        It 'registers the WorkshopRefresh task using the default 03:45 time when WorkshopRefreshTime is absent' {
            $result = Register-GSMWorkshopRefreshSchedule -FolderName 'FakeGame'

            $result | Should -Be $true
            Should -Invoke -ModuleName Scheduler -CommandName Register-ScheduledTask -Times 1 -ParameterFilter { $TaskName -eq 'GSM-FakeGame-WorkshopRefresh' }
            Should -Invoke -ModuleName Scheduler -CommandName New-ScheduledTaskTrigger -Times 1 -ParameterFilter { $At.ToString('HH:mm') -eq '03:45' }
        }

        It 'uses WorkshopRefreshTime from config when present' {
            $script:FakeRoot = New-FakeGSMRootForScheduler -FolderName 'FakeGame' -WithConfig -SupportsWorkshop $true -WorkshopItems @('123') -WorkshopRefreshTime '02:00'
            Mock -ModuleName Scheduler -CommandName Get-GSMRootPath -MockWith { $script:FakeRoot }

            Register-GSMWorkshopRefreshSchedule -FolderName 'FakeGame' | Out-Null

            Should -Invoke -ModuleName Scheduler -CommandName New-ScheduledTaskTrigger -Times 1 -ParameterFilter { $At.ToString('HH:mm') -eq '02:00' }
        }

        It 'registers using the service account credential and Limited run level' {
            Register-GSMWorkshopRefreshSchedule -FolderName 'FakeGame' | Out-Null

            Should -Invoke -ModuleName Scheduler -CommandName Register-ScheduledTask -Times 1 -ParameterFilter {
                $User -eq 'GSM-ServiceAccount' -and $Password -eq 'fakepassword' -and $RunLevel -eq 'Limited'
            }
        }

        It 'unregisters any pre-existing WorkshopRefresh task before registering fresh' {
            Register-GSMWorkshopRefreshSchedule -FolderName 'FakeGame' | Out-Null

            Should -Invoke -ModuleName Scheduler -CommandName Unregister-ScheduledTask -Times 1 -ParameterFilter { $TaskName -eq 'GSM-FakeGame-WorkshopRefresh' }
        }

        It 'throws and logs an error when Register-ScheduledTask fails' {
            Mock -ModuleName Scheduler -CommandName Register-ScheduledTask -MockWith { throw 'simulated registration failure' }

            { Register-GSMWorkshopRefreshSchedule -FolderName 'FakeGame' } | Should -Throw

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

        It 'builds WorkshopRefresh command text calling Update-GSMWorkshopItems with only -FolderName' {
            InModuleScope Scheduler {
                Mock -CommandName Get-GSMRootPath -MockWith { 'C:\GSM' }

                $commandText = Get-GSMSchedulerMaintenanceCommandText -FolderName 'FakeGame' -AccountName 'GSM-ServiceAccount' `
                    -ActionModulePath 'C:\GSM\Core\Workshop.psm1' -ActionFunctionName 'Update-GSMWorkshopItems' -Kind 'WorkshopRefresh'

                $commandText | Should -BeLike "*Import-GSMPlugin -FolderName 'FakeGame'*"
                $commandText | Should -BeLike "*Update-GSMWorkshopItems -FolderName 'FakeGame' | Out-Null*"
                $commandText | Should -Not -BeLike '*-Executable*'
                $commandText | Should -Not -BeLike '*-GetLaunchArgsFunctionName*'
                $commandText | Should -Not -BeLike '*-AccountName*'
                $commandText | Should -BeLike "*Import-Module 'C:\GSM\Core\Workshop.psm1'*"
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

        It 'removes all three tasks when they exist, including WorkshopRefresh' {
            Mock -ModuleName Scheduler -CommandName Get-ScheduledTask -MockWith { [PSCustomObject]@{ TaskName = 'x' } }
            Mock -ModuleName Scheduler -CommandName Unregister-ScheduledTask -MockWith { }

            $result = Unregister-GSMScheduledMaintenance -FolderName 'FakeGame'

            $result | Should -Be $true
            Should -Invoke -ModuleName Scheduler -CommandName Unregister-ScheduledTask -Times 3
            Should -Invoke -ModuleName Scheduler -CommandName Unregister-ScheduledTask -Times 1 -ParameterFilter { $TaskName -eq 'GSM-FakeGame-WorkshopRefresh' }
        }

        It 'is a no-op for WorkshopRefresh specifically when only it is unregistered' {
            Mock -ModuleName Scheduler -CommandName Get-ScheduledTask -MockWith {
                param($TaskName)
                if ($TaskName -eq 'GSM-FakeGame-WorkshopRefresh') { return $null }
                return [PSCustomObject]@{ TaskName = $TaskName }
            }
            Mock -ModuleName Scheduler -CommandName Unregister-ScheduledTask -MockWith { }

            $result = Unregister-GSMScheduledMaintenance -FolderName 'FakeGame'

            $result | Should -Be $true
            Should -Invoke -ModuleName Scheduler -CommandName Unregister-ScheduledTask -Times 2
            Should -Invoke -ModuleName Scheduler -CommandName Unregister-ScheduledTask -Times 0 -ParameterFilter { $TaskName -eq 'GSM-FakeGame-WorkshopRefresh' }
        }

        It 'warns rather than throws when removing one task fails, and still processes the others' {
            Mock -ModuleName Scheduler -CommandName Get-ScheduledTask -MockWith { [PSCustomObject]@{ TaskName = 'x' } }
            Mock -ModuleName Scheduler -CommandName Unregister-ScheduledTask -MockWith {
                param($TaskName)
                if ($TaskName -eq 'GSM-FakeGame-NightlyRestart') {
                    throw 'simulated failure'
                }
            }

            { Unregister-GSMScheduledMaintenance -FolderName 'FakeGame' } | Should -Not -Throw

            Should -Invoke -ModuleName Scheduler -CommandName Write-GSMLog -Times 1 -ParameterFilter { $Level -eq 'Warning' }
            Should -Invoke -ModuleName Scheduler -CommandName Unregister-ScheduledTask -Times 3
        }
    }

    Context 'Get-GSMScheduledMaintenanceStatus' {
        It 'returns an empty array when neither task is registered' {
            Mock -ModuleName Scheduler -CommandName Get-ScheduledTask -MockWith { $null }

            $result = @(Get-GSMScheduledMaintenanceStatus -FolderName 'FakeGame')

            $result.Count | Should -Be 0
        }

        It 'returns one status object per registered task, including WorkshopRefresh' {
            Mock -ModuleName Scheduler -CommandName Get-ScheduledTask -MockWith {
                param($TaskName)
                [PSCustomObject]@{ TaskName = $TaskName; State = 'Ready' }
            }
            Mock -ModuleName Scheduler -CommandName Get-ScheduledTaskInfo -MockWith {
                [PSCustomObject]@{ NextRunTime = (Get-Date '2026-07-09T04:00:00'); LastRunTime = (Get-Date '2026-07-08T04:00:00'); LastTaskResult = 0 }
            }

            $result = @(Get-GSMScheduledMaintenanceStatus -FolderName 'FakeGame')

            $result.Count | Should -Be 3
            ($result | Where-Object { $_.Kind -eq 'NightlyRestart' }).TaskName | Should -Be 'GSM-FakeGame-NightlyRestart'
            ($result | Where-Object { $_.Kind -eq 'NightlyUpdateCheck' }).State | Should -Be 'Ready'
            ($result | Where-Object { $_.Kind -eq 'NightlyRestart' }).LastTaskResult | Should -Be 0
            ($result | Where-Object { $_.Kind -eq 'WorkshopRefresh' }).TaskName | Should -Be 'GSM-FakeGame-WorkshopRefresh'
        }

        It 'omits WorkshopRefresh when only it is not registered' {
            Mock -ModuleName Scheduler -CommandName Get-ScheduledTask -MockWith {
                param($TaskName)
                if ($TaskName -eq 'GSM-FakeGame-WorkshopRefresh') { return $null }
                return [PSCustomObject]@{ TaskName = $TaskName; State = 'Ready' }
            }
            Mock -ModuleName Scheduler -CommandName Get-ScheduledTaskInfo -MockWith {
                [PSCustomObject]@{ NextRunTime = $null; LastRunTime = $null; LastTaskResult = 0 }
            }

            $result = @(Get-GSMScheduledMaintenanceStatus -FolderName 'FakeGame')

            $result.Count | Should -Be 2
            $result.Kind | Should -Not -Contain 'WorkshopRefresh'
        }
    }
}
