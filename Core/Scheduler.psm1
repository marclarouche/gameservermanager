#Requires -Version 7.0
<#
.SYNOPSIS
    Scheduled nightly restart and update-check maintenance for GSM server
    instances.
.DESCRIPTION
    Phase 3 (PRD section 9). Registers two Scheduled Task triggers per
    server instance: a nightly restart (default 04:00) and a nightly
    update check (default 04:15, staggered 15 minutes later so it doesn't
    race the restart). Reuses the same Scheduled Task cmdlets and
    credential-handling pattern Core/ProcessManager.psm1's Start-GSMServer
    already established (Register-ScheduledTask/Unregister-ScheduledTask,
    the service account's plaintext password extracted fresh and dropped
    immediately after each individual Register-ScheduledTask call) rather
    than inventing a second way to talk to Task Scheduler. ProcessManager.psm1
    doesn't export that logic as a standalone helper (it's inlined in
    Start-GSMServer), so there is nothing to import and call here; this
    module mirrors the same cmdlet sequence and conventions instead.

    Each trigger runs in its own fresh pwsh.exe process (Task Scheduler
    doesn't share GSM's interactive session), which imports
    Core/PluginLoader.psm1 to load the target plugin - the same lookup
    Core/Menu.psm1's Invoke-GSMAction uses - then calls either
    Core/Service.psm1's Restart-GSMServer (nightly restart) or
    Core/Update.psm1's Update-GSMServer (nightly update check, which
    already owns the full stop/update/verify/restart cycle; this module
    only invokes it and logs the outcome). Both are called with the same
    FolderName/Executable/GetLaunchArgsFunctionName/AccountName parameter
    set every other Phase 2 dispatch call uses, so Restart-GSMServer is
    "dispatched through whichever ProcessManager mode the instance is set
    to" automatically - that dispatch already lives inside Service.psm1
    itself, not duplicated here.

    Phase 6 adds a third, optional trigger: a nightly Workshop refresh
    (default 03:45, 15 minutes before the nightly restart, so a slow
    refresh can't push into restart time), registered via
    Register-GSMWorkshopRefreshSchedule rather than folded into
    Register-GSMScheduledMaintenance - unlike restart/update-check, it
    only applies to Workshop-capable instances with at least one
    subscribed item, so it needs its own preconditions and is a normal
    no-op (not an error) for every instance that doesn't meet them. It
    calls Core/Workshop.psm1's Update-GSMWorkshopItems, which takes only
    -FolderName (it reads WorkshopItems from that instance's own config
    internally) - unlike Restart-GSMServer/Update-GSMServer, it has no use
    for Executable/GetLaunchArgsFunctionName, so those became optional
    parameters on the shared Get-GSMSchedulerMaintenanceCommandText/
    Register-GSMSchedulerMaintenanceTask helpers rather than being given
    fake placeholder values for this kind. Unregister-GSMScheduledMaintenance
    and Get-GSMScheduledMaintenanceStatus fold WorkshopRefresh into their
    existing three-kind loops rather than gaining a separate
    Unregister-GSMWorkshopRefreshSchedule function - removal/status
    reporting for a task that may or may not exist is already idempotent
    per-task-name logic, so a fourth kind costs nothing there, and callers
    get one single teardown/status entry point for an instance rather than
    needing to remember a second one just for Workshop refresh.
.NOTES
    GetLaunchArgsFunctionName isn't stored anywhere in Plugin.json or
    instance config; it's derived from the "Get-<FolderName>LaunchArgs"
    naming convention every one of the five Phase 1 plugins' Server.psm1
    already follows (confirmed against all five before writing this).
    That keeps this module Core-level and instance-generic, with no
    per-plugin code or config needed to register maintenance for a new
    plugin.
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Utilities.psm1') -Force
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Logging.psm1') -Force
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Config.psm1') -Force
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'PluginLoader.psm1') -Force
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'ServiceAccount.psm1') -Force

# Defaults applied when an instance's config omits RestartTime/UpdateCheckTime
# (Core/Config.psm1's Test-GSMConfig validates the format when present, but
# does not apply these defaults - that's this module's job). Staggered 15
# minutes apart so a nightly update check doesn't race a nightly restart.
$script:GSMSchedulerDefaultRestartTime = '04:00'
$script:GSMSchedulerDefaultUpdateCheckTime = '04:15'

# Default applied when an instance's config omits WorkshopRefreshTime.
# Deliberately before NightlyRestart's 04:00, not after, so a slow Workshop
# refresh can't push into restart time.
$script:GSMSchedulerDefaultWorkshopRefreshTime = '03:45'

function Get-GSMSchedulerConfigPropertyValue {
    # Internal helper. Not exported: reads a property from a config psobject
    # via PSObject.Properties, returning $null when it doesn't exist instead
    # of letting dot-notation throw under Set-StrictMode -Version Latest.
    # Duplicated from Core/Config.psm1's own (not exported) helper rather
    # than imported unqualified, matching this codebase's established
    # convention of small per-module property helpers (see the comment on
    # Core/Service.psm1's Get-GSMServerConfigPath for the same rationale).
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

    return $property.Value
}

function Get-GSMSchedulerPluginJson {
    # Internal helper. Not exported: resolves and validates
    # Plugins/<FolderName>/Plugin.json for its Executable field, reusing
    # Core/PluginLoader.psm1's own Test-GSMPlugin rather than duplicating
    # Plugin.json schema validation. Mirrors Core/Firewall.psm1's identical
    # helper.
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory)]
        [string]$FolderName
    )

    $pluginJsonPath = Join-Path -Path (Get-GSMRootPath) -ChildPath "Plugins/$FolderName/Plugin.json"

    if (-not (Test-Path -Path $pluginJsonPath -PathType Leaf)) {
        throw "Plugin.json not found for '$FolderName' at '$pluginJsonPath'."
    }

    try {
        $rawJson = Get-Content -Path $pluginJsonPath -Raw -ErrorAction Stop
        $pluginJson = $rawJson | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Failed to read Plugin.json for '$FolderName': $($_.Exception.Message)"
    }

    Test-GSMPlugin -PluginJson $pluginJson

    return $pluginJson
}

function Get-GSMSchedulerTaskName {
    # Internal helper. Not exported: builds the "GSM-<FolderName>-<Kind>"
    # Scheduled Task name shared by Register-GSMScheduledMaintenance,
    # Unregister-GSMScheduledMaintenance, and Get-GSMScheduledMaintenanceStatus.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$FolderName,

        [Parameter(Mandatory)]
        [ValidateSet('NightlyRestart', 'NightlyUpdateCheck', 'WorkshopRefresh')]
        [string]$Kind
    )

    return "GSM-$FolderName-$Kind"
}

function Get-GSMSchedulerMaintenanceCommandText {
    # Internal helper. Not exported: builds the PowerShell script text a
    # Scheduled Task runs when a maintenance trigger fires, in a fresh
    # pwsh.exe process. Token substitution (Replace), not the -f format
    # operator, builds this string deliberately: the template's own
    # try/catch blocks use literal curly braces, which -f would misread as
    # format placeholders.
    #
    # Executable/GetLaunchArgsFunctionName are optional (unlike
    # AccountName/ActionModulePath/ActionFunctionName): WorkshopRefresh's
    # action function (Update-GSMWorkshopItems) takes only -FolderName, so
    # there is no real value to supply for either - passing a fake
    # placeholder string would be confusing to read later, so the
    # WorkshopRefresh template simply never references those tokens
    # instead.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$FolderName,

        [Parameter()]
        [string]$Executable = '',

        [Parameter()]
        [string]$GetLaunchArgsFunctionName = '',

        [Parameter(Mandatory)]
        [string]$AccountName,

        [Parameter(Mandatory)]
        [string]$ActionModulePath,

        [Parameter(Mandatory)]
        [string]$ActionFunctionName,

        [Parameter(Mandatory)]
        [ValidateSet('NightlyRestart', 'NightlyUpdateCheck', 'WorkshopRefresh')]
        [string]$Kind
    )

    $rootPath = Get-GSMRootPath
    $pluginLoaderPath = Join-Path -Path $rootPath -ChildPath 'Core/PluginLoader.psm1'
    $loggingPath = Join-Path -Path $rootPath -ChildPath 'Core/Logging.psm1'

    $template = if ($Kind -eq 'WorkshopRefresh') {
        @'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try {
    Import-Module '__LOGGING__' -Force
    Import-Module '__PLUGINLOADER__' -Force
    Import-Module '__ACTIONMODULE__' -Force
    Import-GSMPlugin -FolderName '__FOLDERNAME__'
    __ACTIONFUNCTION__ -FolderName '__FOLDERNAME__' | Out-Null
    Write-GSMLog -Level Info -Message "Scheduled __KIND__ succeeded for '__FOLDERNAME__'."
}
catch {
    Write-GSMLog -Level Error -Message "Scheduled __KIND__ failed for '__FOLDERNAME__': $($_.Exception.Message)"
    exit 1
}
'@
    }
    else {
        @'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try {
    Import-Module '__LOGGING__' -Force
    Import-Module '__PLUGINLOADER__' -Force
    Import-Module '__ACTIONMODULE__' -Force
    Import-GSMPlugin -FolderName '__FOLDERNAME__'
    __ACTIONFUNCTION__ -FolderName '__FOLDERNAME__' -Executable '__EXECUTABLE__' -GetLaunchArgsFunctionName '__LAUNCHARGSFUNCTION__' -AccountName '__ACCOUNTNAME__' | Out-Null
    Write-GSMLog -Level Info -Message "Scheduled __KIND__ succeeded for '__FOLDERNAME__'."
}
catch {
    Write-GSMLog -Level Error -Message "Scheduled __KIND__ failed for '__FOLDERNAME__': $($_.Exception.Message)"
    exit 1
}
'@
    }

    return $template.
        Replace('__LOGGING__', $loggingPath).
        Replace('__PLUGINLOADER__', $pluginLoaderPath).
        Replace('__ACTIONMODULE__', $ActionModulePath).
        Replace('__ACTIONFUNCTION__', $ActionFunctionName).
        Replace('__FOLDERNAME__', $FolderName).
        Replace('__EXECUTABLE__', $Executable).
        Replace('__LAUNCHARGSFUNCTION__', $GetLaunchArgsFunctionName).
        Replace('__ACCOUNTNAME__', $AccountName).
        Replace('__KIND__', $Kind)
}

function New-GSMSchedulerTaskAction {
    # Internal helper. Not exported: builds the New-ScheduledTaskAction
    # object for a maintenance task. Launches a fresh pwsh.exe (resolved via
    # $PSHOME, the currently running PowerShell installation's own
    # directory, not a PATH lookup) with CommandText passed as a base64
    # -EncodedCommand - avoids the multi-level quoting hazards of embedding
    # a script that has its own nested single/double quotes directly into a
    # Task Scheduler action's command-line argument.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$CommandText
    )

    $pwshExecutable = Join-Path -Path $PSHOME -ChildPath 'pwsh.exe'
    $encodedCommand = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($CommandText))

    return New-ScheduledTaskAction -Execute $pwshExecutable -Argument "-NoProfile -NonInteractive -EncodedCommand $encodedCommand"
}

function Register-GSMSchedulerMaintenanceTask {
    # Internal helper. Not exported: registers (or re-registers) a single
    # Scheduled Task for one maintenance kind. Always unregisters any
    # existing task of the same name first, matching
    # Core/ProcessManager.psm1's Start-GSMServer always re-registering its
    # own Scheduled Task fresh rather than layering changes onto a stale
    # definition.
    #
    # Executable/GetLaunchArgsFunctionName are optional, not Mandatory: see
    # Get-GSMSchedulerMaintenanceCommandText's identical .NOTES -
    # Register-GSMWorkshopRefreshSchedule calls this without either, since
    # Update-GSMWorkshopItems has no use for them.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$FolderName,

        [Parameter(Mandatory)]
        [string]$Kind,

        [Parameter(Mandatory)]
        [string]$TaskName,

        [Parameter(Mandatory)]
        [string]$Time,

        [Parameter(Mandatory)]
        [string]$ActionModulePath,

        [Parameter(Mandatory)]
        [string]$ActionFunctionName,

        [Parameter()]
        [string]$Executable = '',

        [Parameter()]
        [string]$GetLaunchArgsFunctionName = '',

        [Parameter(Mandatory)]
        [string]$AccountName,

        [Parameter(Mandatory)]
        [pscredential]$Credential
    )

    try {
        $triggerTime = [datetime]::ParseExact($Time, 'HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
    }
    catch {
        throw "'$Time' is not a valid HH:mm time for scheduled task '$TaskName'."
    }

    $commandText = Get-GSMSchedulerMaintenanceCommandText -FolderName $FolderName -Executable $Executable `
        -GetLaunchArgsFunctionName $GetLaunchArgsFunctionName -AccountName $AccountName `
        -ActionModulePath $ActionModulePath -ActionFunctionName $ActionFunctionName -Kind $Kind

    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

    $action = New-GSMSchedulerTaskAction -CommandText $commandText
    $trigger = New-ScheduledTaskTrigger -Daily -At $triggerTime
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

    # PSScriptAnalyzer's PSAvoidUsingPlainTextForPassword rule flags any
    # *parameter* named/typed like a plaintext password, not local
    # variables - so the plaintext is extracted here, immediately before
    # the one call that needs it, and dropped in the finally block, rather
    # than accepted as a -PlainPassword parameter on this function (the
    # same Windows API limitation Core/ProcessManager.psm1's
    # Start-GSMServer documents: Register-ScheduledTask -Password has no
    # SecureString-accepting overload).
    $plainPassword = $Credential.GetNetworkCredential().Password
    try {
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -User $Credential.UserName -Password $plainPassword -RunLevel Limited -Force -ErrorAction Stop | Out-Null
    }
    catch {
        Write-GSMLog -Level Error -Message "Failed to register scheduled maintenance task '$TaskName' for '$FolderName': $($_.Exception.Message)"
        throw "Failed to register scheduled maintenance task '$TaskName' for '$FolderName': $($_.Exception.Message)"
    }
    finally {
        $plainPassword = $null
    }

    Write-GSMLog -Level Info -Message "Registered scheduled maintenance task '$TaskName' ($Kind at $Time) for '$FolderName'."
}

function Register-GSMScheduledMaintenance {
    <#
    .SYNOPSIS
        Registers nightly restart and update-check Scheduled Tasks for a
        server instance.
    .DESCRIPTION
        Reads Config/<FolderName>.json for RestartTime/UpdateCheckTime
        (defaulting to '04:00'/'04:15' when absent) and
        Plugins/<FolderName>/Plugin.json for Executable, derives the
        instance's "Get-<FolderName>LaunchArgs" function name by
        convention, then registers two Scheduled Tasks:
        "GSM-<FolderName>-NightlyRestart" (calls Core/Service.psm1's
        Restart-GSMServer) and "GSM-<FolderName>-NightlyUpdateCheck" (calls
        Core/Update.psm1's Update-GSMServer). Each re-registers fresh -
        idempotent the same way Start-GSMServer is: calling this again
        after a config change (a new RestartTime, for example) replaces the
        old trigger rather than adding a second one.
    .PARAMETER FolderName
        The plugin's folder name under Plugins/ (e.g. 'Insurgency2014').
    .PARAMETER AccountName
        Name of GSM's local service account to run the maintenance tasks
        as, and to pass through to Restart-GSMServer/Update-GSMServer.
        Defaults to 'GSM-ServiceAccount'.
    .EXAMPLE
        Register-GSMScheduledMaintenance -FolderName 'Insurgency2014'
    .NOTES
        Throws if Config/<FolderName>.json or Plugin.json is missing/
        invalid, if either configured time isn't a valid HH:mm value, or if
        either Register-ScheduledTask call fails. The service account's
        plaintext password is used only for the two Register-ScheduledTask
        calls and dropped immediately after, the same pattern
        Core/ProcessManager.psm1 and Core/Service.psm1 already use.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$FolderName,

        [Parameter()]
        [string]$AccountName = 'GSM-ServiceAccount'
    )

    $rootPath = Get-GSMRootPath
    $configPath = Join-Path -Path $rootPath -ChildPath "Config/$FolderName.json"

    if (-not (Test-Path -Path $configPath -PathType Leaf)) {
        throw "No config found for '$FolderName' at '$configPath'. Run the Configure action first."
    }
    $config = Get-GSMConfig -Path $configPath

    $pluginJson = Get-GSMSchedulerPluginJson -FolderName $FolderName

    $restartTime = Get-GSMSchedulerConfigPropertyValue -Config $config -Name 'RestartTime'
    if ([string]::IsNullOrWhiteSpace($restartTime)) {
        $restartTime = $script:GSMSchedulerDefaultRestartTime
    }

    $updateCheckTime = Get-GSMSchedulerConfigPropertyValue -Config $config -Name 'UpdateCheckTime'
    if ([string]::IsNullOrWhiteSpace($updateCheckTime)) {
        $updateCheckTime = $script:GSMSchedulerDefaultUpdateCheckTime
    }

    $getLaunchArgsFunctionName = "Get-${FolderName}LaunchArgs"
    $servicePath = Join-Path -Path $rootPath -ChildPath 'Core/Service.psm1'
    $updatePath = Join-Path -Path $rootPath -ChildPath 'Core/Update.psm1'

    $credential = Get-GSMServiceAccountCredential -AccountName $AccountName

    # Register-GSMSchedulerMaintenanceTask extracts and drops its own
    # plaintext password per call now (see its .NOTES) - nothing here holds
    # onto one.
    Register-GSMSchedulerMaintenanceTask -FolderName $FolderName -Kind 'NightlyRestart' `
        -TaskName (Get-GSMSchedulerTaskName -FolderName $FolderName -Kind 'NightlyRestart') `
        -Time $restartTime -ActionModulePath $servicePath -ActionFunctionName 'Restart-GSMServer' `
        -Executable $pluginJson.Executable -GetLaunchArgsFunctionName $getLaunchArgsFunctionName `
        -AccountName $AccountName -Credential $credential

    Register-GSMSchedulerMaintenanceTask -FolderName $FolderName -Kind 'NightlyUpdateCheck' `
        -TaskName (Get-GSMSchedulerTaskName -FolderName $FolderName -Kind 'NightlyUpdateCheck') `
        -Time $updateCheckTime -ActionModulePath $updatePath -ActionFunctionName 'Update-GSMServer' `
        -Executable $pluginJson.Executable -GetLaunchArgsFunctionName $getLaunchArgsFunctionName `
        -AccountName $AccountName -Credential $credential

    return $true
}

function Register-GSMWorkshopRefreshSchedule {
    <#
    .SYNOPSIS
        Registers a nightly Workshop refresh Scheduled Task for a server
        instance, if applicable.
    .DESCRIPTION
        Reads Plugins/<FolderName>/Plugin.json's SupportsWorkshop field; if
        it's not true, registers nothing and returns $false (an Info log
        line, not an error - CounterStrikeSource and L4D simply have
        nothing to schedule). Reads Config/<FolderName>.json's
        WorkshopItems array; if it's empty, also registers nothing and
        returns $false (Info-logged) - there's nothing to refresh yet for
        an instance with no subscribed Workshop items. Otherwise reads
        WorkshopRefreshTime from config (defaulting to '03:45' when
        absent) and registers "GSM-<FolderName>-WorkshopRefresh", which
        calls Core/Workshop.psm1's Update-GSMWorkshopItems. Idempotent the
        same way Register-GSMScheduledMaintenance's tasks are: calling
        this again (e.g. after a new item is subscribed) replaces the
        existing trigger rather than adding a second one.
    .PARAMETER FolderName
        The plugin's folder name under Plugins/ (e.g. 'Insurgency2014').
    .PARAMETER AccountName
        Name of GSM's local service account to run the scheduled task as.
        Defaults to 'GSM-ServiceAccount', matching
        Register-GSMScheduledMaintenance's parameter shape - not used by
        Update-GSMWorkshopItems itself (it takes only -FolderName), only
        by the Scheduled Task's own run-as identity and credential lookup.
    .EXAMPLE
        Register-GSMWorkshopRefreshSchedule -FolderName 'Insurgency2014'
    .NOTES
        Throws if Config/<FolderName>.json is missing, if Plugin.json is
        missing/invalid, if WorkshopRefreshTime isn't a valid HH:mm value,
        or if Register-ScheduledTask fails - the same failure modes
        Register-GSMScheduledMaintenance has. Returning $false rather than
        throwing for the two "nothing to schedule" cases (unsupported
        game, no subscribed items) keeps this safe to call unconditionally
        for every instance during a broader maintenance-setup pass,
        without every caller needing to pre-check SupportsWorkshop or
        WorkshopItems itself first.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$FolderName,

        [Parameter()]
        [string]$AccountName = 'GSM-ServiceAccount'
    )

    $rootPath = Get-GSMRootPath

    $pluginJson = Get-GSMSchedulerPluginJson -FolderName $FolderName
    if ($pluginJson.SupportsWorkshop -ne $true) {
        Write-GSMLog -Level Info -Message "'$FolderName' does not support Steam Workshop; no Workshop refresh scheduled."
        return $false
    }

    $configPath = Join-Path -Path $rootPath -ChildPath "Config/$FolderName.json"
    if (-not (Test-Path -Path $configPath -PathType Leaf)) {
        throw "No config found for '$FolderName' at '$configPath'. Run the Configure action first."
    }
    $config = Get-GSMConfig -Path $configPath

    # Two stacked gotchas here, not one. First: @(...) around a possibly-
    # $null property value would otherwise wrap $null into a one-element
    # array containing $null, not an empty array - the same trap
    # Core/Workshop.psm1's Get-GSMWorkshopItemsArray guards against.
    # Second, easy to miss: "$workshopItems = if (...) { @() } else {...}"
    # (the if/else's result captured as a single expression) enumerates an
    # empty-array branch to zero pipeline objects, same as "return $array"
    # does - it would silently reintroduce the first gotcha even with the
    # $null-check in place. Using if/else as plain imperative statements,
    # each assigning $workshopItems directly inside its own block, avoids
    # both: a literal "$workshopItems = @()" assigned this way is a direct
    # value assignment, not something PowerShell enumerates.
    $workshopItemsValue = Get-GSMSchedulerConfigPropertyValue -Config $config -Name 'WorkshopItems'
    if ($null -eq $workshopItemsValue) {
        $workshopItems = [string[]]@()
    }
    else {
        $workshopItems = [string[]]@($workshopItemsValue)
    }

    if ($workshopItems.Count -eq 0) {
        Write-GSMLog -Level Info -Message "'$FolderName' has no subscribed Workshop items; no Workshop refresh scheduled."
        return $false
    }

    $workshopRefreshTime = Get-GSMSchedulerConfigPropertyValue -Config $config -Name 'WorkshopRefreshTime'
    if ([string]::IsNullOrWhiteSpace($workshopRefreshTime)) {
        $workshopRefreshTime = $script:GSMSchedulerDefaultWorkshopRefreshTime
    }

    $workshopModulePath = Join-Path -Path $rootPath -ChildPath 'Core/Workshop.psm1'

    $credential = Get-GSMServiceAccountCredential -AccountName $AccountName

    Register-GSMSchedulerMaintenanceTask -FolderName $FolderName -Kind 'WorkshopRefresh' `
        -TaskName (Get-GSMSchedulerTaskName -FolderName $FolderName -Kind 'WorkshopRefresh') `
        -Time $workshopRefreshTime -ActionModulePath $workshopModulePath -ActionFunctionName 'Update-GSMWorkshopItems' `
        -AccountName $AccountName -Credential $credential

    return $true
}

function Unregister-GSMScheduledMaintenance {
    <#
    .SYNOPSIS
        Removes a server instance's nightly restart, update-check, and
        Workshop refresh Scheduled Tasks.
    .DESCRIPTION
        Removes "GSM-<FolderName>-NightlyRestart",
        "GSM-<FolderName>-NightlyUpdateCheck", and
        "GSM-<FolderName>-WorkshopRefresh" if they exist. A no-op (logged
        as info, not an error) for any task that isn't registered - safe
        to call even for an instance that never had a Workshop refresh
        task registered in the first place (CounterStrikeSource, L4D, or
        any Workshop-capable instance with no subscribed items yet).
    .PARAMETER FolderName
        The plugin's folder name under Plugins/ (e.g. 'Insurgency2014').
    .EXAMPLE
        Unregister-GSMScheduledMaintenance -FolderName 'Insurgency2014'
    .NOTES
        Never throws. A failure removing a task that does exist is logged
        as a warning, not fatal, so one bad task doesn't block removal of
        the others.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$FolderName
    )

    $taskNames = @(
        (Get-GSMSchedulerTaskName -FolderName $FolderName -Kind 'NightlyRestart'),
        (Get-GSMSchedulerTaskName -FolderName $FolderName -Kind 'NightlyUpdateCheck'),
        (Get-GSMSchedulerTaskName -FolderName $FolderName -Kind 'WorkshopRefresh')
    )

    foreach ($taskName in $taskNames) {
        $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue

        if (-not $existingTask) {
            Write-GSMLog -Level Info -Message "No scheduled maintenance task '$taskName' found; nothing to remove."
            continue
        }

        try {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
            Write-GSMLog -Level Info -Message "Removed scheduled maintenance task '$taskName'."
        }
        catch {
            Write-GSMLog -Level Warning -Message "Failed to remove scheduled maintenance task '$taskName' (it may have already been removed): $($_.Exception.Message)"
        }
    }

    return $true
}

function Get-GSMScheduledMaintenanceStatus {
    <#
    .SYNOPSIS
        Reports a server instance's nightly restart, update-check, and
        Workshop refresh Scheduled Task status.
    .DESCRIPTION
        Returns one object per registered task ("GSM-<FolderName>-
        NightlyRestart", "GSM-<FolderName>-NightlyUpdateCheck", and/or
        "GSM-<FolderName>-WorkshopRefresh") with its Kind, State,
        NextRunTime, LastRunTime, and LastTaskResult (from
        Get-ScheduledTaskInfo). A task that isn't registered is simply
        omitted, not reported as an error; an instance with none of the
        three registered returns an empty array. WorkshopRefresh only
        ever appears here if Register-GSMWorkshopRefreshSchedule actually
        registered it (Workshop-capable plugin, at least one subscribed
        item) - there is no separate "not applicable" state, it's just
        absent from the results the same way an un-registered
        NightlyRestart would be.
    .PARAMETER FolderName
        The plugin's folder name under Plugins/ (e.g. 'Insurgency2014').
    .EXAMPLE
        Get-GSMScheduledMaintenanceStatus -FolderName 'Insurgency2014'
    #>
    [CmdletBinding()]
    [OutputType([psobject[]])]
    param(
        [Parameter(Mandatory)]
        [string]$FolderName
    )

    $taskDefinitions = @(
        [PSCustomObject]@{ Kind = 'NightlyRestart'; TaskName = (Get-GSMSchedulerTaskName -FolderName $FolderName -Kind 'NightlyRestart') }
        [PSCustomObject]@{ Kind = 'NightlyUpdateCheck'; TaskName = (Get-GSMSchedulerTaskName -FolderName $FolderName -Kind 'NightlyUpdateCheck') }
        [PSCustomObject]@{ Kind = 'WorkshopRefresh'; TaskName = (Get-GSMSchedulerTaskName -FolderName $FolderName -Kind 'WorkshopRefresh') }
    )

    $statuses = [System.Collections.Generic.List[psobject]]::new()

    foreach ($definition in $taskDefinitions) {
        $task = Get-ScheduledTask -TaskName $definition.TaskName -ErrorAction SilentlyContinue
        if (-not $task) {
            continue
        }

        $info = Get-ScheduledTaskInfo -TaskName $definition.TaskName -ErrorAction SilentlyContinue

        $statuses.Add([PSCustomObject]@{
                FolderName     = $FolderName
                Kind           = $definition.Kind
                TaskName       = $definition.TaskName
                State          = $task.State
                NextRunTime    = if ($info) { $info.NextRunTime } else { $null }
                LastRunTime    = if ($info) { $info.LastRunTime } else { $null }
                LastTaskResult = if ($info) { $info.LastTaskResult } else { $null }
            })
    }

    return $statuses.ToArray()
}

Export-ModuleMember -Function Register-GSMScheduledMaintenance, Unregister-GSMScheduledMaintenance, Get-GSMScheduledMaintenanceStatus, Register-GSMWorkshopRefreshSchedule
