BeforeAll {
    Import-Module "$PSScriptRoot/../Core/SteamCMD.psm1" -Force

    function New-FakeGSMRoot {
        $root = Join-Path $TestDrive ('steamcmd-root-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $root 'Config') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root 'SteamCMD') -Force | Out-Null
        return $root
    }

    # A fake steamcmd.exe payload plus the real SHA-256 of that exact content,
    # so tests can control whether Install-SteamCMD's verification passes or
    # fails without touching the real, pinned Config/SteamCMD.json.
    $script:FakeSteamCmdContent = 'FAKE STEAMCMD CONTENT FOR TESTING'
    $hashScratchFile = Join-Path $TestDrive 'hash-scratch.tmp'
    Set-Content -Path $hashScratchFile -Value $script:FakeSteamCmdContent -NoNewline
    $script:FakeSteamCmdHash = (Get-FileHash -Path $hashScratchFile -Algorithm SHA256).Hash
}

Describe 'Core/SteamCMD.psm1' {

    Context 'Test-SteamCMDPresent' {
        It 'returns $true when SteamCMD/steamcmd.exe exists' {
            $script:FakeRoot = New-FakeGSMRoot
            Set-Content -Path (Join-Path $script:FakeRoot 'SteamCMD/steamcmd.exe') -Value 'anything'
            Mock -ModuleName SteamCMD -CommandName Get-GSMRootPath -MockWith { $script:FakeRoot }

            Test-SteamCMDPresent | Should -Be $true
        }

        It 'returns $false when SteamCMD/steamcmd.exe does not exist' {
            $script:FakeRoot = New-FakeGSMRoot
            Mock -ModuleName SteamCMD -CommandName Get-GSMRootPath -MockWith { $script:FakeRoot }

            Test-SteamCMDPresent | Should -Be $false
        }
    }

    Context 'Install-SteamCMD' {
        BeforeEach {
            $script:FakeRoot = New-FakeGSMRoot
            Mock -ModuleName SteamCMD -CommandName Get-GSMRootPath -MockWith { $script:FakeRoot }
        }

        It 'is a no-op returning $true when SteamCMD is already present and -Force is not set' {
            Set-Content -Path (Join-Path $script:FakeRoot 'SteamCMD/steamcmd.exe') -Value 'already installed'
            Mock -ModuleName SteamCMD -CommandName Invoke-WebRequest -MockWith { }
            Mock -ModuleName SteamCMD -CommandName Expand-Archive -MockWith { }

            $result = Install-SteamCMD

            $result | Should -Be $true
            Should -Invoke -ModuleName SteamCMD -CommandName Invoke-WebRequest -Times 0
            Should -Invoke -ModuleName SteamCMD -CommandName Expand-Archive -Times 0
        }

        It 'downloads, extracts, and verifies successfully when the hash matches' {
            @{
                InstallerUrl = 'https://example.invalid/steamcmd.zip'
                PinnedSHA256 = $script:FakeSteamCmdHash
            } | ConvertTo-Json | Set-Content -Path (Join-Path $script:FakeRoot 'Config/SteamCMD.json')

            Mock -ModuleName SteamCMD -CommandName Invoke-WebRequest -MockWith { }
            Mock -ModuleName SteamCMD -CommandName Expand-Archive -MockWith {
                param($Path, $DestinationPath, [switch]$Force)
                New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
                Set-Content -Path (Join-Path $DestinationPath 'steamcmd.exe') -Value $script:FakeSteamCmdContent -NoNewline
            }

            $result = Install-SteamCMD

            $result | Should -Be $true
            Test-Path -Path (Join-Path $script:FakeRoot 'SteamCMD/steamcmd.exe') | Should -Be $true
            Should -Invoke -ModuleName SteamCMD -CommandName Invoke-WebRequest -Times 1
            Should -Invoke -ModuleName SteamCMD -CommandName Expand-Archive -Times 1
        }

        It 'throws and removes extracted files when the hash does not match' {
            @{
                InstallerUrl = 'https://example.invalid/steamcmd.zip'
                PinnedSHA256 = '0000000000000000000000000000000000000000000000000000000000000000'
            } | ConvertTo-Json | Set-Content -Path (Join-Path $script:FakeRoot 'Config/SteamCMD.json')

            Mock -ModuleName SteamCMD -CommandName Invoke-WebRequest -MockWith { }
            Mock -ModuleName SteamCMD -CommandName Expand-Archive -MockWith {
                param($Path, $DestinationPath, [switch]$Force)
                New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
                Set-Content -Path (Join-Path $DestinationPath 'steamcmd.exe') -Value $script:FakeSteamCmdContent -NoNewline
            }
            Mock -ModuleName SteamCMD -CommandName Write-GSMLog -MockWith { }

            { Install-SteamCMD } | Should -Throw '*hash*'

            Test-Path -Path (Join-Path $script:FakeRoot 'SteamCMD/steamcmd.exe') | Should -Be $false
            Should -Invoke -ModuleName SteamCMD -CommandName Write-GSMLog -Times 1 -ParameterFilter { $Level -eq 'Error' }
        }
    }

    Context 'Update-SteamApp' {
        BeforeEach {
            Mock -ModuleName SteamCMD -CommandName Test-SteamCMDPresent -MockWith { $true }
            Mock -ModuleName SteamCMD -CommandName Start-Process -MockWith {
                [PSCustomObject]@{ ExitCode = 0 }
            }
        }

        It 'builds the correct steamcmd.exe arguments' {
            Update-SteamApp -AppID '237410' -InstallDirectory 'D:\Fake\Insurgency2014'

            Should -Invoke -ModuleName SteamCMD -CommandName Start-Process -Times 1 -ParameterFilter {
                ($ArgumentList -join '|') -eq (@('+login', 'anonymous', '+force_install_dir', 'D:\Fake\Insurgency2014', '+app_update', '237410', 'validate', '+quit') -join '|')
            }
        }

        It 'does not launch steamcmd.exe or hit the network when arguments are validated' {
            Update-SteamApp -AppID '237410' -InstallDirectory 'D:\Fake\Insurgency2014' | Out-Null

            Should -Invoke -ModuleName SteamCMD -CommandName Start-Process -Times 1
        }

        It 'throws when SteamCMD is not present' {
            Mock -ModuleName SteamCMD -CommandName Test-SteamCMDPresent -MockWith { $false }

            { Update-SteamApp -AppID '237410' -InstallDirectory 'D:\Fake\Insurgency2014' } | Should -Throw

            Should -Invoke -ModuleName SteamCMD -CommandName Start-Process -Times 0
        }
    }
}
