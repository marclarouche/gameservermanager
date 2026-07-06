#Requires -Version 7.0
<#
.SYNOPSIS
    Team Fortress 2 install/update logic.
.DESCRIPTION
    Phase 1. Calls Core/SteamCMD.psm1 with this plugin's AppID (232250) to
    install and update the dedicated server.
.NOTES
    Functions to implement: Install-TeamFortress2Server.
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../../Core/Utilities.psm1') -Force
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../../Core/Logging.psm1') -Force
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

Export-ModuleMember -Function Install-TeamFortress2Server
