<#
.SYNOPSIS
    Team Fortress 2 install/update logic.
.DESCRIPTION
    Phase 1. Calls Core/SteamCMD.psm1 with this plugin's AppID (232250) to
    install and update the dedicated server.
.NOTES
    Functions to implement: Install-TeamFortress2Server, Update-TeamFortress2Server.
#>

Set-StrictMode -Version Latest
