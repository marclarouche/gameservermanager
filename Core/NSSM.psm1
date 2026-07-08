#Requires -Version 7.0
<#
.SYNOPSIS
    NSSM (the Non-Sucking Service Manager) binary bundling and verification.
.DESCRIPTION
    Phase 2. Downloads and installs the pinned NSSM build if missing.
    Verifies the SHA-256 of the downloaded build's 64-bit nssm.exe against
    Config/NSSM.json before it is ever placed at Tools/NSSM/nssm.exe, so
    Core/Service.psm1 can rely on Tools/NSSM/nssm.exe being exactly the
    pinned, verified binary. Mirrors Core/SteamCMD.psm1's
    download/hash-verify/extract pattern.
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Utilities.psm1') -Force
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Logging.psm1') -Force

function Test-NSSMPresent {
    <#
    .SYNOPSIS
        Checks whether NSSM is already installed.
    .DESCRIPTION
        Returns whether Tools/NSSM/nssm.exe exists under the repo root,
        resolved via Get-GSMRootPath.
    .EXAMPLE
        if (-not (Test-NSSMPresent)) { Install-NSSM }
    .NOTES
        Only checks for the executable's presence; it does not verify its
        hash. Hash verification only happens at install time, in
        Install-NSSM.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $nssmExePath = Join-Path -Path (Get-GSMRootPath) -ChildPath 'Tools/NSSM/nssm.exe'
    return (Test-Path -Path $nssmExePath -PathType Leaf)
}

function Install-NSSM {
    <#
    .SYNOPSIS
        Downloads, verifies, and installs NSSM.
    .DESCRIPTION
        No-ops and returns $true if Tools/NSSM/nssm.exe already exists and
        Force isn't specified. Otherwise reads Config/NSSM.json for the
        download URL, the archive-relative path of the pinned build
        (PinnedFile, e.g. 'win64/nssm.exe'), and the pinned hash. Downloads
        the release zip to a temp file and extracts it to a separate temp
        directory - NSSM's release zip nests both win32/ and win64/ builds
        under a version-named top folder (e.g.
        nssm-2.24-101-g897c7ad\win64\nssm.exe), unlike SteamCMD's flat zip,
        so extraction can't go straight to the final Tools/NSSM/ location.
        Locates the pinned build inside the extracted tree, verifies its
        SHA-256 against the pinned value, and only then copies that single
        file to Tools/NSSM/nssm.exe. On a mismatch or a missing pinned file,
        nothing is ever written to Tools/NSSM/ and the function throws
        rather than leaving a partial or unverified install in place.
    .PARAMETER Force
        Re-download and reinstall even if Tools/NSSM/nssm.exe already
        exists.
    .EXAMPLE
        Install-NSSM
    .NOTES
        Reads Config/NSSM.json directly (Get-Content + ConvertFrom-Json)
        rather than via Core/Config.psm1's Get-GSMConfig, for the same
        reason Install-SteamCMD does: that function's schema validation is
        for per-game plugin configs, not installer metadata files.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()]
        [switch]$Force
    )

    if ((Test-NSSMPresent) -and -not $Force) {
        return $true
    }

    $rootPath = Get-GSMRootPath
    $configPath = Join-Path -Path $rootPath -ChildPath 'Config/NSSM.json'

    try {
        $rawConfig = Get-Content -Path $configPath -Raw -ErrorAction Stop
        $config = $rawConfig | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Failed to read NSSM config '$configPath': $($_.Exception.Message)"
    }

    $nssmDirectory = Join-Path -Path $rootPath -ChildPath 'Tools/NSSM'
    $nssmExePath = Join-Path -Path $nssmDirectory -ChildPath 'nssm.exe'
    $tempZipPath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "nssm-$([guid]::NewGuid().ToString('N')).zip"
    $tempExtractPath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "nssm-extract-$([guid]::NewGuid().ToString('N'))"

    try {
        try {
            Invoke-WebRequest -Uri $config.InstallerUrl -OutFile $tempZipPath -ErrorAction Stop
        }
        catch {
            throw "Failed to download NSSM from '$($config.InstallerUrl)': $($_.Exception.Message)"
        }

        try {
            Expand-Archive -Path $tempZipPath -DestinationPath $tempExtractPath -Force -ErrorAction Stop
        }
        catch {
            throw "Failed to extract NSSM archive to '$tempExtractPath': $($_.Exception.Message)"
        }

        # The archive nests win32/win64 builds under a version-named top
        # folder, so the pinned file is located by matching the end of its
        # full path against PinnedFile (e.g. 'win64/nssm.exe') rather than
        # a fixed path.
        $pinnedFileSuffix = $config.PinnedFile -replace '/', '\'
        $extractedExe = Get-ChildItem -Path $tempExtractPath -Recurse -Filter 'nssm.exe' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName.EndsWith($pinnedFileSuffix, [System.StringComparison]::OrdinalIgnoreCase) } |
            Select-Object -First 1

        if (-not $extractedExe) {
            throw "Could not find pinned file '$($config.PinnedFile)' in the extracted NSSM archive."
        }

        $actualHash = Get-FileHashSHA256 -Path $extractedExe.FullName

        if ($actualHash -ne $config.PinnedSHA256) {
            Write-GSMLog -Level Error -Message "NSSM hash mismatch for '$($config.PinnedFile)'. Expected '$($config.PinnedSHA256)', got '$actualHash'. Nothing installed."
            throw "NSSM failed hash verification. Expected '$($config.PinnedSHA256)', got '$actualHash'."
        }

        New-Item -ItemType Directory -Path $nssmDirectory -Force | Out-Null
        Copy-Item -Path $extractedExe.FullName -Destination $nssmExePath -Force -ErrorAction Stop

        return $true
    }
    finally {
        Remove-Item -Path $tempZipPath -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $tempExtractPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember -Function Test-NSSMPresent, Install-NSSM
