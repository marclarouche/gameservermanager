BeforeAll {
    Import-Module "$PSScriptRoot/../Core/Backup.psm1" -Force

    function New-FakeGSMRootForBackup {
        param(
            [string]$FolderName = 'FakeGame',
            [switch]$WithConfig,
            [int]$RetentionCount,
            [switch]$WithCfgOverride,
            [switch]$WithCustomMaps
        )

        $root = Join-Path $TestDrive ('backup-root-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $root 'Config') -Force | Out-Null

        if ($WithConfig) {
            $config = [ordered]@{ GameName = 'FakeGame'; AppID = '1' }
            if ($RetentionCount) { $config['BackupRetentionCount'] = $RetentionCount }
            $config | ConvertTo-Json | Set-Content -Path (Join-Path $root "Config/$FolderName.json")
        }

        if ($WithCustomMaps) {
            [ordered]@{ $FolderName = @('live_map'); OtherGame = @('other_map') } | ConvertTo-Json | Set-Content -Path (Join-Path $root 'Config/CustomMaps.json')
        }

        if ($WithCfgOverride) {
            $cfgDir = Join-Path $root "Servers/$FolderName/cfg"
            New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null
            Set-Content -Path (Join-Path $cfgDir 'server.cfg') -Value 'sv_test 1'
        }

        return $root
    }

    function New-FakeGSMBackupZip {
        param(
            [Parameter(Mandatory)] [string]$Root,
            [Parameter(Mandatory)] [string]$FolderName,
            [string]$ConfigJson,
            [hashtable]$CustomMapsSlice,
            [hashtable]$ServerFiles,
            [string]$Timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
        )

        $backupsDirectory = Join-Path $Root 'Backups'
        New-Item -ItemType Directory -Path $backupsDirectory -Force | Out-Null

        $stagingDirectory = Join-Path $TestDrive ('zip-staging-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $stagingDirectory 'Config') -Force | Out-Null

        if ($ConfigJson) {
            Set-Content -Path (Join-Path $stagingDirectory "Config/$FolderName.json") -Value $ConfigJson
        }
        if ($CustomMapsSlice) {
            $CustomMapsSlice | ConvertTo-Json | Set-Content -Path (Join-Path $stagingDirectory 'Config/CustomMaps.json')
        }
        if ($ServerFiles) {
            foreach ($relativePath in $ServerFiles.Keys) {
                $destination = Join-Path $stagingDirectory "ServerFiles/$relativePath"
                New-Item -ItemType Directory -Path (Split-Path -Path $destination -Parent) -Force | Out-Null
                Set-Content -Path $destination -Value $ServerFiles[$relativePath]
            }
        }

        $zipPath = Join-Path $backupsDirectory "$FolderName-$Timestamp.zip"
        Compress-Archive -Path (Join-Path $stagingDirectory '*') -DestinationPath $zipPath -Force
        Remove-Item -Path $stagingDirectory -Recurse -Force

        return $zipPath
    }
}

Describe 'Core/Backup.psm1' {

    BeforeEach {
        Mock -ModuleName Backup -CommandName Write-GSMLog -MockWith { }
    }

    Context 'New-GSMBackup' {
        It 'throws when no config exists for the instance' {
            $fakeRoot = New-FakeGSMRootForBackup -FolderName 'FakeGame'
            Mock -ModuleName Backup -CommandName Get-GSMRootPath -MockWith { $fakeRoot }

            { New-GSMBackup -FolderName 'FakeGame' } | Should -Throw
        }

        It 'creates a zip containing Config/<FolderName>.json' {
            $fakeRoot = New-FakeGSMRootForBackup -FolderName 'FakeGame' -WithConfig
            Mock -ModuleName Backup -CommandName Get-GSMRootPath -MockWith { $fakeRoot }

            $backupPath = New-GSMBackup -FolderName 'FakeGame'

            Test-Path -Path $backupPath | Should -Be $true
            Split-Path -Path $backupPath -Leaf | Should -Match '^FakeGame-\d{8}-\d{6}\.zip$'

            $extractDir = Join-Path $TestDrive ('extract-' + [guid]::NewGuid().ToString('N'))
            Expand-Archive -Path $backupPath -DestinationPath $extractDir
            Test-Path -Path (Join-Path $extractDir 'Config/FakeGame.json') | Should -Be $true
        }

        It 'includes only this instance''s own slice of CustomMaps.json' {
            $fakeRoot = New-FakeGSMRootForBackup -FolderName 'FakeGame' -WithConfig -WithCustomMaps
            Mock -ModuleName Backup -CommandName Get-GSMRootPath -MockWith { $fakeRoot }

            $backupPath = New-GSMBackup -FolderName 'FakeGame'

            $extractDir = Join-Path $TestDrive ('extract-' + [guid]::NewGuid().ToString('N'))
            Expand-Archive -Path $backupPath -DestinationPath $extractDir
            $customMaps = Get-Content -Path (Join-Path $extractDir 'Config/CustomMaps.json') -Raw | ConvertFrom-Json

            $customMaps.FakeGame | Should -Be @('live_map')
            $customMaps.PSObject.Properties['OtherGame'] | Should -BeNullOrEmpty
        }

        It 'includes .cfg overrides under ServerFiles when present' {
            $fakeRoot = New-FakeGSMRootForBackup -FolderName 'FakeGame' -WithConfig -WithCfgOverride
            Mock -ModuleName Backup -CommandName Get-GSMRootPath -MockWith { $fakeRoot }

            $backupPath = New-GSMBackup -FolderName 'FakeGame'

            $extractDir = Join-Path $TestDrive ('extract-' + [guid]::NewGuid().ToString('N'))
            Expand-Archive -Path $backupPath -DestinationPath $extractDir
            Test-Path -Path (Join-Path $extractDir 'ServerFiles/cfg/server.cfg') | Should -Be $true
            (Get-Content -Path (Join-Path $extractDir 'ServerFiles/cfg/server.cfg') -Raw).Trim() | Should -Be 'sv_test 1'
        }

        It 'omits CustomMaps.json and ServerFiles when there is nothing to include' {
            $fakeRoot = New-FakeGSMRootForBackup -FolderName 'FakeGame' -WithConfig
            Mock -ModuleName Backup -CommandName Get-GSMRootPath -MockWith { $fakeRoot }

            $backupPath = New-GSMBackup -FolderName 'FakeGame'

            $extractDir = Join-Path $TestDrive ('extract-' + [guid]::NewGuid().ToString('N'))
            Expand-Archive -Path $backupPath -DestinationPath $extractDir
            Test-Path -Path (Join-Path $extractDir 'Config/CustomMaps.json') | Should -Be $false
            Test-Path -Path (Join-Path $extractDir 'ServerFiles') | Should -Be $false
        }

        It 'prunes backups beyond the default retention count of 5' {
            $fakeRoot = New-FakeGSMRootForBackup -FolderName 'FakeGame' -WithConfig
            Mock -ModuleName Backup -CommandName Get-GSMRootPath -MockWith { $fakeRoot }

            $backupsDirectory = Join-Path $fakeRoot 'Backups'
            New-Item -ItemType Directory -Path $backupsDirectory -Force | Out-Null
            1..5 | ForEach-Object {
                New-Item -ItemType File -Path (Join-Path $backupsDirectory ('FakeGame-2026010{0}-040000.zip' -f $_)) -Force | Out-Null
            }

            New-GSMBackup -FolderName 'FakeGame' | Out-Null

            $remaining = @(Get-GSMBackupList -FolderName 'FakeGame')
            $remaining.Count | Should -Be 5
            $remaining.FileName | Should -Not -Contain 'FakeGame-20260101-040000.zip'
        }

        It 'respects a custom BackupRetentionCount from config' {
            $fakeRoot = New-FakeGSMRootForBackup -FolderName 'FakeGame' -WithConfig -RetentionCount 2
            Mock -ModuleName Backup -CommandName Get-GSMRootPath -MockWith { $fakeRoot }

            $backupsDirectory = Join-Path $fakeRoot 'Backups'
            New-Item -ItemType Directory -Path $backupsDirectory -Force | Out-Null
            New-Item -ItemType File -Path (Join-Path $backupsDirectory 'FakeGame-20260101-040000.zip') -Force | Out-Null
            New-Item -ItemType File -Path (Join-Path $backupsDirectory 'FakeGame-20260102-040000.zip') -Force | Out-Null

            New-GSMBackup -FolderName 'FakeGame' | Out-Null

            $remaining = @(Get-GSMBackupList -FolderName 'FakeGame')
            $remaining.Count | Should -Be 2
        }

        It 'returns the full path to the created archive' {
            $fakeRoot = New-FakeGSMRootForBackup -FolderName 'FakeGame' -WithConfig
            Mock -ModuleName Backup -CommandName Get-GSMRootPath -MockWith { $fakeRoot }

            $result = New-GSMBackup -FolderName 'FakeGame'

            Split-Path -Path $result -Parent | Should -Be (Join-Path $fakeRoot 'Backups')
            Test-Path -Path $result | Should -Be $true
        }
    }

    Context 'Get-GSMBackupList' {
        It 'returns an empty array when Backups/ does not exist' {
            $fakeRoot = New-FakeGSMRootForBackup -FolderName 'FakeGame'
            Mock -ModuleName Backup -CommandName Get-GSMRootPath -MockWith { $fakeRoot }

            $result = @(Get-GSMBackupList -FolderName 'FakeGame')

            $result.Count | Should -Be 0
        }

        It 'returns only matching backups, newest first, ignoring other instances'' files' {
            $fakeRoot = New-FakeGSMRootForBackup -FolderName 'FakeGame'
            Mock -ModuleName Backup -CommandName Get-GSMRootPath -MockWith { $fakeRoot }

            $backupsDirectory = Join-Path $fakeRoot 'Backups'
            New-Item -ItemType Directory -Path $backupsDirectory -Force | Out-Null
            New-Item -ItemType File -Path (Join-Path $backupsDirectory 'FakeGame-20260101-040000.zip') -Force | Out-Null
            New-Item -ItemType File -Path (Join-Path $backupsDirectory 'FakeGame-20260103-040000.zip') -Force | Out-Null
            New-Item -ItemType File -Path (Join-Path $backupsDirectory 'FakeGame-20260102-040000.zip') -Force | Out-Null
            New-Item -ItemType File -Path (Join-Path $backupsDirectory 'FakeGame2-20260104-040000.zip') -Force | Out-Null

            $result = @(Get-GSMBackupList -FolderName 'FakeGame')

            $result.Count | Should -Be 3
            $result[0].FileName | Should -Be 'FakeGame-20260103-040000.zip'
            $result[1].FileName | Should -Be 'FakeGame-20260102-040000.zip'
            $result[2].FileName | Should -Be 'FakeGame-20260101-040000.zip'
        }
    }

    Context 'Restore-GSMBackup' {
        It 'throws when the backup file does not exist' {
            $fakeRoot = New-FakeGSMRootForBackup -FolderName 'FakeGame' -WithConfig
            Mock -ModuleName Backup -CommandName Get-GSMRootPath -MockWith { $fakeRoot }

            { Restore-GSMBackup -FolderName 'FakeGame' -BackupPath (Join-Path $fakeRoot 'Backups/does-not-exist.zip') } | Should -Throw
        }

        It 'takes a safety backup before restoring when a live config exists' {
            $fakeRoot = New-FakeGSMRootForBackup -FolderName 'FakeGame' -WithConfig
            Mock -ModuleName Backup -CommandName Get-GSMRootPath -MockWith { $fakeRoot }

            $validConfigJson = '{"GameName":"FakeGame","AppID":"1"}'
            $backupPath = New-FakeGSMBackupZip -Root $fakeRoot -FolderName 'FakeGame' -ConfigJson $validConfigJson -Timestamp '20260101-000000'

            Restore-GSMBackup -FolderName 'FakeGame' -BackupPath $backupPath | Out-Null

            $backupsAfter = @(Get-GSMBackupList -FolderName 'FakeGame')
            # The pre-restore safety backup plus the one already on disk.
            $backupsAfter.Count | Should -Be 2
        }

        It 'applies a valid restored config to the live config file' {
            $fakeRoot = New-FakeGSMRootForBackup -FolderName 'FakeGame' -WithConfig
            Mock -ModuleName Backup -CommandName Get-GSMRootPath -MockWith { $fakeRoot }

            $restoredConfigJson = '{"GameName":"FakeGame","AppID":"1","DefaultPort":28016}'
            $backupPath = New-FakeGSMBackupZip -Root $fakeRoot -FolderName 'FakeGame' -ConfigJson $restoredConfigJson -Timestamp '20260101-000000'

            Restore-GSMBackup -FolderName 'FakeGame' -BackupPath $backupPath | Out-Null

            $liveConfig = Get-Content -Path (Join-Path $fakeRoot 'Config/FakeGame.json') -Raw | ConvertFrom-Json
            $liveConfig.DefaultPort | Should -Be 28016
        }

        It 'fails closed: does not touch the live config and preserves the safety backup when the restored config fails validation' {
            $fakeRoot = New-FakeGSMRootForBackup -FolderName 'FakeGame' -WithConfig
            Mock -ModuleName Backup -CommandName Get-GSMRootPath -MockWith { $fakeRoot }

            $originalLiveConfig = Get-Content -Path (Join-Path $fakeRoot 'Config/FakeGame.json') -Raw

            $invalidConfigJson = '{"GameName":"FakeGame","AppID":"1","DefaultPort":99999}'
            $backupPath = New-FakeGSMBackupZip -Root $fakeRoot -FolderName 'FakeGame' -ConfigJson $invalidConfigJson -Timestamp '20260101-000000'

            { Restore-GSMBackup -FolderName 'FakeGame' -BackupPath $backupPath } | Should -Throw '*validation*'

            $liveConfigAfter = Get-Content -Path (Join-Path $fakeRoot 'Config/FakeGame.json') -Raw
            $liveConfigAfter | Should -Be $originalLiveConfig

            # The safety backup taken before validation failed must still be
            # there - "fail closed" means nothing gets cleaned up on failure.
            $backupsAfter = @(Get-GSMBackupList -FolderName 'FakeGame')
            $backupsAfter.Count | Should -Be 2
        }

        It 'throws when the backup has no config for this instance' {
            $fakeRoot = New-FakeGSMRootForBackup -FolderName 'FakeGame' -WithConfig
            Mock -ModuleName Backup -CommandName Get-GSMRootPath -MockWith { $fakeRoot }

            $backupPath = New-FakeGSMBackupZip -Root $fakeRoot -FolderName 'FakeGame' -ConfigJson $null -CustomMapsSlice @{ FakeGame = @('x') } -Timestamp '20260101-000000'

            { Restore-GSMBackup -FolderName 'FakeGame' -BackupPath $backupPath } | Should -Throw '*does not contain a config*'
        }

        It 'merges only this instance''s CustomMaps entry, leaving other instances'' entries untouched' {
            $fakeRoot = New-FakeGSMRootForBackup -FolderName 'FakeGame' -WithConfig -WithCustomMaps
            Mock -ModuleName Backup -CommandName Get-GSMRootPath -MockWith { $fakeRoot }

            $validConfigJson = '{"GameName":"FakeGame","AppID":"1"}'
            $backupPath = New-FakeGSMBackupZip -Root $fakeRoot -FolderName 'FakeGame' -ConfigJson $validConfigJson -CustomMapsSlice @{ FakeGame = @('restored_map') } -Timestamp '20260101-000000'

            Restore-GSMBackup -FolderName 'FakeGame' -BackupPath $backupPath | Out-Null

            $liveCustomMaps = Get-Content -Path (Join-Path $fakeRoot 'Config/CustomMaps.json') -Raw | ConvertFrom-Json
            $liveCustomMaps.FakeGame | Should -Be @('restored_map')
            $liveCustomMaps.OtherGame | Should -Be @('other_map')
        }

        It 'restores .cfg overrides from ServerFiles back onto Servers/<FolderName>' {
            $fakeRoot = New-FakeGSMRootForBackup -FolderName 'FakeGame' -WithConfig
            Mock -ModuleName Backup -CommandName Get-GSMRootPath -MockWith { $fakeRoot }

            $validConfigJson = '{"GameName":"FakeGame","AppID":"1"}'
            $backupPath = New-FakeGSMBackupZip -Root $fakeRoot -FolderName 'FakeGame' -ConfigJson $validConfigJson -ServerFiles @{ 'cfg/server.cfg' = 'sv_restored 1' } -Timestamp '20260101-000000'

            Restore-GSMBackup -FolderName 'FakeGame' -BackupPath $backupPath | Out-Null

            $restoredCfgPath = Join-Path $fakeRoot 'Servers/FakeGame/cfg/server.cfg'
            Test-Path -Path $restoredCfgPath | Should -Be $true
            (Get-Content -Path $restoredCfgPath -Raw).Trim() | Should -Be 'sv_restored 1'
        }

        It 'proceeds without a safety backup, with a warning, when there is no existing config to protect' {
            $fakeRoot = New-FakeGSMRootForBackup -FolderName 'FakeGame'
            Mock -ModuleName Backup -CommandName Get-GSMRootPath -MockWith { $fakeRoot }

            $validConfigJson = '{"GameName":"FakeGame","AppID":"1"}'
            $backupPath = New-FakeGSMBackupZip -Root $fakeRoot -FolderName 'FakeGame' -ConfigJson $validConfigJson -Timestamp '20260101-000000'

            $result = Restore-GSMBackup -FolderName 'FakeGame' -BackupPath $backupPath

            $result | Should -Be $true
            Test-Path -Path (Join-Path $fakeRoot 'Config/FakeGame.json') | Should -Be $true
            Should -Invoke -ModuleName Backup -CommandName Write-GSMLog -Times 1 -ParameterFilter { $Level -eq 'Warning' -and $Message -match 'without a safety backup' }

            # Only the one backup that was already on disk (the source of the
            # restore itself) - no safety backup was created.
            $backupsAfter = @(Get-GSMBackupList -FolderName 'FakeGame')
            $backupsAfter.Count | Should -Be 1
        }
    }
}
