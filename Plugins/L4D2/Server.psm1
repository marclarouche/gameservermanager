<#
.SYNOPSIS
    Left 4 Dead 2 server lifecycle and launch parameters.
.DESCRIPTION
    Phase 1 (launch params, config template) / Phase 2 (start/stop/restart via
    Core/Service.psm1). Builds the srcds.exe launch string from the active config.
.NOTES
    Functions to implement: Get-L4D2LaunchArgs, New-L4D2Config.
#>

Set-StrictMode -Version Latest
