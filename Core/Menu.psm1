#Requires -Version 7.0
<#
.SYNOPSIS
    Main menu and navigation for GSM.
.DESCRIPTION
    Phase 1. Renders the console menu, lists installed/available plugins
    (games), and routes user selection to the right plugin action.
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Utilities.psm1')
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Logging.psm1')
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'PluginLoader.psm1') -Force
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'RCON.psm1') -Force
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Workshop.psm1') -Force

# Maps each action to the plugin function name it expects, with {0} standing
# in for the plugin's FolderName (e.g. 'Insurgency2014'). Start/Stop/Restart/
# Status are thin per-plugin wrappers around Core/ProcessManager.psm1
# (PRD section 8, item 11); Configure is a thin per-plugin wrapper around
# Core/ConfigEditor.psm1 (item 12).
$script:GSMActionFunctionTemplates = @{
    Install   = 'Install-{0}Server'
    Start     = 'Start-{0}Server'
    Stop      = 'Stop-{0}Server'
    Restart   = 'Restart-{0}Server'
    Status    = 'Get-{0}ServerStatus'
    Configure = 'New-{0}Config'
}

function Invoke-GSMAction {
    <#
    .SYNOPSIS
        Dispatches a lifecycle action to the matching game plugin.
    .DESCRIPTION
        Looks up the target plugin via Find-GSMPlugins - by FolderName if
        given, otherwise by Plugin.json's GameName - imports it via
        Import-GSMPlugin, then calls the plugin function that implements
        Action. This is the only place that looks up and dispatches to a
        plugin: Show-MainMenu and GSM.ps1's non-interactive path both call
        this instead of duplicating the lookup logic.
    .PARAMETER GameName
        The GameName value from the target plugin's Plugin.json (e.g.
        'Insurgency'). Ambiguous when two plugins share a GameName (e.g. L4D
        and L4D2 both report 'Left4Dead') - use -FolderName instead in that
        case. Exactly one of -GameName or -FolderName must be supplied.
    .PARAMETER FolderName
        The plugin's folder name under Plugins/ (e.g. 'L4D2'). Always
        unambiguous, unlike -GameName. Exactly one of -GameName or
        -FolderName must be supplied.
    .PARAMETER Action
        The lifecycle action to perform.
    .EXAMPLE
        Invoke-GSMAction -GameName 'Insurgency' -Action Install
    .EXAMPLE
        Invoke-GSMAction -FolderName 'L4D2' -Action Install
    .NOTES
        Expects the plugin folder to expose a function named per Action:
        Install-<FolderName>Server, Start-<FolderName>Server,
        Stop-<FolderName>Server, Restart-<FolderName>Server,
        Get-<FolderName>ServerStatus, or New-<FolderName>Config. A plugin
        that doesn't implement the requested action results in a logged
        error and $false, not a thrown exception.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()]
        [string]$GameName,

        [Parameter()]
        [string]$FolderName,

        [Parameter(Mandatory)]
        [ValidateSet('Install', 'Start', 'Stop', 'Restart', 'Status', 'Configure')]
        [string]$Action
    )

    if (-not $GameName -and -not $FolderName) {
        Write-GSMLog -Level Error -Message "Invoke-GSMAction requires either -GameName or -FolderName."
        return $false
    }

    if ($GameName -and $FolderName) {
        Write-GSMLog -Level Error -Message "Invoke-GSMAction accepts only one of -GameName or -FolderName, not both."
        return $false
    }

    try {
        $plugins = Find-GSMPlugins
    }
    catch {
        Write-GSMLog -Level Error -Message "Could not scan plugins while dispatching action '$Action' for '$($FolderName ? $FolderName : $GameName)': $($_.Exception.Message)"
        return $false
    }

    if ($FolderName) {
        $plugin = $plugins | Where-Object { $_.FolderName -eq $FolderName } | Select-Object -First 1

        if (-not $plugin) {
            Write-GSMLog -Level Error -Message "No plugin found for folder '$FolderName'."
            return $false
        }
    }
    else {
        $matchingPlugins = @($plugins | Where-Object { $_.GameName -eq $GameName })

        if ($matchingPlugins.Count -eq 0) {
            Write-GSMLog -Level Error -Message "No plugin found for game '$GameName'."
            return $false
        }

        if ($matchingPlugins.Count -gt 1) {
            $folderNames = ($matchingPlugins.FolderName -join ', ')
            Write-GSMLog -Level Error -Message "GameName '$GameName' matches multiple plugins ($folderNames). Use -FolderName to disambiguate."
            return $false
        }

        $plugin = $matchingPlugins[0]
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
        $result = & $functionName

        # Status is the one action whose whole purpose is the value it
        # returns (Running/Stopped/Crashed from Core/ProcessManager.psm1),
        # so it's the one case where that return value is worth surfacing
        # rather than discarding. Every other action's result is
        # informational at best; Invoke-GSMAction's contract stays "$true on
        # success, $false on failure" either way.
        if ($Action -eq 'Status') {
            Write-GSMLog -Level Info -Message "Status for plugin '$($plugin.FolderName)': $result"
        }

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
            Write-Host "  - $($plugin.FolderName): $($plugin.GameName) $($plugin.Version)"
        }

        # Selection is keyed by FolderName, not GameName: two plugins can
        # report the same Plugin.json GameName (e.g. L4D and L4D2 both say
        # 'Left4Dead'), and FolderName is guaranteed unique by Find-GSMPlugins.
        # Dashboard sits at this level, not in the per-game action list
        # below: it's a whole-of-GSM view across every instance, not an
        # action performed against one selected game.
        $gameChoices = @($plugins.FolderName) + @('Dashboard', 'Exit')
        $selectedFolder = Read-GSMPrompt -Message 'Select a game by its folder name shown above, Dashboard for the web dashboard, or Exit to quit' -ValidValues $gameChoices

        if ($selectedFolder -eq 'Exit') {
            return
        }

        if ($selectedFolder -eq 'Dashboard') {
            # Lazily imported here, not at this module's own top level:
            # Core/Dashboard.psm1 imports Core/Menu.psm1 (for Invoke-GSMAction),
            # so importing it unconditionally from Menu.psm1's own top-level
            # script would be a circular Import-Module -Force loop. Blocking/
            # interactive like RCON Console below, and likewise bypasses
            # Invoke-GSMAction's dispatch table entirely.
            Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Dashboard.psm1') -Force
            Start-GSMDashboard
            continue
        }

        # "Manage Workshop Items" is shown only for a plugin whose Plugin.json
        # sets SupportsWorkshop true (Insurgency2014, TeamFortress2, L4D2) -
        # the same conditional-visibility idea as SupportsRCON gating RCON
        # itself, just applied to the menu's action list rather than a
        # connection attempt.
        $selectedPlugin = $plugins | Where-Object { $_.FolderName -eq $selectedFolder } | Select-Object -First 1
        $actionChoices = @('Install', 'Start', 'Stop', 'Restart', 'Status', 'Configure', 'RCON Console')
        if ($selectedPlugin.SupportsWorkshop) {
            $actionChoices += 'Manage Workshop Items'
        }

        $selectedAction = Read-GSMPrompt -Message "Select an action ($($actionChoices -join ', '))" -ValidValues $actionChoices

        if ($selectedAction -eq 'RCON Console') {
            # Blocking/interactive, unlike every other action here - it has
            # no simple success/failure result to report, so it bypasses
            # Invoke-GSMAction's $script:GSMActionFunctionTemplates dispatch
            # entirely and calls Start-GSMRCONConsole directly.
            Start-GSMRCONConsole -FolderName $selectedFolder
            continue
        }

        if ($selectedAction -eq 'Manage Workshop Items') {
            # Blocking/interactive, same reasoning as RCON Console above -
            # bypasses Invoke-GSMAction's dispatch table and calls
            # Core/Workshop.psm1's own sub-menu directly.
            Show-GSMWorkshopMenu -FolderName $selectedFolder
            continue
        }

        $succeeded = Invoke-GSMAction -FolderName $selectedFolder -Action $selectedAction

        if ($succeeded) {
            Write-Host "$selectedAction succeeded for $selectedFolder." -ForegroundColor Green
        }
        else {
            Write-Warning "$selectedAction failed for $selectedFolder. Check the logs for details."
        }
    }
}

Export-ModuleMember -Function Show-MainMenu, Invoke-GSMAction
