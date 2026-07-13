BeforeAll {
    . "$PSScriptRoot/../Build-GSMPackage.ps1"

    # PSScriptAnalyzer's PSUseShouldProcessForStateChangingFunctions flags the
    # "New-" verb here. Left as-is, matching Tests/ServiceAccount.Tests.ps1's
    # own fixture: this is a private test fixture (not part of the script or
    # exported), always called unconditionally within TestDrive, and never
    # invoked with -WhatIf/-Confirm expectations, so ShouldProcess support
    # would be boilerplate with no real safety benefit.
    function New-FakeGSMPackageSource {
        # Builds a minimal fake repo tree containing everything
        # Build-GSMPackage.ps1 requires, so tests exercise the real staging
        # logic against TestDrive rather than this repo's own files.
        param(
            [string]$Version = '1.0.0',
            [switch]$OmitVersion,
            [switch]$OmitNSSM
        )

        $root = Join-Path $TestDrive ('package-source-' + [guid]::NewGuid().ToString('N'))

        New-Item -ItemType Directory -Path (Join-Path $root 'Core') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root 'Plugins/Insurgency2014') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root 'Config') -Force | Out-Null

        Set-Content -Path (Join-Path $root 'GSM.ps1') -Value '# fake entry point'
        Set-Content -Path (Join-Path $root 'README.md') -Value '# fake readme'
        Set-Content -Path (Join-Path $root 'CHANGELOG.md') -Value '# fake changelog'
        Set-Content -Path (Join-Path $root 'LICENSE') -Value 'MIT'
        Set-Content -Path (Join-Path $root 'Core/Utilities.psm1') -Value '# fake module'
        Set-Content -Path (Join-Path $root 'Plugins/Insurgency2014/Plugin.json') -Value '{}'
        Set-Content -Path (Join-Path $root 'Config/SteamCMD.json') -Value '{}'
        Set-Content -Path (Join-Path $root 'Config/NSSM.json') -Value '{}'

        if (-not $OmitVersion) {
            Set-Content -Path (Join-Path $root 'VERSION') -Value $Version
        }

        if (-not $OmitNSSM) {
            New-Item -ItemType Directory -Path (Join-Path $root 'Tools/NSSM') -Force | Out-Null
            Set-Content -Path (Join-Path $root 'Tools/NSSM/nssm.exe') -Value 'fake binary'
        }

        return $root
    }
}

Describe 'Build-GSMPackage.ps1' {

    BeforeEach {
        Mock -CommandName Write-GSMLog -MockWith { }
        Mock -CommandName Write-Host -MockWith { }
    }

    Context 'Get-GSMPackageVersion' {
        It 'throws a clear error when VERSION is missing' {
            $fakeRoot = New-FakeGSMPackageSource -OmitVersion

            { Get-GSMPackageVersion -RootPath $fakeRoot } | Should -Throw '*VERSION file not found*'
        }

        It 'throws a clear error when VERSION is malformed' {
            $fakeRoot = New-FakeGSMPackageSource
            Set-Content -Path (Join-Path $fakeRoot 'VERSION') -Value 'not-a-version'

            { Get-GSMPackageVersion -RootPath $fakeRoot } | Should -Throw '*not a valid semantic version*'
        }

        It 'throws a clear error when VERSION is empty' {
            $fakeRoot = New-FakeGSMPackageSource
            Set-Content -Path (Join-Path $fakeRoot 'VERSION') -Value ''

            { Get-GSMPackageVersion -RootPath $fakeRoot } | Should -Throw '*not a valid semantic version*'
        }

        It 'returns a valid plain semantic version' {
            $fakeRoot = New-FakeGSMPackageSource -Version '1.2.3'

            Get-GSMPackageVersion -RootPath $fakeRoot | Should -Be '1.2.3'
        }

        It 'returns a valid pre-release semantic version, trimmed of surrounding whitespace' {
            $fakeRoot = New-FakeGSMPackageSource -Version "0.4.0-alpha`n"

            Get-GSMPackageVersion -RootPath $fakeRoot | Should -Be '0.4.0-alpha'
        }
    }

    Context 'Copy-GSMPackageItem' {
        It 'throws when a required file is missing' {
            $fakeRoot = New-FakeGSMPackageSource
            $staging = Join-Path $TestDrive ('staging-' + [guid]::NewGuid().ToString('N'))
            $manifest = [System.Collections.Generic.List[psobject]]::new()

            { Copy-GSMPackageItem -RootPath $fakeRoot -StagingPath $staging -RelativePath 'DoesNotExist.txt' -Manifest $manifest } | Should -Throw '*not found*'
        }

        It 'copies a required file and records it as a File in the manifest' {
            $fakeRoot = New-FakeGSMPackageSource
            $staging = Join-Path $TestDrive ('staging-' + [guid]::NewGuid().ToString('N'))
            $manifest = [System.Collections.Generic.List[psobject]]::new()

            Copy-GSMPackageItem -RootPath $fakeRoot -StagingPath $staging -RelativePath 'GSM.ps1' -Manifest $manifest

            Test-Path -Path (Join-Path $staging 'GSM.ps1') | Should -Be $true
            $manifest.Count | Should -Be 1
            $manifest[0].Item | Should -Be 'GSM.ps1'
            $manifest[0].Type | Should -Be 'File'
        }

        It 'copies a required folder recursively and records it as a Folder in the manifest' {
            $fakeRoot = New-FakeGSMPackageSource
            $staging = Join-Path $TestDrive ('staging-' + [guid]::NewGuid().ToString('N'))
            $manifest = [System.Collections.Generic.List[psobject]]::new()

            Copy-GSMPackageItem -RootPath $fakeRoot -StagingPath $staging -RelativePath 'Plugins' -Manifest $manifest

            Test-Path -Path (Join-Path $staging 'Plugins/Insurgency2014/Plugin.json') | Should -Be $true
            $manifest[0].Item | Should -Be 'Plugins'
            $manifest[0].Type | Should -Be 'Folder'
        }
    }

    Context 'Copy-GSMOptionalPackageFolder' {
        It 'copies Tools/NSSM when present' {
            $fakeRoot = New-FakeGSMPackageSource
            $staging = Join-Path $TestDrive ('staging-' + [guid]::NewGuid().ToString('N'))
            $manifest = [System.Collections.Generic.List[psobject]]::new()

            Copy-GSMOptionalPackageFolder -RootPath $fakeRoot -StagingPath $staging -RelativePath 'Tools/NSSM' -Manifest $manifest

            Test-Path -Path (Join-Path $staging 'Tools/NSSM/nssm.exe') | Should -Be $true
            $manifest[0].Type | Should -Be 'Folder'
        }

        It 'does not throw and records a skip when Tools/NSSM is absent' {
            $fakeRoot = New-FakeGSMPackageSource -OmitNSSM
            $staging = Join-Path $TestDrive ('staging-' + [guid]::NewGuid().ToString('N'))
            $manifest = [System.Collections.Generic.List[psobject]]::new()

            { Copy-GSMOptionalPackageFolder -RootPath $fakeRoot -StagingPath $staging -RelativePath 'Tools/NSSM' -Manifest $manifest } | Should -Not -Throw

            Test-Path -Path (Join-Path $staging 'Tools/NSSM') | Should -Be $false
            $manifest[0].Type | Should -Be 'Folder (skipped)'
        }
    }

    Context 'New-GSMPackagePlaceholderFolder' {
        It 'creates an empty folder containing only a .gitkeep placeholder' {
            $staging = Join-Path $TestDrive ('staging-' + [guid]::NewGuid().ToString('N'))
            $manifest = [System.Collections.Generic.List[psobject]]::new()

            New-GSMPackagePlaceholderFolder -StagingPath $staging -RelativePath 'Logs' -Manifest $manifest

            $items = @(Get-ChildItem -Path (Join-Path $staging 'Logs') -Force)
            $items.Count | Should -Be 1
            $items[0].Name | Should -Be '.gitkeep'
            $manifest[0].Type | Should -Be 'Folder (empty)'
        }
    }

    Context 'Invoke-GSMPackageBuild' {
        It 'stages the expected includes, excludes Tests/Docs/.git/.claude, and calls Compress-Archive to the versioned Build/ path' {
            $fakeRoot = New-FakeGSMPackageSource -Version '2.0.0'
            New-Item -ItemType Directory -Path (Join-Path $fakeRoot 'Tests') -Force | Out-Null
            Set-Content -Path (Join-Path $fakeRoot 'Tests/Fake.Tests.ps1') -Value '# should never be staged'
            New-Item -ItemType Directory -Path (Join-Path $fakeRoot 'Docs') -Force | Out-Null
            Set-Content -Path (Join-Path $fakeRoot 'Docs/PRD.md') -Value '# should never be staged'

            Mock -CommandName Get-GSMRootPath -MockWith { $fakeRoot }

            # Assertions run *inside* the Compress-Archive mock, not after
            # Invoke-GSMPackageBuild returns: its own finally block deletes
            # the staging directory right after Compress-Archive is called
            # (mocked or not), so checking Test-Path afterward would always
            # see a directory that's already gone. $script: (not a local
            # var) because the mock scriptblock's own assignments aren't
            # visible to this It block's scope otherwise.
            $script:capturedZipPath = $null
            $script:stagedPathChecks = $null
            Mock -CommandName Compress-Archive -MockWith {
                param($Path, $DestinationPath)
                $stagingPath = Split-Path -Path $Path -Parent
                $script:capturedZipPath = $DestinationPath

                $script:stagedPathChecks = [ordered]@{
                    'GSM.ps1'                              = Test-Path -Path (Join-Path $stagingPath 'GSM.ps1')
                    'Core/Utilities.psm1'                   = Test-Path -Path (Join-Path $stagingPath 'Core/Utilities.psm1')
                    'Plugins/Insurgency2014/Plugin.json'    = Test-Path -Path (Join-Path $stagingPath 'Plugins/Insurgency2014/Plugin.json')
                    'Config/SteamCMD.json'                  = Test-Path -Path (Join-Path $stagingPath 'Config/SteamCMD.json')
                    'Config/NSSM.json'                      = Test-Path -Path (Join-Path $stagingPath 'Config/NSSM.json')
                    'Logs/.gitkeep'                          = Test-Path -Path (Join-Path $stagingPath 'Logs/.gitkeep')
                    'Reports/.gitkeep'                       = Test-Path -Path (Join-Path $stagingPath 'Reports/.gitkeep')
                    'Backups/.gitkeep'                       = Test-Path -Path (Join-Path $stagingPath 'Backups/.gitkeep')
                    'SteamCMD/.gitkeep'                      = Test-Path -Path (Join-Path $stagingPath 'SteamCMD/.gitkeep')
                    'Tests (excluded)'                       = -not (Test-Path -Path (Join-Path $stagingPath 'Tests'))
                    'Docs (excluded)'                        = -not (Test-Path -Path (Join-Path $stagingPath 'Docs'))
                    '.git (excluded)'                        = -not (Test-Path -Path (Join-Path $stagingPath '.git'))
                    '.claude (excluded)'                     = -not (Test-Path -Path (Join-Path $stagingPath '.claude'))
                }

                New-Item -ItemType File -Path $DestinationPath -Force | Out-Null
            }

            Invoke-GSMPackageBuild

            $script:capturedZipPath | Should -Be (Join-Path $fakeRoot 'Build/GameServerManager-v2.0.0.zip')

            foreach ($check in $script:stagedPathChecks.GetEnumerator()) {
                $check.Value | Should -Be $true -Because "'$($check.Key)' should be true"
            }

            Should -Invoke -CommandName Compress-Archive -Times 1
        }

        It 'prints a manifest and the package path via Write-Host after a successful build' {
            $fakeRoot = New-FakeGSMPackageSource -Version '2.0.0'
            Mock -CommandName Get-GSMRootPath -MockWith { $fakeRoot }
            Mock -CommandName Compress-Archive -MockWith {
                param($DestinationPath)
                New-Item -ItemType File -Path $DestinationPath -Force | Out-Null
            }

            Invoke-GSMPackageBuild

            Should -Invoke -CommandName Write-Host -ParameterFilter { $Object -match 'GSM package manifest' }
            Should -Invoke -CommandName Write-Host -ParameterFilter { $Object -match 'Package:.*GameServerManager-v2\.0\.0\.zip' }
        }

        It 'throws before staging anything when VERSION is missing' {
            $fakeRoot = New-FakeGSMPackageSource -OmitVersion
            Mock -CommandName Get-GSMRootPath -MockWith { $fakeRoot }
            Mock -CommandName Compress-Archive -MockWith { }

            { Invoke-GSMPackageBuild } | Should -Throw '*VERSION file not found*'

            Should -Invoke -CommandName Compress-Archive -Times 0
        }

        It 'always cleans up the temporary staging directory, even after a failure' {
            $fakeRoot = New-FakeGSMPackageSource -Version '2.0.0'
            Mock -CommandName Get-GSMRootPath -MockWith { $fakeRoot }
            Mock -CommandName Compress-Archive -MockWith { throw 'simulated zip failure' }

            $tempPathBefore = @(Get-ChildItem -Path ([System.IO.Path]::GetTempPath()) -Filter 'gsm-package-staging-*' -Directory -ErrorAction SilentlyContinue)

            { Invoke-GSMPackageBuild } | Should -Throw '*Failed to create package archive*'

            $tempPathAfter = @(Get-ChildItem -Path ([System.IO.Path]::GetTempPath()) -Filter 'gsm-package-staging-*' -Directory -ErrorAction SilentlyContinue)
            $tempPathAfter.Count | Should -Be $tempPathBefore.Count
        }
    }
}
