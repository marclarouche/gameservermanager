#Requires -Version 7.0
<#
.SYNOPSIS
    Left 4 Dead 2 install/update logic.
.DESCRIPTION
    Phase 1. Calls Core/SteamCMD.psm1 with this plugin's AppID (222860) to
    install and update the dedicated server.
.NOTES
    Functions implemented: Install-L4D2Server.

    Workshop placement (Phase 5): Add-L4D2WorkshopItem copies (not links) a
    downloaded Workshop item into left4dead2/addons/<WorkshopID>. L4D2
    Workshop content (campaigns, skins, gameplay mods) is VPK-packed and
    mounted straight out of left4dead2/addons the same way Team Fortress 2
    reads tf/custom, so this follows the identical copy-not-junction
    reasoning documented in TeamFortress2's Install.psm1 - compatibility
    over disk savings for VPK-based addon content.
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../../Core/Utilities.psm1')
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../../Core/Logging.psm1')
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../../Core/SteamCMD.psm1') -Force

# This plugin's Steam dedicated server AppID (matches Plugin.json).
$script:L4D2AppID = '222860'

function Install-L4D2Server {
    <#
    .SYNOPSIS
        Installs or updates the Left 4 Dead 2 dedicated server.
    .DESCRIPTION
        Calls Core/SteamCMD.psm1's Update-SteamApp with this plugin's AppID
        (222860) and an install directory of Servers/L4D2 under the repo
        root. Update-SteamApp's own app_update/validate call is idempotent,
        so this same function handles both the first install and later
        updates.
    .EXAMPLE
        Install-L4D2Server
    .NOTES
        Bootstraps SteamCMD first if it isn't already present (via
        Test-SteamCMDPresent / Install-SteamCMD), mirroring how
        Core/Service.psm1's Install-GSMServerService bootstraps NSSM on
        first use. Throws if SteamCMD can't be installed or if the
        steamcmd.exe process exits non-zero.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $installDirectory = Join-Path -Path (Get-GSMRootPath) -ChildPath 'Servers/L4D2'

    try {
        if (-not (Test-SteamCMDPresent)) {
            Install-SteamCMD | Out-Null
        }

        Update-SteamApp -AppID $script:L4D2AppID -InstallDirectory $installDirectory
    }
    catch {
        Write-GSMLog -Level Error -Message "Failed to install/update Left 4 Dead 2 server in '$installDirectory': $($_.Exception.Message)"
        throw
    }

    return $true
}

function Add-L4D2WorkshopItem {
    <#
    .SYNOPSIS
        Places a downloaded Workshop item into the Left 4 Dead 2 server's
        addons folder.
    .DESCRIPTION
        Copies ContentPath into
        Servers/L4D2/left4dead2/addons/<WorkshopID> (see this module's
        top-of-file .NOTES for why a copy rather than a link). Any existing
        folder at that destination is removed first, so re-adding the same
        WorkshopID (e.g. a manual refresh) always ends up with a clean copy
        of the current content rather than stale files left over underneath
        it.
    .PARAMETER WorkshopID
        The numeric Steam Workshop item ID, e.g. '123456789'.
    .PARAMETER ContentPath
        Full path to the content SteamCMD already downloaded for this item.
    .EXAMPLE
        Add-L4D2WorkshopItem -WorkshopID '123456789' -ContentPath 'D:\GSM\SteamCMD\steamapps\workshop\content\222860\123456789'
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

    $addonsDirectory = Join-Path -Path (Get-GSMRootPath) -ChildPath 'Servers/L4D2/left4dead2/addons'
    $destinationPath = Join-Path -Path $addonsDirectory -ChildPath $WorkshopID

    try {
        New-Item -ItemType Directory -Path $addonsDirectory -Force -ErrorAction Stop | Out-Null

        if (Test-Path -Path $destinationPath) {
            Remove-Item -Path $destinationPath -Recurse -Force -ErrorAction Stop
        }

        Copy-Item -Path $ContentPath -Destination $destinationPath -Recurse -Force -ErrorAction Stop
    }
    catch {
        throw "Failed to place Workshop item '$WorkshopID' into '$destinationPath': $($_.Exception.Message)"
    }

    return $true
}

function Remove-L4D2WorkshopItem {
    <#
    .SYNOPSIS
        Removes a placed Workshop item from the Left 4 Dead 2 server's
        addons folder.
    .DESCRIPTION
        Removes the folder at Servers/L4D2/left4dead2/addons/<WorkshopID>,
        if present.
    .PARAMETER WorkshopID
        The numeric Steam Workshop item ID to remove, e.g. '123456789'.
    .EXAMPLE
        Remove-L4D2WorkshopItem -WorkshopID '123456789'
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

    $destinationPath = Join-Path -Path (Get-GSMRootPath) -ChildPath "Servers/L4D2/left4dead2/addons/$WorkshopID"

    if (-not (Test-Path -Path $destinationPath)) {
        Write-GSMLog -Level Info -Message "No placed content found for Workshop item '$WorkshopID' at '$destinationPath'; Remove-L4D2WorkshopItem is a no-op."
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

Export-ModuleMember -Function Install-L4D2Server, Add-L4D2WorkshopItem, Remove-L4D2WorkshopItem
