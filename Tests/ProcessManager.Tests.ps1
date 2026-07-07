BeforeAll {
    Import-Module "$PSScriptRoot/../Core/ProcessManager.psm1" -Force

    function New-FakeGSMRootForProcessManager {
        param(
            [string]$FolderName = 'FakeGame',
            [string]$Executable = 'srcds.exe',
            [switch]$WithConfig,
            [switch]$WithExecutable
        )

        $root = Join-Path $TestDrive ('processmanager-root-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $root 'Config') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root "Servers/$FolderName") -Force | Out-Null

        if ($WithConfig) {
            Set-Content -Path (Join-Path $root "Config/$FolderName.json") -Value '{"GameName":"FakeGame","AppID":"1"}'
        }
        if ($WithExecutable) {
            Set-Content -Path (Join-Path $root "Servers/$FolderName/$Executable") -Value 'fake-binary'
        }

        return $root
    }

    # A real, globally-available function standing in for a plugin's own
    # Get-<Game>LaunchArgs, since Start-GSMServer resolves it by name via
    # Get-Command (matching Menu.psm1's Invoke-GSMAction dispatch pattern),
    # not something Mock -ModuleName can intercept from outside the plugin.
    #
    # Must be defined with the global: scope modifier, not just a bare
    # "function" (which only reaches script scope of this test file):
    # Get-Command, called from inside the ProcessManager module - a sibling
    # scope, not a descendant of this BeforeAll - can only resolve Global
    # scope or another module's exported members.
    function global:Get-FakeGameLaunchArgs {
        param($Config)
        # $Config intentionally unused: this fake ignores the real config
        # and returns fixed args. Referenced here only to satisfy
        # PSReviewUnusedParameter, since the real Get-<Game>LaunchArgs
        # functions this stands in for all take -Config.
        $null = $Config
        return @('-console', '+map', 'test_map')
    }

    # Built via AppendChar rather than ConvertTo-SecureString -AsPlainText,
    # matching the established pattern in Tests/ServiceAccount.Tests.ps1:
    # PSScriptAnalyzer's PSAvoidUsingConvertToSecureStringWithPlainText rule
    # flags that cmdlet unconditionally, even in test-only fixture code.
    function New-TestSecureStringForProcessManager([string]$PlainText) {
        $secureString = [System.Security.SecureString]::new()
        foreach ($char in $PlainText.ToCharArray()) {
            $secureString.AppendChar($char)
        }
        return $secureString
    }
}

AfterAll {
    # Global function fixtures must not leak into whichever test file runs
    # next in the same Pester process.
    Remove-Item -Path 'function:global:Get-FakeGameLaunchArgs' -Force -ErrorAction SilentlyContinue
}

Describe 'Core/ProcessManager.psm1' {

    BeforeEach {
        Mock -ModuleName ProcessManager -CommandName Write-GSMLog -MockWith { }
    }

    Context 'Start-GSMServer - preconditions' {
        It 'throws a clear, actionable error when Config/<FolderName>.json does not exist' {
            $fakeRoot = New-FakeGSMRootForProcessManager -FolderName 'FakeGame'
            Mock -ModuleName ProcessManager -CommandName Get-GSMRootPath -MockWith { $fakeRoot }

            { Start-GSMServer -FolderName 'FakeGame' -Executable 'srcds.exe' -GetLaunchArgsFunctionName 'Get-FakeGameLaunchArgs' } |
                Should -Throw '*Configure*'
        }

        It 'throws a clear, actionable error when the server executable is not installed' {
            $fakeRoot = New-FakeGSMRootForProcessManager -FolderName 'FakeGame' -WithConfig
            Mock -ModuleName ProcessManager -CommandName Get-GSMRootPath -MockWith { $fakeRoot }
            Mock -ModuleName ProcessManager -CommandName Get-GSMConfig -MockWith { [PSCustomObject]@{ GameName = 'FakeGame' } }

            { Start-GSMServer -FolderName 'FakeGame' -Executable 'srcds.exe' -GetLaunchArgsFunctionName 'Get-FakeGameLaunchArgs' } |
                Should -Throw '*Install*'
        }

        It 'throws when the launch-args function name does not resolve to a real command' {
            $fakeRoot = New-FakeGSMRootForProcessManager -FolderName 'FakeGame' -WithConfig -WithExecutable
            Mock -ModuleName ProcessManager -CommandName Get-GSMRootPath -MockWith { $fakeRoot }
            Mock -ModuleName ProcessManager -CommandName Get-GSMConfig -MockWith { [PSCustomObject]@{ GameName = 'FakeGame' } }

            { Start-GSMServer -FolderName 'FakeGame' -Executable 'srcds.exe' -GetLaunchArgsFunctionName 'Get-ThisFunctionDoesNotExist' } |
                Should -Throw '*not available*'
        }

        It 'is a no-op returning $true without touching the Scheduled Task when the server is already running' {
            $fakeRoot = New-FakeGSMRootForProcessManager -FolderName 'FakeGame' -WithConfig -WithExecutable
            Mock -ModuleName ProcessManager -CommandName Get-GSMRootPath -MockWith { $fakeRoot }

            $statusDir = Join-Path $fakeRoot 'Config/ServerStatus'
            New-Item -ItemType Directory -Path $statusDir -Force | Out-Null
            [PSCustomObject]@{ ProcessId = 4242; StartTimeUtc = (Get-Date).ToString('o'); ExecutablePath = 'x'; TaskName = 'GSM-FakeGame' } |
                ConvertTo-Json | Set-Content -Path (Join-Path $statusDir 'FakeGame.json')

            Mock -ModuleName ProcessManager -CommandName Get-Process -MockWith { [PSCustomObject]@{ Id = 4242 } }
            Mock -ModuleName ProcessManager -CommandName Register-ScheduledTask -MockWith { }
            Mock -ModuleName ProcessManager -CommandName Start-ScheduledTask -MockWith { }

            $result = Start-GSMServer -FolderName 'FakeGame' -Executable 'srcds.exe' -GetLaunchArgsFunctionName 'Get-FakeGameLaunchArgs'

            $result | Should -Be $true
            Should -Invoke -ModuleName ProcessManager -CommandName Register-ScheduledTask -Times 0
            Should -Invoke -ModuleName ProcessManager -CommandName Start-ScheduledTask -Times 0
        }
    }

    Context 'Start-GSMServer - happy path' {
        BeforeEach {
            $script:FakeRoot = New-FakeGSMRootForProcessManager -FolderName 'FakeGame' -WithConfig -WithExecutable
            Mock -ModuleName ProcessManager -CommandName Get-GSMRootPath -MockWith { $script:FakeRoot }
            Mock -ModuleName ProcessManager -CommandName Get-GSMConfig -MockWith { [PSCustomObject]@{ GameName = 'FakeGame' } }

            $fakeCredential = [pscredential]::new('GSM-ServiceAccount', (New-TestSecureStringForProcessManager -PlainText 'fakepassword'))
            Mock -ModuleName ProcessManager -CommandName Get-GSMServiceAccountCredential -MockWith { $fakeCredential }

            Mock -ModuleName ProcessManager -CommandName Unregister-ScheduledTask -MockWith { }
            # New-ScheduledTaskAction/New-ScheduledTaskSettingsSet are left to
            # call through to the real ScheduledTasks module cmdlets (they
            # only build an in-memory CIM instance; nothing touches the Task
            # Scheduler service until Register-ScheduledTask, which IS
            # mocked below). Real cmdlets, not test doubles, are needed here
            # because Pester rebuilds a mock using the target cmdlet's own
            # parameter types, and Register-ScheduledTask's -Action/-Settings
            # parameters require genuine CimInstance objects - a
            # [PSCustomObject] stand-in fails parameter binding.
            Mock -ModuleName ProcessManager -CommandName New-ScheduledTaskAction -MockWith { ScheduledTasks\New-ScheduledTaskAction -Execute $Execute -Argument $Argument -WorkingDirectory $WorkingDirectory }
            Mock -ModuleName ProcessManager -CommandName New-ScheduledTaskSettingsSet -MockWith { ScheduledTasks\New-ScheduledTaskSettingsSet -ExecutionTimeLimit $ExecutionTimeLimit -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries }
            Mock -ModuleName ProcessManager -CommandName Register-ScheduledTask -MockWith { }
            Mock -ModuleName ProcessManager -CommandName Start-ScheduledTask -MockWith { }
            Mock -ModuleName ProcessManager -CommandName Get-CimInstance -MockWith {
                [PSCustomObject]@{ ProcessId = 9999 }
            }
        }

        It 'unregisters any pre-existing task, then registers and starts a fresh one under the service account' {
            Start-GSMServer -FolderName 'FakeGame' -Executable 'srcds.exe' -GetLaunchArgsFunctionName 'Get-FakeGameLaunchArgs' -TimeoutSeconds 2 -PollIntervalMilliseconds 10 | Out-Null

            Should -Invoke -ModuleName ProcessManager -CommandName Unregister-ScheduledTask -Times 1 -ParameterFilter { $TaskName -eq 'GSM-FakeGame' }
            Should -Invoke -ModuleName ProcessManager -CommandName Register-ScheduledTask -Times 1 -ParameterFilter {
                $TaskName -eq 'GSM-FakeGame' -and $User -eq 'GSM-ServiceAccount' -and $Password -eq 'fakepassword' -and $RunLevel -eq 'Limited'
            }
            Should -Invoke -ModuleName ProcessManager -CommandName Start-ScheduledTask -Times 1 -ParameterFilter { $TaskName -eq 'GSM-FakeGame' }
        }

        It 'builds the Scheduled Task action from the executable path, joined launch args, and install directory' {
            Start-GSMServer -FolderName 'FakeGame' -Executable 'srcds.exe' -GetLaunchArgsFunctionName 'Get-FakeGameLaunchArgs' -TimeoutSeconds 2 -PollIntervalMilliseconds 10 | Out-Null

            Should -Invoke -ModuleName ProcessManager -CommandName New-ScheduledTaskAction -Times 1 -ParameterFilter {
                $Execute -eq (Join-Path $script:FakeRoot 'Servers/FakeGame/srcds.exe') -and
                $Argument -eq '-console +map test_map' -and
                $WorkingDirectory -eq (Join-Path $script:FakeRoot 'Servers/FakeGame')
            }
        }

        It 'sets no execution time limit, since game servers run indefinitely' {
            Start-GSMServer -FolderName 'FakeGame' -Executable 'srcds.exe' -GetLaunchArgsFunctionName 'Get-FakeGameLaunchArgs' -TimeoutSeconds 2 -PollIntervalMilliseconds 10 | Out-Null

            Should -Invoke -ModuleName ProcessManager -CommandName New-ScheduledTaskSettingsSet -Times 1 -ParameterFilter {
                $ExecutionTimeLimit -eq [System.TimeSpan]::Zero
            }
        }

        It 'writes the resolved PID and start time to Config/ServerStatus/<FolderName>.json' {
            Start-GSMServer -FolderName 'FakeGame' -Executable 'srcds.exe' -GetLaunchArgsFunctionName 'Get-FakeGameLaunchArgs' -TimeoutSeconds 2 -PollIntervalMilliseconds 10 | Out-Null

            $statusPath = Join-Path $script:FakeRoot 'Config/ServerStatus/FakeGame.json'
            Test-Path -Path $statusPath | Should -Be $true

            $status = Get-Content -Path $statusPath -Raw | ConvertFrom-Json
            $status.ProcessId | Should -Be 9999
            $status.TaskName | Should -Be 'GSM-FakeGame'
            $status.ExecutablePath | Should -Be (Join-Path $script:FakeRoot 'Servers/FakeGame/srcds.exe')
            { [datetime]::Parse($status.StartTimeUtc) } | Should -Not -Throw
        }

        It 'never logs the plaintext service account password' {
            Start-GSMServer -FolderName 'FakeGame' -Executable 'srcds.exe' -GetLaunchArgsFunctionName 'Get-FakeGameLaunchArgs' -TimeoutSeconds 2 -PollIntervalMilliseconds 10 | Out-Null

            Should -Invoke -ModuleName ProcessManager -CommandName Write-GSMLog -Times 0 -ParameterFilter { $Message -match 'fakepassword' }
        }

        It 'returns $true on success' {
            $result = Start-GSMServer -FolderName 'FakeGame' -Executable 'srcds.exe' -GetLaunchArgsFunctionName 'Get-FakeGameLaunchArgs' -TimeoutSeconds 2 -PollIntervalMilliseconds 10

            $result | Should -Be $true
        }

        It 'throws and logs if Register-ScheduledTask fails' {
            Mock -ModuleName ProcessManager -CommandName Register-ScheduledTask -MockWith { throw 'simulated registration failure' }

            { Start-GSMServer -FolderName 'FakeGame' -Executable 'srcds.exe' -GetLaunchArgsFunctionName 'Get-FakeGameLaunchArgs' -TimeoutSeconds 2 -PollIntervalMilliseconds 10 } | Should -Throw

            Should -Invoke -ModuleName ProcessManager -CommandName Write-GSMLog -Times 1 -ParameterFilter { $Level -eq 'Error' }
            Should -Invoke -ModuleName ProcessManager -CommandName Start-ScheduledTask -Times 0
        }

        It 'throws when no matching process appears within the timeout' {
            Mock -ModuleName ProcessManager -CommandName Get-CimInstance -MockWith { $null }

            { Start-GSMServer -FolderName 'FakeGame' -Executable 'srcds.exe' -GetLaunchArgsFunctionName 'Get-FakeGameLaunchArgs' -TimeoutSeconds 1 -PollIntervalMilliseconds 10 } |
                Should -Throw '*timeout*' -Because 'the error message should explain no process was found'
        }
    }

    Context 'Stop-GSMServer' {
        It 'is a no-op returning $true and logs a warning when no status file exists' {
            $fakeRoot = New-FakeGSMRootForProcessManager -FolderName 'FakeGame'
            Mock -ModuleName ProcessManager -CommandName Get-GSMRootPath -MockWith { $fakeRoot }

            $result = Stop-GSMServer -FolderName 'FakeGame'

            $result | Should -Be $true
            Should -Invoke -ModuleName ProcessManager -CommandName Write-GSMLog -Times 1 -ParameterFilter { $Level -eq 'Warning' }
        }

        It 'stops the tracked process and removes the status file' {
            $fakeRoot = New-FakeGSMRootForProcessManager -FolderName 'FakeGame'
            Mock -ModuleName ProcessManager -CommandName Get-GSMRootPath -MockWith { $fakeRoot }

            $statusDir = Join-Path $fakeRoot 'Config/ServerStatus'
            New-Item -ItemType Directory -Path $statusDir -Force | Out-Null
            $statusPath = Join-Path $statusDir 'FakeGame.json'
            [PSCustomObject]@{ ProcessId = 5555; StartTimeUtc = (Get-Date).ToString('o'); ExecutablePath = 'x'; TaskName = 'GSM-FakeGame' } |
                ConvertTo-Json | Set-Content -Path $statusPath

            Mock -ModuleName ProcessManager -CommandName Stop-Process -MockWith { }

            $result = Stop-GSMServer -FolderName 'FakeGame'

            $result | Should -Be $true
            Should -Invoke -ModuleName ProcessManager -CommandName Stop-Process -Times 1 -ParameterFilter { $Id -eq 5555 -and $Force -eq $true }
            Test-Path -Path $statusPath | Should -Be $false
        }

        It 'warns rather than throws, and still clears the status file, when the tracked process is already gone' {
            $fakeRoot = New-FakeGSMRootForProcessManager -FolderName 'FakeGame'
            Mock -ModuleName ProcessManager -CommandName Get-GSMRootPath -MockWith { $fakeRoot }

            $statusDir = Join-Path $fakeRoot 'Config/ServerStatus'
            New-Item -ItemType Directory -Path $statusDir -Force | Out-Null
            $statusPath = Join-Path $statusDir 'FakeGame.json'
            [PSCustomObject]@{ ProcessId = 6666; StartTimeUtc = (Get-Date).ToString('o'); ExecutablePath = 'x'; TaskName = 'GSM-FakeGame' } |
                ConvertTo-Json | Set-Content -Path $statusPath

            Mock -ModuleName ProcessManager -CommandName Stop-Process -MockWith { throw 'Cannot find a process with the process identifier 6666.' }

            { Stop-GSMServer -FolderName 'FakeGame' } | Should -Not -Throw

            Should -Invoke -ModuleName ProcessManager -CommandName Write-GSMLog -Times 1 -ParameterFilter { $Level -eq 'Warning' }
            Test-Path -Path $statusPath | Should -Be $false
        }
    }

    Context 'Restart-GSMServer' {
        It 'calls Stop-GSMServer then Start-GSMServer with the same parameters' {
            $fakeRoot = New-FakeGSMRootForProcessManager -FolderName 'FakeGame' -WithConfig -WithExecutable
            Mock -ModuleName ProcessManager -CommandName Get-GSMRootPath -MockWith { $fakeRoot }
            Mock -ModuleName ProcessManager -CommandName Get-GSMConfig -MockWith { [PSCustomObject]@{ GameName = 'FakeGame' } }

            $fakeCredential = [pscredential]::new('GSM-ServiceAccount', (New-TestSecureStringForProcessManager -PlainText 'fakepassword'))
            Mock -ModuleName ProcessManager -CommandName Get-GSMServiceAccountCredential -MockWith { $fakeCredential }
            Mock -ModuleName ProcessManager -CommandName Unregister-ScheduledTask -MockWith { }
            # See the matching comment in the happy-path context above: these
            # must produce real CimInstance objects for Register-ScheduledTask
            # to bind, so they call through to the real cmdlets.
            Mock -ModuleName ProcessManager -CommandName New-ScheduledTaskAction -MockWith { ScheduledTasks\New-ScheduledTaskAction -Execute $Execute -Argument $Argument -WorkingDirectory $WorkingDirectory }
            Mock -ModuleName ProcessManager -CommandName New-ScheduledTaskSettingsSet -MockWith { ScheduledTasks\New-ScheduledTaskSettingsSet -ExecutionTimeLimit $ExecutionTimeLimit -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries }
            Mock -ModuleName ProcessManager -CommandName Register-ScheduledTask -MockWith { }
            Mock -ModuleName ProcessManager -CommandName Start-ScheduledTask -MockWith { }
            Mock -ModuleName ProcessManager -CommandName Get-CimInstance -MockWith { [PSCustomObject]@{ ProcessId = 7777 } }
            Mock -ModuleName ProcessManager -CommandName Stop-Process -MockWith { }

            $result = Restart-GSMServer -FolderName 'FakeGame' -Executable 'srcds.exe' -GetLaunchArgsFunctionName 'Get-FakeGameLaunchArgs'

            $result | Should -Be $true
            Should -Invoke -ModuleName ProcessManager -CommandName Register-ScheduledTask -Times 1
            Should -Invoke -ModuleName ProcessManager -CommandName Start-ScheduledTask -Times 1
        }
    }

    Context 'Get-GSMServerStatus' {
        It 'returns Stopped when no status file exists' {
            $fakeRoot = New-FakeGSMRootForProcessManager -FolderName 'FakeGame'
            Mock -ModuleName ProcessManager -CommandName Get-GSMRootPath -MockWith { $fakeRoot }

            Get-GSMServerStatus -FolderName 'FakeGame' | Should -Be 'Stopped'
        }

        It 'returns Stopped when the status file is malformed' {
            $fakeRoot = New-FakeGSMRootForProcessManager -FolderName 'FakeGame'
            Mock -ModuleName ProcessManager -CommandName Get-GSMRootPath -MockWith { $fakeRoot }

            $statusDir = Join-Path $fakeRoot 'Config/ServerStatus'
            New-Item -ItemType Directory -Path $statusDir -Force | Out-Null
            Set-Content -Path (Join-Path $statusDir 'FakeGame.json') -Value '{ not valid json ]'

            Get-GSMServerStatus -FolderName 'FakeGame' | Should -Be 'Stopped'
        }

        It 'returns Running when the tracked PID still resolves to a live process' {
            $fakeRoot = New-FakeGSMRootForProcessManager -FolderName 'FakeGame'
            Mock -ModuleName ProcessManager -CommandName Get-GSMRootPath -MockWith { $fakeRoot }

            $statusDir = Join-Path $fakeRoot 'Config/ServerStatus'
            New-Item -ItemType Directory -Path $statusDir -Force | Out-Null
            [PSCustomObject]@{ ProcessId = 8888; StartTimeUtc = (Get-Date).ToString('o'); ExecutablePath = 'x'; TaskName = 'GSM-FakeGame' } |
                ConvertTo-Json | Set-Content -Path (Join-Path $statusDir 'FakeGame.json')

            Mock -ModuleName ProcessManager -CommandName Get-Process -MockWith { [PSCustomObject]@{ Id = 8888 } }

            Get-GSMServerStatus -FolderName 'FakeGame' | Should -Be 'Running'
        }

        It 'returns Crashed when the status file exists but the tracked PID no longer resolves' {
            $fakeRoot = New-FakeGSMRootForProcessManager -FolderName 'FakeGame'
            Mock -ModuleName ProcessManager -CommandName Get-GSMRootPath -MockWith { $fakeRoot }

            $statusDir = Join-Path $fakeRoot 'Config/ServerStatus'
            New-Item -ItemType Directory -Path $statusDir -Force | Out-Null
            [PSCustomObject]@{ ProcessId = 1234; StartTimeUtc = (Get-Date).ToString('o'); ExecutablePath = 'x'; TaskName = 'GSM-FakeGame' } |
                ConvertTo-Json | Set-Content -Path (Join-Path $statusDir 'FakeGame.json')

            Mock -ModuleName ProcessManager -CommandName Get-Process -MockWith { $null }

            Get-GSMServerStatus -FolderName 'FakeGame' | Should -Be 'Crashed'
        }
    }
}
