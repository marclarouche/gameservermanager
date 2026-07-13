#Requires -Version 7.0
<#
.SYNOPSIS
    SteamCMD install and update wrapper.
.DESCRIPTION
    Phase 1. Downloads and installs SteamCMD if missing, and runs app
    install/update commands on behalf of plugins. Verifies SHA-256 of the
    downloaded SteamCMD installer per PRD section 10.
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Utilities.psm1')
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Logging.psm1')

function Test-SteamCMDPresent {
    <#
    .SYNOPSIS
        Checks whether SteamCMD is already installed.
    .DESCRIPTION
        Returns whether SteamCMD/steamcmd.exe exists under the repo root,
        resolved via Get-GSMRootPath.
    .EXAMPLE
        if (-not (Test-SteamCMDPresent)) { Install-SteamCMD }
    .NOTES
        Only checks for the executable's presence; it does not verify its
        hash. Hash verification only happens at install time, in
        Install-SteamCMD.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $steamCmdExePath = Join-Path -Path (Get-GSMRootPath) -ChildPath 'SteamCMD/steamcmd.exe'
    return (Test-Path -Path $steamCmdExePath -PathType Leaf)
}

function Install-SteamCMD {
    <#
    .SYNOPSIS
        Downloads, verifies, and installs SteamCMD.
    .DESCRIPTION
        No-ops and returns $true if SteamCMD/steamcmd.exe already exists and
        Force isn't specified. Otherwise reads Config/SteamCMD.json for the
        installer URL and pinned hash, downloads the installer zip to a temp
        location, extracts it to SteamCMD/, and verifies the extracted
        steamcmd.exe's SHA-256 against the pinned value. On a mismatch, the
        newly extracted files are removed and the function throws rather
        than leaving a partial or unverified install in place.
    .PARAMETER Force
        Re-download and reinstall even if SteamCMD/steamcmd.exe already
        exists.
    .EXAMPLE
        Install-SteamCMD
    .NOTES
        Reads Config/SteamCMD.json directly (Get-Content + ConvertFrom-Json)
        rather than via Core/Config.psm1's Get-GSMConfig: that function's
        validation requires GameName and AppID fields, which belong to
        per-game plugin configs, not this installer metadata file. Using it
        here would make every read of Config/SteamCMD.json throw.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()]
        [switch]$Force
    )

    if ((Test-SteamCMDPresent) -and -not $Force) {
        return $true
    }

    $rootPath = Get-GSMRootPath
    $configPath = Join-Path -Path $rootPath -ChildPath 'Config/SteamCMD.json'

    try {
        $rawConfig = Get-Content -Path $configPath -Raw -ErrorAction Stop
        $config = $rawConfig | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Failed to read SteamCMD config '$configPath': $($_.Exception.Message)"
    }

    $steamCmdDirectory = Join-Path -Path $rootPath -ChildPath 'SteamCMD'
    $tempZipPath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "steamcmd-$([guid]::NewGuid().ToString('N')).zip"

    $filesBeforeExtract = @()
    if (Test-Path -Path $steamCmdDirectory -PathType Container) {
        $filesBeforeExtract = @(Get-ChildItem -Path $steamCmdDirectory -Recurse -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
    }

    try {
        try {
            Invoke-WebRequest -Uri $config.InstallerUrl -OutFile $tempZipPath -ErrorAction Stop
        }
        catch {
            throw "Failed to download SteamCMD installer from '$($config.InstallerUrl)': $($_.Exception.Message)"
        }

        try {
            Expand-Archive -Path $tempZipPath -DestinationPath $steamCmdDirectory -Force -ErrorAction Stop
        }
        catch {
            throw "Failed to extract SteamCMD installer to '$steamCmdDirectory': $($_.Exception.Message)"
        }

        $extractedFiles = @(Get-ChildItem -Path $steamCmdDirectory -Recurse -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
        $newFiles = @($extractedFiles | Where-Object { $_ -notin $filesBeforeExtract })

        $steamCmdExePath = Join-Path -Path $steamCmdDirectory -ChildPath 'steamcmd.exe'
        $actualHash = Get-FileHashSHA256 -Path $steamCmdExePath

        if ($actualHash -ne $config.PinnedSHA256) {
            foreach ($file in $newFiles) {
                Remove-Item -Path $file -Force -ErrorAction SilentlyContinue
            }

            Write-GSMLog -Level Error -Message "SteamCMD installer hash mismatch. Expected '$($config.PinnedSHA256)', got '$actualHash'. Extracted files removed."
            throw "SteamCMD installer failed hash verification. Expected '$($config.PinnedSHA256)', got '$actualHash'."
        }

        return $true
    }
    finally {
        Remove-Item -Path $tempZipPath -Force -ErrorAction SilentlyContinue
    }
}

function Update-SteamApp {
    <#
    .SYNOPSIS
        Installs or updates a Steam dedicated server app via SteamCMD.
    .DESCRIPTION
        Runs steamcmd.exe with an anonymous login, a forced install
        directory, and app_update/validate for AppID, then quits.
    .PARAMETER AppID
        The Steam AppID of the dedicated server to install or update.
    .PARAMETER InstallDirectory
        Directory to install or update the app into.
    .EXAMPLE
        Update-SteamApp -AppID '237410' -InstallDirectory 'D:\GSM\Servers\Insurgency2014'
    .NOTES
        Throws if SteamCMD/steamcmd.exe isn't present; it does not call
        Install-SteamCMD itself, callers must install SteamCMD first. Steam's
        own manifest validation covers file integrity for the installed app;
        only the SteamCMD installer itself is hash-pinned (Install-SteamCMD).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$AppID,

        [Parameter(Mandatory)]
        [string]$InstallDirectory
    )

    if (-not (Test-SteamCMDPresent)) {
        throw 'SteamCMD is not installed. Run Install-SteamCMD first.'
    }

    $steamCmdExePath = Join-Path -Path (Get-GSMRootPath) -ChildPath 'SteamCMD/steamcmd.exe'

    $arguments = @(
        '+login', 'anonymous',
        '+force_install_dir', $InstallDirectory,
        '+app_update', $AppID, 'validate',
        '+quit'
    )

    try {
        $process = Start-Process -FilePath $steamCmdExePath -ArgumentList $arguments -Wait -NoNewWindow -PassThru -ErrorAction Stop

        if ($process.ExitCode -ne 0) {
            throw "steamcmd.exe exited with code $($process.ExitCode) while updating AppID '$AppID'."
        }
    }
    catch {
        Write-GSMLog -Level Error -Message "Failed to update AppID '$AppID' in '$InstallDirectory': $($_.Exception.Message)"
        throw
    }
}

Export-ModuleMember -Function Test-SteamCMDPresent, Install-SteamCMD, Update-SteamApp
