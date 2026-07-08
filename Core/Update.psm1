#Requires -Version 7.0
<#
.SYNOPSIS
    Game server update lifecycle for GSM (Phase 2).
.DESCRIPTION
    Phase 2 (PRD section 9). Thin orchestration only: this module contains
    no process-management or SteamCMD logic of its own. It imports
    Core/Service.psm1 for Stop-GSMServer/Start-GSMServer and
    Core/SteamCMD.psm1 for Update-SteamApp, and composes them into a single
    stop -> update -> verify -> restart lifecycle.

    On update failure, the server is deliberately left stopped rather than
    restarted: restarting a server whose files may be partially updated
    (an interrupted app_update, a failed validate pass) risks running a
    broken or inconsistent install. A clear, unambiguous error is the safer
    outcome, and matches how a human operator would want to find out - not
    by a game server silently coming back up in a bad state.
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Utilities.psm1') -Force
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Logging.psm1') -Force
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Config.psm1') -Force
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Service.psm1') -Force
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'SteamCMD.psm1') -Force

function Get-GSMServerConfigPath {
    # Internal helper. Not exported: duplicated from Core/Service.psm1 (not
    # exported there either), matching this codebase's existing convention
    # of small per-module path/property helpers living alongside their own
    # module rather than being imported unprefixed across modules.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$FolderName
    )

    return Join-Path -Path (Get-GSMRootPath) -ChildPath "Config/$FolderName.json"
}

function Get-GSMServerInstallDirectory {
    # Internal helper. Not exported: duplicated from Core/Service.psm1 for
    # the same reason as Get-GSMServerConfigPath above.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$FolderName
    )

    return Join-Path -Path (Get-GSMRootPath) -ChildPath "Servers/$FolderName"
}

function Update-GSMServer {
    <#
    .SYNOPSIS
        Stops, updates via SteamCMD, and restarts a game server.
    .DESCRIPTION
        Reads Config/<FolderName>.json for the server's AppID, then runs:
        Stop-GSMServer, Update-SteamApp (which verifies success via
        steamcmd.exe's own exit code and its app_update ... validate pass),
        and finally Start-GSMServer - but only if the update succeeded.

        If Update-SteamApp throws, this function logs the failure and
        rethrows without ever calling Start-GSMServer: the server is left
        stopped, not restarted into a possibly broken install. Callers that
        need the server running again after a failed update must fix the
        underlying problem and call Start-GSMServer (or this function)
        themselves.
    .PARAMETER FolderName
        The plugin's folder name under Plugins/ (e.g. 'Insurgency2014').
    .PARAMETER Executable
        The server executable's file name (e.g. 'srcds.exe'), passed through
        to Start-GSMServer on a successful update.
    .PARAMETER GetLaunchArgsFunctionName
        Name of the plugin's own exported launch-argument-building function,
        passed through to Start-GSMServer on a successful update.
    .PARAMETER AccountName
        Name of GSM's local service account to run the process as. Defaults
        to 'GSM-ServiceAccount'.
    .EXAMPLE
        Update-GSMServer -FolderName 'Insurgency2014' -Executable 'srcds.exe' -GetLaunchArgsFunctionName 'Get-Insurgency2014LaunchArgs'
    .NOTES
        Requires SteamCMD to already be installed (Core/SteamCMD.psm1's
        Install-SteamCMD); this function does not install it, matching
        Update-SteamApp's own contract. Requires Config/<FolderName>.json to
        exist; Core/Config.psm1's Test-GSMConfig already guarantees AppID is
        present on any config that loads successfully.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$FolderName,

        [Parameter(Mandatory)]
        [string]$Executable,

        [Parameter(Mandatory)]
        [string]$GetLaunchArgsFunctionName,

        [Parameter()]
        [string]$AccountName = 'GSM-ServiceAccount'
    )

    $configPath = Get-GSMServerConfigPath -FolderName $FolderName
    if (-not (Test-Path -Path $configPath -PathType Leaf)) {
        throw "No config found for '$FolderName' at '$configPath'. Run the Configure action first."
    }
    $config = Get-GSMConfig -Path $configPath
    $appId = $config.AppID

    $installDirectory = Get-GSMServerInstallDirectory -FolderName $FolderName

    Write-GSMLog -Level Info -Message "Stopping '$FolderName' for update."
    Stop-GSMServer -FolderName $FolderName | Out-Null

    try {
        Write-GSMLog -Level Info -Message "Updating '$FolderName' (AppID $appId) via SteamCMD."
        Update-SteamApp -AppID $appId -InstallDirectory $installDirectory
    }
    catch {
        Write-GSMLog -Level Error -Message "Update failed for '$FolderName': $($_.Exception.Message). Server left stopped."
        throw "Update failed for '$FolderName'; server left stopped rather than restarted into a possibly broken install. $($_.Exception.Message)"
    }

    Write-GSMLog -Level Info -Message "Update succeeded for '$FolderName'; restarting."
    return Start-GSMServer -FolderName $FolderName -Executable $Executable -GetLaunchArgsFunctionName $GetLaunchArgsFunctionName -AccountName $AccountName
}

Export-ModuleMember -Function Update-GSMServer
