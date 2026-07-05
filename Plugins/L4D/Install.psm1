<#
.SYNOPSIS
    Left 4 Dead install/update logic.
.DESCRIPTION
    Phase 1. Calls Core/SteamCMD.psm1 with this plugin's AppID (222840) to
    install and update the dedicated server.
.NOTES
    Functions to implement: Install-L4DServer, Update-L4DServer.
#>

Set-StrictMode -Version Latest
