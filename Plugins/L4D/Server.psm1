<#
.SYNOPSIS
    Left 4 Dead server lifecycle and launch parameters.
.DESCRIPTION
    Phase 1 (launch params, config template) / Phase 2 (start/stop/restart via
    Core/Service.psm1). Builds the srcds.exe launch string from the active config.
.NOTES
    Functions to implement: Get-L4DLaunchArgs, New-L4DConfig.
#>

Set-StrictMode -Version Latest
