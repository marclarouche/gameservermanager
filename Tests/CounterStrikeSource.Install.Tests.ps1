BeforeAll {
    # Every plugin's Install/Server/Maps/Modes modules share these same bare
    # names (see Core/PluginLoader.psm1's Import-GSMPlugin), so a stale copy
    # left loaded by another test file/run in this same session has to be
    # removed first, or Pester's -ModuleName resolution fails with
    # "Multiple script or manifest modules named 'Install' are currently
    # loaded."
    Remove-Module -Name 'Install' -Force -ErrorAction SilentlyContinue
    Import-Module "$PSScriptRoot/../Plugins/CounterStrikeSource/Install.psm1" -Force
}

Describe 'Plugins/CounterStrikeSource/Install.psm1' {

    Context 'Install-CounterStrikeSourceServer' {
        BeforeEach {
            Mock -ModuleName Install -CommandName Get-GSMRootPath -MockWith { 'D:\Fake\GSM' }
            Mock -ModuleName Install -CommandName Update-SteamApp -MockWith { }
            Mock -ModuleName Install -CommandName Write-GSMLog -MockWith { }
            # SteamCMD present by default, so the bootstrap guard is skipped and
            # these tests exercise the same path as before it was added; the
            # "bootstraps SteamCMD" test below flips this to $false.
            Mock -ModuleName Install -CommandName Test-SteamCMDPresent -MockWith { $true }
            Mock -ModuleName Install -CommandName Install-SteamCMD -MockWith { }
        }

        It 'calls Update-SteamApp with AppID 232330 and the Servers/CounterStrikeSource install directory' {
            Install-CounterStrikeSourceServer

            Should -Invoke -ModuleName Install -CommandName Update-SteamApp -Times 1 -ParameterFilter {
                $AppID -eq '232330' -and
                $InstallDirectory -eq (Join-Path 'D:\Fake\GSM' 'Servers/CounterStrikeSource')
            }
        }

        It 'returns $true on success' {
            $result = Install-CounterStrikeSourceServer

            $result | Should -Be $true
        }

        It 'does not hit the network or SteamCMD directly (only through Update-SteamApp)' {
            Install-CounterStrikeSourceServer | Out-Null

            Should -Invoke -ModuleName Install -CommandName Update-SteamApp -Times 1
        }

        It 'logs and rethrows when Update-SteamApp fails' {
            Mock -ModuleName Install -CommandName Update-SteamApp -MockWith { throw 'simulated steamcmd failure' }

            { Install-CounterStrikeSourceServer } | Should -Throw '*simulated steamcmd failure*'

            Should -Invoke -ModuleName Install -CommandName Write-GSMLog -Times 1 -ParameterFilter { $Level -eq 'Error' }
        }

        It 'bootstraps SteamCMD via Install-SteamCMD when it is not already present' {
            Mock -ModuleName Install -CommandName Test-SteamCMDPresent -MockWith { $false }

            Install-CounterStrikeSourceServer

            Should -Invoke -ModuleName Install -CommandName Install-SteamCMD -Times 1
            Should -Invoke -ModuleName Install -CommandName Update-SteamApp -Times 1
        }

        It 'does not reinstall SteamCMD when it is already present' {
            Install-CounterStrikeSourceServer | Out-Null

            Should -Invoke -ModuleName Install -CommandName Install-SteamCMD -Times 0
        }
    }
}
