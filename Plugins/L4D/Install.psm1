#Requires -Version 7.0
<#
.SYNOPSIS
    Left 4 Dead (2008) install/update logic.
.DESCRIPTION
    Phase 1. Calls Core/SteamCMD.psm1 with this plugin's AppID (222840) to
    install and update the dedicated server.
.NOTES
    Functions implemented: Install-L4DServer.
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../../Core/Utilities.psm1')
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../../Core/Logging.psm1')
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../../Core/SteamCMD.psm1') -Force

# This plugin's Steam dedicated server AppID (matches Plugin.json).
$script:L4DAppID = '222840'

function Install-L4DServer {
    <#
    .SYNOPSIS
        Installs or updates the Left 4 Dead (2008) dedicated server.
    .DESCRIPTION
        Calls Core/SteamCMD.psm1's Update-SteamApp with this plugin's AppID
        (222840) and an install directory of Servers/L4D under the repo
        root. Update-SteamApp's own app_update/validate call is idempotent,
        so this same function handles both the first install and later
        updates.
    .EXAMPLE
        Install-L4DServer
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

    $installDirectory = Join-Path -Path (Get-GSMRootPath) -ChildPath 'Servers/L4D'

    try {
        if (-not (Test-SteamCMDPresent)) {
            Install-SteamCMD | Out-Null
        }

        Update-SteamApp -AppID $script:L4DAppID -InstallDirectory $installDirectory
    }
    catch {
        Write-GSMLog -Level Error -Message "Failed to install/update Left 4 Dead server in '$installDirectory': $($_.Exception.Message)"
        throw
    }

    return $true
}

Export-ModuleMember -Function Install-L4DServer
