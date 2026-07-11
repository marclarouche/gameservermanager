#Requires -Version 7.0
<#
.SYNOPSIS
    Insurgency (2014) install/update logic.
.DESCRIPTION
    Phase 1. Calls Core/SteamCMD.psm1 with this plugin's AppID (237410) to
    install and update the dedicated server.
.NOTES
    Functions to implement: Install-Insurgency2014Server.

    Workshop placement (Phase 5): Add-Insurgency2014WorkshopItem links a
    downloaded Workshop item into insurgency/addons/<WorkshopID> as a
    directory junction (New-Item -ItemType Junction) rather than a copy.
    Insurgency (2014) Workshop content is typically whole map packages that
    can run into the hundreds of megabytes, and junctions need no elevated
    privileges on NTFS (unlike symbolic links), so there's no reason to pay
    for a second copy on disk - the addons folder just needs an entry that
    resolves to SteamCMD's own downloaded copy under
    SteamCMD/steamapps/workshop/content/<AppID>/<WorkshopID>.
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../../Core/Utilities.psm1') -Force
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../../Core/Logging.psm1') -Force
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../../Core/SteamCMD.psm1') -Force

# This plugin's Steam dedicated server AppID (matches Plugin.json).
$script:Insurgency2014AppID = '237410'

function Install-Insurgency2014Server {
    <#
    .SYNOPSIS
        Installs or updates the Insurgency (2014) dedicated server.
    .DESCRIPTION
        Calls Core/SteamCMD.psm1's Update-SteamApp with this plugin's AppID
        (237410) and an install directory of Servers/Insurgency2014 under
        the repo root. Update-SteamApp's own app_update/validate call is
        idempotent, so this same function handles both the first install
        and later updates.
    .EXAMPLE
        Install-Insurgency2014Server
    .NOTES
        Throws if SteamCMD isn't installed yet (Update-SteamApp's own
        check) or if the steamcmd.exe process exits non-zero. Callers must
        run Install-SteamCMD first; this function does not install SteamCMD
        itself.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $installDirectory = Join-Path -Path (Get-GSMRootPath) -ChildPath 'Servers/Insurgency2014'

    try {
        Update-SteamApp -AppID $script:Insurgency2014AppID -InstallDirectory $installDirectory
    }
    catch {
        Write-GSMLog -Level Error -Message "Failed to install/update Insurgency (2014) server in '$installDirectory': $($_.Exception.Message)"
        throw
    }

    return $true
}

function Add-Insurgency2014WorkshopItem {
    <#
    .SYNOPSIS
        Places a downloaded Workshop item into the Insurgency (2014)
        server's addons folder.
    .DESCRIPTION
        Links ContentPath into
        Servers/Insurgency2014/insurgency/addons/<WorkshopID> as a
        directory junction (see this module's top-of-file .NOTES for why a
        junction rather than a copy). Any existing junction or folder at
        that destination is removed first, so re-adding the same
        WorkshopID (e.g. a manual refresh) always ends up pointing at the
        current content rather than layering on top of a stale one.
    .PARAMETER WorkshopID
        The numeric Steam Workshop item ID, e.g. '123456789'.
    .PARAMETER ContentPath
        Full path to the content SteamCMD already downloaded for this item.
    .EXAMPLE
        Add-Insurgency2014WorkshopItem -WorkshopID '123456789' -ContentPath 'D:\GSM\SteamCMD\steamapps\workshop\content\237410\123456789'
    .NOTES
        Called by Core/Workshop.psm1's Add-GSMWorkshopItem; not intended to
        be called directly against a server that isn't installed yet.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$WorkshopID,

        [Parameter(Mandatory)]
        [string]$ContentPath
    )

    if (-not (Test-Path -Path $ContentPath -PathType Container)) {
        throw "Workshop content path not found: '$ContentPath'."
    }

    $addonsDirectory = Join-Path -Path (Get-GSMRootPath) -ChildPath 'Servers/Insurgency2014/insurgency/addons'
    $destinationPath = Join-Path -Path $addonsDirectory -ChildPath $WorkshopID

    try {
        New-Item -ItemType Directory -Path $addonsDirectory -Force -ErrorAction Stop | Out-Null

        if (Test-Path -Path $destinationPath) {
            Remove-Item -Path $destinationPath -Recurse -Force -ErrorAction Stop
        }

        New-Item -ItemType Junction -Path $destinationPath -Target $ContentPath -ErrorAction Stop | Out-Null
    }
    catch {
        throw "Failed to place Workshop item '$WorkshopID' into '$destinationPath': $($_.Exception.Message)"
    }

    return $true
}

function Remove-Insurgency2014WorkshopItem {
    <#
    .SYNOPSIS
        Removes a placed Workshop item from the Insurgency (2014) server's
        addons folder.
    .DESCRIPTION
        Removes the junction (or folder) at
        Servers/Insurgency2014/insurgency/addons/<WorkshopID>, if present.
    .PARAMETER WorkshopID
        The numeric Steam Workshop item ID to remove, e.g. '123456789'.
    .EXAMPLE
        Remove-Insurgency2014WorkshopItem -WorkshopID '123456789'
    .NOTES
        A no-op (returns $true, logs at Info level) if nothing is placed at
        that path already - the item may have been removed manually, or
        never successfully placed. Called by Core/Workshop.psm1's
        Remove-GSMWorkshopItem.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$WorkshopID
    )

    $destinationPath = Join-Path -Path (Get-GSMRootPath) -ChildPath "Servers/Insurgency2014/insurgency/addons/$WorkshopID"

    if (-not (Test-Path -Path $destinationPath)) {
        Write-GSMLog -Level Info -Message "No placed content found for Workshop item '$WorkshopID' at '$destinationPath'; Remove-Insurgency2014WorkshopItem is a no-op."
        return $true
    }

    try {
        Remove-Item -Path $destinationPath -Recurse -Force -ErrorAction Stop
    }
    catch {
        throw "Failed to remove Workshop item '$WorkshopID' from '$destinationPath': $($_.Exception.Message)"
    }

    return $true
}

Export-ModuleMember -Function Install-Insurgency2014Server, Add-Insurgency2014WorkshopItem, Remove-Insurgency2014WorkshopItem
