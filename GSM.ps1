#Requires -Version 7.0
<#
.SYNOPSIS
    GameServer Manager entry point.
.DESCRIPTION
    Loads Core modules, then either dispatches a single action
    non-interactively (when a game selector and -Action are both given) or
    launches the interactive main menu (when neither is given). This is the
    only script the user runs directly.
.PARAMETER GameName
    The GameName value from a plugin's Plugin.json (e.g. 'Insurgency').
    Must be supplied together with -Action for non-interactive mode. Only
    use this when the GameName is unique across installed plugins - some
    plugins share a GameName (e.g. L4D and L4D2 both report 'Left4Dead'),
    in which case -FolderName is required instead.
.PARAMETER FolderName
    The plugin's folder name under Plugins/ (e.g. 'L4D2'). Always
    unambiguous, unlike -GameName. Must be supplied together with -Action
    for non-interactive mode. Supply only one of -GameName or -FolderName.
.PARAMETER Action
    The lifecycle action to perform. Must be supplied together with
    -GameName or -FolderName for non-interactive mode.
.EXAMPLE
    ./GSM.ps1
    Launches the interactive main menu.
.EXAMPLE
    ./GSM.ps1 -GameName Insurgency -Action Install
    Runs the Install action for Insurgency non-interactively and exits 0 or 1.
.EXAMPLE
    ./GSM.ps1 -FolderName L4D2 -Action Install
    Runs the Install action for the L4D2 plugin specifically, disambiguating
    it from L4D (both share GameName 'Left4Dead').
.NOTES
    A game selector (-GameName or -FolderName, not both) and -Action must be
    provided together; supplying only one is a usage error and exits 1
    without running anything.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$GameName,

    [Parameter()]
    [string]$FolderName,

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

$gameSelector = $GameName -or $FolderName

if ($GameName -and $FolderName) {
    Write-Error 'Specify only one of -GameName or -FolderName, not both.' -ErrorAction Continue
    exit 1
}
elseif ($gameSelector -and $Action) {
    if ($FolderName) {
        $succeeded = Invoke-GSMAction -FolderName $FolderName -Action $Action
    }
    else {
        $succeeded = Invoke-GSMAction -GameName $GameName -Action $Action
    }

    if ($succeeded) {
        exit 0
    }
    else {
        exit 1
    }
}
elseif (-not $gameSelector -and -not $Action) {
    Show-MainMenu
}
else {
    Write-Error 'Both a game selector (-GameName or -FolderName) and -Action are required together for non-interactive mode.' -ErrorAction Continue
    exit 1
}
