BeforeAll {
    # See Tests/TeamFortress2.Install.Tests.ps1 for why this Remove-Module
    # is needed: every plugin's Modes.psm1 shares the same bare module name.
    Remove-Module -Name 'Modes' -Force -ErrorAction SilentlyContinue
    Import-Module "$PSScriptRoot/../Plugins/TeamFortress2/Modes.psm1" -Force
}

Describe 'Plugins/TeamFortress2/Modes.psm1' {

    Context 'Get-TeamFortress2Modes' {
        It 'returns all 20 confirmed official game modes' {
            $modes = Get-TeamFortress2Modes

            $modes.Count | Should -Be 20

            $expectedModes = @(
                'capture-the-flag', 'control-point', 'territorial-control',
                'payload', 'arena', 'payload-race', 'king-of-the-hill',
                'medieval-mode', 'special-delivery', 'mann-vs-machine',
                'robot-destruction', 'mannpower', 'pass-time',
                'player-destruction', 'versus-saxton-hale', 'zombie-infection',
                'tug-of-war', 'hold-the-flag', 'competitive-mode', 'training-mode'
            )
            ($modes | Sort-Object) | Should -Be ($expectedModes | Sort-Object)
        }
    }

    Context 'Test-TeamFortress2Mode' {
        It 'returns $true for a known mode, case-insensitively' {
            Test-TeamFortress2Mode -ModeName 'payload' | Should -Be $true
            Test-TeamFortress2Mode -ModeName 'Payload' | Should -Be $true
            Test-TeamFortress2Mode -ModeName 'PAYLOAD' | Should -Be $true
        }

        It 'returns $true for every confirmed mode' {
            foreach ($mode in Get-TeamFortress2Modes) {
                Test-TeamFortress2Mode -ModeName $mode | Should -Be $true -Because "mode '$mode' should validate"
            }
        }

        It 'returns $false for an unrecognized mode name' {
            Test-TeamFortress2Mode -ModeName 'battle_royale' | Should -Be $false
        }
    }
}
