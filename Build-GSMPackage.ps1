#Requires -Version 7.0
<#
.SYNOPSIS
    Builds a distributable GSM release package.
.DESCRIPTION
    Phase 6 (Workstream B, PRD section 9). Reads the version string from
    VERSION, stages a clean copy of the files needed to run GSM on a fresh
    machine into a temporary directory, and compresses it to
    Build/GameServerManager-v<version>.zip via Compress-Archive.

    Included: GSM.ps1, Core/, Plugins/, README.md, CHANGELOG.md, LICENSE,
    VERSION, plus Config/SteamCMD.json and Config/NSSM.json - tracked seed
    data (see this repo's .gitignore carve-outs for those two files) that
    Install-SteamCMD and Install-NSSM both require to bootstrap those tools
    on a fresh install, unlike per-instance Config/<FolderName>.json files,
    which don't exist until a user runs the Configure action and are never
    shipped. Tools/NSSM/ is bundled if already present on the machine
    building the package (avoids a network fetch on first install) but is
    optional: Core/Service.psm1's Install-GSMServerService calls Install-NSSM
    itself if Tools/NSSM/nssm.exe is missing, so its absence from the
    package is not an error.

    Config/, Logs/, Reports/, Backups/, and SteamCMD/ otherwise ship as
    empty directories (a .gitkeep placeholder, so they survive
    Compress-Archive, which omits empty directories) - never their live
    dev-machine contents (per-instance configs, logs, backups, or the
    installed SteamCMD binary itself).

    Tests/, .git/, Docs/, and .claude/ are excluded by omission: this
    script copies a fixed, named list of items rather than the whole repo
    tree, so anything not on that list is never staged.
.EXAMPLE
    ./Build-GSMPackage.ps1
    Builds Build/GameServerManager-v0.4.0-alpha.zip from the current repo
    state.
.NOTES
    Does not implement -WhatIf/ShouldProcess: matches this repo's existing
    accepted PSUseShouldProcessForStateChangingFunctions exemption (see
    Tests/ServiceAccount.Tests.ps1's header comment) rather than adding
    boilerplate with no real safety benefit for a script whose only writes
    are to a temp staging directory and Build/.
#>
[CmdletBinding()]
[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'CLI build script; manifest/summary output is direct user-facing display, not pipeline data. Matches the same justification used for Show-MainMenu in Core/Menu.psm1 and Tests/Run-AllTests.ps1.')]
param()

Set-StrictMode -Version Latest


Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Core/Utilities.psm1')
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Core/Logging.psm1')

function Get-GSMPackageVersion {
    # Internal helper (script-scoped, not exported - this is a script, not a
    # module): reads and validates VERSION.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$RootPath
    )

    $versionPath = Join-Path -Path $RootPath -ChildPath 'VERSION'
    if (-not (Test-Path -Path $versionPath -PathType Leaf)) {
        throw "VERSION file not found at '$versionPath'."
    }

    try {
        $version = (Get-Content -Path $versionPath -Raw -ErrorAction Stop).Trim()
    }
    catch {
        throw "Failed to read VERSION file '$versionPath': $($_.Exception.Message)"
    }

    if ([string]::IsNullOrWhiteSpace($version) -or $version -notmatch '^\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?$') {
        throw "VERSION file contents '$version' is not a valid semantic version (expected e.g. '1.0.0' or '0.4.0-alpha')."
    }

    return $version
}

function Copy-GSMPackageItem {
    # Internal helper. Not exported: copies one required top-level file or
    # directory from the repo root into the staging directory, recording it
    # for the manifest. Throws if the source doesn't exist - every caller of
    # this function passes an item this package cannot function without.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RootPath,

        [Parameter(Mandatory)]
        [string]$StagingPath,

        [Parameter(Mandatory)]
        [string]$RelativePath,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[psobject]]$Manifest
    )

    $sourcePath = Join-Path -Path $RootPath -ChildPath $RelativePath
    $destinationPath = Join-Path -Path $StagingPath -ChildPath $RelativePath

    if (Test-Path -Path $sourcePath -PathType Container) {
        New-Item -ItemType Directory -Path (Split-Path -Path $destinationPath -Parent) -Force -ErrorAction Stop | Out-Null
        Copy-Item -Path $sourcePath -Destination $destinationPath -Recurse -Force -ErrorAction Stop
        $fileCount = (Get-ChildItem -Path $sourcePath -Recurse -File -ErrorAction SilentlyContinue | Measure-Object).Count
        $Manifest.Add([PSCustomObject]@{ Item = $RelativePath; Type = 'Folder'; Detail = "$fileCount file(s)" })
    }
    elseif (Test-Path -Path $sourcePath -PathType Leaf) {
        New-Item -ItemType Directory -Path (Split-Path -Path $destinationPath -Parent) -Force -ErrorAction Stop | Out-Null
        Copy-Item -Path $sourcePath -Destination $destinationPath -Force -ErrorAction Stop
        $Manifest.Add([PSCustomObject]@{ Item = $RelativePath; Type = 'File'; Detail = '{0:N0} bytes' -f (Get-Item -Path $sourcePath).Length })
    }
    else {
        throw "Required package item '$RelativePath' not found at '$sourcePath'."
    }
}

function Copy-GSMOptionalPackageFolder {
    # Internal helper. Not exported: bundles Tools/NSSM/ into the package
    # only if it already exists on the machine building the package. Its
    # absence is not an error - see this script's own .DESCRIPTION for why.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RootPath,

        [Parameter(Mandatory)]
        [string]$StagingPath,

        [Parameter(Mandatory)]
        [string]$RelativePath,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[psobject]]$Manifest
    )

    $sourcePath = Join-Path -Path $RootPath -ChildPath $RelativePath

    if (-not (Test-Path -Path $sourcePath -PathType Container)) {
        $Manifest.Add([PSCustomObject]@{ Item = $RelativePath; Type = 'Folder (skipped)'; Detail = 'not present locally; downloaded on first use' })
        return
    }

    Copy-GSMPackageItem -RootPath $RootPath -StagingPath $StagingPath -RelativePath $RelativePath -Manifest $Manifest
}

function New-GSMPackagePlaceholderFolder {
    # Internal helper. Not exported: creates an empty runtime folder in the
    # staging directory with a .gitkeep placeholder, so it survives
    # Compress-Archive (which omits empty directories) without shipping any
    # live dev-machine contents (logs, backups, installed binaries, etc.).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$StagingPath,

        [Parameter(Mandatory)]
        [string]$RelativePath,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[psobject]]$Manifest
    )

    $destinationPath = Join-Path -Path $StagingPath -ChildPath $RelativePath
    New-Item -ItemType Directory -Path $destinationPath -Force -ErrorAction Stop | Out-Null
    New-Item -ItemType File -Path (Join-Path -Path $destinationPath -ChildPath '.gitkeep') -Force -ErrorAction Stop | Out-Null

    $Manifest.Add([PSCustomObject]@{ Item = $RelativePath; Type = 'Folder (empty)'; Detail = 'placeholder only' })
}

function Write-GSMPackageManifest {
    # Internal helper. Not exported: prints a readable manifest table plus
    # the final zip path and size, so a bad include/exclude list is obvious
    # immediately rather than discovered on install.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[psobject]]$Manifest,

        [Parameter(Mandatory)]
        [string]$ZipPath,

        [Parameter(Mandatory)]
        [string]$Version
    )

    Write-Host ''
    Write-Host "GSM package manifest (v$Version):" -ForegroundColor Cyan
    $Manifest | Format-Table -Property Item, Type, Detail -AutoSize | Out-String | Write-Host

    $zipSizeBytes = (Get-Item -Path $ZipPath).Length
    $zipSizeMB = [math]::Round($zipSizeBytes / 1MB, 2)
    Write-Host "Package: $ZipPath ($zipSizeMB MB)" -ForegroundColor Green
}

function Invoke-GSMPackageBuild {
    # Not exported (script-scoped): the actual build sequence, factored out
    # of this script's top level so Tests/Build-GSMPackage.Tests.ps1 can dot-
    # source this file to reach the functions above without also running a
    # real build against this repo's own tree - see the invocation guard at
    # the bottom of this file.
    [CmdletBinding()]
    param()

    $rootPath = Get-GSMRootPath
    $version = Get-GSMPackageVersion -RootPath $rootPath

    $buildDirectory = Join-Path -Path $rootPath -ChildPath 'Build'
    New-Item -ItemType Directory -Path $buildDirectory -Force -ErrorAction SilentlyContinue | Out-Null

    $zipPath = Join-Path -Path $buildDirectory -ChildPath "GameServerManager-v$version.zip"
    $stagingDirectory = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "gsm-package-staging-$([guid]::NewGuid().ToString('N'))"

    $manifest = [System.Collections.Generic.List[psobject]]::new()

    try {
        New-Item -ItemType Directory -Path $stagingDirectory -Force -ErrorAction Stop | Out-Null

        $filesToCopy = @('GSM.ps1', 'README.md', 'CHANGELOG.md', 'LICENSE', 'VERSION')
        foreach ($file in $filesToCopy) {
            Copy-GSMPackageItem -RootPath $rootPath -StagingPath $stagingDirectory -RelativePath $file -Manifest $manifest
        }

        $foldersToCopy = @('Core', 'Plugins')
        foreach ($folder in $foldersToCopy) {
            Copy-GSMPackageItem -RootPath $rootPath -StagingPath $stagingDirectory -RelativePath $folder -Manifest $manifest
        }

        Copy-GSMOptionalPackageFolder -RootPath $rootPath -StagingPath $stagingDirectory -RelativePath 'Tools/NSSM' -Manifest $manifest

        New-Item -ItemType Directory -Path (Join-Path -Path $stagingDirectory -ChildPath 'Config') -Force -ErrorAction Stop | Out-Null
        foreach ($seedFile in @('Config/SteamCMD.json', 'Config/NSSM.json')) {
            Copy-GSMPackageItem -RootPath $rootPath -StagingPath $stagingDirectory -RelativePath $seedFile -Manifest $manifest
        }
        New-Item -ItemType File -Path (Join-Path -Path $stagingDirectory -ChildPath 'Config/.gitkeep') -Force -ErrorAction Stop | Out-Null

        $emptyFolders = @('Logs', 'Reports', 'Backups', 'SteamCMD')
        foreach ($folder in $emptyFolders) {
            New-GSMPackagePlaceholderFolder -StagingPath $stagingDirectory -RelativePath $folder -Manifest $manifest
        }

        try {
            Compress-Archive -Path (Join-Path -Path $stagingDirectory -ChildPath '*') -DestinationPath $zipPath -Force -ErrorAction Stop
        }
        catch {
            throw "Failed to create package archive '$zipPath': $($_.Exception.Message)"
        }
    }
    finally {
        Remove-Item -Path $stagingDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-GSMLog -Level Info -Message "Built package '$zipPath' for version $version."
    Write-GSMPackageManifest -Manifest $manifest -ZipPath $zipPath -Version $version
}

# Dot-sourcing this file (as Tests/Build-GSMPackage.Tests.ps1 does) sets
# InvocationName to '.', which skips the real build - the same guard idiom
# Tests/Run-AllTests.ps1's own header describes for its own different
# process-isolation reason.
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-GSMPackageBuild
}
