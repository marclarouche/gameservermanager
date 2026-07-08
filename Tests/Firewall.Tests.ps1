BeforeAll {
    Import-Module "$PSScriptRoot/../Core/Firewall.psm1" -Force

    function New-FakeGSMRootForFirewall {
        param(
            [string]$FolderName = 'FakeGame',
            [int]$DefaultPort = 27015,
            [string]$Protocol
        )

        $root = Join-Path $TestDrive ('firewall-root-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $root "Plugins/$FolderName") -Force | Out-Null

        $pluginJson = [ordered]@{
            GameName         = 'FakeGame'
            Version          = '1'
            AppID            = '1'
            Engine           = 'Source'
            Executable       = 'srcds.exe'
            DefaultPort      = $DefaultPort
            SupportsWorkshop = $false
            SupportsRCON     = $true
        }
        if ($Protocol) {
            $pluginJson['Protocol'] = $Protocol
        }
        $pluginJson | ConvertTo-Json | Set-Content -Path (Join-Path $root "Plugins/$FolderName/Plugin.json")

        return $root
    }
}

Describe 'Core/Firewall.psm1' {

    BeforeEach {
        Mock -ModuleName Firewall -CommandName Write-GSMLog -MockWith { }
    }

    Context 'Add-GSMFirewallRule' {
        It 'throws a clear error when Plugin.json does not exist' {
            $fakeRoot = Join-Path $TestDrive ('firewall-root-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $fakeRoot -Force | Out-Null
            Mock -ModuleName Firewall -CommandName Get-GSMRootPath -MockWith { $fakeRoot }

            { Add-GSMFirewallRule -FolderName 'NoSuchPlugin' } | Should -Throw '*Plugin.json*'
        }

        It 'creates both a TCP and a UDP rule when Plugin.json has no Protocol field' {
            $fakeRoot = New-FakeGSMRootForFirewall -FolderName 'FakeGame' -DefaultPort 27015
            Mock -ModuleName Firewall -CommandName Get-GSMRootPath -MockWith { $fakeRoot }
            Mock -ModuleName Firewall -CommandName Get-NetFirewallRule -MockWith { $null }
            Mock -ModuleName Firewall -CommandName New-NetFirewallRule -MockWith { }

            $result = Add-GSMFirewallRule -FolderName 'FakeGame'

            $result | Should -Contain 'GSM-FakeGame-27015-TCP'
            $result | Should -Contain 'GSM-FakeGame-27015-UDP'
            Should -Invoke -ModuleName Firewall -CommandName New-NetFirewallRule -Times 1 -ParameterFilter {
                $Name -eq 'GSM-FakeGame-27015-TCP' -and $Protocol -eq 'TCP' -and $LocalPort -eq 27015 -and $Direction -eq 'Inbound' -and $Action -eq 'Allow'
            }
            Should -Invoke -ModuleName Firewall -CommandName New-NetFirewallRule -Times 1 -ParameterFilter {
                $Name -eq 'GSM-FakeGame-27015-UDP' -and $Protocol -eq 'UDP'
            }
        }

        It 'creates only one rule when Plugin.json restricts Protocol to a single value' {
            $fakeRoot = New-FakeGSMRootForFirewall -FolderName 'FakeGame' -DefaultPort 27015 -Protocol 'TCP'
            Mock -ModuleName Firewall -CommandName Get-GSMRootPath -MockWith { $fakeRoot }
            Mock -ModuleName Firewall -CommandName Get-NetFirewallRule -MockWith { $null }
            Mock -ModuleName Firewall -CommandName New-NetFirewallRule -MockWith { }

            $result = Add-GSMFirewallRule -FolderName 'FakeGame'

            $result | Should -Be @('GSM-FakeGame-27015-TCP')
            Should -Invoke -ModuleName Firewall -CommandName New-NetFirewallRule -Times 1
        }

        It 'throws when Plugin.json has an invalid Protocol value' {
            $fakeRoot = New-FakeGSMRootForFirewall -FolderName 'FakeGame' -Protocol 'IPX'
            Mock -ModuleName Firewall -CommandName Get-GSMRootPath -MockWith { $fakeRoot }

            { Add-GSMFirewallRule -FolderName 'FakeGame' } | Should -Throw '*Protocol*'
        }

        It 'uses the -Port override instead of Plugin.json DefaultPort when supplied' {
            $fakeRoot = New-FakeGSMRootForFirewall -FolderName 'FakeGame' -DefaultPort 27015 -Protocol 'TCP'
            Mock -ModuleName Firewall -CommandName Get-GSMRootPath -MockWith { $fakeRoot }
            Mock -ModuleName Firewall -CommandName Get-NetFirewallRule -MockWith { $null }
            Mock -ModuleName Firewall -CommandName New-NetFirewallRule -MockWith { }

            $result = Add-GSMFirewallRule -FolderName 'FakeGame' -Port 28016

            $result | Should -Be @('GSM-FakeGame-28016-TCP')
        }

        It 'is idempotent: does not recreate a rule that already exists' {
            $fakeRoot = New-FakeGSMRootForFirewall -FolderName 'FakeGame' -DefaultPort 27015 -Protocol 'TCP'
            Mock -ModuleName Firewall -CommandName Get-GSMRootPath -MockWith { $fakeRoot }
            Mock -ModuleName Firewall -CommandName Get-NetFirewallRule -MockWith { [PSCustomObject]@{ Name = 'GSM-FakeGame-27015-TCP' } }
            Mock -ModuleName Firewall -CommandName New-NetFirewallRule -MockWith { }

            $result = Add-GSMFirewallRule -FolderName 'FakeGame'

            $result | Should -Be @('GSM-FakeGame-27015-TCP')
            Should -Invoke -ModuleName Firewall -CommandName New-NetFirewallRule -Times 0
        }

        It 'removes and recreates an existing rule when -Force is set' {
            $fakeRoot = New-FakeGSMRootForFirewall -FolderName 'FakeGame' -DefaultPort 27015 -Protocol 'TCP'
            Mock -ModuleName Firewall -CommandName Get-GSMRootPath -MockWith { $fakeRoot }
            Mock -ModuleName Firewall -CommandName Get-NetFirewallRule -MockWith { [PSCustomObject]@{ Name = 'GSM-FakeGame-27015-TCP' } }
            Mock -ModuleName Firewall -CommandName Remove-NetFirewallRule -MockWith { }
            Mock -ModuleName Firewall -CommandName New-NetFirewallRule -MockWith { }

            Add-GSMFirewallRule -FolderName 'FakeGame' -Force | Out-Null

            Should -Invoke -ModuleName Firewall -CommandName Remove-NetFirewallRule -Times 1 -ParameterFilter { $Name -eq 'GSM-FakeGame-27015-TCP' }
            Should -Invoke -ModuleName Firewall -CommandName New-NetFirewallRule -Times 1
        }

        It 'throws and logs an error when New-NetFirewallRule fails' {
            $fakeRoot = New-FakeGSMRootForFirewall -FolderName 'FakeGame' -DefaultPort 27015 -Protocol 'TCP'
            Mock -ModuleName Firewall -CommandName Get-GSMRootPath -MockWith { $fakeRoot }
            Mock -ModuleName Firewall -CommandName Get-NetFirewallRule -MockWith { $null }
            Mock -ModuleName Firewall -CommandName New-NetFirewallRule -MockWith { throw 'simulated failure' }

            { Add-GSMFirewallRule -FolderName 'FakeGame' } | Should -Throw

            Should -Invoke -ModuleName Firewall -CommandName Write-GSMLog -Times 1 -ParameterFilter { $Level -eq 'Error' }
        }
    }

    Context 'Remove-GSMFirewallRule' {
        It 'is a no-op returning $true and logs info when no rules exist' {
            Mock -ModuleName Firewall -CommandName Get-NetFirewallRule -MockWith { $null }
            Mock -ModuleName Firewall -CommandName Remove-NetFirewallRule -MockWith { }

            $result = Remove-GSMFirewallRule -FolderName 'FakeGame'

            $result | Should -Be $true
            Should -Invoke -ModuleName Firewall -CommandName Remove-NetFirewallRule -Times 0
        }

        It 'removes every matching rule for the instance' {
            Mock -ModuleName Firewall -CommandName Get-NetFirewallRule -MockWith {
                @(
                    [PSCustomObject]@{ Name = 'GSM-FakeGame-27015-TCP' }
                    [PSCustomObject]@{ Name = 'GSM-FakeGame-27015-UDP' }
                )
            }
            Mock -ModuleName Firewall -CommandName Remove-NetFirewallRule -MockWith { }

            $result = Remove-GSMFirewallRule -FolderName 'FakeGame'

            $result | Should -Be $true
            Should -Invoke -ModuleName Firewall -CommandName Remove-NetFirewallRule -Times 2
        }

        It 'warns rather than throws when removing one rule fails, and still processes the rest' {
            Mock -ModuleName Firewall -CommandName Get-NetFirewallRule -MockWith {
                @(
                    [PSCustomObject]@{ Name = 'GSM-FakeGame-27015-TCP' }
                    [PSCustomObject]@{ Name = 'GSM-FakeGame-27015-UDP' }
                )
            }
            Mock -ModuleName Firewall -CommandName Remove-NetFirewallRule -MockWith {
                param($Name)
                if ($Name -eq 'GSM-FakeGame-27015-TCP') {
                    throw 'simulated failure'
                }
            }

            { Remove-GSMFirewallRule -FolderName 'FakeGame' } | Should -Not -Throw

            Should -Invoke -ModuleName Firewall -CommandName Write-GSMLog -Times 1 -ParameterFilter { $Level -eq 'Warning' }
            Should -Invoke -ModuleName Firewall -CommandName Remove-NetFirewallRule -Times 2
        }
    }

    Context 'Get-GSMFirewallRuleStatus' {
        It 'returns an empty array when no rules exist for the instance' {
            Mock -ModuleName Firewall -CommandName Get-NetFirewallRule -MockWith { $null }

            $result = @(Get-GSMFirewallRuleStatus -FolderName 'FakeGame')

            $result.Count | Should -Be 0
        }

        It 'returns one status object per matching rule, with protocol/port parsed from the rule name and enabled from the rule itself' {
            Mock -ModuleName Firewall -CommandName Get-NetFirewallRule -MockWith {
                @(
                    [PSCustomObject]@{ Name = 'GSM-FakeGame-27015-TCP'; Enabled = 'True'; Direction = 'Inbound'; Action = 'Allow' }
                    [PSCustomObject]@{ Name = 'GSM-FakeGame-27015-UDP'; Enabled = 'False'; Direction = 'Inbound'; Action = 'Allow' }
                )
            }

            $result = @(Get-GSMFirewallRuleStatus -FolderName 'FakeGame')

            $result.Count | Should -Be 2

            $tcpStatus = $result | Where-Object { $_.RuleName -eq 'GSM-FakeGame-27015-TCP' }
            $tcpStatus.Protocol | Should -Be 'TCP'
            $tcpStatus.Port | Should -Be 27015
            $tcpStatus.Enabled | Should -Be $true
            $tcpStatus.FolderName | Should -Be 'FakeGame'

            $udpStatus = $result | Where-Object { $_.RuleName -eq 'GSM-FakeGame-27015-UDP' }
            $udpStatus.Protocol | Should -Be 'UDP'
            $udpStatus.Enabled | Should -Be $false
        }
    }
}
