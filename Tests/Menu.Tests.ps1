BeforeAll {
    Import-Module "$PSScriptRoot/../Core/Menu.psm1" -Force
    $script:RealPluginsDirectory = (Resolve-Path "$PSScriptRoot/../Plugins").Path
    $script:GsmScriptPath = (Resolve-Path "$PSScriptRoot/../GSM.ps1").Path
}

Describe 'Core/Menu.psm1' {

    Context 'Invoke-GSMAction' {
        BeforeEach {
            $script:FakePluginFolder = Join-Path $script:RealPluginsDirectory 'GSMTestFakeGame'
        }

        AfterEach {
            if (Test-Path -Path $script:FakePluginFolder) {
                Remove-Item -Path $script:FakePluginFolder -Recurse -Force -ErrorAction SilentlyContinue
            }

            # Import-GSMPlugin imports by bare file basename (Install, Server,
            # Maps, Modes), so a global import from this plugin folder or from
            # Insurgency2014 (via the "unimplemented action" test) would
            # otherwise leak into whichever test file runs next in the same
            # process and shadow that file's own plugin imports of the same
            # name.
            Remove-Module -Name 'Install', 'Server', 'Maps', 'Modes' -Force -ErrorAction SilentlyContinue
        }

        It 'calls the matching plugin function for a valid plugin and action' {
            New-Item -ItemType Directory -Path $script:FakePluginFolder -Force | Out-Null

            Set-Content -Path (Join-Path $script:FakePluginFolder 'Plugin.json') -Value @'
{"GameName":"GSMTestFakeGame","Version":"1","AppID":"999999","Engine":"Source","Executable":"fake.exe","DefaultPort":27015,"SupportsWorkshop":false,"SupportsRCON":false}
'@
            Set-Content -Path (Join-Path $script:FakePluginFolder 'Install.psm1') -Value @'
Set-StrictMode -Version Latest
function Install-GSMTestFakeGameServer {
    $global:GSMTestInvokedFunction = 'Install-GSMTestFakeGameServer'
}
Export-ModuleMember -Function Install-GSMTestFakeGameServer
'@
            Set-Content -Path (Join-Path $script:FakePluginFolder 'Server.psm1') -Value 'Set-StrictMode -Version Latest'
            Set-Content -Path (Join-Path $script:FakePluginFolder 'Maps.psm1') -Value 'Set-StrictMode -Version Latest'
            Set-Content -Path (Join-Path $script:FakePluginFolder 'Modes.psm1') -Value 'Set-StrictMode -Version Latest'

            $global:GSMTestInvokedFunction = $null
            $result = Invoke-GSMAction -GameName 'GSMTestFakeGame' -Action Install

            $result | Should -Be $true
            $global:GSMTestInvokedFunction | Should -Be 'Install-GSMTestFakeGameServer'
        }

        It 'returns $false and logs an error for an unknown GameName' {
            Mock -ModuleName Menu -CommandName Write-GSMLog -MockWith { }

            $result = Invoke-GSMAction -GameName 'NoSuchGameAtAll' -Action Install

            $result | Should -Be $false
            Should -Invoke -ModuleName Menu -CommandName Write-GSMLog -Times 1 -ParameterFilter { $Level -eq 'Error' }
        }

        It 'returns $false without throwing when the plugin does not implement the action' {
            # A fake plugin whose Server.psm1 defines no functions at all, so
            # this test's premise ("action not implemented") doesn't depend
            # on which actions a real Phase 1 plugin happens to implement
            # yet - every real plugin now implements Start/Stop/Restart/
            # Status/Configure.
            New-Item -ItemType Directory -Path $script:FakePluginFolder -Force | Out-Null

            Set-Content -Path (Join-Path $script:FakePluginFolder 'Plugin.json') -Value @'
{"GameName":"GSMTestFakeGame","Version":"1","AppID":"999999","Engine":"Source","Executable":"fake.exe","DefaultPort":27015,"SupportsWorkshop":false,"SupportsRCON":false}
'@
            Set-Content -Path (Join-Path $script:FakePluginFolder 'Install.psm1') -Value 'Set-StrictMode -Version Latest'
            Set-Content -Path (Join-Path $script:FakePluginFolder 'Server.psm1') -Value 'Set-StrictMode -Version Latest'
            Set-Content -Path (Join-Path $script:FakePluginFolder 'Maps.psm1') -Value 'Set-StrictMode -Version Latest'
            Set-Content -Path (Join-Path $script:FakePluginFolder 'Modes.psm1') -Value 'Set-StrictMode -Version Latest'

            Mock -ModuleName Menu -CommandName Write-GSMLog -MockWith { }

            $script:result = $null
            { $script:result = Invoke-GSMAction -GameName 'GSMTestFakeGame' -Action Start } | Should -Not -Throw

            $script:result | Should -Be $false
            Should -Invoke -ModuleName Menu -CommandName Write-GSMLog -Times 1 -ParameterFilter { $Level -eq 'Error' }
        }

        It 'dispatches the Restart action to Restart-<FolderName>Server' {
            New-Item -ItemType Directory -Path $script:FakePluginFolder -Force | Out-Null

            Set-Content -Path (Join-Path $script:FakePluginFolder 'Plugin.json') -Value @'
{"GameName":"GSMTestFakeGame","Version":"1","AppID":"999999","Engine":"Source","Executable":"fake.exe","DefaultPort":27015,"SupportsWorkshop":false,"SupportsRCON":false}
'@
            Set-Content -Path (Join-Path $script:FakePluginFolder 'Install.psm1') -Value 'Set-StrictMode -Version Latest'
            Set-Content -Path (Join-Path $script:FakePluginFolder 'Server.psm1') -Value @'
Set-StrictMode -Version Latest
function Restart-GSMTestFakeGameServer {
    $global:GSMTestInvokedFunction = 'Restart-GSMTestFakeGameServer'
}
Export-ModuleMember -Function Restart-GSMTestFakeGameServer
'@
            Set-Content -Path (Join-Path $script:FakePluginFolder 'Maps.psm1') -Value 'Set-StrictMode -Version Latest'
            Set-Content -Path (Join-Path $script:FakePluginFolder 'Modes.psm1') -Value 'Set-StrictMode -Version Latest'

            $global:GSMTestInvokedFunction = $null
            $result = Invoke-GSMAction -GameName 'GSMTestFakeGame' -Action Restart

            $result | Should -Be $true
            $global:GSMTestInvokedFunction | Should -Be 'Restart-GSMTestFakeGameServer'
        }

        It 'logs the returned value for the Status action instead of discarding it' {
            Mock -ModuleName Menu -CommandName Write-GSMLog -MockWith { }

            New-Item -ItemType Directory -Path $script:FakePluginFolder -Force | Out-Null

            Set-Content -Path (Join-Path $script:FakePluginFolder 'Plugin.json') -Value @'
{"GameName":"GSMTestFakeGame","Version":"1","AppID":"999999","Engine":"Source","Executable":"fake.exe","DefaultPort":27015,"SupportsWorkshop":false,"SupportsRCON":false}
'@
            Set-Content -Path (Join-Path $script:FakePluginFolder 'Install.psm1') -Value 'Set-StrictMode -Version Latest'
            Set-Content -Path (Join-Path $script:FakePluginFolder 'Server.psm1') -Value @'
Set-StrictMode -Version Latest
function Get-GSMTestFakeGameServerStatus {
    return 'Running'
}
Export-ModuleMember -Function Get-GSMTestFakeGameServerStatus
'@
            Set-Content -Path (Join-Path $script:FakePluginFolder 'Maps.psm1') -Value 'Set-StrictMode -Version Latest'
            Set-Content -Path (Join-Path $script:FakePluginFolder 'Modes.psm1') -Value 'Set-StrictMode -Version Latest'

            $result = Invoke-GSMAction -GameName 'GSMTestFakeGame' -Action Status

            $result | Should -Be $true
            Should -Invoke -ModuleName Menu -CommandName Write-GSMLog -Times 1 -ParameterFilter {
                $Level -eq 'Info' -and $Message -match 'Running'
            }
        }
    }
}

Describe 'GSM.ps1 entry point' {

    BeforeAll {
        # GSM.ps1's non-interactive path calls `exit`, which would terminate
        # the Pester process itself if run in-process. Instead, run a copy of
        # the real script as its own child pwsh process, alongside minimal
        # fake Core modules so Invoke-GSMAction is a controlled stand-in
        # rather than a full end-to-end plugin run.
        $script:FakeEntryDir = Join-Path $TestDrive 'gsm-entry-tests'
        New-Item -ItemType Directory -Path (Join-Path $script:FakeEntryDir 'Core') -Force | Out-Null
        Copy-Item -Path $script:GsmScriptPath -Destination (Join-Path $script:FakeEntryDir 'GSM.ps1') -Force

        Set-Content -Path (Join-Path $script:FakeEntryDir 'Core/Utilities.psm1') -Value 'Set-StrictMode -Version Latest'
        Set-Content -Path (Join-Path $script:FakeEntryDir 'Core/Logging.psm1') -Value 'Set-StrictMode -Version Latest'
        Set-Content -Path (Join-Path $script:FakeEntryDir 'Core/PluginLoader.psm1') -Value 'Set-StrictMode -Version Latest'
        Set-Content -Path (Join-Path $script:FakeEntryDir 'Core/Menu.psm1') -Value @'
Set-StrictMode -Version Latest

function Invoke-GSMAction {
    param(
        [string]$GameName,
        [string]$Action
    )
    return ($GameName -eq 'WillSucceed')
}

function Show-MainMenu {
    # No-op stand-in; entry-point tests never take this branch.
}

Export-ModuleMember -Function Invoke-GSMAction, Show-MainMenu
'@

        $script:FakeGsmScriptPath = Join-Path $script:FakeEntryDir 'GSM.ps1'
    }

    It 'exits 0 when Invoke-GSMAction succeeds' {
        & pwsh -NoProfile -File $script:FakeGsmScriptPath -GameName 'WillSucceed' -Action 'Install' | Out-Null
        $LASTEXITCODE | Should -Be 0
    }

    It 'exits 1 when Invoke-GSMAction fails' {
        & pwsh -NoProfile -File $script:FakeGsmScriptPath -GameName 'WillFail' -Action 'Install' | Out-Null
        $LASTEXITCODE | Should -Be 1
    }

    It 'exits 1 when only -GameName is supplied without -Action' {
        & pwsh -NoProfile -File $script:FakeGsmScriptPath -GameName 'WillSucceed' 2>$null | Out-Null
        $LASTEXITCODE | Should -Be 1
    }
}
