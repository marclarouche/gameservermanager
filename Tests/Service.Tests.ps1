BeforeAll {
    Import-Module "$PSScriptRoot/../Core/Service.psm1" -Force

    function New-FakeGSMRootForService {
        param(
            [string]$FolderName = 'FakeGame',
            [string]$Executable = 'srcds.exe',
            [switch]$WithConfig,
            [switch]$WithExecutable
        )

        $root = Join-Path $TestDrive ('service-root-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $root 'Config') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root "Servers/$FolderName") -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root 'Tools/NSSM') -Force | Out-Null

        if ($WithConfig) {
            # Placeholder content only: Get-GSMConfig itself is mocked per
            # test to control what the code actually reads. This file only
            # needs to exist so Resolve-GSMServerProcessManagerMode's
            # Test-Path check (and Sync-GSMServerServiceRegistration's own)
            # pass.
            Set-Content -Path (Join-Path $root "Config/$FolderName.json") -Value '{"GameName":"FakeGame","AppID":"1"}'
        }
        if ($WithExecutable) {
            Set-Content -Path (Join-Path $root "Servers/$FolderName/$Executable") -Value 'fake-binary'
        }

        return $root
    }

    # A real, globally-available function standing in for a plugin's own
    # Get-<Game>LaunchArgs, matching Tests/ProcessManager.Tests.ps1's
    # identical fixture (see its comment for why this must be global-scoped,
    # not just script-scoped).
    function global:Get-FakeGameLaunchArgs {
        param($Config)
        $null = $Config
        return @('-console', '+map', 'test_map')
    }

    function New-TestSecureStringForService([string]$PlainText) {
        $secureString = [System.Security.SecureString]::new()
        foreach ($char in $PlainText.ToCharArray()) {
            $secureString.AppendChar($char)
        }
        return $secureString
    }
}

AfterAll {
    Remove-Item -Path 'function:global:Get-FakeGameLaunchArgs' -Force -ErrorAction SilentlyContinue
}

Describe 'Core/Service.psm1' {

    BeforeEach {
        Mock -ModuleName Service -CommandName Write-GSMLog -MockWith { }
        Mock -ModuleName Service -CommandName Test-NSSMPresent -MockWith { $true }

        # Default nssm.exe stand-in: every Start-Process call "succeeds"
        # with exit code 0, and (only relevant to `status` calls, which
        # pass -RedirectStandardOutput) writes $script:FakeNSSMStatusOutput
        # to the redirected file. Individual tests override
        # $script:FakeNSSMExitCode / $script:FakeNSSMStatusOutput before
        # calling the function under test.
        $script:FakeNSSMExitCode = 0
        # Defaults to "not running" rather than "running": most tests below
        # exercise the install-and-start path, and only the one test that
        # specifically covers the already-running no-op sets this to
        # SERVICE_RUNNING itself.
        $script:FakeNSSMStatusOutput = 'SERVICE_STOPPED'
        Mock -ModuleName Service -CommandName Start-Process -MockWith {
            param($FilePath, $ArgumentList, [switch]$Wait, [switch]$NoNewWindow, [switch]$PassThru, $ErrorAction, $RedirectStandardOutput)
            $null = $FilePath
            $null = $Wait
            $null = $NoNewWindow
            $null = $PassThru
            $null = $ErrorAction

            if ($RedirectStandardOutput -and ($ArgumentList -contains 'status')) {
                Set-Content -Path $RedirectStandardOutput -Value $script:FakeNSSMStatusOutput -NoNewline
            }

            [PSCustomObject]@{ ExitCode = $script:FakeNSSMExitCode }
        }

        $fakeCredential = [pscredential]::new('GSM-ServiceAccount', (New-TestSecureStringForService -PlainText 'fakepassword'))
        Mock -ModuleName Service -CommandName Get-GSMServiceAccountCredential -MockWith { $fakeCredential }
    }

    Context 'Install-GSMServerService' {
        BeforeEach {
            $script:FakeRoot = New-FakeGSMRootForService -FolderName 'FakeGame'
            Mock -ModuleName Service -CommandName Get-GSMRootPath -MockWith { $script:FakeRoot }
        }

        It 'installs NSSM first when it is not already present' {
            # Test-NSSMPresent must re-check real file state on every call,
            # not just the first: Invoke-GSMNSSMCommand calls it again for
            # every subsequent nssm.exe invocation this function makes
            # (remove, install, set AppParameters, etc.), and those must
            # see NSSM as present once Install-NSSM has "installed" it -
            # exactly like the real, unmocked Test-NSSMPresent would once
            # Install-NSSM actually writes the file to disk.
            Mock -ModuleName Service -CommandName Test-NSSMPresent -MockWith {
                Test-Path -Path (Join-Path $script:FakeRoot 'Tools/NSSM/nssm.exe') -PathType Leaf
            }
            Mock -ModuleName Service -CommandName Install-NSSM -MockWith {
                Set-Content -Path (Join-Path $script:FakeRoot 'Tools/NSSM/nssm.exe') -Value 'fake nssm binary'
                $true
            }

            Install-GSMServerService -FolderName 'FakeGame' -ExecutablePath 'D:\Fake\srcds.exe' -InstallDirectory 'D:\Fake' -LaunchArguments @('-console') | Out-Null

            Should -Invoke -ModuleName Service -CommandName Install-NSSM -Times 1
        }

        It 'removes any existing service before installing, then installs with the executable path' {
            Install-GSMServerService -FolderName 'FakeGame' -ExecutablePath 'D:\Fake\srcds.exe' -InstallDirectory 'D:\Fake' -LaunchArguments @('-console') | Out-Null

            Should -Invoke -ModuleName Service -CommandName Start-Process -Times 1 -ParameterFilter {
                ($ArgumentList -join '|') -eq (@('remove', 'GSM-FakeGame', 'confirm') -join '|')
            }
            Should -Invoke -ModuleName Service -CommandName Start-Process -Times 1 -ParameterFilter {
                ($ArgumentList -join '|') -eq (@('install', 'GSM-FakeGame', 'D:\Fake\srcds.exe') -join '|')
            }
        }

        It 'sets AppParameters from the joined launch arguments' {
            Install-GSMServerService -FolderName 'FakeGame' -ExecutablePath 'D:\Fake\srcds.exe' -InstallDirectory 'D:\Fake' -LaunchArguments @('-console', '+map', 'test_map') | Out-Null

            Should -Invoke -ModuleName Service -CommandName Start-Process -Times 1 -ParameterFilter {
                ($ArgumentList -join '|') -eq (@('set', 'GSM-FakeGame', 'AppParameters', '-console +map test_map') -join '|')
            }
        }

        It 'skips AppParameters when there are no launch arguments' {
            Install-GSMServerService -FolderName 'FakeGame' -ExecutablePath 'D:\Fake\srcds.exe' -InstallDirectory 'D:\Fake' | Out-Null

            Should -Invoke -ModuleName Service -CommandName Start-Process -Times 0 -ParameterFilter {
                $ArgumentList -contains 'AppParameters'
            }
        }

        It 'sets AppDirectory to InstallDirectory' {
            Install-GSMServerService -FolderName 'FakeGame' -ExecutablePath 'D:\Fake\srcds.exe' -InstallDirectory 'D:\Fake' | Out-Null

            Should -Invoke -ModuleName Service -CommandName Start-Process -Times 1 -ParameterFilter {
                ($ArgumentList -join '|') -eq (@('set', 'GSM-FakeGame', 'AppDirectory', 'D:\Fake') -join '|')
            }
        }

        It 'sets ObjectName to the service account credential' {
            Install-GSMServerService -FolderName 'FakeGame' -ExecutablePath 'D:\Fake\srcds.exe' -InstallDirectory 'D:\Fake' -AccountName 'GSM-ServiceAccount' | Out-Null

            Should -Invoke -ModuleName Service -CommandName Start-Process -Times 1 -ParameterFilter {
                ($ArgumentList -join '|') -eq (@('set', 'GSM-FakeGame', 'ObjectName', 'GSM-ServiceAccount', 'fakepassword') -join '|')
            }
        }

        It 'never logs the plaintext service account password' {
            Install-GSMServerService -FolderName 'FakeGame' -ExecutablePath 'D:\Fake\srcds.exe' -InstallDirectory 'D:\Fake' | Out-Null

            Should -Invoke -ModuleName Service -CommandName Write-GSMLog -Times 0 -ParameterFilter { $Message -match 'fakepassword' }
        }

        It 'throws when nssm install fails' {
            Mock -ModuleName Service -CommandName Start-Process -MockWith {
                param($FilePath, $ArgumentList, [switch]$Wait, [switch]$NoNewWindow, [switch]$PassThru, $ErrorAction, $RedirectStandardOutput)
                $null = $FilePath; $null = $Wait; $null = $NoNewWindow; $null = $PassThru; $null = $ErrorAction; $null = $RedirectStandardOutput
                if ($ArgumentList -contains 'install') {
                    return [PSCustomObject]@{ ExitCode = 1 }
                }
                return [PSCustomObject]@{ ExitCode = 0 }
            }

            { Install-GSMServerService -FolderName 'FakeGame' -ExecutablePath 'D:\Fake\srcds.exe' -InstallDirectory 'D:\Fake' } | Should -Throw

            Should -Invoke -ModuleName Service -CommandName Write-GSMLog -Times 1 -ParameterFilter { $Level -eq 'Error' }
        }

        It 'throws when nssm set ObjectName fails' {
            Mock -ModuleName Service -CommandName Start-Process -MockWith {
                param($FilePath, $ArgumentList, [switch]$Wait, [switch]$NoNewWindow, [switch]$PassThru, $ErrorAction, $RedirectStandardOutput)
                $null = $FilePath; $null = $Wait; $null = $NoNewWindow; $null = $PassThru; $null = $ErrorAction; $null = $RedirectStandardOutput
                if ($ArgumentList -contains 'ObjectName') {
                    return [PSCustomObject]@{ ExitCode = 1 }
                }
                return [PSCustomObject]@{ ExitCode = 0 }
            }

            { Install-GSMServerService -FolderName 'FakeGame' -ExecutablePath 'D:\Fake\srcds.exe' -InstallDirectory 'D:\Fake' } | Should -Throw
        }
    }

    Context 'Uninstall-GSMServerService' {
        BeforeEach {
            $script:FakeRoot = New-FakeGSMRootForService -FolderName 'FakeGame'
            Mock -ModuleName Service -CommandName Get-GSMRootPath -MockWith { $script:FakeRoot }
        }

        It 'stops then removes the service' {
            Uninstall-GSMServerService -FolderName 'FakeGame' | Out-Null

            Should -Invoke -ModuleName Service -CommandName Start-Process -Times 1 -ParameterFilter {
                ($ArgumentList -join '|') -eq (@('stop', 'GSM-FakeGame') -join '|')
            }
            Should -Invoke -ModuleName Service -CommandName Start-Process -Times 1 -ParameterFilter {
                ($ArgumentList -join '|') -eq (@('remove', 'GSM-FakeGame', 'confirm') -join '|')
            }
        }

        It 'never throws and logs a warning when the service was never installed' {
            $script:FakeNSSMExitCode = 1

            { Uninstall-GSMServerService -FolderName 'FakeGame' } | Should -Not -Throw

            Should -Invoke -ModuleName Service -CommandName Write-GSMLog -Times 1 -ParameterFilter { $Level -eq 'Warning' }
        }
    }

    Context 'Set-GSMServiceCrashRecovery' {
        BeforeEach {
            $script:FakeRoot = New-FakeGSMRootForService -FolderName 'FakeGame'
            Mock -ModuleName Service -CommandName Get-GSMRootPath -MockWith { $script:FakeRoot }
        }

        It 'sets AppExit to Default Restart' {
            Set-GSMServiceCrashRecovery -FolderName 'FakeGame' | Out-Null

            Should -Invoke -ModuleName Service -CommandName Start-Process -Times 1 -ParameterFilter {
                ($ArgumentList -join '|') -eq (@('set', 'GSM-FakeGame', 'AppExit', 'Default', 'Restart') -join '|')
            }
        }

        It 'sets AppRestartDelay and AppThrottle to their documented 5000/10000ms defaults' {
            Set-GSMServiceCrashRecovery -FolderName 'FakeGame' | Out-Null

            Should -Invoke -ModuleName Service -CommandName Start-Process -Times 1 -ParameterFilter {
                ($ArgumentList -join '|') -eq (@('set', 'GSM-FakeGame', 'AppRestartDelay', 5000) -join '|')
            }
            Should -Invoke -ModuleName Service -CommandName Start-Process -Times 1 -ParameterFilter {
                ($ArgumentList -join '|') -eq (@('set', 'GSM-FakeGame', 'AppThrottle', 10000) -join '|')
            }
        }

        It 'honors custom RestartDelayMilliseconds and ThrottleMilliseconds' {
            Set-GSMServiceCrashRecovery -FolderName 'FakeGame' -RestartDelayMilliseconds 2000 -ThrottleMilliseconds 15000 | Out-Null

            Should -Invoke -ModuleName Service -CommandName Start-Process -Times 1 -ParameterFilter {
                ($ArgumentList -join '|') -eq (@('set', 'GSM-FakeGame', 'AppRestartDelay', 2000) -join '|')
            }
            Should -Invoke -ModuleName Service -CommandName Start-Process -Times 1 -ParameterFilter {
                ($ArgumentList -join '|') -eq (@('set', 'GSM-FakeGame', 'AppThrottle', 15000) -join '|')
            }
        }

        It 'throws when any nssm set call fails' {
            $script:FakeNSSMExitCode = 1

            { Set-GSMServiceCrashRecovery -FolderName 'FakeGame' } | Should -Throw
        }
    }

    Context 'Get-GSMServerStatus - dispatch' {
        BeforeEach {
            $script:FakeRoot = New-FakeGSMRootForService -FolderName 'FakeGame' -WithConfig
            Mock -ModuleName Service -CommandName Get-GSMRootPath -MockWith { $script:FakeRoot }
        }

        It 'delegates to the ScheduledTask backend when ProcessManager is ScheduledTask, and never touches nssm' {
            Mock -ModuleName Service -CommandName Get-GSMConfig -MockWith { [PSCustomObject]@{ GameName = 'FakeGame'; ProcessManager = 'ScheduledTask' } }
            Mock -ModuleName Service -CommandName Get-ScheduledTaskGSMServerStatus -MockWith { 'Crashed' }

            Get-GSMServerStatus -FolderName 'FakeGame' | Should -Be 'Crashed'
            Should -Invoke -ModuleName Service -CommandName Get-ScheduledTaskGSMServerStatus -Times 1 -ParameterFilter { $FolderName -eq 'FakeGame' }
            Should -Invoke -ModuleName Service -CommandName Start-Process -Times 0
        }

        It 'returns Running when nssm status reports SERVICE_RUNNING (default NSSM mode, no ProcessManager field)' {
            Mock -ModuleName Service -CommandName Get-GSMConfig -MockWith { [PSCustomObject]@{ GameName = 'FakeGame' } }
            $script:FakeNSSMStatusOutput = 'SERVICE_RUNNING'

            Get-GSMServerStatus -FolderName 'FakeGame' | Should -Be 'Running'
        }

        It 'returns Stopped when nssm status reports SERVICE_STOPPED' {
            Mock -ModuleName Service -CommandName Get-GSMConfig -MockWith { [PSCustomObject]@{ GameName = 'FakeGame'; ProcessManager = 'NSSM' } }
            $script:FakeNSSMStatusOutput = 'SERVICE_STOPPED'

            Get-GSMServerStatus -FolderName 'FakeGame' | Should -Be 'Stopped'
        }

        It 'returns Stopped without throwing when nssm status exits non-zero (service does not exist)' {
            Mock -ModuleName Service -CommandName Get-GSMConfig -MockWith { [PSCustomObject]@{ GameName = 'FakeGame' } }
            $script:FakeNSSMExitCode = 3
            $script:FakeNSSMStatusOutput = ''

            { Get-GSMServerStatus -FolderName 'FakeGame' } | Should -Not -Throw
            Get-GSMServerStatus -FolderName 'FakeGame' | Should -Be 'Stopped'
        }

        It 'returns Stopped without throwing when NSSM itself is not installed' {
            Mock -ModuleName Service -CommandName Get-GSMConfig -MockWith { [PSCustomObject]@{ GameName = 'FakeGame' } }
            Mock -ModuleName Service -CommandName Test-NSSMPresent -MockWith { $false }

            Get-GSMServerStatus -FolderName 'FakeGame' | Should -Be 'Stopped'
            Should -Invoke -ModuleName Service -CommandName Start-Process -Times 0
        }
    }

    Context 'Start-GSMServer - dispatch' {
        BeforeEach {
            $script:FakeRoot = New-FakeGSMRootForService -FolderName 'FakeGame' -WithConfig -WithExecutable
            Mock -ModuleName Service -CommandName Get-GSMRootPath -MockWith { $script:FakeRoot }
        }

        It 'delegates entirely to the ScheduledTask backend when ProcessManager is ScheduledTask, and never touches nssm' {
            Mock -ModuleName Service -CommandName Get-GSMConfig -MockWith { [PSCustomObject]@{ GameName = 'FakeGame'; ProcessManager = 'ScheduledTask' } }
            Mock -ModuleName Service -CommandName Start-ScheduledTaskGSMServer -MockWith { $true }

            $result = Start-GSMServer -FolderName 'FakeGame' -Executable 'srcds.exe' -GetLaunchArgsFunctionName 'Get-FakeGameLaunchArgs' -TimeoutSeconds 2 -PollIntervalMilliseconds 10

            $result | Should -Be $true
            Should -Invoke -ModuleName Service -CommandName Start-ScheduledTaskGSMServer -Times 1 -ParameterFilter {
                $FolderName -eq 'FakeGame' -and $Executable -eq 'srcds.exe' -and $GetLaunchArgsFunctionName -eq 'Get-FakeGameLaunchArgs'
            }
            Should -Invoke -ModuleName Service -CommandName Start-Process -Times 0
        }

        It 'is a no-op returning $true without installing the service when already running (default NSSM mode)' {
            Mock -ModuleName Service -CommandName Get-GSMConfig -MockWith { [PSCustomObject]@{ GameName = 'FakeGame' } }
            $script:FakeNSSMStatusOutput = 'SERVICE_RUNNING'

            $result = Start-GSMServer -FolderName 'FakeGame' -Executable 'srcds.exe' -GetLaunchArgsFunctionName 'Get-FakeGameLaunchArgs' -TimeoutSeconds 2 -PollIntervalMilliseconds 10

            $result | Should -Be $true
            Should -Invoke -ModuleName Service -CommandName Start-Process -Times 1 -ParameterFilter { $ArgumentList -contains 'status' }
            Should -Invoke -ModuleName Service -CommandName Start-Process -Times 0 -ParameterFilter { $ArgumentList -contains 'install' }
        }

        It 'installs the service, applies crash recovery, starts it, and returns $true when not already running' {
            Mock -ModuleName Service -CommandName Get-GSMConfig -MockWith { [PSCustomObject]@{ GameName = 'FakeGame'; ProcessManager = 'NSSM' } }
            # Status is only "already running" once nssm start has actually
            # been invoked - the Start-Process override below tracks that
            # directly rather than using the shared $script:FakeNSSMStatusOutput.
            $script:StartCalled = $false
            Mock -ModuleName Service -CommandName Start-Process -MockWith {
                param($FilePath, $ArgumentList, [switch]$Wait, [switch]$NoNewWindow, [switch]$PassThru, $ErrorAction, $RedirectStandardOutput)
                $null = $FilePath; $null = $Wait; $null = $NoNewWindow; $null = $PassThru; $null = $ErrorAction

                if ($ArgumentList -contains 'start') {
                    $script:StartCalled = $true
                }
                if ($RedirectStandardOutput -and ($ArgumentList -contains 'status')) {
                    $statusText = if ($script:StartCalled) { 'SERVICE_RUNNING' } else { 'SERVICE_STOPPED' }
                    Set-Content -Path $RedirectStandardOutput -Value $statusText -NoNewline
                }
                [PSCustomObject]@{ ExitCode = 0 }
            }

            $result = Start-GSMServer -FolderName 'FakeGame' -Executable 'srcds.exe' -GetLaunchArgsFunctionName 'Get-FakeGameLaunchArgs' -TimeoutSeconds 2 -PollIntervalMilliseconds 10

            $result | Should -Be $true
            Should -Invoke -ModuleName Service -CommandName Start-Process -Times 1 -ParameterFilter {
                ($ArgumentList -join '|') -eq (@('install', 'GSM-FakeGame', (Join-Path $script:FakeRoot 'Servers/FakeGame/srcds.exe')) -join '|')
            }
            Should -Invoke -ModuleName Service -CommandName Start-Process -Times 1 -ParameterFilter {
                ($ArgumentList -join '|') -eq (@('set', 'GSM-FakeGame', 'AppExit', 'Default', 'Restart') -join '|')
            }
            Should -Invoke -ModuleName Service -CommandName Start-Process -Times 1 -ParameterFilter {
                ($ArgumentList -join '|') -eq (@('start', 'GSM-FakeGame') -join '|')
            }
        }

        It 'throws when nssm start fails' {
            Mock -ModuleName Service -CommandName Get-GSMConfig -MockWith { [PSCustomObject]@{ GameName = 'FakeGame' } }
            $script:FakeNSSMStatusOutput = 'SERVICE_STOPPED'
            Mock -ModuleName Service -CommandName Start-Process -MockWith {
                param($FilePath, $ArgumentList, [switch]$Wait, [switch]$NoNewWindow, [switch]$PassThru, $ErrorAction, $RedirectStandardOutput)
                $null = $FilePath; $null = $Wait; $null = $NoNewWindow; $null = $PassThru; $null = $ErrorAction
                if ($ArgumentList -contains 'start') {
                    return [PSCustomObject]@{ ExitCode = 1 }
                }
                if ($RedirectStandardOutput) {
                    Set-Content -Path $RedirectStandardOutput -Value 'SERVICE_STOPPED' -NoNewline
                }
                [PSCustomObject]@{ ExitCode = 0 }
            }

            { Start-GSMServer -FolderName 'FakeGame' -Executable 'srcds.exe' -GetLaunchArgsFunctionName 'Get-FakeGameLaunchArgs' -TimeoutSeconds 1 -PollIntervalMilliseconds 10 } | Should -Throw
        }

        It 'throws a timeout error when the service never reports Running' {
            Mock -ModuleName Service -CommandName Get-GSMConfig -MockWith { [PSCustomObject]@{ GameName = 'FakeGame' } }
            $script:FakeNSSMStatusOutput = 'SERVICE_STOPPED'

            { Start-GSMServer -FolderName 'FakeGame' -Executable 'srcds.exe' -GetLaunchArgsFunctionName 'Get-FakeGameLaunchArgs' -TimeoutSeconds 1 -PollIntervalMilliseconds 10 } |
                Should -Throw '*imeout*'
        }

        It 'throws a clear, actionable error when Config/<FolderName>.json does not exist' {
            $noConfigRoot = New-FakeGSMRootForService -FolderName 'NoConfigGame' -WithExecutable
            Mock -ModuleName Service -CommandName Get-GSMRootPath -MockWith { $noConfigRoot }

            { Start-GSMServer -FolderName 'NoConfigGame' -Executable 'srcds.exe' -GetLaunchArgsFunctionName 'Get-FakeGameLaunchArgs' -TimeoutSeconds 1 -PollIntervalMilliseconds 10 } |
                Should -Throw '*Configure*'
        }

        It 'throws a clear, actionable error when the server executable is not installed' {
            $noExeRoot = New-FakeGSMRootForService -FolderName 'NoExeGame' -WithConfig
            Mock -ModuleName Service -CommandName Get-GSMRootPath -MockWith { $noExeRoot }
            Mock -ModuleName Service -CommandName Get-GSMConfig -MockWith { [PSCustomObject]@{ GameName = 'NoExeGame' } }

            { Start-GSMServer -FolderName 'NoExeGame' -Executable 'srcds.exe' -GetLaunchArgsFunctionName 'Get-FakeGameLaunchArgs' -TimeoutSeconds 1 -PollIntervalMilliseconds 10 } |
                Should -Throw '*Install*'
        }

        It 'throws when the launch-args function name does not resolve to a real command' {
            Mock -ModuleName Service -CommandName Get-GSMConfig -MockWith { [PSCustomObject]@{ GameName = 'FakeGame' } }

            { Start-GSMServer -FolderName 'FakeGame' -Executable 'srcds.exe' -GetLaunchArgsFunctionName 'Get-ThisFunctionDoesNotExist' -TimeoutSeconds 1 -PollIntervalMilliseconds 10 } |
                Should -Throw '*not available*'
        }
    }

    Context 'Stop-GSMServer - dispatch' {
        BeforeEach {
            $script:FakeRoot = New-FakeGSMRootForService -FolderName 'FakeGame' -WithConfig
            Mock -ModuleName Service -CommandName Get-GSMRootPath -MockWith { $script:FakeRoot }
        }

        It 'delegates to the ScheduledTask backend when ProcessManager is ScheduledTask' {
            Mock -ModuleName Service -CommandName Get-GSMConfig -MockWith { [PSCustomObject]@{ GameName = 'FakeGame'; ProcessManager = 'ScheduledTask' } }
            Mock -ModuleName Service -CommandName Stop-ScheduledTaskGSMServer -MockWith { $true }

            Stop-GSMServer -FolderName 'FakeGame' | Should -Be $true
            Should -Invoke -ModuleName Service -CommandName Stop-ScheduledTaskGSMServer -Times 1 -ParameterFilter { $FolderName -eq 'FakeGame' }
            Should -Invoke -ModuleName Service -CommandName Start-Process -Times 0
        }

        It 'runs nssm stop in the default NSSM mode' {
            Mock -ModuleName Service -CommandName Get-GSMConfig -MockWith { [PSCustomObject]@{ GameName = 'FakeGame' } }

            Stop-GSMServer -FolderName 'FakeGame' | Should -Be $true

            Should -Invoke -ModuleName Service -CommandName Start-Process -Times 1 -ParameterFilter {
                ($ArgumentList -join '|') -eq (@('stop', 'GSM-FakeGame') -join '|')
            }
        }

        It 'never throws, and logs a warning, when nssm stop exits non-zero' {
            Mock -ModuleName Service -CommandName Get-GSMConfig -MockWith { [PSCustomObject]@{ GameName = 'FakeGame' } }
            $script:FakeNSSMExitCode = 1

            $script:result = $null
            { $script:result = Stop-GSMServer -FolderName 'FakeGame' } | Should -Not -Throw

            $script:result | Should -Be $true
            Should -Invoke -ModuleName Service -CommandName Write-GSMLog -Times 1 -ParameterFilter { $Level -eq 'Warning' }
        }

        It 'treats a missing config as NSSM mode and still runs nssm stop' {
            $noConfigRoot = New-FakeGSMRootForService -FolderName 'NoConfigGame'
            Mock -ModuleName Service -CommandName Get-GSMRootPath -MockWith { $noConfigRoot }

            Stop-GSMServer -FolderName 'NoConfigGame' | Should -Be $true

            Should -Invoke -ModuleName Service -CommandName Start-Process -Times 1 -ParameterFilter {
                ($ArgumentList -join '|') -eq (@('stop', 'GSM-NoConfigGame') -join '|')
            }
        }
    }

    Context 'Restart-GSMServer - dispatch' {
        BeforeEach {
            $script:FakeRoot = New-FakeGSMRootForService -FolderName 'FakeGame' -WithConfig -WithExecutable
            Mock -ModuleName Service -CommandName Get-GSMRootPath -MockWith { $script:FakeRoot }
        }

        It 'delegates to the ScheduledTask backend when ProcessManager is ScheduledTask' {
            Mock -ModuleName Service -CommandName Get-GSMConfig -MockWith { [PSCustomObject]@{ GameName = 'FakeGame'; ProcessManager = 'ScheduledTask' } }
            Mock -ModuleName Service -CommandName Restart-ScheduledTaskGSMServer -MockWith { $true }

            $result = Restart-GSMServer -FolderName 'FakeGame' -Executable 'srcds.exe' -GetLaunchArgsFunctionName 'Get-FakeGameLaunchArgs'

            $result | Should -Be $true
            Should -Invoke -ModuleName Service -CommandName Restart-ScheduledTaskGSMServer -Times 1 -ParameterFilter {
                $FolderName -eq 'FakeGame' -and $Executable -eq 'srcds.exe' -and $GetLaunchArgsFunctionName -eq 'Get-FakeGameLaunchArgs'
            }
            Should -Invoke -ModuleName Service -CommandName Start-Process -Times 0
        }

        It 'syncs the service registration and runs nssm restart in the default NSSM mode' {
            Mock -ModuleName Service -CommandName Get-GSMConfig -MockWith { [PSCustomObject]@{ GameName = 'FakeGame' } }

            $result = Restart-GSMServer -FolderName 'FakeGame' -Executable 'srcds.exe' -GetLaunchArgsFunctionName 'Get-FakeGameLaunchArgs'

            $result | Should -Be $true
            Should -Invoke -ModuleName Service -CommandName Start-Process -Times 1 -ParameterFilter {
                ($ArgumentList -join '|') -eq (@('install', 'GSM-FakeGame', (Join-Path $script:FakeRoot 'Servers/FakeGame/srcds.exe')) -join '|')
            }
            Should -Invoke -ModuleName Service -CommandName Start-Process -Times 1 -ParameterFilter {
                ($ArgumentList -join '|') -eq (@('restart', 'GSM-FakeGame') -join '|')
            }
        }

        It 'throws when nssm restart fails' {
            Mock -ModuleName Service -CommandName Get-GSMConfig -MockWith { [PSCustomObject]@{ GameName = 'FakeGame' } }
            Mock -ModuleName Service -CommandName Start-Process -MockWith {
                param($FilePath, $ArgumentList, [switch]$Wait, [switch]$NoNewWindow, [switch]$PassThru, $ErrorAction, $RedirectStandardOutput)
                $null = $FilePath; $null = $Wait; $null = $NoNewWindow; $null = $PassThru; $null = $ErrorAction; $null = $RedirectStandardOutput
                if ($ArgumentList -contains 'restart') {
                    return [PSCustomObject]@{ ExitCode = 1 }
                }
                [PSCustomObject]@{ ExitCode = 0 }
            }

            { Restart-GSMServer -FolderName 'FakeGame' -Executable 'srcds.exe' -GetLaunchArgsFunctionName 'Get-FakeGameLaunchArgs' } | Should -Throw
        }
    }
}
