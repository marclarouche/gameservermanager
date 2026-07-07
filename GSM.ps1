#Requires -Version 7.0
<#
.SYNOPSIS
    GameServer Manager entry point.
.DESCRIPTION
    Loads Core modules, then either dispatches a single action
    non-interactively (when both -GameName and -Action are given) or
    launches the interactive main menu (when neither is given). This is the
    only script the user runs directly.
.PARAMETER GameName
    The GameName value from a plugin's Plugin.json (e.g. 'Insurgency').
    Must be supplied together with -Action for non-interactive mode.
.PARAMETER Action
    The lifecycle action to perform. Must be supplied together with
    -GameName for non-interactive mode.
.EXAMPLE
    ./GSM.ps1
    Launches the interactive main menu.
.EXAMPLE
    ./GSM.ps1 -GameName Insurgency -Action Install
    Runs the Install action for Insurgency non-interactively and exits 0 or 1.
.NOTES
    -GameName and -Action must be provided together; supplying only one is
    a usage error and exits 1 without running anything.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$GameName,

    [Parameter()]
    [ValidateSet('Install', 'Start', 'Stop', 'Restart', 'Status', 'Configure')]
    [string]$Action
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Core/Utilities.psm1') -Force
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Core/Logging.psm1') -Force
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Core/PluginLoader.psm1') -Force
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Core/Menu.psm1') -Force

if ($GameName -and $Action) {
    $succeeded = Invoke-GSMAction -GameName $GameName -Action $Action
    if ($succeeded) {
        exit 0
    }
    else {
        exit 1
    }
}
elseif (-not $GameName -and -not $Action) {
    Show-MainMenu
}
else {
    Write-Error 'Both -GameName and -Action are required together for non-interactive mode.' -ErrorAction Continue
    exit 1
}
