<#
.SYNOPSIS
    SteamCMD install and update wrapper.
.DESCRIPTION
    Phase 1. Downloads and installs SteamCMD if missing, and runs app
    install/update commands on behalf of plugins. Verifies SHA-256 of
    downloaded files per PRD section 10.
.NOTES
    Functions to implement: Install-SteamCMD, Update-SteamApp,
    Test-SteamCMDPresent.
#>

Set-StrictMode -Version Latest
