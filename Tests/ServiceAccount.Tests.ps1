BeforeAll {
    Import-Module "$PSScriptRoot/../Core/ServiceAccount.psm1" -Force

    # PSScriptAnalyzer's PSUseShouldProcessForStateChangingFunctions flags the
    # "New-" verb here. Left as-is: this is a private test fixture (not part of
    # the module or exported), always called unconditionally within TestDrive,
    # and never invoked with -WhatIf/-Confirm expectations, so ShouldProcess
    # support would be boilerplate with no real safety benefit.
    function New-FakeGSMRoot {
        $root = Join-Path $TestDrive ('serviceaccount-root-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $root 'Config') -Force | Out-Null
        return $root
    }

    # Safe, module-wide defaults so every test starts from a known state
    # ("account doesn't exist yet, not an admin member") without creating,
    # querying, or removing any real local account.
    Mock -ModuleName ServiceAccount -CommandName Get-LocalUser -MockWith { $null }
    Mock -ModuleName ServiceAccount -CommandName New-LocalUser -MockWith { }
    Mock -ModuleName ServiceAccount -CommandName Set-LocalUser -MockWith { }
    Mock -ModuleName ServiceAccount -CommandName Remove-LocalUser -MockWith { }
    Mock -ModuleName ServiceAccount -CommandName Get-LocalGroupMember -MockWith { @() }
}

Describe 'Core/ServiceAccount.psm1' {

    Context 'New-GSMServiceAccount - elevation' {
        It 'throws a clear error naming the requirement when not elevated' {
            Mock -ModuleName ServiceAccount -CommandName Test-GSMElevation -MockWith { $false }

            { New-GSMServiceAccount -AccountName 'GSM-Test' } | Should -Throw '*elevat*'
        }

        It 'proceeds to create the account when elevated' {
            $script:FakeRoot = New-FakeGSMRoot
            Mock -ModuleName ServiceAccount -CommandName Test-GSMElevation -MockWith { $true }
            Mock -ModuleName ServiceAccount -CommandName Get-GSMRootPath -MockWith { $script:FakeRoot }

            $result = New-GSMServiceAccount -AccountName 'GSM-Test'

            $result | Should -Be $true
            Should -Invoke -ModuleName ServiceAccount -CommandName New-LocalUser -Times 1
            Test-Path -Path (Join-Path $script:FakeRoot 'Config/ServiceAccount.secure.txt') | Should -Be $true
        }
    }

    Context 'New-GSMServiceAccount - existing account' {
        BeforeEach {
            Mock -ModuleName ServiceAccount -CommandName Test-GSMElevation -MockWith { $true }
        }

        It 'is a no-op returning $true when the account already exists and -Force is not set' {
            Mock -ModuleName ServiceAccount -CommandName Get-LocalUser -MockWith { [PSCustomObject]@{ Name = 'GSM-Test' } }

            $result = New-GSMServiceAccount -AccountName 'GSM-Test'

            $result | Should -Be $true
            Should -Invoke -ModuleName ServiceAccount -CommandName New-LocalUser -Times 0
            Should -Invoke -ModuleName ServiceAccount -CommandName Set-LocalUser -Times 0
        }

        It 'rotates the password via Set-LocalUser and overwrites the encrypted file when -Force is set' {
            $script:FakeRoot = New-FakeGSMRoot
            Mock -ModuleName ServiceAccount -CommandName Get-LocalUser -MockWith { [PSCustomObject]@{ Name = 'GSM-Test' } }
            Mock -ModuleName ServiceAccount -CommandName Get-GSMRootPath -MockWith { $script:FakeRoot }

            $secureFilePath = Join-Path $script:FakeRoot 'Config/ServiceAccount.secure.txt'
            Set-Content -Path $secureFilePath -Value 'old-encrypted-placeholder'

            $result = New-GSMServiceAccount -AccountName 'GSM-Test' -Force

            $result | Should -Be $true
            Should -Invoke -ModuleName ServiceAccount -CommandName Set-LocalUser -Times 1
            Should -Invoke -ModuleName ServiceAccount -CommandName New-LocalUser -Times 0
            (Get-Content -Path $secureFilePath -Raw) | Should -Not -Match 'old-encrypted-placeholder'
        }
    }

    Context 'New-GSMServiceAccountPassword (private helper, via InModuleScope)' {
        It 'generates passwords meeting length and character-mix requirements across multiple generations' {
            InModuleScope ServiceAccount {
                1..25 | ForEach-Object {
                    $securePassword = New-GSMServiceAccountPassword
                    $securePassword | Should -BeOfType [securestring]

                    # Only converted back to plaintext here, inside the test,
                    # to verify the generator's internal correctness.
                    $plainPassword = $securePassword | ConvertFrom-SecureString -AsPlainText

                    $plainPassword.Length | Should -BeGreaterOrEqual 24
                    $plainPassword | Should -Match '[A-Z]'
                    $plainPassword | Should -Match '[a-z]'
                    $plainPassword | Should -Match '[0-9]'
                    $plainPassword | Should -Match '[!@#%\^&\*\-_=\+]'
                }
            }
        }

        It 'throws when asked for a length below the 24-character minimum' {
            InModuleScope ServiceAccount {
                { New-GSMServiceAccountPassword -Length 10 } | Should -Throw
            }
        }
    }

    Context 'Password never leaks' {
        It 'never includes the plaintext password in a Write-GSMLog call or the thrown error message' {
            # A fixed, throwaway test constant (not a real credential) used only to
            # confirm it never surfaces in a log message or exception. Built directly
            # as a SecureString below so no plain-text parameter is ever declared.
            $testSecretValue = 'Kx9!mZ2pQaR7vTn4hGs8LwEb'

            $secureTestSecretValue = [securestring]::new()
            foreach ($char in $testSecretValue.ToCharArray()) {
                $secureTestSecretValue.AppendChar($char)
            }
            $secureTestSecretValue.MakeReadOnly()

            Mock -ModuleName ServiceAccount -CommandName Test-GSMElevation -MockWith { $true }
            Mock -ModuleName ServiceAccount -CommandName Get-LocalUser -MockWith { $null }
            Mock -ModuleName ServiceAccount -CommandName New-LocalUser -MockWith { throw 'simulated New-LocalUser failure' }
            Mock -ModuleName ServiceAccount -CommandName Write-GSMLog -MockWith { }

            $passwordMockScriptBlock = { $secureTestSecretValue }.GetNewClosure()
            Mock -ModuleName ServiceAccount -CommandName New-GSMServiceAccountPassword -MockWith $passwordMockScriptBlock

            $threw = $false
            $errorMessage = $null
            try {
                New-GSMServiceAccount -AccountName 'GSM-Test'
            }
            catch {
                $threw = $true
                $errorMessage = $_.Exception.Message
            }

            $threw | Should -Be $true
            $errorMessage | Should -Not -Match ([regex]::Escape($testSecretValue))
            Should -Invoke -ModuleName ServiceAccount -CommandName Write-GSMLog -Times 1
            Should -Invoke -ModuleName ServiceAccount -CommandName Write-GSMLog -Times 0 -ParameterFilter {
                $Message -match [regex]::Escape($testSecretValue)
            }
        }
    }

    Context 'Get-GSMServiceAccountCredential' {
        BeforeEach {
            # Built via AppendChar rather than ConvertTo-SecureString -AsPlainText,
            # matching the 'Password never leaks' context above: PSScriptAnalyzer's
            # PSAvoidUsingConvertToSecureStringWithPlainText rule flags that cmdlet
            # unconditionally, even in test-only fixture code.
            #
            # PSUseShouldProcessForStateChangingFunctions flags the "New-" verb
            # here too. Left as-is for the same reason as New-FakeGSMRoot above:
            # a private test fixture, not part of the module, always called
            # unconditionally within TestDrive.
            function New-TestSecureStringFor([string]$PlainText) {
                $secure = [securestring]::new()
                foreach ($char in $PlainText.ToCharArray()) {
                    $secure.AppendChar($char)
                }
                $secure.MakeReadOnly()
                return $secure
            }
        }

        It 'builds a PSCredential from the stored encrypted password' {
            $fakeRoot = New-FakeGSMRoot
            Mock -ModuleName ServiceAccount -CommandName Get-GSMRootPath -MockWith { $fakeRoot }

            $securePassword = New-TestSecureStringFor 'Sup3rSecretPassphrase!'
            $encrypted = $securePassword | ConvertFrom-SecureString
            Set-Content -Path (Join-Path $fakeRoot 'Config/ServiceAccount.secure.txt') -Value $encrypted

            $credential = Get-GSMServiceAccountCredential -AccountName 'GSM-Test'

            $credential | Should -BeOfType [pscredential]
            $credential.UserName | Should -Be 'GSM-Test'
            $credential.GetNetworkCredential().Password | Should -Be 'Sup3rSecretPassphrase!'
        }

        It 'defaults AccountName to GSM-ServiceAccount' {
            $fakeRoot = New-FakeGSMRoot
            Mock -ModuleName ServiceAccount -CommandName Get-GSMRootPath -MockWith { $fakeRoot }

            $securePassword = New-TestSecureStringFor 'AnotherSecretPassphrase!'
            $encrypted = $securePassword | ConvertFrom-SecureString
            Set-Content -Path (Join-Path $fakeRoot 'Config/ServiceAccount.secure.txt') -Value $encrypted

            $credential = Get-GSMServiceAccountCredential

            $credential.UserName | Should -Be 'GSM-ServiceAccount'
        }

        It 'throws a clear, actionable error when no stored credential file exists' {
            $fakeRoot = New-FakeGSMRoot
            Mock -ModuleName ServiceAccount -CommandName Get-GSMRootPath -MockWith { $fakeRoot }

            { Get-GSMServiceAccountCredential -AccountName 'GSM-Test' } | Should -Throw '*New-GSMServiceAccount*'
        }
    }

    Context 'Test-GSMServiceAccount' {
        BeforeEach {
            Mock -ModuleName ServiceAccount -CommandName Test-GSMAccountPresence -MockWith { $true }
            Mock -ModuleName ServiceAccount -CommandName Test-GSMAccountIsAdminMember -MockWith { $false }
            Mock -ModuleName ServiceAccount -CommandName Test-GSMUserRight -MockWith { $true }
            Mock -ModuleName ServiceAccount -CommandName Test-GSMExpectedFolderPermission -MockWith { $true }
            Mock -ModuleName ServiceAccount -CommandName Write-GSMLog -MockWith { }
        }

        It 'returns $true when all five conditions are met' {
            Test-GSMServiceAccount -AccountName 'GSM-Test' | Should -Be $true
        }

        It 'returns $false when the account does not exist' {
            Mock -ModuleName ServiceAccount -CommandName Test-GSMAccountPresence -MockWith { $false }

            Test-GSMServiceAccount -AccountName 'GSM-Test' | Should -Be $false
        }

        It 'returns $false when the account is a member of Administrators' {
            Mock -ModuleName ServiceAccount -CommandName Test-GSMAccountIsAdminMember -MockWith { $true }

            Test-GSMServiceAccount -AccountName 'GSM-Test' | Should -Be $false
        }

        It 'returns $false when SeServiceLogonRight is missing' {
            Mock -ModuleName ServiceAccount -CommandName Test-GSMUserRight -ParameterFilter { $RightName -eq 'SeServiceLogonRight' } -MockWith { $false }

            Test-GSMServiceAccount -AccountName 'GSM-Test' | Should -Be $false
        }

        It 'returns $false when SeBatchLogonRight is missing' {
            Mock -ModuleName ServiceAccount -CommandName Test-GSMUserRight -ParameterFilter { $RightName -eq 'SeBatchLogonRight' } -MockWith { $false }

            Test-GSMServiceAccount -AccountName 'GSM-Test' | Should -Be $false
        }

        It 'returns $false when the expected folder ACLs are missing' {
            Mock -ModuleName ServiceAccount -CommandName Test-GSMExpectedFolderPermission -MockWith { $false }

            Test-GSMServiceAccount -AccountName 'GSM-Test' | Should -Be $false
        }
    }

    Context 'Set-GSMServiceAccountRights' {
        BeforeEach {
            $script:FakeRoot = New-FakeGSMRoot
            $script:FakeSid = 'S-1-5-21-1111111111-2222222222-3333333333-1001'
            $script:CapturedCfgContent = $null

            Mock -ModuleName ServiceAccount -CommandName Get-GSMRootPath -MockWith { $script:FakeRoot }
            Mock -ModuleName ServiceAccount -CommandName Get-GSMAccountSID -MockWith { $script:FakeSid }
            Mock -ModuleName ServiceAccount -CommandName Write-GSMLog -MockWith { }

            Mock -ModuleName ServiceAccount -CommandName Start-Process -MockWith {
                [PSCustomObject]@{ ExitCode = 0 }
            }
            Mock -ModuleName ServiceAccount -CommandName Get-Content -MockWith {
                @('[Version]', '[Privilege Rights]')
            }
            Mock -ModuleName ServiceAccount -CommandName Set-Content -MockWith {
                param($Value)
                $script:CapturedCfgContent = $Value -join "`n"
            }

            Mock -ModuleName ServiceAccount -CommandName Get-Acl -MockWith {
                [PSCustomObject]@{ AddedRules = [System.Collections.Generic.List[object]]::new() } |
                    Add-Member -MemberType ScriptMethod -Name AddAccessRule -Value {
                        param($rule)
                        $this.AddedRules.Add($rule)
                    } -PassThru
            }
            Mock -ModuleName ServiceAccount -CommandName Set-Acl -MockWith { }
        }

        It 'exports and re-imports user rights via a single secedit round-trip, granting SeServiceLogonRight and SeBatchLogonRight to the account SID' {
            Set-GSMServiceAccountRights -AccountName 'GSM-Test'

            Should -Invoke -ModuleName ServiceAccount -CommandName Start-Process -Times 1 -ParameterFilter {
                $FilePath -eq 'secedit.exe' -and
                $ArgumentList[0] -eq '/export' -and
                $ArgumentList[1] -eq '/cfg' -and
                $ArgumentList[2] -like '*secedit-export.inf' -and
                $ArgumentList[3] -eq '/areas' -and
                $ArgumentList[4] -eq 'USER_RIGHTS'
            }

            Should -Invoke -ModuleName ServiceAccount -CommandName Start-Process -Times 1 -ParameterFilter {
                $FilePath -eq 'secedit.exe' -and
                $ArgumentList[0] -eq '/configure' -and
                $ArgumentList[1] -eq '/db' -and
                $ArgumentList[2] -like '*secedit.sdb' -and
                $ArgumentList[3] -eq '/cfg' -and
                $ArgumentList[4] -like '*secedit-export.inf' -and
                $ArgumentList[5] -eq '/areas' -and
                $ArgumentList[6] -eq 'USER_RIGHTS'
            }

            # Both rights are granted in the SAME secedit round-trip: still
            # just one export call and one configure call, not two of each.
            Should -Invoke -ModuleName ServiceAccount -CommandName Start-Process -Times 2

            $script:CapturedCfgContent | Should -Match 'SeServiceLogonRight'
            $script:CapturedCfgContent | Should -Match 'SeBatchLogonRight'
            ($script:CapturedCfgContent -split "`n" | Where-Object { $_ -match '^SeServiceLogonRight' }) | Should -Match ([regex]::Escape("*$script:FakeSid"))
            ($script:CapturedCfgContent -split "`n" | Where-Object { $_ -match '^SeBatchLogonRight' }) | Should -Match ([regex]::Escape("*$script:FakeSid"))
        }

        It 'preserves an existing right''s other SIDs and appends the account rather than replacing the line' {
            Mock -ModuleName ServiceAccount -CommandName Get-Content -MockWith {
                @('[Version]', '[Privilege Rights]', 'SeServiceLogonRight = *S-1-5-80-1234567890')
            }

            Set-GSMServiceAccountRights -AccountName 'GSM-Test'

            $serviceLogonLine = ($script:CapturedCfgContent -split "`n" | Where-Object { $_ -match '^SeServiceLogonRight' })
            $serviceLogonLine | Should -Match ([regex]::Escape('*S-1-5-80-1234567890'))
            $serviceLogonLine | Should -Match ([regex]::Escape("*$script:FakeSid"))
        }

        It 'grants Modify (not FullControl) via Set-Acl on exactly the six expected folders' {
            $script:CapturedSetAclCalls = [System.Collections.Generic.List[object]]::new()
            Mock -ModuleName ServiceAccount -CommandName Set-Acl -MockWith {
                param($Path, $AclObject)
                $script:CapturedSetAclCalls.Add([PSCustomObject]@{ Path = $Path; AclObject = $AclObject })
            }

            Set-GSMServiceAccountRights -AccountName 'GSM-Test'

            Should -Invoke -ModuleName ServiceAccount -CommandName Get-Acl -Times 6
            $script:CapturedSetAclCalls.Count | Should -Be 6

            foreach ($folder in 'Config', 'Logs', 'Reports', 'Backups', 'SteamCMD', 'Servers') {
                $expectedPath = Join-Path $script:FakeRoot $folder
                $call = $script:CapturedSetAclCalls | Where-Object { $_.Path -eq $expectedPath }

                $call | Should -Not -BeNullOrEmpty -Because "Set-Acl should be called for '$folder' ($expectedPath)"
                $call.AclObject.AddedRules.Count | Should -Be 1 -Because "folder '$folder'"
                $call.AclObject.AddedRules[0].IdentityReference.Value | Should -Be 'GSM-Test' -Because "folder '$folder'"

                # .NET's AccessRule constructor ORs in Synchronize for Allow-type
                # rules, so the resulting FileSystemRights is 'Modify, Synchronize',
                # not a bare 'Modify'. Check for the Modify bit the same way
                # Test-GSMExpectedFolderPermission (Core/ServiceAccount.psm1) does,
                # rather than an exact equality match.
                $grantedRights = $call.AclObject.AddedRules[0].FileSystemRights
                ($grantedRights -band [System.Security.AccessControl.FileSystemRights]::Modify) |
                    Should -Be ([System.Security.AccessControl.FileSystemRights]::Modify) -Because "folder '$folder' should have Modify"

                # FullControl-only bits must not be present, i.e. this is Modify, not FullControl.
                ($grantedRights -band [System.Security.AccessControl.FileSystemRights]::TakeOwnership) |
                    Should -Be 0 -Because "folder '$folder' should not get TakeOwnership"
                ($grantedRights -band [System.Security.AccessControl.FileSystemRights]::ChangePermissions) |
                    Should -Be 0 -Because "folder '$folder' should not get ChangePermissions"

                $call.AclObject.AddedRules[0].AccessControlType | Should -Be ([System.Security.AccessControl.AccessControlType]::Allow) -Because "folder '$folder'"
            }

            # No folders outside the configured six.
            $expectedPaths = 'Config', 'Logs', 'Reports', 'Backups', 'SteamCMD', 'Servers' | ForEach-Object { Join-Path $script:FakeRoot $_ }
            $script:CapturedSetAclCalls | Where-Object { $_.Path -notin $expectedPaths } | Should -BeNullOrEmpty
        }

        It 'throws and logs without touching any ACL when the secedit export fails' {
            Mock -ModuleName ServiceAccount -CommandName Start-Process -ParameterFilter { $ArgumentList[0] -eq '/export' } -MockWith {
                [PSCustomObject]@{ ExitCode = 1 }
            }

            { Set-GSMServiceAccountRights -AccountName 'GSM-Test' } | Should -Throw '*export*exited with code 1*'

            Should -Invoke -ModuleName ServiceAccount -CommandName Write-GSMLog -Times 1 -ParameterFilter { $Level -eq 'Error' }
            Should -Invoke -ModuleName ServiceAccount -CommandName Get-Acl -Times 0
            Should -Invoke -ModuleName ServiceAccount -CommandName Set-Acl -Times 0
        }

        It 'throws and logs without touching any ACL when the secedit import/configure step fails' {
            Mock -ModuleName ServiceAccount -CommandName Start-Process -ParameterFilter { $ArgumentList[0] -eq '/configure' } -MockWith {
                [PSCustomObject]@{ ExitCode = 3 }
            }

            { Set-GSMServiceAccountRights -AccountName 'GSM-Test' } | Should -Throw '*SeServiceLogonRight*SeBatchLogonRight*'

            Should -Invoke -ModuleName ServiceAccount -CommandName Write-GSMLog -Times 1 -ParameterFilter { $Level -eq 'Error' }
            Should -Invoke -ModuleName ServiceAccount -CommandName Get-Acl -Times 0
            Should -Invoke -ModuleName ServiceAccount -CommandName Set-Acl -Times 0
        }

        It 'throws, logs, and stops granting further folders when Set-Acl fails partway through' {
            Mock -ModuleName ServiceAccount -CommandName Set-Acl -ParameterFilter {
                $Path -eq (Join-Path $script:FakeRoot 'Logs')
            } -MockWith {
                throw 'Access to the path is denied.'
            }

            { Set-GSMServiceAccountRights -AccountName 'GSM-Test' } | Should -Throw

            Should -Invoke -ModuleName ServiceAccount -CommandName Write-GSMLog -Times 1 -ParameterFilter {
                $Level -eq 'Error' -and $Message -match 'Logs'
            }

            # Config (first folder) succeeded, Logs (second) failed and threw: Reports,
            # Backups, SteamCMD, and Servers must never be reached.
            Should -Invoke -ModuleName ServiceAccount -CommandName Set-Acl -Times 2
            foreach ($untouchedFolder in 'Reports', 'Backups', 'SteamCMD', 'Servers') {
                Should -Invoke -ModuleName ServiceAccount -CommandName Set-Acl -Times 0 -ParameterFilter {
                    $Path -eq (Join-Path $script:FakeRoot $untouchedFolder)
                }
            }
        }
    }

    Context 'Remove-GSMServiceAccount' {
        It 'removes the account via Remove-LocalUser' {
            Remove-GSMServiceAccount -AccountName 'GSM-Test'

            Should -Invoke -ModuleName ServiceAccount -CommandName Remove-LocalUser -Times 1
        }

        It 'logs and rethrows when Remove-LocalUser fails' {
            Mock -ModuleName ServiceAccount -CommandName Remove-LocalUser -MockWith { throw 'simulated failure' }
            Mock -ModuleName ServiceAccount -CommandName Write-GSMLog -MockWith { }

            { Remove-GSMServiceAccount -AccountName 'GSM-Test' } | Should -Throw

            Should -Invoke -ModuleName ServiceAccount -CommandName Write-GSMLog -Times 1 -ParameterFilter { $Level -eq 'Error' }
        }
    }
}
