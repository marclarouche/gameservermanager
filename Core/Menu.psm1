#Requires -Version 7.0
<#
.SYNOPSIS
    Main menu and navigation for GSM.
.DESCRIPTION
    Phase 1. Renders the console menu, lists installed/available plugins
    (games), and routes user selection to the right plugin action.
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Utilities.psm1') -Force
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Logging.psm1') -Force
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'PluginLoader.psm1') -Force

# Maps each action to the plugin function name it expects, with {0} standing
# in for the plugin's FolderName (e.g. 'Insurgency2014'). Start/Stop/Status
# hooks don't exist until Core/Service.psm1 (Phase 2); Install and Configure
# match the function names already sketched in the Phase 1 plugin stubs.
$script:GSMActionFunctionTemplates = @{
    Install   = 'Install-{0}Server'
    Start     = 'Start-{0}Server'
    Stop      = 'Stop-{0}Server'
    Status    = 'Get-{0}ServerStatus'
    Configure = 'New-{0}Config'
}

function Invoke-GSMAction {
    <#
    .SYNOPSIS
        Dispatches a lifecycle action to the matching game plugin.
    .DESCRIPTION
        Looks up the plugin whose Plugin.json GameName matches GameName via
        Find-GSMPlugins, imports it via Import-GSMPlugin, then calls the
        plugin function that implements Action. This is the only place that
        looks up and dispatches to a plugin: Show-MainMenu and GSM.ps1's
        non-interactive path both call this instead of duplicating the
        lookup logic.
    .PARAMETER GameName
        The GameName value from the target plugin's Plugin.json (e.g.
        'Insurgency').
    .PARAMETER Action
        The lifecycle action to perform.
    .EXAMPLE
        Invoke-GSMAction -GameName 'Insurgency' -Action Install
    .NOTES
        Expects the plugin folder to expose a function named per Action:
        Install-<FolderName>Server, Start-<FolderName>Server,
        Stop-<FolderName>Server, Get-<FolderName>ServerStatus, or
        New-<FolderName>Config. A plugin that doesn't implement the
        requested action yet (true of every Phase 1 plugin today) results in
        a logged error and $false, not a thrown exception.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$GameName,

        [Parameter(Mandatory)]
        [ValidateSet('Install', 'Start', 'Stop', 'Status', 'Configure')]
        [string]$Action
    )

    try {
        $plugins = Find-GSMPlugins
    }
    catch {
        Write-GSMLog -Level Error -Message "Could not scan plugins while dispatching action '$Action' for '$GameName': $($_.Exception.Message)"
        return $false
    }

    $plugin = $plugins | Where-Object { $_.GameName -eq $GameName } | Select-Object -First 1

    if (-not $plugin) {
        Write-GSMLog -Level Error -Message "No plugin found for game '$GameName'."
        return $false
    }

    try {
        Import-GSMPlugin -FolderName $plugin.FolderName
    }
    catch {
        Write-GSMLog -Level Error -Message "Failed to import plugin '$($plugin.FolderName)': $($_.Exception.Message)"
        return $false
    }

    $functionName = $script:GSMActionFunctionTemplates[$Action] -f $plugin.FolderName
    $command = Get-Command -Name $functionName -ErrorAction SilentlyContinue

    if (-not $command) {
        Write-GSMLog -Level Error -Message "Plugin '$($plugin.FolderName)' does not implement the '$Action' action (expected function '$functionName')."
        return $false
    }

    try {
        & $functionName | Out-Null
        return $true
    }
    catch {
        Write-GSMLog -Level Error -Message "Action '$Action' failed for plugin '$($plugin.FolderName)': $($_.Exception.Message)"
        return $false
    }
}

function Show-MainMenu {
    <#
    .SYNOPSIS
        Interactive console menu for GSM.
    .DESCRIPTION
        Lists installed plugins via Find-GSMPlugins, prompts for a game and
        an action via Read-GSMPrompt, dispatches through Invoke-GSMAction,
        and repeats until the user chooses to exit.
    .EXAMPLE
        Show-MainMenu
    .NOTES
        Exits the loop when the user selects 'Exit' at the game prompt, or
        immediately if no valid plugins are found.
    #>
    [CmdletBinding()]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive console menu; output is direct user-facing display, not pipeline data.')]
    param()

    while ($true) {
        $plugins = Find-GSMPlugins

        if (-not $plugins -or $plugins.Count -eq 0) {
            Write-Warning 'No valid plugins found in the Plugins/ directory.'
            return
        }

        Write-Host ''
        Write-Host 'Installed games:'
        foreach ($plugin in $plugins) {
            Write-Host "  - $($plugin.GameName) $($plugin.Version)"
        }

        $gameChoices = @($plugins.GameName | Select-Object -Unique) + 'Exit'
        $selectedGame = Read-GSMPrompt -Message 'Select a game (or Exit to quit)' -ValidValues $gameChoices

        if ($selectedGame -eq 'Exit') {
            return
        }

        $selectedAction = Read-GSMPrompt -Message 'Select an action (Install, Start, Stop, Status, Configure)' -ValidValues @('Install', 'Start', 'Stop', 'Status', 'Configure')

        $succeeded = Invoke-GSMAction -GameName $selectedGame -Action $selectedAction

        if ($succeeded) {
            Write-Host "$selectedAction succeeded for $selectedGame." -ForegroundColor Green
        }
        else {
            Write-Warning "$selectedAction failed for $selectedGame. Check the logs for details."
        }
    }
}

Export-ModuleMember -Function Show-MainMenu, Invoke-GSMAction
