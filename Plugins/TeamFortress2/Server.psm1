<#
.SYNOPSIS
    Team Fortress 2 server lifecycle and launch parameters.
.DESCRIPTION
    Phase 1 (launch params, config template) / Phase 2 (start/stop/restart via
    Core/Service.psm1). Builds the srcds.exe launch string from the active config.
.NOTES
    Functions to implement: Get-TeamFortress2LaunchArgs, New-TeamFortress2Config.
#>

Set-StrictMode -Version Latest
