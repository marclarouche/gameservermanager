#Requires -Version 7.0
<#
.SYNOPSIS
    NSSM-backed game server process lifecycle for GSM (Phase 2).
.DESCRIPTION
    Phase 2 (PRD section 9). A drop-in alternative to
    Core/ProcessManager.psm1: exports the same public function names and
    parameters (Start-GSMServer, Stop-GSMServer, Restart-GSMServer,
    Get-GSMServerStatus), so per-plugin Server.psm1 thin wrappers can import
    this module instead with no call-site changes.

    Each of those four functions reads the target server's
    Config/<FolderName>.json ProcessManager field ('NSSM', the default when
    the field is absent, or 'ScheduledTask') and either runs this module's
    own NSSM-backed logic or delegates to Core/ProcessManager.psm1's
    original Scheduled Task logic. ProcessManager.psm1 is imported here with
    a 'ScheduledTask' prefix (Start-ScheduledTaskGSMServer etc.) so its
    exports don't collide with this module's own same-named ones.

    NSSM mode registers each server as a genuine Windows Service
    (Tools/NSSM/nssm.exe, Core/NSSM.psm1) running under GSM's service
    account (Core/ServiceAccount.psm1's SeServiceLogonRight), with NSSM's
    own AppExit=Restart crash recovery configured via
    Set-GSMServiceCrashRecovery. That's the capability the Scheduled
    Task-based Phase 1 approach could never provide natively: a Scheduled
    Task has no equivalent of a service's automatic restart-on-crash
    behavior.
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Utilities.psm1')
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Logging.psm1')
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Config.psm1') -Force
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'ServiceAccount.psm1') -Force
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'NSSM.psm1') -Force
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'ProcessManager.psm1') -Prefix 'ScheduledTask' -Force

function Get-GSMServiceName {
    # Internal helper. Not exported: the NSSM service name for FolderName.
    # Deliberately matches Core/ProcessManager.psm1's GSM-<FolderName>
    # Scheduled Task naming convention - both are keyed by FolderName, not
    # GameName, for the same reason (L4D and L4D2 share GameName
    # 'Left4Dead'; see Core/Menu.psm1's Invoke-GSMAction and the Phase 1
    # session notes on this).
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$FolderName
    )

    return "GSM-$FolderName"
}

function Get-GSMServerConfigPath {
    # Internal helper. Not exported: duplicated from Core/ProcessManager.psm1
    # (not exported there either) rather than imported unprefixed, matching
    # this codebase's existing convention of small per-module path/property
    # helpers living alongside their own module (e.g.
    # Get-GSMConfigPropertyValue in Core/Config.psm1 vs
    # Get-GSMPluginPropertyValue in Core/PluginLoader.psm1).
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$FolderName
    )

    return Join-Path -Path (Get-GSMRootPath) -ChildPath "Config/$FolderName.json"
}

function Get-GSMServerInstallDirectory {
    # Internal helper. Not exported: duplicated from Core/ProcessManager.psm1
    # for the same reason as Get-GSMServerConfigPath above.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$FolderName
    )

    return Join-Path -Path (Get-GSMRootPath) -ChildPath "Servers/$FolderName"
}

function Resolve-GSMServerProcessManagerMode {
    # Internal helper. Not exported: resolves FolderName's ProcessManager
    # mode by reading Config/<FolderName>.json if it exists.
    # Core/Config.psm1's Test-GSMConfig validates the field's value when
    # present; this only reads it. Missing config, unreadable config, or a
    # missing field all resolve to 'NSSM' - the same default used
    # everywhere this field is consulted, so a server whose config predates
    # this field (or was already removed) is never silently treated as
    # ScheduledTask.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$FolderName
    )

    $configPath = Get-GSMServerConfigPath -FolderName $FolderName
    if (-not (Test-Path -Path $configPath -PathType Leaf)) {
        return 'NSSM'
    }

    try {
        $config = Get-GSMConfig -Path $configPath
    }
    catch {
        return 'NSSM'
    }

    $property = $config.PSObject.Properties['ProcessManager']
    if ($null -eq $property -or [string]::IsNullOrWhiteSpace($property.Value)) {
        return 'NSSM'
    }

    return $property.Value
}

function Invoke-GSMNSSMCommand {
    # Internal helper. Not exported: runs Tools/NSSM/nssm.exe with
    # ArgumentList and returns its exit code (and, with -CaptureOutput, its
    # trimmed stdout). Callers decide how to interpret a non-zero exit code:
    # nssm's own semantics differ by subcommand (e.g. removing a service
    # that was never installed "fails" in a way callers here treat as a
    # no-op, not an error).
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string[]]$ArgumentList,

        [Parameter()]
        [switch]$CaptureOutput
    )

    if (-not (Test-NSSMPresent)) {
        throw 'NSSM is not installed. Run Install-NSSM first.'
    }

    $nssmExePath = Join-Path -Path (Get-GSMRootPath) -ChildPath 'Tools/NSSM/nssm.exe'
    $stdOutPath = $null

    try {
        $processParams = @{
            FilePath     = $nssmExePath
            ArgumentList = $ArgumentList
            Wait         = $true
            NoNewWindow  = $true
            PassThru     = $true
            ErrorAction  = 'Stop'
        }

        if ($CaptureOutput) {
            $stdOutPath = [System.IO.Path]::GetTempFileName()
            $processParams['RedirectStandardOutput'] = $stdOutPath
        }

        $process = Start-Process @processParams

        $stdOut = $null
        if ($CaptureOutput) {
            $stdOut = Get-Content -Path $stdOutPath -Raw -ErrorAction SilentlyContinue
            if ($stdOut) {
                $stdOut = $stdOut.Trim()
            }
        }

        return [PSCustomObject]@{
            ExitCode = $process.ExitCode
            StdOut   = $stdOut
        }
    }
    catch {
        throw "Failed to run nssm.exe with arguments '$($ArgumentList -join ' ')': $($_.Exception.Message)"
    }
    finally {
        if ($stdOutPath) {
            Remove-Item -Path $stdOutPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Install-GSMServerService {
    <#
    .SYNOPSIS
        Registers (or re-registers) FolderName's game server as an
        NSSM-managed Windows Service.
    .DESCRIPTION
        Installs NSSM first if it isn't already present, and provisions
        AccountName (via Test-GSMServiceAccount / New-GSMServiceAccount /
        Set-GSMServiceAccountRights) first if it doesn't already exist or
        doesn't yet have its expected rights - neither NSSM nor the service
        account bootstraps itself otherwise, and every real Start on a
        fresh machine needs both. Removes any existing service of the same
        name, then runs `nssm install` with ExecutablePath, followed by
        `nssm set` calls for AppParameters (the launch arguments,
        space-joined), AppDirectory, and ObjectName (the service account
        identity) - always re-applied from scratch, so the service reflects
        the current executable, launch arguments, and account rather than
        whatever was true the last time it was installed. Mirrors
        Core/ProcessManager.psm1's Start-GSMServer always re-registering
        its Scheduled Task fresh on every start.
    .PARAMETER FolderName
        The plugin's folder name under Plugins/ (e.g. 'Insurgency2014').
    .PARAMETER ExecutablePath
        Full path to the server executable.
    .PARAMETER InstallDirectory
        Directory to run the service from (NSSM's AppDirectory).
    .PARAMETER LaunchArguments
        Launch arguments to pass to the executable.
    .PARAMETER AccountName
        Name of GSM's local service account to run the service as. Defaults
        to 'GSM-ServiceAccount'.
    .EXAMPLE
        Install-GSMServerService -FolderName 'Insurgency2014' -ExecutablePath 'D:\GSM\Servers\Insurgency2014\srcds.exe' -InstallDirectory 'D:\GSM\Servers\Insurgency2014' -LaunchArguments @('-game','insurgency') -AccountName 'GSM-ServiceAccount'
    .NOTES
        Uses the service account's plaintext password only for the single
        `nssm set <svc> ObjectName` call, for the same reason
        Core/ProcessManager.psm1's Register-ScheduledTask -Password does:
        neither API has a SecureString-accepting form. The reference is
        dropped immediately after that one call.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$FolderName,

        [Parameter(Mandatory)]
        [string]$ExecutablePath,

        [Parameter(Mandatory)]
        [string]$InstallDirectory,

        [Parameter()]
        [string[]]$LaunchArguments = @(),

        [Parameter()]
        [string]$AccountName = 'GSM-ServiceAccount'
    )

    if (-not (Test-NSSMPresent)) {
        Install-NSSM | Out-Null
    }

    # Test-GSMServiceAccount logs its own Error-level messages for whichever
    # of its five conditions aren't met yet - expected and harmless the
    # first time this runs against a fresh account, since that's exactly
    # what "needs provisioning" looks like. New-GSMServiceAccount itself
    # requires elevation and throws a clear error if the session isn't
    # elevated; Start already requires elevation for this reason.
    if (-not (Test-GSMServiceAccount -AccountName $AccountName)) {
        New-GSMServiceAccount -AccountName $AccountName | Out-Null
        Set-GSMServiceAccountRights -AccountName $AccountName
    }

    $serviceName = Get-GSMServiceName -FolderName $FolderName

    # Idempotent removal first, so every install below reflects the current
    # executable/args/account rather than layering on top of a stale one.
    Invoke-GSMNSSMCommand -ArgumentList @('remove', $serviceName, 'confirm') | Out-Null

    $installResult = Invoke-GSMNSSMCommand -ArgumentList @('install', $serviceName, $ExecutablePath)
    if ($installResult.ExitCode -ne 0) {
        Write-GSMLog -Level Error -Message "nssm install failed for '$serviceName' (exit code $($installResult.ExitCode))."
        throw "Failed to install NSSM service '$serviceName' for '$FolderName' (nssm exit code $($installResult.ExitCode))."
    }

    if ($LaunchArguments.Count -gt 0) {
        $parametersResult = Invoke-GSMNSSMCommand -ArgumentList @('set', $serviceName, 'AppParameters', ($LaunchArguments -join ' '))
        if ($parametersResult.ExitCode -ne 0) {
            Write-GSMLog -Level Error -Message "nssm set AppParameters failed for '$serviceName' (exit code $($parametersResult.ExitCode))."
            throw "Failed to set launch arguments for NSSM service '$serviceName' (nssm exit code $($parametersResult.ExitCode))."
        }
    }

    $directoryResult = Invoke-GSMNSSMCommand -ArgumentList @('set', $serviceName, 'AppDirectory', $InstallDirectory)
    if ($directoryResult.ExitCode -ne 0) {
        Write-GSMLog -Level Error -Message "nssm set AppDirectory failed for '$serviceName' (exit code $($directoryResult.ExitCode))."
        throw "Failed to set working directory for NSSM service '$serviceName' (nssm exit code $($directoryResult.ExitCode))."
    }

    $credential = Get-GSMServiceAccountCredential -AccountName $AccountName
    $plainPassword = $credential.GetNetworkCredential().Password
    try {
        # NSSM's own `set ObjectName` call maps to the Windows
        # ChangeServiceConfig API, which - unlike Get-GSMServiceAccountCredential's
        # other consumer, Core/ProcessManager.psm1's Register-ScheduledTask -
        # rejects a bare local account name with "The account name is
        # invalid or does not exist, or the password is invalid," even
        # though the account genuinely exists. It needs the ".\" local-machine
        # qualifier; qualified only here, not on the shared credential
        # object itself, since that would also affect the ScheduledTask
        # path, which doesn't have this requirement.
        $qualifiedAccountName = ".\$($credential.UserName)"
        $objectNameResult = Invoke-GSMNSSMCommand -ArgumentList @('set', $serviceName, 'ObjectName', $qualifiedAccountName, $plainPassword)
        if ($objectNameResult.ExitCode -ne 0) {
            Write-GSMLog -Level Error -Message "nssm set ObjectName failed for '$serviceName' (exit code $($objectNameResult.ExitCode))."
            throw "Failed to set the service account identity for NSSM service '$serviceName' (nssm exit code $($objectNameResult.ExitCode))."
        }
    }
    finally {
        $plainPassword = $null
    }

    return $true
}

function Uninstall-GSMServerService {
    <#
    .SYNOPSIS
        Stops and removes FolderName's NSSM service.
    .DESCRIPTION
        Runs `nssm stop` (ignoring failure - it may already be stopped) then
        `nssm remove <svc> confirm`. Never throws: matches
        Core/ProcessManager.psm1's Stop-GSMServer contract of logging a
        warning rather than throwing when there is nothing to remove.
    .PARAMETER FolderName
        The plugin's folder name under Plugins/ (e.g. 'Insurgency2014').
    .EXAMPLE
        Uninstall-GSMServerService -FolderName 'Insurgency2014'
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$FolderName
    )

    $serviceName = Get-GSMServiceName -FolderName $FolderName

    Invoke-GSMNSSMCommand -ArgumentList @('stop', $serviceName) | Out-Null
    $result = Invoke-GSMNSSMCommand -ArgumentList @('remove', $serviceName, 'confirm')

    if ($result.ExitCode -ne 0) {
        Write-GSMLog -Level Warning -Message "nssm remove for '$serviceName' returned exit code $($result.ExitCode) (it may not have been installed)."
    }

    return $true
}

function Set-GSMServiceCrashRecovery {
    <#
    .SYNOPSIS
        Configures NSSM's built-in crash recovery for FolderName's service.
    .DESCRIPTION
        Sets AppExit Default Restart (NSSM restarts the app on any exit
        code, clean or not - a dedicated game server has no "expected" exit
        code that should be left stopped), plus AppRestartDelay and
        AppThrottle. Must be called after the service already exists (i.e.
        after Install-GSMServerService).
    .PARAMETER FolderName
        The plugin's folder name under Plugins/ (e.g. 'Insurgency2014').
    .PARAMETER RestartDelayMilliseconds
        Delay before NSSM restarts the app after it exits. Defaults to 5000
        (5 seconds): long enough that a crash-looping server doesn't hammer
        restarts every few hundred milliseconds, short enough that a
        one-off crash still recovers quickly.
    .PARAMETER ThrottleMilliseconds
        Minimum time, in milliseconds, the app must stay running before
        NSSM considers the start "successful" rather than a failed startup
        attempt - falling short of this repeatedly triggers NSSM's own
        escalating restart-delay backoff. Defaults to 10000 (10 seconds):
        dedicated game servers routinely take several seconds to bind ports
        and load the first map, so this is set well above NSSM's own
        built-in 1500ms default to avoid a slow-but-healthy startup being
        misclassified as a crash loop.
    .EXAMPLE
        Set-GSMServiceCrashRecovery -FolderName 'Insurgency2014'
    .NOTES
        Throws if any of the three `nssm set` calls fails, e.g. because the
        service doesn't exist yet.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$FolderName,

        [Parameter()]
        [int]$RestartDelayMilliseconds = 5000,

        [Parameter()]
        [int]$ThrottleMilliseconds = 10000
    )

    $serviceName = Get-GSMServiceName -FolderName $FolderName

    $exitResult = Invoke-GSMNSSMCommand -ArgumentList @('set', $serviceName, 'AppExit', 'Default', 'Restart')
    if ($exitResult.ExitCode -ne 0) {
        Write-GSMLog -Level Error -Message "nssm set AppExit failed for '$serviceName' (exit code $($exitResult.ExitCode))."
        throw "Failed to configure crash recovery (AppExit) for NSSM service '$serviceName' (nssm exit code $($exitResult.ExitCode))."
    }

    $delayResult = Invoke-GSMNSSMCommand -ArgumentList @('set', $serviceName, 'AppRestartDelay', $RestartDelayMilliseconds)
    if ($delayResult.ExitCode -ne 0) {
        Write-GSMLog -Level Error -Message "nssm set AppRestartDelay failed for '$serviceName' (exit code $($delayResult.ExitCode))."
        throw "Failed to configure crash recovery (AppRestartDelay) for NSSM service '$serviceName' (nssm exit code $($delayResult.ExitCode))."
    }

    $throttleResult = Invoke-GSMNSSMCommand -ArgumentList @('set', $serviceName, 'AppThrottle', $ThrottleMilliseconds)
    if ($throttleResult.ExitCode -ne 0) {
        Write-GSMLog -Level Error -Message "nssm set AppThrottle failed for '$serviceName' (exit code $($throttleResult.ExitCode))."
        throw "Failed to configure crash recovery (AppThrottle) for NSSM service '$serviceName' (nssm exit code $($throttleResult.ExitCode))."
    }

    return $true
}

function Sync-GSMServerServiceRegistration {
    # Internal helper. Not exported: resolves FolderName's current config,
    # launch args, and executable path, then (re)installs the NSSM service
    # and applies crash-recovery defaults. Shared setup that both
    # Start-GSMServer and Restart-GSMServer need before actually starting
    # or restarting the service, factored out so neither duplicates it.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$FolderName,

        [Parameter(Mandatory)]
        [string]$Executable,

        [Parameter(Mandatory)]
        [string]$GetLaunchArgsFunctionName,

        [Parameter(Mandatory)]
        [string]$AccountName
    )

    $configPath = Get-GSMServerConfigPath -FolderName $FolderName
    if (-not (Test-Path -Path $configPath -PathType Leaf)) {
        throw "No config found for '$FolderName' at '$configPath'. Run the Configure action first."
    }
    $config = Get-GSMConfig -Path $configPath

    $launchArgsCommand = Get-Command -Name $GetLaunchArgsFunctionName -ErrorAction SilentlyContinue
    if (-not $launchArgsCommand) {
        throw "Launch-argument function '$GetLaunchArgsFunctionName' is not available. Is the plugin imported?"
    }
    $launchArgs = @(& $launchArgsCommand -Config $config)

    $installDirectory = Get-GSMServerInstallDirectory -FolderName $FolderName
    $executablePath = Join-Path -Path $installDirectory -ChildPath $Executable
    if (-not (Test-Path -Path $executablePath -PathType Leaf)) {
        throw "Server executable not found at '$executablePath'. Run the Install action first."
    }

    Install-GSMServerService -FolderName $FolderName -ExecutablePath $executablePath -InstallDirectory $installDirectory -LaunchArguments $launchArgs -AccountName $AccountName | Out-Null
    Set-GSMServiceCrashRecovery -FolderName $FolderName | Out-Null
}

function Start-GSMServer {
    <#
    .SYNOPSIS
        Starts a game server, via an NSSM-managed Windows Service or a
        Scheduled Task depending on the server's config.
    .DESCRIPTION
        Reads Config/<FolderName>.json's ProcessManager field to choose a
        backend: 'ScheduledTask' delegates entirely to
        Core/ProcessManager.psm1's original Start-GSMServer; anything else
        (including a missing field, which defaults to 'NSSM') registers
        FolderName as an NSSM service (Install-GSMServerService), applies
        crash recovery (Set-GSMServiceCrashRecovery), runs `nssm start`, and
        polls Get-GSMServerStatus until it reports 'Running' or
        TimeoutSeconds elapses.

        A no-op returning $true if Get-GSMServerStatus already reports
        'Running' for FolderName.
    .PARAMETER FolderName
        The plugin's folder name under Plugins/ (e.g. 'Insurgency2014').
    .PARAMETER Executable
        The server executable's file name (e.g. 'srcds.exe'), resolved
        relative to Servers/<FolderName>.
    .PARAMETER GetLaunchArgsFunctionName
        Name of the plugin's own exported launch-argument-building function,
        which must accept a -Config parameter and return a string array.
    .PARAMETER AccountName
        Name of GSM's local service account to run the process as. Defaults
        to 'GSM-ServiceAccount'.
    .PARAMETER TimeoutSeconds
        How long to wait for the service to report 'Running' after starting
        it, in seconds. Defaults to 10.
    .PARAMETER PollIntervalMilliseconds
        How long to wait between status polls, in milliseconds. Defaults to
        500.
    .EXAMPLE
        Start-GSMServer -FolderName 'Insurgency2014' -Executable 'srcds.exe' -GetLaunchArgsFunctionName 'Get-Insurgency2014LaunchArgs'
    .NOTES
        Same parameter set as Core/ProcessManager.psm1's Start-GSMServer by
        design, so per-plugin Server.psm1 thin wrappers call this the exact
        same way regardless of which module they import.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$FolderName,

        [Parameter(Mandatory)]
        [string]$Executable,

        [Parameter(Mandatory)]
        [string]$GetLaunchArgsFunctionName,

        [Parameter()]
        [string]$AccountName = 'GSM-ServiceAccount',

        [Parameter()]
        [int]$TimeoutSeconds = 10,

        [Parameter()]
        [int]$PollIntervalMilliseconds = 500
    )

    $mode = Resolve-GSMServerProcessManagerMode -FolderName $FolderName

    if ($mode -eq 'ScheduledTask') {
        return Start-ScheduledTaskGSMServer -FolderName $FolderName -Executable $Executable -GetLaunchArgsFunctionName $GetLaunchArgsFunctionName -AccountName $AccountName -TimeoutSeconds $TimeoutSeconds -PollIntervalMilliseconds $PollIntervalMilliseconds
    }
    elseif ($mode -ne 'NSSM') {
        throw "Unknown ProcessManager mode '$mode' for '$FolderName'. Expected 'NSSM' or 'ScheduledTask'."
    }

    if ((Get-GSMServerStatus -FolderName $FolderName) -eq 'Running') {
        Write-GSMLog -Level Info -Message "Server '$FolderName' is already running; Start-GSMServer is a no-op."
        return $true
    }

    Sync-GSMServerServiceRegistration -FolderName $FolderName -Executable $Executable -GetLaunchArgsFunctionName $GetLaunchArgsFunctionName -AccountName $AccountName

    $serviceName = Get-GSMServiceName -FolderName $FolderName
    $startResult = Invoke-GSMNSSMCommand -ArgumentList @('start', $serviceName)
    if ($startResult.ExitCode -ne 0) {
        Write-GSMLog -Level Error -Message "nssm start failed for '$serviceName' (exit code $($startResult.ExitCode))."
        throw "Failed to start NSSM service '$serviceName' for '$FolderName' (nssm exit code $($startResult.ExitCode))."
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $isRunning = $false
    while (-not $isRunning -and (Get-Date) -lt $deadline) {
        if ((Get-GSMServerStatus -FolderName $FolderName) -eq 'Running') {
            $isRunning = $true
        }
        else {
            Start-Sleep -Milliseconds $PollIntervalMilliseconds
        }
    }

    if (-not $isRunning) {
        throw "Timeout waiting for NSSM service '$serviceName' to report Running within $TimeoutSeconds second(s)."
    }

    return $true
}

function Stop-GSMServer {
    <#
    .SYNOPSIS
        Stops a running game server.
    .DESCRIPTION
        Reads Config/<FolderName>.json's ProcessManager field to choose a
        backend: 'ScheduledTask' delegates to
        Core/ProcessManager.psm1's original Stop-GSMServer; anything else
        (including a missing config, which defaults to 'NSSM') runs
        `nssm stop`. Never throws: a non-zero exit from `nssm stop` (e.g.
        the service was never installed, or was already stopped) is logged
        as a warning, not an error, since the end state Stop-GSMServer
        promises - nothing running - is already true either way.
    .PARAMETER FolderName
        The plugin's folder name under Plugins/ (e.g. 'Insurgency2014').
    .EXAMPLE
        Stop-GSMServer -FolderName 'Insurgency2014'
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$FolderName
    )

    $mode = Resolve-GSMServerProcessManagerMode -FolderName $FolderName

    if ($mode -eq 'ScheduledTask') {
        return Stop-ScheduledTaskGSMServer -FolderName $FolderName
    }

    $serviceName = Get-GSMServiceName -FolderName $FolderName
    $result = Invoke-GSMNSSMCommand -ArgumentList @('stop', $serviceName)

    if ($result.ExitCode -ne 0) {
        Write-GSMLog -Level Warning -Message "nssm stop for '$serviceName' returned exit code $($result.ExitCode) (it may already be stopped or not installed)."
    }

    return $true
}

function Restart-GSMServer {
    <#
    .SYNOPSIS
        Restarts a game server.
    .DESCRIPTION
        Reads Config/<FolderName>.json's ProcessManager field to choose a
        backend: 'ScheduledTask' delegates to
        Core/ProcessManager.psm1's original Restart-GSMServer; anything
        else (including a missing config, which defaults to 'NSSM')
        re-syncs the service registration (same as Start-GSMServer, so any
        config changes since the last install are picked up) and then runs
        `nssm restart`.
    .PARAMETER FolderName
        The plugin's folder name under Plugins/ (e.g. 'Insurgency2014').
    .PARAMETER Executable
        The server executable's file name (e.g. 'srcds.exe').
    .PARAMETER GetLaunchArgsFunctionName
        Name of the plugin's own launch-argument-building function.
    .PARAMETER AccountName
        Name of GSM's local service account to run the process as. Defaults
        to 'GSM-ServiceAccount'.
    .EXAMPLE
        Restart-GSMServer -FolderName 'Insurgency2014' -Executable 'srcds.exe' -GetLaunchArgsFunctionName 'Get-Insurgency2014LaunchArgs'
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$FolderName,

        [Parameter(Mandatory)]
        [string]$Executable,

        [Parameter(Mandatory)]
        [string]$GetLaunchArgsFunctionName,

        [Parameter()]
        [string]$AccountName = 'GSM-ServiceAccount'
    )

    $mode = Resolve-GSMServerProcessManagerMode -FolderName $FolderName

    if ($mode -eq 'ScheduledTask') {
        return Restart-ScheduledTaskGSMServer -FolderName $FolderName -Executable $Executable -GetLaunchArgsFunctionName $GetLaunchArgsFunctionName -AccountName $AccountName
    }
    elseif ($mode -ne 'NSSM') {
        throw "Unknown ProcessManager mode '$mode' for '$FolderName'. Expected 'NSSM' or 'ScheduledTask'."
    }

    Sync-GSMServerServiceRegistration -FolderName $FolderName -Executable $Executable -GetLaunchArgsFunctionName $GetLaunchArgsFunctionName -AccountName $AccountName

    $serviceName = Get-GSMServiceName -FolderName $FolderName
    $result = Invoke-GSMNSSMCommand -ArgumentList @('restart', $serviceName)
    if ($result.ExitCode -ne 0) {
        Write-GSMLog -Level Error -Message "nssm restart failed for '$serviceName' (exit code $($result.ExitCode))."
        throw "Failed to restart NSSM service '$serviceName' for '$FolderName' (nssm exit code $($result.ExitCode))."
    }

    return $true
}

function Get-GSMServerStatus {
    <#
    .SYNOPSIS
        Reports whether a game server is running or stopped.
    .DESCRIPTION
        Reads Config/<FolderName>.json's ProcessManager field to choose a
        backend: 'ScheduledTask' delegates to
        Core/ProcessManager.psm1's original Get-GSMServerStatus (which can
        return 'Running', 'Stopped', or 'Crashed'); anything else (including
        a missing config, which defaults to 'NSSM') runs `nssm status` and
        returns 'Running' if its output contains SERVICE_RUNNING, otherwise
        'Stopped'.
    .PARAMETER FolderName
        The plugin's folder name under Plugins/ (e.g. 'Insurgency2014').
    .EXAMPLE
        Get-GSMServerStatus -FolderName 'Insurgency2014'
    .NOTES
        NSSM mode never returns 'Crashed', unlike ScheduledTask mode. This
        is a deliberate scope decision, not an oversight: NSSM's own
        AppExit=Restart crash recovery means a crashed process is normally
        already back to SERVICE_RUNNING by the time anything checks status,
        and `nssm status` only reports the live SCM state - it has no
        "did this crash and get auto-restarted" signal to surface. Does not
        throw when NSSM itself isn't installed or `nssm status` fails; both
        are reported as 'Stopped'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$FolderName
    )

    $mode = Resolve-GSMServerProcessManagerMode -FolderName $FolderName

    if ($mode -eq 'ScheduledTask') {
        return Get-ScheduledTaskGSMServerStatus -FolderName $FolderName
    }

    if (-not (Test-NSSMPresent)) {
        return 'Stopped'
    }

    $serviceName = Get-GSMServiceName -FolderName $FolderName

    try {
        $result = Invoke-GSMNSSMCommand -ArgumentList @('status', $serviceName) -CaptureOutput
    }
    catch {
        return 'Stopped'
    }

    if ($result.ExitCode -ne 0 -or -not $result.StdOut) {
        return 'Stopped'
    }

    if ($result.StdOut -match 'SERVICE_RUNNING') {
        return 'Running'
    }

    return 'Stopped'
}

Export-ModuleMember -Function Start-GSMServer, Stop-GSMServer, Restart-GSMServer, Get-GSMServerStatus, Install-GSMServerService, Uninstall-GSMServerService, Set-GSMServiceCrashRecovery
