BeforeAll {
    Import-Module "$PSScriptRoot/../Core/Config.psm1" -Force
    $script:TestDir = Join-Path $TestDrive 'config-tests'
    New-Item -ItemType Directory -Path $script:TestDir -Force | Out-Null
}

Describe 'Core/Config.psm1' {

    It 'loads a valid config file' {
        $path = Join-Path $script:TestDir 'valid.json'
        Set-Content -Path $path -Value '{"GameName":"Insurgency","AppID":"237410","DefaultPort":27015}'
        $cfg = Get-GSMConfig -Path $path
        $cfg.GameName | Should -Be 'Insurgency'
    }

    It 'rejects malformed JSON' {
        $path = Join-Path $script:TestDir 'malformed.json'
        Set-Content -Path $path -Value '{"GameName": "Insurgency", "AppID":'
        { Get-GSMConfig -Path $path } | Should -Throw
    }

    It 'rejects a missing required field' {
        $path = Join-Path $script:TestDir 'missing.json'
        Set-Content -Path $path -Value '{"AppID":"237410"}'
        { Get-GSMConfig -Path $path } | Should -Throw
    }

    It 'rejects an out-of-range port' {
        $path = Join-Path $script:TestDir 'badport.json'
        Set-Content -Path $path -Value '{"GameName":"Insurgency","AppID":"237410","DefaultPort":99999}'
        { Get-GSMConfig -Path $path } | Should -Throw
    }

    It 'rejects duplicate top-level keys' {
        $path = Join-Path $script:TestDir 'dupe.json'
        Set-Content -Path $path -Value '{"GameName":"Insurgency","GameName":"Duplicate","AppID":"237410"}'
        { Get-GSMConfig -Path $path } | Should -Throw
    }

    It 'rejects unsafe LaunchOptions characters' {
        $path = Join-Path $script:TestDir 'unsafe.json'
        Set-Content -Path $path -Value '{"GameName":"Insurgency","AppID":"237410","LaunchOptions":"+exec cfg.cfg; rm -rf /"}'
        { Get-GSMConfig -Path $path } | Should -Throw
    }

    It 'missing file throws with the path in the message' {
        $path = Join-Path $script:TestDir 'does-not-exist.json'
        { Get-GSMConfig -Path $path } | Should -Throw -ExpectedMessage '*does-not-exist.json*'
    }

    It 'writes a valid config and reads it back' {
        $path = Join-Path $script:TestDir 'roundtrip.json'
        $cfg = [PSCustomObject]@{ GameName = 'Insurgency'; AppID = '237410'; DefaultPort = 27015 }
        Set-GSMConfig -Path $path -Config $cfg
        (Get-GSMConfig -Path $path).AppID | Should -Be '237410'
    }

    It 'creates the target directory when it does not exist yet' {
        $path = Join-Path $script:TestDir 'not-created-yet/newconfig.json'
        $cfg = [PSCustomObject]@{ GameName = 'Insurgency'; AppID = '237410'; DefaultPort = 27015 }

        Test-Path -Path (Split-Path -Path $path -Parent) | Should -Be $false

        { Set-GSMConfig -Path $path -Config $cfg } | Should -Not -Throw

        Test-Path -Path $path -PathType Leaf | Should -Be $true
        (Get-GSMConfig -Path $path).AppID | Should -Be '237410'
    }

    It 'rejects writing an invalid config' {
        $path = Join-Path $script:TestDir 'invalid-write.json'
        $cfg = [PSCustomObject]@{ GameName = 'Insurgency'; AppID = '237410'; DefaultPort = 0 }
        { Set-GSMConfig -Path $path -Config $cfg } | Should -Throw
    }

    It 'loads a valid config that omits the optional DefaultPort field entirely' {
        $path = Join-Path $script:TestDir 'no-port.json'
        Set-Content -Path $path -Value '{"GameName":"Insurgency","AppID":"237410"}'
        { Get-GSMConfig -Path $path } | Should -Not -Throw
    }

    It 'loads a valid config that omits the optional ProcessManager field entirely' {
        $path = Join-Path $script:TestDir 'no-processmanager.json'
        Set-Content -Path $path -Value '{"GameName":"Insurgency","AppID":"237410"}'
        { Get-GSMConfig -Path $path } | Should -Not -Throw
    }

    It 'loads a valid config with ProcessManager set to NSSM' {
        $path = Join-Path $script:TestDir 'pm-nssm.json'
        Set-Content -Path $path -Value '{"GameName":"Insurgency","AppID":"237410","ProcessManager":"NSSM"}'
        { Get-GSMConfig -Path $path } | Should -Not -Throw
    }

    It 'loads a valid config with ProcessManager set to ScheduledTask' {
        $path = Join-Path $script:TestDir 'pm-scheduledtask.json'
        Set-Content -Path $path -Value '{"GameName":"Insurgency","AppID":"237410","ProcessManager":"ScheduledTask"}'
        { Get-GSMConfig -Path $path } | Should -Not -Throw
    }

    It 'rejects an invalid ProcessManager value' {
        $path = Join-Path $script:TestDir 'pm-invalid.json'
        Set-Content -Path $path -Value '{"GameName":"Insurgency","AppID":"237410","ProcessManager":"Docker"}'
        { Get-GSMConfig -Path $path } | Should -Throw
    }

    It 'loads a valid config that omits the optional RestartTime and UpdateCheckTime fields entirely' {
        $path = Join-Path $script:TestDir 'no-scheduler-times.json'
        Set-Content -Path $path -Value '{"GameName":"Insurgency","AppID":"237410"}'
        { Get-GSMConfig -Path $path } | Should -Not -Throw
    }

    It 'loads a valid config with well-formed RestartTime and UpdateCheckTime values' {
        $path = Join-Path $script:TestDir 'scheduler-times.json'
        Set-Content -Path $path -Value '{"GameName":"Insurgency","AppID":"237410","RestartTime":"04:00","UpdateCheckTime":"04:15"}'
        { Get-GSMConfig -Path $path } | Should -Not -Throw
    }

    It 'rejects an invalid RestartTime value' {
        $path = Join-Path $script:TestDir 'bad-restarttime.json'
        Set-Content -Path $path -Value '{"GameName":"Insurgency","AppID":"237410","RestartTime":"25:00"}'
        { Get-GSMConfig -Path $path } | Should -Throw
    }

    It 'rejects an invalid UpdateCheckTime value' {
        $path = Join-Path $script:TestDir 'bad-updatechecktime.json'
        Set-Content -Path $path -Value '{"GameName":"Insurgency","AppID":"237410","UpdateCheckTime":"4:15pm"}'
        { Get-GSMConfig -Path $path } | Should -Throw
    }

    It 'loads a valid config that omits the optional BackupRetentionCount field entirely' {
        $path = Join-Path $script:TestDir 'no-retention.json'
        Set-Content -Path $path -Value '{"GameName":"Insurgency","AppID":"237410"}'
        { Get-GSMConfig -Path $path } | Should -Not -Throw
    }

    It 'loads a valid config with a positive integer BackupRetentionCount' {
        $path = Join-Path $script:TestDir 'retention.json'
        Set-Content -Path $path -Value '{"GameName":"Insurgency","AppID":"237410","BackupRetentionCount":10}'
        { Get-GSMConfig -Path $path } | Should -Not -Throw
    }

    It 'rejects a BackupRetentionCount less than 1' {
        $path = Join-Path $script:TestDir 'bad-retention.json'
        Set-Content -Path $path -Value '{"GameName":"Insurgency","AppID":"237410","BackupRetentionCount":0}'
        { Get-GSMConfig -Path $path } | Should -Throw
    }
}
