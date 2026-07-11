BeforeAll {
    Import-Module "$PSScriptRoot/../Core/Dashboard.psm1" -Force
}

Describe 'Core/Dashboard.psm1' {

    Context 'Get-GSMDashboardStatusJson' {
        It 'projects instance fields from Get-GSMServerHealthReportData and drops ConfigSummary' {
            InModuleScope Dashboard {
                Mock -CommandName Get-GSMServerHealthReportData -MockWith {
                    [PSCustomObject]@{
                        GeneratedAtUtc = [datetime]'2026-07-10T00:00:00Z'
                        Instances      = @(
                            [PSCustomObject]@{
                                FolderName    = 'FakeGame'
                                GameName      = 'Fake'
                                Version       = '1'
                                AppID         = '1'
                                Installed     = $true
                                ServerStatus  = 'Running'
                                ConfigSummary = [ordered]@{ RCONPassword = '(set, redacted)' }
                            }
                        )
                    }
                }

                $json = Get-GSMDashboardStatusJson | ConvertFrom-Json

                $json.Instances.Count | Should -Be 1
                $json.Instances[0].FolderName | Should -Be 'FakeGame'
                $json.Instances[0].ServerStatus | Should -Be 'Running'
                $json.Instances[0].PSObject.Properties['ConfigSummary'] | Should -BeNullOrEmpty
            }
        }

        It 'returns an empty Instances array when there are no plugins' {
            InModuleScope Dashboard {
                Mock -CommandName Get-GSMServerHealthReportData -MockWith {
                    [PSCustomObject]@{ GeneratedAtUtc = [datetime]'2026-07-10T00:00:00Z'; Instances = @() }
                }

                $json = Get-GSMDashboardStatusJson | ConvertFrom-Json

                @($json.Instances).Count | Should -Be 0
            }
        }
    }

    Context 'Invoke-GSMDashboardAction' {
        It 'dispatches through Invoke-GSMAction and reports success' {
            InModuleScope Dashboard {
                Mock -CommandName Invoke-GSMAction -MockWith { $true }

                $result = Invoke-GSMDashboardAction -FolderName 'FakeGame' -Action 'Start'

                $result.Success | Should -Be $true
                Should -Invoke -CommandName Invoke-GSMAction -Times 1 -ParameterFilter { $FolderName -eq 'FakeGame' -and $Action -eq 'Start' }
            }
        }

        It 'reports failure when Invoke-GSMAction fails' {
            InModuleScope Dashboard {
                Mock -CommandName Invoke-GSMAction -MockWith { $false }

                $result = Invoke-GSMDashboardAction -FolderName 'FakeGame' -Action 'Stop'

                $result.Success | Should -Be $false
            }
        }
    }

    Context 'Invoke-GSMDashboardRCONCommand' {
        It 'returns the RCON response on success' {
            InModuleScope Dashboard {
                Mock -CommandName Send-GSMRCONCommand -MockWith { 'pong' }

                $result = Invoke-GSMDashboardRCONCommand -FolderName 'FakeGame' -Command 'status'

                $result.Success | Should -Be $true
                $result.Response | Should -Be 'pong'
            }
        }

        It 'returns Success = $false and the error message when Send-GSMRCONCommand throws' {
            InModuleScope Dashboard {
                Mock -CommandName Send-GSMRCONCommand -MockWith { throw "RCON authentication failed for 'FakeGame'." }

                $result = Invoke-GSMDashboardRCONCommand -FolderName 'FakeGame' -Command 'status'

                $result.Success | Should -Be $false
                $result.Error | Should -Match 'authentication failed'
            }
        }
    }

    Context 'Invoke-GSMDashboardRequest' {
        It 'serves the dashboard HTML page at GET /' {
            InModuleScope Dashboard {
                $result = Invoke-GSMDashboardRequest -Method 'GET' -Path '/'

                $result.StatusCode | Should -Be 200
                $result.ContentType | Should -Be 'text/html'
                $result.Body | Should -Match '<title>GSM Dashboard</title>'
            }
        }

        It 'serves JSON status at GET /api/status' {
            InModuleScope Dashboard {
                Mock -CommandName Get-GSMDashboardStatusJson -MockWith { '{"Instances":[]}' }

                $result = Invoke-GSMDashboardRequest -Method 'GET' -Path '/api/status'

                $result.StatusCode | Should -Be 200
                $result.ContentType | Should -Be 'application/json'
                $result.Body | Should -Be '{"Instances":[]}'
            }
        }

        It 'returns a 500 JSON error when status gathering fails' {
            InModuleScope Dashboard {
                Mock -CommandName Get-GSMDashboardStatusJson -MockWith { throw 'boom' }

                $result = Invoke-GSMDashboardRequest -Method 'GET' -Path '/api/status'

                $result.StatusCode | Should -Be 500
                ($result.Body | ConvertFrom-Json).Success | Should -Be $false
            }
        }

        It 'dispatches POST /api/action to Invoke-GSMDashboardAction and returns its JSON result' {
            InModuleScope Dashboard {
                Mock -CommandName Invoke-GSMDashboardAction -MockWith { [PSCustomObject]@{ Success = $true } }

                $body = @{ FolderName = 'FakeGame'; Action = 'Start' } | ConvertTo-Json
                $result = Invoke-GSMDashboardRequest -Method 'POST' -Path '/api/action' -Body $body

                $result.StatusCode | Should -Be 200
                ($result.Body | ConvertFrom-Json).Success | Should -Be $true
                Should -Invoke -CommandName Invoke-GSMDashboardAction -Times 1 -ParameterFilter { $FolderName -eq 'FakeGame' -and $Action -eq 'Start' }
            }
        }

        It 'returns 400 for a malformed /api/action body' {
            InModuleScope Dashboard {
                $result = Invoke-GSMDashboardRequest -Method 'POST' -Path '/api/action' -Body 'not json'

                $result.StatusCode | Should -Be 400
            }
        }

        It 'dispatches POST /api/rcon to Invoke-GSMDashboardRCONCommand and returns its JSON result' {
            InModuleScope Dashboard {
                Mock -CommandName Invoke-GSMDashboardRCONCommand -MockWith { [PSCustomObject]@{ Success = $true; Response = 'pong' } }

                $body = @{ FolderName = 'FakeGame'; Command = 'status' } | ConvertTo-Json
                $result = Invoke-GSMDashboardRequest -Method 'POST' -Path '/api/rcon' -Body $body

                $result.StatusCode | Should -Be 200
                ($result.Body | ConvertFrom-Json).Response | Should -Be 'pong'
                Should -Invoke -CommandName Invoke-GSMDashboardRCONCommand -Times 1 -ParameterFilter { $FolderName -eq 'FakeGame' -and $Command -eq 'status' }
            }
        }

        It 'returns 400 for a malformed /api/rcon body' {
            InModuleScope Dashboard {
                $result = Invoke-GSMDashboardRequest -Method 'POST' -Path '/api/rcon' -Body 'not json'

                $result.StatusCode | Should -Be 400
            }
        }

        It 'returns 404 for an unknown route' {
            InModuleScope Dashboard {
                $result = Invoke-GSMDashboardRequest -Method 'GET' -Path '/nope'

                $result.StatusCode | Should -Be 404
            }
        }
    }

    Context 'Get-GSMDashboardHtml' {
        It 'returns HTML containing the dashboard title and its API endpoints' {
            InModuleScope Dashboard {
                $html = Get-GSMDashboardHtml

                $html | Should -Match '<title>GSM Dashboard</title>'
                $html | Should -Match '/api/status'
                $html | Should -Match '/api/action'
                $html | Should -Match '/api/rcon'
            }
        }
    }
}
