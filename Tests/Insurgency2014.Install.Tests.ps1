BeforeAll {
    # Every plugin's Install/Server/Maps/Modes modules share these same bare
    # names (see Core/PluginLoader.psm1's Import-GSMPlugin), so a stale copy
    # left loaded by another test file/run in this same session has to be
    # removed first, or Pester's -ModuleName resolution fails with
    # "Multiple script or manifest modules named 'Install' are currently
    # loaded."
    Remove-Module -Name 'Install' -Force -ErrorAction SilentlyContinue
    Import-Module "$PSScriptRoot/../Plugins/Insurgency2014/Install.psm1" -Force
}

Describe 'Plugins/Insurgency2014/Install.psm1' {

    Context 'Install-Insurgency2014Server' {
        BeforeEach {
            Mock -ModuleName Install -CommandName Get-GSMRootPath -MockWith { 'D:\Fake\GSM' }
            Mock -ModuleName Install -CommandName Update-SteamApp -MockWith { }
            Mock -ModuleName Install -CommandName Write-GSMLog -MockWith { }
        }

        It 'calls Update-SteamApp with AppID 237410 and the Servers/Insurgency2014 install directory' {
            Install-Insurgency2014Server

            Should -Invoke -ModuleName Install -CommandName Update-SteamApp -Times 1 -ParameterFilter {
                $AppID -eq '237410' -and
                $InstallDirectory -eq (Join-Path 'D:\Fake\GSM' 'Servers/Insurgency2014')
            }
        }

        It 'returns $true on success' {
            $result = Install-Insurgency2014Server

            $result | Should -Be $true
        }

        It 'does not hit the network or SteamCMD directly (only through Update-SteamApp)' {
            Install-Insurgency2014Server | Out-Null

            Should -Invoke -ModuleName Install -CommandName Update-SteamApp -Times 1
        }

        It 'logs and rethrows when Update-SteamApp fails' {
            Mock -ModuleName Install -CommandName Update-SteamApp -MockWith { throw 'simulated steamcmd failure' }

            { Install-Insurgency2014Server } | Should -Throw '*simulated steamcmd failure*'

            Should -Invoke -ModuleName Install -CommandName Write-GSMLog -Times 1 -ParameterFilter { $Level -eq 'Error' }
        }
    }
}
