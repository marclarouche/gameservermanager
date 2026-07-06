BeforeAll {
    Import-Module "$PSScriptRoot/../Core/ServiceAccount.psm1" -Force

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
            $knownPassword = 'Kx9!mZ2pQaR7vTn4hGs8LwEb'

            Mock -ModuleName ServiceAccount -CommandName Test-GSMElevation -MockWith { $true }
            Mock -ModuleName ServiceAccount -CommandName Get-LocalUser -MockWith { $null }
            Mock -ModuleName ServiceAccount -CommandName New-LocalUser -MockWith { throw 'simulated New-LocalUser failure' }
            Mock -ModuleName ServiceAccount -CommandName Write-GSMLog -MockWith { }

            InModuleScope ServiceAccount -Parameters @{ KnownPassword = $knownPassword } {
                param($KnownPassword)
                $mockScriptBlock = {
                    $secure = [securestring]::new()
                    foreach ($char in $KnownPassword.ToCharArray()) {
                        $secure.AppendChar($char)
                    }
                    $secure.MakeReadOnly()
                    return $secure
                }.GetNewClosure()
                Mock -CommandName New-GSMServiceAccountPassword -MockWith $mockScriptBlock
            }

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
            $errorMessage | Should -Not -Match ([regex]::Escape($knownPassword))
            Should -Invoke -ModuleName ServiceAccount -CommandName Write-GSMLog -Times 1
            Should -Invoke -ModuleName ServiceAccount -CommandName Write-GSMLog -Times 0 -ParameterFilter {
                $Message -match [regex]::Escape($knownPassword)
            }
        }
    }

    Context 'Test-GSMServiceAccount' {
        BeforeEach {
            Mock -ModuleName ServiceAccount -CommandName Test-GSMAccountPresence -MockWith { $true }
            Mock -ModuleName ServiceAccount -CommandName Test-GSMAccountIsAdminMember -MockWith { $false }
            Mock -ModuleName ServiceAccount -CommandName Test-GSMServiceLogonRight -MockWith { $true }
            Mock -ModuleName ServiceAccount -CommandName Test-GSMExpectedFolderPermission -MockWith { $true }
            Mock -ModuleName ServiceAccount -CommandName Write-GSMLog -MockWith { }
        }

        It 'returns $true when all four conditions are met' {
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
            Mock -ModuleName ServiceAccount -CommandName Test-GSMServiceLogonRight -MockWith { $false }

            Test-GSMServiceAccount -AccountName 'GSM-Test' | Should -Be $false
        }

        It 'returns $false when the expected folder ACLs are missing' {
            Mock -ModuleName ServiceAccount -CommandName Test-GSMExpectedFolderPermission -MockWith { $false }

            Test-GSMServiceAccount -AccountName 'GSM-Test' | Should -Be $false
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
