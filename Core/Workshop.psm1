#Requires -Version 7.0
<#
.SYNOPSIS
    Steam Workshop subscribe/download for GSM (Phase 5).
.DESCRIPTION
    Phase 5. Subscribe/download only - there is no in-app Workshop catalog
    browsing and no plugin marketplace (cut entirely in Phase 4's decisions
    log). A player already knows a Workshop item's numeric ID from the Steam
    Workshop page in a browser and gives it to GSM; this module downloads it
    via SteamCMD's +workshop_download_item and hands the downloaded content
    to the owning plugin to place where its game actually expects it.

    Generic and instance-agnostic: this module knows nothing about any
    single game's addon folder layout. Placement/removal is the plugin's own
    job, exposed as a per-plugin Add-<FolderName>WorkshopItem /
    Remove-<FolderName>WorkshopItem function pair (see
    Plugins/Insurgency2014/TeamFortress2/L4D2's Install.psm1), the same
    naming-convention dispatch Core/Menu.psm1 already uses for
    Install-<FolderName>Server etc.

    Gated by Plugin.json's SupportsWorkshop field - only Insurgency2014,
    TeamFortress2, and L4D2 have it set true. CounterStrikeSource and L4D
    fail closed with a clear error, the same pattern Core/RCON.psm1 and
    Core/Firewall.psm1 use for their own Plugin.json-driven checks.

    Subscriptions are tracked per-instance in Config/<FolderName>.json's
    WorkshopItems array - not shared like Config/CustomMaps.json, since two
    instances of the same game may want different addons. That field
    already exists in this schema (Core/ConfigEditor.psm1's
    New-GSMServerConfig writes it, and each of the three plugins' own
    Test-<Game>ServerConfig validates it as an array); this module is simply
    the first thing to populate it automatically instead of by hand.

    Nightly refresh (Core/Scheduler.psm1 integration) is explicitly deferred
    to a later task - Update-GSMWorkshopItems here is manual-only, invoked
    from Core/Menu.psm1's "Manage Workshop Items" action.
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Utilities.psm1')
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Logging.psm1')
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Config.psm1') -Force
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'PluginLoader.psm1') -Force
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'SteamCMD.psm1') -Force

function Get-GSMWorkshopConfigPropertyValue {
    # Internal helper. Not exported: reads a property from a config psobject
    # via PSObject.Properties, returning $null when it doesn't exist instead
    # of letting dot-notation throw PropertyNotFoundException under
    # Set-StrictMode -Version Latest. WorkshopItems is array-valued, so (like
    # Insurgency2014/TeamFortress2/L4D2's Server.psm1 equivalents) this uses
    # Write-Output -NoEnumerate for array values only, to avoid a
    # single-element array unrolling into a bare scalar.
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [psobject]$Config,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $property = $Config.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    if ($property.Value -is [array]) {
        Write-Output -InputObject $property.Value -NoEnumerate
    }
    else {
        return $property.Value
    }
}

function Get-GSMWorkshopItemsArray {
    # Internal helper. Not exported: reads Config's WorkshopItems as a
    # guaranteed array, never $null. Wrapping a $null-returning expression
    # in @(...) produces a 1-element array containing $null, not an empty
    # array (the same trap Core/Firewall.psm1's Remove-GSMFirewallRule and
    # Get-GSMFirewallRuleStatus explicitly guard against) - this checks for
    # $null before wrapping instead.
    #
    # Both branches use Write-Output -NoEnumerate rather than a plain
    # "return $array": "return" enumerates an array value onto the output
    # pipeline, and for a zero-element array that means zero objects are
    # emitted at all - the caller then gets $null instead of an empty array,
    # not just the more commonly-known 1-element-unwraps-to-a-scalar version
    # of this same trap (see Get-Insurgency2014ConfigPropertyValue's .NOTES
    # in Plugins/Insurgency2014/Server.psm1 for that version of it).
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [psobject]$Config
    )

    $value = Get-GSMWorkshopConfigPropertyValue -Config $Config -Name 'WorkshopItems'
    if ($null -eq $value) {
        Write-Output -InputObject ([string[]]@()) -NoEnumerate
        return
    }

    Write-Output -InputObject ([string[]]@($value)) -NoEnumerate
}

function Get-GSMWorkshopPluginJson {
    # Internal helper. Not exported: resolves and validates
    # Plugins/<FolderName>/Plugin.json via Find-GSMPlugins, matching by
    # FolderName. Mirrors Core/RCON.psm1's and Core/Firewall.psm1's identical
    # helper, except sourced through Find-GSMPlugins (which every one of
    # this module's public functions needs anyway, to enumerate the plugin's
    # FolderName-matched entry) rather than reading Plugin.json directly.
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory)]
        [string]$FolderName
    )

    $plugins = Find-GSMPlugins
    $plugin = $plugins | Where-Object { $_.FolderName -eq $FolderName } | Select-Object -First 1

    if (-not $plugin) {
        throw "No plugin found for folder '$FolderName'."
    }

    return $plugin
}

function Assert-GSMWorkshopSupported {
    # Internal helper. Not exported: fails closed with a clear error when
    # PluginJson's SupportsWorkshop is not true. Applied uniformly by every
    # exported function in this module (Add/Remove/Get/Update), not just the
    # download path - CounterStrikeSource and L4D must reject every Workshop
    # call, not merely the ones that touch SteamCMD.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$PluginJson
    )

    if ($PluginJson.SupportsWorkshop -ne $true) {
        throw "'$($PluginJson.FolderName)' does not support Steam Workshop (Plugin.json's SupportsWorkshop is false)."
    }
}

function Get-GSMWorkshopConfigPath {
    # Internal helper. Not exported: duplicated from Core/Update.psm1's
    # identical helper (not exported there either), matching this codebase's
    # existing convention of small per-module path helpers.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$FolderName
    )

    return Join-Path -Path (Get-GSMRootPath) -ChildPath "Config/$FolderName.json"
}

function Get-GSMWorkshopInstanceConfig {
    # Internal helper. Not exported: loads Config/<FolderName>.json, throwing
    # the same "run Configure first" error Core/Update.psm1's
    # Update-GSMServer uses when it's missing - a Workshop item can't be
    # recorded against an instance that doesn't have a config yet.
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory)]
        [string]$FolderName
    )

    $configPath = Get-GSMWorkshopConfigPath -FolderName $FolderName
    if (-not (Test-Path -Path $configPath -PathType Leaf)) {
        throw "No config found for '$FolderName' at '$configPath'. Run the Configure action first."
    }

    return Get-GSMConfig -Path $configPath
}

function Get-GSMWorkshopContentPath {
    # Internal helper. Not exported: resolves where SteamCMD drops a
    # downloaded Workshop item - steamapps/workshop/content/<AppID>/
    # <WorkshopID>/, relative to SteamCMD's own directory (SteamCMD/ under
    # the repo root). No -force_install_dir is passed to
    # +workshop_download_item (see Invoke-GSMWorkshopDownload's .NOTES), so
    # this is always where SteamCMD itself puts the content, not a
    # game-specific install directory.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$AppID,

        [Parameter(Mandatory)]
        [string]$WorkshopID
    )

    return Join-Path -Path (Get-GSMRootPath) -ChildPath "SteamCMD/steamapps/workshop/content/$AppID/$WorkshopID"
}

function Invoke-GSMWorkshopDownload {
    # Internal helper. Not exported: runs steamcmd.exe's
    # +workshop_download_item for one AppID/WorkshopID pair and validates
    # the result, the same way Core/SteamCMD.psm1's Update-SteamApp
    # validates its own steamcmd.exe exit code before proceeding. Returns
    # the resolved content path on success.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$AppID,

        [Parameter(Mandatory)]
        [string]$WorkshopID
    )

    if (-not (Test-SteamCMDPresent)) {
        throw 'SteamCMD is not installed. Run Install-SteamCMD first.'
    }

    $steamCmdExePath = Join-Path -Path (Get-GSMRootPath) -ChildPath 'SteamCMD/steamcmd.exe'

    $arguments = @(
        '+login', 'anonymous',
        '+workshop_download_item', $AppID, $WorkshopID,
        '+quit'
    )

    try {
        $process = Start-Process -FilePath $steamCmdExePath -ArgumentList $arguments -Wait -NoNewWindow -PassThru -ErrorAction Stop

        if ($process.ExitCode -ne 0) {
            throw "steamcmd.exe exited with code $($process.ExitCode) while downloading WorkshopID '$WorkshopID' (AppID '$AppID')."
        }
    }
    catch {
        Write-GSMLog -Level Error -Message "Workshop download failed for AppID '$AppID', WorkshopID '$WorkshopID': $($_.Exception.Message)"
        throw "Failed to download Workshop item '$WorkshopID' for AppID '$AppID': $($_.Exception.Message)"
    }

    $contentPath = Get-GSMWorkshopContentPath -AppID $AppID -WorkshopID $WorkshopID

    # steamcmd.exe is known to exit 0 for a Workshop ID that doesn't exist or
    # doesn't belong to this AppID, without downloading anything - checking
    # the content actually landed is the only reliable way to catch that.
    if (-not (Test-Path -Path $contentPath -PathType Container)) {
        Write-GSMLog -Level Error -Message "Workshop download reported success but no content was found for AppID '$AppID', WorkshopID '$WorkshopID' at '$contentPath'."
        throw "Workshop item '$WorkshopID' could not be found for AppID '$AppID'. Check the Workshop ID and that it belongs to this game."
    }

    return $contentPath
}

function Invoke-GSMWorkshopPlacement {
    # Internal helper. Not exported: imports FolderName's plugin and calls
    # its Add-<FolderName>WorkshopItem placement function with the
    # downloaded ContentPath. Never hardcodes a game name or path here - the
    # plugin decides how (and whether to copy or link) its own content gets
    # placed.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$FolderName,

        [Parameter(Mandatory)]
        [string]$WorkshopID,

        [Parameter(Mandatory)]
        [string]$ContentPath
    )

    try {
        Import-GSMPlugin -FolderName $FolderName
    }
    catch {
        throw "Failed to import plugin '$FolderName' for Workshop item placement: $($_.Exception.Message)"
    }

    $functionName = "Add-${FolderName}WorkshopItem"
    $command = Get-Command -Name $functionName -ErrorAction SilentlyContinue
    if (-not $command) {
        throw "Plugin '$FolderName' does not implement Workshop item placement (expected function '$functionName')."
    }

    try {
        & $functionName -WorkshopID $WorkshopID -ContentPath $ContentPath | Out-Null
    }
    catch {
        Write-GSMLog -Level Error -Message "Workshop item placement failed for '$FolderName', WorkshopID '$WorkshopID': $($_.Exception.Message)"
        throw "Failed to place Workshop item '$WorkshopID' for '$FolderName': $($_.Exception.Message)"
    }
}

function Invoke-GSMWorkshopRemoval {
    # Internal helper. Not exported: imports FolderName's plugin and calls
    # its Remove-<FolderName>WorkshopItem removal function.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$FolderName,

        [Parameter(Mandatory)]
        [string]$WorkshopID
    )

    try {
        Import-GSMPlugin -FolderName $FolderName
    }
    catch {
        throw "Failed to import plugin '$FolderName' for Workshop item removal: $($_.Exception.Message)"
    }

    $functionName = "Remove-${FolderName}WorkshopItem"
    $command = Get-Command -Name $functionName -ErrorAction SilentlyContinue
    if (-not $command) {
        throw "Plugin '$FolderName' does not implement Workshop item removal (expected function '$functionName')."
    }

    try {
        & $functionName -WorkshopID $WorkshopID | Out-Null
    }
    catch {
        Write-GSMLog -Level Error -Message "Workshop item removal failed for '$FolderName', WorkshopID '$WorkshopID': $($_.Exception.Message)"
        throw "Failed to remove Workshop item '$WorkshopID' for '$FolderName': $($_.Exception.Message)"
    }
}

function Sync-GSMWorkshopItem {
    # Internal helper. Not exported: downloads and places one Workshop item,
    # shared by Add-GSMWorkshopItem (a single new subscription) and
    # Update-GSMWorkshopItems (refreshing every existing one), so the
    # download+placement steps live in exactly one place. Neither reads nor
    # writes Config/<FolderName>.json's WorkshopItems array itself - that's
    # each caller's own job, so Update-GSMWorkshopItems can reuse this
    # without re-appending IDs already on the list.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$FolderName,

        [Parameter(Mandatory)]
        [string]$AppID,

        [Parameter(Mandatory)]
        [string]$WorkshopID
    )

    $contentPath = Invoke-GSMWorkshopDownload -AppID $AppID -WorkshopID $WorkshopID
    Invoke-GSMWorkshopPlacement -FolderName $FolderName -WorkshopID $WorkshopID -ContentPath $contentPath
}

function Add-GSMWorkshopItem {
    <#
    .SYNOPSIS
        Subscribes to and downloads a Steam Workshop item for a server
        instance.
    .DESCRIPTION
        Validates that FolderName's plugin supports Workshop (Plugin.json's
        SupportsWorkshop), downloads WorkshopID via steamcmd.exe's
        +workshop_download_item, and calls the plugin's own
        Add-<FolderName>WorkshopItem function to place the downloaded
        content where the game expects it. Only once both the download and
        placement succeed is WorkshopID appended to
        Config/<FolderName>.json's WorkshopItems array - a download or
        placement failure leaves the config untouched (fails closed).
        Adding a WorkshopID already present in WorkshopItems re-runs the
        download and placement (a manual refresh of that one item) without
        adding a duplicate entry.
    .PARAMETER FolderName
        The plugin's folder name under Plugins/ (e.g. 'Insurgency2014').
    .PARAMETER WorkshopID
        The numeric Steam Workshop item ID, e.g. '123456789'.
    .EXAMPLE
        Add-GSMWorkshopItem -FolderName 'Insurgency2014' -WorkshopID '123456789'
    .NOTES
        Throws if FolderName's plugin doesn't support Workshop, if no config
        exists yet for FolderName, if the SteamCMD download fails (bad exit
        code or the item isn't found), or if the plugin's own placement
        function fails.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$FolderName,

        [Parameter(Mandatory)]
        [string]$WorkshopID
    )

    $pluginJson = Get-GSMWorkshopPluginJson -FolderName $FolderName
    Assert-GSMWorkshopSupported -PluginJson $pluginJson

    $config = Get-GSMWorkshopInstanceConfig -FolderName $FolderName

    Sync-GSMWorkshopItem -FolderName $FolderName -AppID $pluginJson.AppID -WorkshopID $WorkshopID

    $currentItems = Get-GSMWorkshopItemsArray -Config $config
    if ($currentItems -notcontains $WorkshopID) {
        $updatedItems = $currentItems + $WorkshopID
        Add-Member -InputObject $config -NotePropertyName 'WorkshopItems' -NotePropertyValue $updatedItems -Force
        Set-GSMConfig -Path (Get-GSMWorkshopConfigPath -FolderName $FolderName) -Config $config
    }

    Write-GSMLog -Level Info -Message "Added Workshop item for '$FolderName': WorkshopID '$WorkshopID'."
    return $true
}

function Remove-GSMWorkshopItem {
    <#
    .SYNOPSIS
        Removes a subscribed Steam Workshop item from a server instance.
    .DESCRIPTION
        Validates that FolderName's plugin supports Workshop, then throws a
        clear error if WorkshopID is not currently in
        Config/<FolderName>.json's WorkshopItems array - this is never a
        silent no-op. Otherwise calls the plugin's own
        Remove-<FolderName>WorkshopItem function to delete the placed local
        files, and only drops WorkshopID from WorkshopItems once that
        removal succeeds.
    .PARAMETER FolderName
        The plugin's folder name under Plugins/ (e.g. 'Insurgency2014').
    .PARAMETER WorkshopID
        The numeric Steam Workshop item ID to remove, e.g. '123456789'.
    .EXAMPLE
        Remove-GSMWorkshopItem -FolderName 'Insurgency2014' -WorkshopID '123456789'
    .NOTES
        Throws if FolderName's plugin doesn't support Workshop, if no config
        exists yet for FolderName, if WorkshopID isn't currently subscribed,
        or if the plugin's own removal function fails.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$FolderName,

        [Parameter(Mandatory)]
        [string]$WorkshopID
    )

    $pluginJson = Get-GSMWorkshopPluginJson -FolderName $FolderName
    Assert-GSMWorkshopSupported -PluginJson $pluginJson

    $config = Get-GSMWorkshopInstanceConfig -FolderName $FolderName
    $currentItems = Get-GSMWorkshopItemsArray -Config $config

    if ($currentItems -notcontains $WorkshopID) {
        throw "WorkshopID '$WorkshopID' is not currently subscribed for '$FolderName'."
    }

    Invoke-GSMWorkshopRemoval -FolderName $FolderName -WorkshopID $WorkshopID

    $updatedItems = @($currentItems | Where-Object { $_ -ne $WorkshopID })
    Add-Member -InputObject $config -NotePropertyName 'WorkshopItems' -NotePropertyValue $updatedItems -Force
    Set-GSMConfig -Path (Get-GSMWorkshopConfigPath -FolderName $FolderName) -Config $config

    Write-GSMLog -Level Info -Message "Removed Workshop item for '$FolderName': WorkshopID '$WorkshopID'."
    return $true
}

function Get-GSMWorkshopItems {
    <#
    .SYNOPSIS
        Returns the Workshop items currently subscribed for a server
        instance.
    .DESCRIPTION
        Reads Config/<FolderName>.json's WorkshopItems array. Reads config
        only - no SteamCMD invocation and no filesystem check of the placed
        content.
    .PARAMETER FolderName
        The plugin's folder name under Plugins/ (e.g. 'Insurgency2014').
    .EXAMPLE
        Get-GSMWorkshopItems -FolderName 'Insurgency2014'
    .NOTES
        Throws if FolderName's plugin doesn't support Workshop or if no
        config exists yet for FolderName, the same as every other function
        in this module. Returns an empty array, not an error, when
        WorkshopItems is present but empty (or absent from an older config).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [string]$FolderName
    )

    $pluginJson = Get-GSMWorkshopPluginJson -FolderName $FolderName
    Assert-GSMWorkshopSupported -PluginJson $pluginJson

    $config = Get-GSMWorkshopInstanceConfig -FolderName $FolderName

    return Get-GSMWorkshopItemsArray -Config $config
}

function Update-GSMWorkshopItems {
    <#
    .SYNOPSIS
        Refreshes every Workshop item currently subscribed for a server
        instance.
    .DESCRIPTION
        Re-runs the download+placement step (Sync-GSMWorkshopItem, the same
        internal logic Add-GSMWorkshopItem uses) for every WorkshopID
        already in Config/<FolderName>.json's WorkshopItems array, for
        refreshing stale content. Does not append or otherwise modify
        WorkshopItems - every ID refreshed here is already on the list, so
        there is nothing to add.
    .PARAMETER FolderName
        The plugin's folder name under Plugins/ (e.g. 'Insurgency2014').
    .EXAMPLE
        Update-GSMWorkshopItems -FolderName 'Insurgency2014'
    .NOTES
        Throws if FolderName's plugin doesn't support Workshop or if no
        config exists yet for FolderName. Stops at the first item that
        fails to download or place, leaving any items later in the list
        un-refreshed - a partial refresh is reported as a failure, not
        silently swallowed. A no-op (returns $true) when WorkshopItems is
        empty.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$FolderName
    )

    $pluginJson = Get-GSMWorkshopPluginJson -FolderName $FolderName
    Assert-GSMWorkshopSupported -PluginJson $pluginJson

    $config = Get-GSMWorkshopInstanceConfig -FolderName $FolderName
    $currentItems = Get-GSMWorkshopItemsArray -Config $config

    if ($currentItems.Count -eq 0) {
        Write-GSMLog -Level Info -Message "No Workshop items subscribed for '$FolderName'; Update-GSMWorkshopItems is a no-op."
        return $true
    }

    foreach ($workshopId in $currentItems) {
        Sync-GSMWorkshopItem -FolderName $FolderName -AppID $pluginJson.AppID -WorkshopID $workshopId
        Write-GSMLog -Level Info -Message "Refreshed Workshop item for '$FolderName': WorkshopID '$workshopId'."
    }

    return $true
}

function Show-GSMWorkshopMenu {
    <#
    .SYNOPSIS
        Interactive Workshop item management sub-menu for one server
        instance.
    .DESCRIPTION
        Loops prompting for a sub-action (Add, Remove, List, Refresh, Back)
        via Read-GSMPrompt and dispatches to this module's own
        Add/Remove/Get/Update-GSMWorkshopItem(s) functions, printing results
        or errors, until the user chooses Back. Called from
        Core/Menu.psm1's Show-MainMenu the same way Start-GSMRCONConsole is
        - a blocking, interactive action that bypasses Invoke-GSMAction's
        dispatch table entirely.
    .PARAMETER FolderName
        The plugin's folder name under Plugins/ (e.g. 'Insurgency2014').
    .EXAMPLE
        Show-GSMWorkshopMenu -FolderName 'Insurgency2014'
    .NOTES
        Every dispatched action's failure is caught and shown as a warning,
        never allowed to throw out of the loop - matches
        Start-GSMRCONConsole's console-loop error handling.
    #>
    [CmdletBinding()]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive console sub-menu; output is direct user-facing display, not pipeline data. Matches the same justification used for Show-MainMenu in Core/Menu.psm1 and Start-GSMRCONConsole in Core/RCON.psm1.')]
    param(
        [Parameter(Mandatory)]
        [string]$FolderName
    )

    while ($true) {
        $subAction = Read-GSMPrompt -Message "Workshop items for '$FolderName' - Add, Remove, List, Refresh, or Back" -ValidValues @('Add', 'Remove', 'List', 'Refresh', 'Back')

        if ($subAction -eq 'Back') {
            return
        }

        try {
            switch ($subAction) {
                'Add' {
                    $workshopId = Read-GSMPrompt -Message 'Workshop ID to add'
                    Add-GSMWorkshopItem -FolderName $FolderName -WorkshopID $workshopId | Out-Null
                    Write-Host "Added Workshop item '$workshopId'." -ForegroundColor Green
                }
                'Remove' {
                    $workshopId = Read-GSMPrompt -Message 'Workshop ID to remove'
                    Remove-GSMWorkshopItem -FolderName $FolderName -WorkshopID $workshopId | Out-Null
                    Write-Host "Removed Workshop item '$workshopId'." -ForegroundColor Green
                }
                'List' {
                    # Get-GSMWorkshopItems already returns a proper array (it
                    # forwards Get-GSMWorkshopItemsArray's -NoEnumerate output
                    # through its own "return"). Wrapping that in @(...) here
                    # would treat the whole array as a single element of a
                    # new outer array, since @(...) collects pipeline output
                    # objects rather than flattening an array that's already
                    # one such object.
                    $items = Get-GSMWorkshopItems -FolderName $FolderName
                    if ($items.Count -eq 0) {
                        Write-Host 'No Workshop items subscribed.'
                    }
                    else {
                        Write-Host "Subscribed Workshop items: $($items -join ', ')"
                    }
                }
                'Refresh' {
                    Update-GSMWorkshopItems -FolderName $FolderName | Out-Null
                    Write-Host 'Workshop items refreshed.' -ForegroundColor Green
                }
            }
        }
        catch {
            Write-Warning "Workshop $subAction failed: $($_.Exception.Message)"
        }
    }
}

Export-ModuleMember -Function Add-GSMWorkshopItem, Remove-GSMWorkshopItem, Get-GSMWorkshopItems, Update-GSMWorkshopItems, Show-GSMWorkshopMenu
