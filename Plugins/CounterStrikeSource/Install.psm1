#Requires -Version 7.0
<#
.SYNOPSIS
    Counter-Strike: Source install/update logic.
.DESCRIPTION
    Phase 1. Calls Core/SteamCMD.psm1 with this plugin's AppID (232330) to
    install and update the dedicated server.
.NOTES
    Functions implemented: Install-CounterStrikeSourceServer.
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../../Core/Utilities.psm1') -Force
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../../Core/Logging.psm1') -Force
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../../Core/SteamCMD.psm1') -Force

# This plugin's Steam dedicated server AppID (matches Plugin.json).
$script:CounterStrikeSourceAppID = '232330'

function Install-CounterStrikeSourceServer {
    <#
    .SYNOPSIS
        Installs or updates the Counter-Strike: Source dedicated server.
    .DESCRIPTION
        Calls Core/SteamCMD.psm1's Update-SteamApp with this plugin's AppID
        (232330) and an install directory of Servers/CounterStrikeSource
        under the repo root. Update-SteamApp's own app_update/validate call
        is idempotent, so this same function handles both the first install
        and later updates.
    .EXAMPLE
        Install-CounterStrikeSourceServer
    .NOTES
        Throws if SteamCMD isn't installed yet (Update-SteamApp's own
        check) or if the steamcmd.exe process exits non-zero. Callers must
        run Install-SteamCMD first; this function does not install SteamCMD
        itself.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $installDirectory = Join-Path -Path (Get-GSMRootPath) -ChildPath 'Servers/CounterStrikeSource'

    try {
        Update-SteamApp -AppID $script:CounterStrikeSourceAppID -InstallDirectory $installDirectory
    }
    catch {
        Write-GSMLog -Level Error -Message "Failed to install/update Counter-Strike: Source server in '$installDirectory': $($_.Exception.Message)"
        throw
    }

    return $true
}

Export-ModuleMember -Function Install-CounterStrikeSourceServer
