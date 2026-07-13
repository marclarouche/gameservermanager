#Requires -Version 7.0
<#
.SYNOPSIS
    Config/state backup and restore for GSM server instances.
.DESCRIPTION
    Phase 3 (PRD section 9). Uses the built-in Compress-Archive/
    Expand-Archive cmdlets - no external dependency. Backs up config and
    state only: Config/<FolderName>.json, any per-server .cfg overrides
    under Servers/<FolderName>, and this instance's own slice of the
    shared Config/CustomMaps.json. Never backs up the full game install -
    SteamCMD can always reinstall that (PRD section 10, "Safe Updates:
    automatic backups before applying updates").

    Backups are written to Backups/<FolderName>-<yyyyMMdd-HHmmss>.zip. The
    task's original naming convention was
    "Backups/<PluginFolderName>-<InstanceName>-<timestamp>.zip"; GSM has no
    multi-instance-per-plugin concept (every plugin folder is exactly one
    server instance - see Core/Firewall.psm1's header for the same note),
    so InstanceName and PluginFolderName are the same value here and the
    duplicate segment is collapsed.
.NOTES
    Config/CustomMaps.json is shared across every plugin folder (keyed by
    FolderName - see its own contents). A backup snapshots only this
    instance's own key from it, and Restore-GSMBackup merges only that key
    back into the live file, never overwriting the whole thing: restoring
    FolderName-A must not roll back FolderName-B's custom maps to whatever
    they were at FolderName-A's backup time.
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Utilities.psm1')
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Logging.psm1')
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Config.psm1') -Force

# Default number of backups kept per instance when Config/<FolderName>.json
# omits BackupRetentionCount.
$script:GSMBackupDefaultRetentionCount = 5

function Get-GSMBackupRetentionCount {
    # Internal helper. Not exported: resolves FolderName's configured
    # BackupRetentionCount, defaulting to 5 when the instance's config is
    # missing, unreadable, or omits the field. Core/Config.psm1's
    # Test-GSMConfig validates the field's value when present; this only
    # reads it, the same division of responsibility as
    # Core/Service.psm1's Resolve-GSMServerProcessManagerMode.
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [string]$FolderName
    )

    $configPath = Join-Path -Path (Get-GSMRootPath) -ChildPath "Config/$FolderName.json"
    if (-not (Test-Path -Path $configPath -PathType Leaf)) {
        return $script:GSMBackupDefaultRetentionCount
    }

    try {
        $config = Get-GSMConfig -Path $configPath
    }
    catch {
        return $script:GSMBackupDefaultRetentionCount
    }

    $property = $config.PSObject.Properties['BackupRetentionCount']
    if ($null -eq $property -or -not $property.Value) {
        return $script:GSMBackupDefaultRetentionCount
    }

    return [int]$property.Value
}

function Get-GSMBackupList {
    <#
    .SYNOPSIS
        Lists a server instance's backups, newest first.
    .DESCRIPTION
        Scans Backups/ for files matching "<FolderName>-<yyyyMMdd-HHmmss>.zip"
        and returns one object per match (FolderName, Path, FileName,
        Timestamp, SizeBytes), sorted newest-first. This is a pure query -
        it never deletes anything; New-GSMBackup is what applies retention,
        using this function's own sorted output to decide what's beyond the
        configured count. Returns an empty array, not an error, when
        Backups/ doesn't exist or has no matches for FolderName.
    .PARAMETER FolderName
        The plugin's folder name under Plugins/ (e.g. 'Insurgency2014').
    .EXAMPLE
        Get-GSMBackupList -FolderName 'Insurgency2014'
    #>
    [CmdletBinding()]
    [OutputType([psobject[]])]
    param(
        [Parameter(Mandatory)]
        [string]$FolderName
    )

    $backups = [System.Collections.Generic.List[psobject]]::new()

    $backupsDirectory = Join-Path -Path (Get-GSMRootPath) -ChildPath 'Backups'
    if (-not (Test-Path -Path $backupsDirectory -PathType Container)) {
        return $backups.ToArray()
    }

    $namePattern = '^{0}-(\d{{8}}-\d{{6}})$' -f [regex]::Escape($FolderName)

    # Sorted here, on the FileInfo objects (BaseName's embedded timestamp
    # sorts lexicographically the same as chronologically), so the loop
    # below can build $backups already in newest-first order and return
    # $backups.ToArray() directly - piping the final PSCustomObject list
    # through Sort-Object right before returning is what made
    # PSScriptAnalyzer's PSUseOutputTypeCorrectly flag this function
    # against its declared [psobject[]] OutputType.
    $files = @(Get-ChildItem -Path $backupsDirectory -Filter "$FolderName-*.zip" -File -ErrorAction SilentlyContinue |
            Where-Object { $_.BaseName -match $namePattern } |
            Sort-Object -Property BaseName -Descending)

    foreach ($file in $files) {
        $null = $file.BaseName -match $namePattern
        $backups.Add([PSCustomObject]@{
                FolderName = $FolderName
                Path       = $file.FullName
                FileName   = $file.Name
                Timestamp  = $matches[1]
                SizeBytes  = $file.Length
            })
    }

    return $backups.ToArray()
}

function Remove-GSMOldBackups {
    # Internal helper. Not exported: prunes backups for FolderName beyond
    # its configured retention count, keeping the newest ones (per
    # Get-GSMBackupList's own newest-first sort). Called by New-GSMBackup
    # after each successful backup. A failure pruning one old backup is
    # logged as a warning and does not stop the rest from being pruned.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$FolderName
    )

    $retentionCount = Get-GSMBackupRetentionCount -FolderName $FolderName
    $backups = @(Get-GSMBackupList -FolderName $FolderName)

    if ($backups.Count -le $retentionCount) {
        return
    }

    $backupsToPrune = $backups | Select-Object -Skip $retentionCount

    foreach ($backup in $backupsToPrune) {
        try {
            Remove-Item -Path $backup.Path -Force -ErrorAction Stop
            Write-GSMLog -Level Info -Message "Pruned old backup '$($backup.Path)' for '$FolderName' (retention: $retentionCount)."
        }
        catch {
            Write-GSMLog -Level Warning -Message "Failed to prune old backup '$($backup.Path)' for '$FolderName': $($_.Exception.Message)"
        }
    }
}

function Get-GSMBackupCustomMapsSlice {
    # Internal helper. Not exported: reads Config/CustomMaps.json and
    # returns only FolderName's own entry as a single-key hashtable, ready
    # to serialize into a backup archive. Returns $null (nothing to back
    # up) if the shared file is missing, unreadable, or has no entry for
    # FolderName.
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$FolderName
    )

    $customMapsPath = Join-Path -Path (Get-GSMRootPath) -ChildPath 'Config/CustomMaps.json'
    if (-not (Test-Path -Path $customMapsPath -PathType Leaf)) {
        return $null
    }

    try {
        $customMaps = Get-Content -Path $customMapsPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Write-GSMLog -Level Warning -Message "Could not read '$customMapsPath' while backing up '$FolderName'; CustomMaps will be omitted from this backup: $($_.Exception.Message)"
        return $null
    }

    $property = $customMaps.PSObject.Properties[$FolderName]
    if (-not $property) {
        return $null
    }

    return @{ $FolderName = @($property.Value) }
}

function New-GSMBackup {
    <#
    .SYNOPSIS
        Backs up a server instance's config and state to a zip archive.
    .DESCRIPTION
        Stages Config/<FolderName>.json, this instance's own slice of
        Config/CustomMaps.json (if any), and any *.cfg files found
        recursively under Servers/<FolderName> (if any) into a temporary
        directory, then compresses it to
        Backups/<FolderName>-<yyyyMMdd-HHmmss>.zip via Compress-Archive.
        Prunes backups beyond the instance's configured retention count
        (BackupRetentionCount, default 5) afterward.
    .PARAMETER FolderName
        The plugin's folder name under Plugins/ (e.g. 'Insurgency2014').
    .EXAMPLE
        New-GSMBackup -FolderName 'Insurgency2014'
    .NOTES
        Throws if Config/<FolderName>.json doesn't exist (nothing to back
        up) or if Compress-Archive fails. Returns the full path to the
        created archive.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$FolderName
    )

    $rootPath = Get-GSMRootPath
    $configPath = Join-Path -Path $rootPath -ChildPath "Config/$FolderName.json"

    if (-not (Test-Path -Path $configPath -PathType Leaf)) {
        throw "No config found for '$FolderName' at '$configPath'. Nothing to back up."
    }

    $backupsDirectory = Join-Path -Path $rootPath -ChildPath 'Backups'
    New-Item -ItemType Directory -Path $backupsDirectory -Force -ErrorAction SilentlyContinue | Out-Null

    $timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $backupPath = Join-Path -Path $backupsDirectory -ChildPath "$FolderName-$timestamp.zip"

    $stagingDirectory = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "gsm-backup-staging-$([guid]::NewGuid().ToString('N'))"

    try {
        $stagingConfigDirectory = Join-Path -Path $stagingDirectory -ChildPath 'Config'
        New-Item -ItemType Directory -Path $stagingConfigDirectory -Force | Out-Null

        try {
            Copy-Item -Path $configPath -Destination (Join-Path -Path $stagingConfigDirectory -ChildPath "$FolderName.json") -ErrorAction Stop
        }
        catch {
            throw "Failed to stage config for '$FolderName' backup: $($_.Exception.Message)"
        }

        $customMapsSlice = Get-GSMBackupCustomMapsSlice -FolderName $FolderName
        if ($customMapsSlice) {
            $customMapsSlice | ConvertTo-Json | Set-Content -Path (Join-Path -Path $stagingConfigDirectory -ChildPath 'CustomMaps.json')
        }

        # Any per-server .cfg overrides. None exist in this repo today (no
        # plugin writes them yet), but this is recursive and
        # forward-compatible: a future plugin's server.cfg/admins.cfg, or a
        # manually-placed one, is picked up automatically.
        $serverDirectory = Join-Path -Path $rootPath -ChildPath "Servers/$FolderName"
        if (Test-Path -Path $serverDirectory -PathType Container) {
            $cfgFiles = @(Get-ChildItem -Path $serverDirectory -Filter '*.cfg' -Recurse -File -ErrorAction SilentlyContinue)
            if ($cfgFiles.Count -gt 0) {
                $stagingServerFilesDirectory = Join-Path -Path $stagingDirectory -ChildPath 'ServerFiles'
                foreach ($cfgFile in $cfgFiles) {
                    $relativePath = $cfgFile.FullName.Substring($serverDirectory.Length).TrimStart('\', '/')
                    $destinationPath = Join-Path -Path $stagingServerFilesDirectory -ChildPath $relativePath
                    New-Item -ItemType Directory -Path (Split-Path -Path $destinationPath -Parent) -Force -ErrorAction SilentlyContinue | Out-Null
                    Copy-Item -Path $cfgFile.FullName -Destination $destinationPath -ErrorAction Stop
                }
            }
        }

        try {
            Compress-Archive -Path (Join-Path -Path $stagingDirectory -ChildPath '*') -DestinationPath $backupPath -Force -ErrorAction Stop
        }
        catch {
            Write-GSMLog -Level Error -Message "Failed to create backup archive '$backupPath' for '$FolderName': $($_.Exception.Message)"
            throw "Failed to create backup archive for '$FolderName': $($_.Exception.Message)"
        }
    }
    finally {
        Remove-Item -Path $stagingDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-GSMLog -Level Info -Message "Created backup '$backupPath' for '$FolderName'."

    Remove-GSMOldBackups -FolderName $FolderName

    return $backupPath
}

function Merge-GSMRestoredCustomMaps {
    # Internal helper. Not exported: merges only FolderName's own key from a
    # restored CustomMaps.json snapshot into the live, shared
    # Config/CustomMaps.json. Never overwrites the whole live file - see
    # this module's header .NOTES for why. Failures here are logged as
    # warnings, not fatal: the config validation gate is what
    # Restore-GSMBackup's fail-closed guarantee is about, and CustomMaps is
    # supplementary.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$FolderName,

        [Parameter(Mandatory)]
        [string]$ExtractedCustomMapsPath
    )

    try {
        $restoredSnapshot = Get-Content -Path $ExtractedCustomMapsPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Write-GSMLog -Level Warning -Message "Restored CustomMaps snapshot for '$FolderName' could not be read and was skipped: $($_.Exception.Message)"
        return
    }

    $property = $restoredSnapshot.PSObject.Properties[$FolderName]
    if (-not $property) {
        return
    }
    $restoredMaps = @($property.Value)

    $liveCustomMapsPath = Join-Path -Path (Get-GSMRootPath) -ChildPath 'Config/CustomMaps.json'
    $liveCustomMaps = [ordered]@{}

    if (Test-Path -Path $liveCustomMapsPath -PathType Leaf) {
        try {
            $existing = Get-Content -Path $liveCustomMapsPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            foreach ($existingProperty in $existing.PSObject.Properties) {
                $liveCustomMaps[$existingProperty.Name] = @($existingProperty.Value)
            }
        }
        catch {
            Write-GSMLog -Level Warning -Message "Live CustomMaps.json could not be read while restoring '$FolderName'; it will be written with only this instance's restored entry: $($_.Exception.Message)"
        }
    }

    $liveCustomMaps[$FolderName] = $restoredMaps

    try {
        $liveCustomMaps | ConvertTo-Json | Set-Content -Path $liveCustomMapsPath -ErrorAction Stop
    }
    catch {
        Write-GSMLog -Level Warning -Message "Failed to write merged CustomMaps.json while restoring '$FolderName': $($_.Exception.Message)"
    }
}

function Restore-GSMBackup {
    <#
    .SYNOPSIS
        Restores a server instance's config and state from a backup
        archive.
    .DESCRIPTION
        Takes a fresh safety backup of the instance's current live config
        first (via New-GSMBackup), so a bad restore is itself reversible -
        skipped with a logged warning, not an error, if there is no live
        config yet to back up (e.g. restoring into an instance whose
        config was deleted). Extracts BackupPath to a temporary directory,
        validates the extracted Config/<FolderName>.json via
        Core/Config.psm1's Get-GSMConfig (which runs the same
        Test-GSMConfig validation Get-/Set-GSMConfig always do) before
        applying anything live. Fails closed: if the restored config
        doesn't validate, or the backup has no config for FolderName at
        all, nothing is applied and the safety backup is left in place.
        Once the config is applied, merges back this instance's slice of
        CustomMaps.json (if the backup has one) and copies back any
        *.cfg overrides (if any) - both best-effort, logged on failure
        rather than failing the whole restore, since the config validation
        gate above is what "restore complete" actually depends on.
    .PARAMETER FolderName
        The plugin's folder name under Plugins/ (e.g. 'Insurgency2014').
    .PARAMETER BackupPath
        Full path to the backup .zip to restore from (e.g. from
        Get-GSMBackupList's Path property).
    .EXAMPLE
        Restore-GSMBackup -FolderName 'Insurgency2014' -BackupPath 'D:\GSM\Backups\Insurgency2014-20260708-040000.zip'
    .NOTES
        Throws (without applying anything) if BackupPath doesn't exist,
        the archive can't be extracted, it has no config for FolderName, or
        the extracted config fails validation. Returns $true on success.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$FolderName,

        [Parameter(Mandatory)]
        [string]$BackupPath
    )

    if (-not (Test-Path -Path $BackupPath -PathType Leaf)) {
        throw "Backup file not found: $BackupPath"
    }

    $rootPath = Get-GSMRootPath
    $liveConfigPath = Join-Path -Path $rootPath -ChildPath "Config/$FolderName.json"

    $safetyBackupPath = $null
    if (Test-Path -Path $liveConfigPath -PathType Leaf) {
        Write-GSMLog -Level Info -Message "Taking a safety backup of '$FolderName' before restoring from '$BackupPath'."
        $safetyBackupPath = New-GSMBackup -FolderName $FolderName
    }
    else {
        Write-GSMLog -Level Warning -Message "No existing config for '$FolderName'; proceeding with restore from '$BackupPath' without a safety backup."
    }

    $tempExtractDirectory = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "gsm-restore-$([guid]::NewGuid().ToString('N'))"

    try {
        try {
            Expand-Archive -Path $BackupPath -DestinationPath $tempExtractDirectory -Force -ErrorAction Stop
        }
        catch {
            throw "Failed to extract backup '$BackupPath': $($_.Exception.Message)"
        }

        $extractedConfigPath = Join-Path -Path $tempExtractDirectory -ChildPath "Config/$FolderName.json"
        if (-not (Test-Path -Path $extractedConfigPath -PathType Leaf)) {
            throw "Backup '$BackupPath' does not contain a config for '$FolderName' (expected 'Config/$FolderName.json'). Restore aborted; nothing was applied$(if ($safetyBackupPath) { ". Safety backup preserved at '$safetyBackupPath'." } else { '.' })"
        }

        try {
            Get-GSMConfig -Path $extractedConfigPath | Out-Null
        }
        catch {
            throw "Restored config from '$BackupPath' failed validation; nothing was applied$(if ($safetyBackupPath) { ". Safety backup preserved at '$safetyBackupPath'." } else { '.' }) Validation error: $($_.Exception.Message)"
        }

        try {
            Copy-Item -Path $extractedConfigPath -Destination $liveConfigPath -Force -ErrorAction Stop
        }
        catch {
            throw "Failed to apply restored config for '$FolderName': $($_.Exception.Message)$(if ($safetyBackupPath) { " Safety backup preserved at '$safetyBackupPath'." } else { '' })"
        }

        $extractedCustomMapsPath = Join-Path -Path $tempExtractDirectory -ChildPath 'Config/CustomMaps.json'
        if (Test-Path -Path $extractedCustomMapsPath -PathType Leaf) {
            Merge-GSMRestoredCustomMaps -FolderName $FolderName -ExtractedCustomMapsPath $extractedCustomMapsPath
        }

        $extractedServerFilesDirectory = Join-Path -Path $tempExtractDirectory -ChildPath 'ServerFiles'
        if (Test-Path -Path $extractedServerFilesDirectory -PathType Container) {
            $liveServerDirectory = Join-Path -Path $rootPath -ChildPath "Servers/$FolderName"
            $cfgFiles = @(Get-ChildItem -Path $extractedServerFilesDirectory -Recurse -File -ErrorAction SilentlyContinue)
            foreach ($cfgFile in $cfgFiles) {
                $relativePath = $cfgFile.FullName.Substring($extractedServerFilesDirectory.Length).TrimStart('\', '/')
                $destinationPath = Join-Path -Path $liveServerDirectory -ChildPath $relativePath
                try {
                    New-Item -ItemType Directory -Path (Split-Path -Path $destinationPath -Parent) -Force -ErrorAction Stop | Out-Null
                    Copy-Item -Path $cfgFile.FullName -Destination $destinationPath -Force -ErrorAction Stop
                }
                catch {
                    Write-GSMLog -Level Warning -Message "Failed to restore server file '$relativePath' for '$FolderName': $($_.Exception.Message)"
                }
            }
        }
    }
    finally {
        Remove-Item -Path $tempExtractDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-GSMLog -Level Info -Message "Restored '$FolderName' from backup '$BackupPath'.$(if ($safetyBackupPath) { " Safety backup of the pre-restore state is at '$safetyBackupPath'." })"

    return $true
}

Export-ModuleMember -Function New-GSMBackup, Restore-GSMBackup, Get-GSMBackupList
