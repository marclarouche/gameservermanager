#Requires -Version 7.0
<#
.SYNOPSIS
    GameServer Manager entry point.
.DESCRIPTION
    Loads Core modules, discovers plugins via Core/PluginLoader.psm1, and
    launches the main menu. This is the only script the user runs directly.
.NOTES
    Phase 1 - TODO. Wire up module imports and call Show-MainMenu once
    Core/Menu.psm1 exists.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# TODO: Import-Module Core modules from ./Core
# TODO: Call plugin discovery from Core/PluginLoader.psm1
# TODO: Call Show-MainMenu from Core/Menu.psm1
