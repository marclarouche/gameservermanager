#Requires -Version 7.0
<#
.SYNOPSIS
    Team Fortress 2 install/update logic.
.DESCRIPTION
    Phase 1. Calls Core/SteamCMD.psm1 with this plugin's AppID (232250) to
    install and update the dedicated server.
.NOTES
    Functions to implement: Install-TeamFortress2Server.

    Workshop placement (Phase 5): Add-TeamFortress2WorkshopItem copies (not
    links) a downloaded Workshop item into tf/custom/<WorkshopID>. TF2
    Workshop content is VPK-packed custom content read directly out of
    tf/custom by the engine's search-path system, the same convention
    community server documentation recommends addon content be placed in -
    a plain copy is the well-documented, broadly compatible choice here,
    unlike Insurgency2014's whole map packages where avoiding a second copy
    on disk was worth the tradeoff.
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../../Core/Utilities.psm1')
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../../Core/Logging.psm1')
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../../Core/SteamCMD.psm1') -Force

# This plugin's Steam dedicated server AppID (matches Plugin.json).
$script:TeamFortress2AppID = '232250'

function Install-TeamFortress2Server {
    <#
    .SYNOPSIS
        Installs or updates the Team Fortress 2 dedicated server.
    .DESCRIPTION
        Calls Core/SteamCMD.psm1's Update-SteamApp with this plugin's AppID
        (232250) and an install directory of Servers/TeamFortress2 under
        the repo root. Update-SteamApp's own app_update/validate call is
        idempotent, so this same function handles both the first install
        and later updates.
    .EXAMPLE
        Install-TeamFortress2Server
    .NOTES
        Throws if SteamCMD isn't installed yet (Update-SteamApp's own
        check) or if the steamcmd.exe process exits non-zero. Callers must
        run Install-SteamCMD first; this function does not install SteamCMD
        itself.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $installDirectory = Join-Path -Path (Get-GSMRootPath) -ChildPath 'Servers/TeamFortress2'

    try {
        Update-SteamApp -AppID $script:TeamFortress2AppID -InstallDirectory $installDirectory
    }
    catch {
        Write-GSMLog -Level Error -Message "Failed to install/update Team Fortress 2 server in '$installDirectory': $($_.Exception.Message)"
        throw
    }

    return $true
}

function Add-TeamFortress2WorkshopItem {
    <#
    .SYNOPSIS
        Places a downloaded Workshop item into the Team Fortress 2 server's
        custom content folder.
    .DESCRIPTION
        Copies ContentPath into
        Servers/TeamFortress2/tf/custom/<WorkshopID> (see this module's
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
        Add-TeamFortress2WorkshopItem -WorkshopID '123456789' -ContentPath 'D:\GSM\SteamCMD\steamapps\workshop\content\232250\123456789'
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

    $customDirectory = Join-Path -Path (Get-GSMRootPath) -ChildPath 'Servers/TeamFortress2/tf/custom'
    $destinationPath = Join-Path -Path $customDirectory -ChildPath $WorkshopID

    try {
        New-Item -ItemType Directory -Path $customDirectory -Force -ErrorAction Stop | Out-Null

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

function Remove-TeamFortress2WorkshopItem {
    <#
    .SYNOPSIS
        Removes a placed Workshop item from the Team Fortress 2 server's
        custom content folder.
    .DESCRIPTION
        Removes the folder at Servers/TeamFortress2/tf/custom/<WorkshopID>,
        if present.
    .PARAMETER WorkshopID
        The numeric Steam Workshop item ID to remove, e.g. '123456789'.
    .EXAMPLE
        Remove-TeamFortress2WorkshopItem -WorkshopID '123456789'
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

    $destinationPath = Join-Path -Path (Get-GSMRootPath) -ChildPath "Servers/TeamFortress2/tf/custom/$WorkshopID"

    if (-not (Test-Path -Path $destinationPath)) {
        Write-GSMLog -Level Info -Message "No placed content found for Workshop item '$WorkshopID' at '$destinationPath'; Remove-TeamFortress2WorkshopItem is a no-op."
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

Export-ModuleMember -Function Install-TeamFortress2Server, Add-TeamFortress2WorkshopItem, Remove-TeamFortress2WorkshopItem
