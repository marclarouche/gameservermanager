<#
.SYNOPSIS
    Counter-Strike: Source server lifecycle and launch parameters.
.DESCRIPTION
    Phase 1 (launch params, config template) / Phase 2 (start/stop/restart via
    Core/Service.psm1). Builds the srcds.exe launch string from the active config.
.NOTES
    Functions to implement: Get-CounterStrikeSourceLaunchArgs, New-CounterStrikeSourceConfig.
#>

Set-StrictMode -Version Latest
