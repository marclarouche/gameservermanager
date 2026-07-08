BeforeAll {
    Import-Module "$PSScriptRoot/../Core/NSSM.psm1" -Force

    function New-FakeGSMRoot {
        $root = Join-Path $TestDrive ('nssm-root-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $root 'Config') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root 'Tools') -Force | Out-Null
        return $root
    }

    # A fake nssm.exe payload plus the real SHA-256 of that exact content,
    # so tests can control whether Install-NSSM's verification passes or
    # fails without touching the real, pinned Config/NSSM.json.
    $script:FakeNssmContent = 'FAKE NSSM CONTENT FOR TESTING'
    $hashScratchFile = Join-Path $TestDrive 'nssm-hash-scratch.tmp'
    Set-Content -Path $hashScratchFile -Value $script:FakeNssmContent -NoNewline
    $script:FakeNssmHash = (Get-FileHash -Path $hashScratchFile -Algorithm SHA256).Hash
}

Describe 'Core/NSSM.psm1' {

    Context 'Test-NSSMPresent' {
        It 'returns $true when Tools/NSSM/nssm.exe exists' {
            $script:FakeRoot = New-FakeGSMRoot
            New-Item -ItemType Directory -Path (Join-Path $script:FakeRoot 'Tools/NSSM') -Force | Out-Null
            Set-Content -Path (Join-Path $script:FakeRoot 'Tools/NSSM/nssm.exe') -Value 'anything'
            Mock -ModuleName NSSM -CommandName Get-GSMRootPath -MockWith { $script:FakeRoot }

            Test-NSSMPresent | Should -Be $true
        }

        It 'returns $false when Tools/NSSM/nssm.exe does not exist' {
            $script:FakeRoot = New-FakeGSMRoot
            Mock -ModuleName NSSM -CommandName Get-GSMRootPath -MockWith { $script:FakeRoot }

            Test-NSSMPresent | Should -Be $false
        }
    }

    Context 'Install-NSSM' {
        BeforeEach {
            $script:FakeRoot = New-FakeGSMRoot
            Mock -ModuleName NSSM -CommandName Get-GSMRootPath -MockWith { $script:FakeRoot }
        }

        It 'is a no-op returning $true when NSSM is already present and -Force is not set' {
            New-Item -ItemType Directory -Path (Join-Path $script:FakeRoot 'Tools/NSSM') -Force | Out-Null
            Set-Content -Path (Join-Path $script:FakeRoot 'Tools/NSSM/nssm.exe') -Value 'already installed'
            Mock -ModuleName NSSM -CommandName Invoke-WebRequest -MockWith { }
            Mock -ModuleName NSSM -CommandName Expand-Archive -MockWith { }

            $result = Install-NSSM

            $result | Should -Be $true
            Should -Invoke -ModuleName NSSM -CommandName Invoke-WebRequest -Times 0
            Should -Invoke -ModuleName NSSM -CommandName Expand-Archive -Times 0
        }

        It 'downloads, extracts, verifies the win64 build, and installs only that file when the hash matches' {
            @{
                InstallerUrl = 'https://example.invalid/nssm.zip'
                PinnedFile   = 'win64/nssm.exe'
                PinnedSHA256 = $script:FakeNssmHash
            } | ConvertTo-Json | Set-Content -Path (Join-Path $script:FakeRoot 'Config/NSSM.json')

            Mock -ModuleName NSSM -CommandName Invoke-WebRequest -MockWith { }
            Mock -ModuleName NSSM -CommandName Expand-Archive -MockWith {
                param($Path, $DestinationPath, [switch]$Force)
                # $Path and $Force are unused in this fake body, but the
                # param block must mirror the real Expand-Archive cmdlet's
                # parameters for Pester's mock to bind call-site arguments
                # correctly - see the same pattern in SteamCMD.Tests.ps1.
                $null = $Path
                $null = $Force
                $versionFolder = Join-Path $DestinationPath 'nssm-2.24-101-g897c7ad'
                New-Item -ItemType Directory -Path (Join-Path $versionFolder 'win32') -Force | Out-Null
                New-Item -ItemType Directory -Path (Join-Path $versionFolder 'win64') -Force | Out-Null
                Set-Content -Path (Join-Path $versionFolder 'win32/nssm.exe') -Value '32-bit build, never pinned' -NoNewline
                Set-Content -Path (Join-Path $versionFolder 'win64/nssm.exe') -Value $script:FakeNssmContent -NoNewline
            }

            $result = Install-NSSM

            $result | Should -Be $true
            $installedPath = Join-Path $script:FakeRoot 'Tools/NSSM/nssm.exe'
            Test-Path -Path $installedPath | Should -Be $true
            (Get-Content -Path $installedPath -Raw) | Should -Be $script:FakeNssmContent
            Should -Invoke -ModuleName NSSM -CommandName Invoke-WebRequest -Times 1
            Should -Invoke -ModuleName NSSM -CommandName Expand-Archive -Times 1
        }

        It 'throws and installs nothing when the hash does not match' {
            @{
                InstallerUrl = 'https://example.invalid/nssm.zip'
                PinnedFile   = 'win64/nssm.exe'
                PinnedSHA256 = '0000000000000000000000000000000000000000000000000000000000000000'
            } | ConvertTo-Json | Set-Content -Path (Join-Path $script:FakeRoot 'Config/NSSM.json')

            Mock -ModuleName NSSM -CommandName Invoke-WebRequest -MockWith { }
            Mock -ModuleName NSSM -CommandName Expand-Archive -MockWith {
                param($Path, $DestinationPath, [switch]$Force)
                $null = $Path
                $null = $Force
                $versionFolder = Join-Path $DestinationPath 'nssm-2.24-101-g897c7ad'
                New-Item -ItemType Directory -Path (Join-Path $versionFolder 'win32') -Force | Out-Null
                New-Item -ItemType Directory -Path (Join-Path $versionFolder 'win64') -Force | Out-Null
                Set-Content -Path (Join-Path $versionFolder 'win32/nssm.exe') -Value '32-bit build, never pinned' -NoNewline
                Set-Content -Path (Join-Path $versionFolder 'win64/nssm.exe') -Value $script:FakeNssmContent -NoNewline
            }
            Mock -ModuleName NSSM -CommandName Write-GSMLog -MockWith { }

            { Install-NSSM } | Should -Throw '*hash*'

            Test-Path -Path (Join-Path $script:FakeRoot 'Tools/NSSM/nssm.exe') | Should -Be $false
            Should -Invoke -ModuleName NSSM -CommandName Write-GSMLog -Times 1 -ParameterFilter { $Level -eq 'Error' }
        }

        It 'throws when the pinned file is not found anywhere in the extracted archive' {
            @{
                InstallerUrl = 'https://example.invalid/nssm.zip'
                PinnedFile   = 'win64/nssm.exe'
                PinnedSHA256 = $script:FakeNssmHash
            } | ConvertTo-Json | Set-Content -Path (Join-Path $script:FakeRoot 'Config/NSSM.json')

            Mock -ModuleName NSSM -CommandName Invoke-WebRequest -MockWith { }
            Mock -ModuleName NSSM -CommandName Expand-Archive -MockWith {
                param($Path, $DestinationPath, [switch]$Force)
                $null = $Path
                $null = $Force
                New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
                # Deliberately empty extraction - no nssm.exe anywhere.
            }

            { Install-NSSM } | Should -Throw '*Could not find*'

            Test-Path -Path (Join-Path $script:FakeRoot 'Tools/NSSM/nssm.exe') | Should -Be $false
        }
    }
}
