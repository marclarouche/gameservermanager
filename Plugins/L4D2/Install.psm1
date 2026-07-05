<#
.SYNOPSIS
    Left 4 Dead 2 install/update logic.
.DESCRIPTION
    Phase 1. Calls Core/SteamCMD.psm1 with this plugin's AppID (222860) to
    install and update the dedicated server.
.NOTES
    Functions to implement: Install-L4D2Server, Update-L4D2Server.
#>

Set-StrictMode -Version Latest
