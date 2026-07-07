#Requires -Version 7.0
<#
.SYNOPSIS
    Basic, pre-Service.psm1 game server process lifecycle for GSM.
.DESCRIPTION
    Phase 1 (PRD section 8, item 11). Starts, stops, restarts, and reports
    status for a game server process, running it under GSM's least-privilege
    service account (Core/ServiceAccount.psm1) via a per-plugin Scheduled
    Task rather than a native Windows Service.

    A Scheduled Task, not a native Windows Service, is used deliberately:
    dedicated-server executables like srcds.exe don't implement the Service
    Control Manager protocol (they never call SetServiceStatus), so
    registering one directly as a service would have Windows kill it after
    about 30 seconds for not responding to the SCM. Making a plain
    executable behave as a real service needs a service-wrapper tool (e.g.
    NSSM) - that is Core/Service.psm1, Phase 2. A Scheduled Task requires no
    wrapper: it just launches a plain process as a specified account, using
    SeBatchLogonRight rather than SeServiceLogonRight.

    This module is entirely game-agnostic: every plugin's Start-<Game>Server
    is a thin wrapper that supplies its own FolderName, Executable, and the
    name of its own Get-<Game>LaunchArgs function; no plugin builds any of
    the Scheduled Task or process-tracking logic itself.
.NOTES
    Status is tracked in a local JSON file per server
    (Config/ServerStatus/<FolderName>.json: ProcessId, StartTimeUtc,
    ExecutablePath, TaskName), not by querying the Scheduled Task's own
    State. This is deliberate: it lets Get-GSMServerStatus distinguish a
    server that exited/crashed on its own (status file exists, but the
    recorded PID no longer resolves to a running process) from one that was
    never started, which a bare Scheduled Task State query can't express as
    clearly.
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Utilities.psm1') -Force
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Logging.psm1') -Force
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Config.psm1') -Force
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'ServiceAccount.psm1') -Force

function Get-GSMServerConfigPath {
    # Internal helper. Not exported: resolves the path to a server's live
    # config file, Config/<FolderName>.json. Keyed by plugin FOLDER name, not
    # GameName - L4D and L4D2 both have GameName "Left4Dead" (see
    # Plugin.json), so keying by GameName would make the two plugins
    # overwrite each other's config. This matches the same FolderName-keying
    # convention already used by the shared Config/CustomMaps.json.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$FolderName
    )

    return Join-Path -Path (Get-GSMRootPath) -ChildPath "Config/$FolderName.json"
}

function Get-GSMServerStatusPath {
    # Internal helper. Not exported: resolves the path to a server's runtime
    # status file, Config/ServerStatus/<FolderName>.json.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$FolderName
    )

    return Join-Path -Path (Get-GSMRootPath) -ChildPath "Config/ServerStatus/$FolderName.json"
}

function Get-GSMServerInstallDirectory {
    # Internal helper. Not exported: resolves a plugin's install directory,
    # Servers/<FolderName>, matching every plugin's own Install-<Game>Server
    # convention.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$FolderName
    )

    return Join-Path -Path (Get-GSMRootPath) -ChildPath "Servers/$FolderName"
}

function Start-GSMServer {
    <#
    .SYNOPSIS
        Starts a game server as a Scheduled Task running under GSM's
        service account.
    .DESCRIPTION
        Requires Config/<FolderName>.json to already exist (run the
        Configure action first) and the server's executable to already be
        installed under Servers/<FolderName> (run the Install action
        first). Loads the config via Core/Config.psm1's Get-GSMConfig,
        builds launch arguments by calling the plugin's own
        Get-<Game>LaunchArgs function (named by GetLaunchArgsFunctionName),
        then registers and starts a Scheduled Task (named GSM-<FolderName>)
        that runs the executable with those arguments under AccountName's
        credential. Waits up to TimeoutSeconds for the spawned process to
        appear via Win32_Process, then records its PID and start time to
        Config/ServerStatus/<FolderName>.json.

        A no-op returning $true if Get-GSMServerStatus already reports
        'Running' for FolderName: Start-GSMServer never launches a second
        instance on top of one already running.
    .PARAMETER FolderName
        The plugin's folder name under Plugins/ (e.g. 'Insurgency2014'),
        used to resolve its config, install directory, status file, and
        Scheduled Task name.
    .PARAMETER Executable
        The server executable's file name (e.g. 'srcds.exe'), resolved
        relative to Servers/<FolderName>.
    .PARAMETER GetLaunchArgsFunctionName
        Name of the plugin's own exported launch-argument-building function
        (e.g. 'Get-Insurgency2014LaunchArgs'), which must accept a
        -Config parameter and return a string array.
    .PARAMETER AccountName
        Name of GSM's local service account to run the process as. Defaults
        to 'GSM-ServiceAccount'.
    .PARAMETER TimeoutSeconds
        How long to wait for the spawned process to appear after starting
        the Scheduled Task, in seconds. Defaults to 10.
    .PARAMETER PollIntervalMilliseconds
        How long to wait between polling attempts while looking for the
        spawned process, in milliseconds. Defaults to 500.
    .EXAMPLE
        Start-GSMServer -FolderName 'Insurgency2014' -Executable 'srcds.exe' -GetLaunchArgsFunctionName 'Get-Insurgency2014LaunchArgs'
    .NOTES
        Throws if the config or executable is missing, if registering or
        starting the Scheduled Task fails, or if no matching process appears
        within TimeoutSeconds.
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

    if ((Get-GSMServerStatus -FolderName $FolderName) -eq 'Running') {
        Write-GSMLog -Level Info -Message "Server '$FolderName' is already running; Start-GSMServer is a no-op."
        return $true
    }

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

    $credential = Get-GSMServiceAccountCredential -AccountName $AccountName
    $taskName = "GSM-$FolderName"

    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

    $action = New-ScheduledTaskAction -Execute $executablePath -Argument ($launchArgs -join ' ') -WorkingDirectory $installDirectory
    # No execution time limit: game servers run indefinitely, unlike Task
    # Scheduler's default 3-day limit for ad hoc tasks.
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([System.TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

    $plainPassword = $credential.GetNetworkCredential().Password
    try {
        try {
            Register-ScheduledTask -TaskName $taskName -Action $action -Settings $settings -User $credential.UserName -Password $plainPassword -RunLevel Limited -Force -ErrorAction Stop | Out-Null
        }
        catch {
            Write-GSMLog -Level Error -Message "Failed to register Scheduled Task '$taskName' for '$FolderName': $($_.Exception.Message)"
            throw
        }
    }
    finally {
        # The Task Scheduler API (Register-ScheduledTask -Password) has no
        # SecureString-accepting overload, so the password is unavoidably
        # plaintext for this one call - that's a Windows API limitation, not
        # a design choice here. Drop the reference immediately afterward.
        $plainPassword = $null
    }

    try {
        Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
    }
    catch {
        Write-GSMLog -Level Error -Message "Failed to start Scheduled Task '$taskName' for '$FolderName': $($_.Exception.Message)"
        throw
    }

    $processId = $null
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $escapedExecutablePath = $executablePath.Replace("'", "''")

    while (-not $processId -and (Get-Date) -lt $deadline) {
        $matchingProcess = Get-CimInstance -ClassName Win32_Process -Filter "ExecutablePath = '$escapedExecutablePath'" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($matchingProcess) {
            $processId = $matchingProcess.ProcessId
        }
        else {
            Start-Sleep -Milliseconds $PollIntervalMilliseconds
        }
    }

    if (-not $processId) {
        throw "Timeout waiting for '$executablePath' to appear as a running process: Scheduled Task '$taskName' started but no matching process was found within $TimeoutSeconds second(s)."
    }

    $statusPath = Get-GSMServerStatusPath -FolderName $FolderName
    New-Item -ItemType Directory -Path (Split-Path -Path $statusPath -Parent) -Force -ErrorAction SilentlyContinue | Out-Null

    $statusObject = [PSCustomObject]@{
        ProcessId      = $processId
        StartTimeUtc   = (Get-Date).ToUniversalTime().ToString('o')
        ExecutablePath = $executablePath
        TaskName       = $taskName
    }
    $statusObject | ConvertTo-Json | Set-Content -Path $statusPath

    return $true
}

function Stop-GSMServer {
    <#
    .SYNOPSIS
        Stops a running game server.
    .DESCRIPTION
        Reads Config/ServerStatus/<FolderName>.json for the tracked process
        ID and stops it via Stop-Process -Force, then clears the status
        file. A no-op returning $true (with a logged warning, not a thrown
        error) if no status file exists or the tracked process has already
        exited: the end state Stop-GSMServer promises (nothing running) is
        already true either way.
    .PARAMETER FolderName
        The plugin's folder name under Plugins/ (e.g. 'Insurgency2014').
    .EXAMPLE
        Stop-GSMServer -FolderName 'Insurgency2014'
    .NOTES
        Does not stop or unregister the underlying Scheduled Task itself;
        the task is left registered (with no trigger, so it won't run again
        on its own) so the next Start-GSMServer call can re-register it
        fresh with current config/launch args.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$FolderName
    )

    $statusPath = Get-GSMServerStatusPath -FolderName $FolderName

    if (-not (Test-Path -Path $statusPath -PathType Leaf)) {
        Write-GSMLog -Level Warning -Message "No running status recorded for '$FolderName'; nothing to stop."
        return $true
    }

    try {
        $status = Get-Content -Path $statusPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Write-GSMLog -Level Warning -Message "Status file for '$FolderName' could not be read; removing it and treating the server as already stopped: $($_.Exception.Message)"
        Remove-Item -Path $statusPath -Force -ErrorAction SilentlyContinue
        return $true
    }

    try {
        Stop-Process -Id $status.ProcessId -Force -ErrorAction Stop
    }
    catch {
        Write-GSMLog -Level Warning -Message "Could not stop process $($status.ProcessId) for '$FolderName' (it may have already exited): $($_.Exception.Message)"
    }

    Remove-Item -Path $statusPath -Force -ErrorAction SilentlyContinue

    return $true
}

function Restart-GSMServer {
    <#
    .SYNOPSIS
        Restarts a game server.
    .DESCRIPTION
        Calls Stop-GSMServer, then Start-GSMServer with the same parameters.
        No logic beyond that sequencing.
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
    .NOTES
        Throws under the same conditions as Start-GSMServer.
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

    Stop-GSMServer -FolderName $FolderName | Out-Null

    return Start-GSMServer -FolderName $FolderName -Executable $Executable -GetLaunchArgsFunctionName $GetLaunchArgsFunctionName -AccountName $AccountName
}

function Get-GSMServerStatus {
    <#
    .SYNOPSIS
        Reports whether a game server is running, stopped, or crashed.
    .DESCRIPTION
        Returns 'Stopped' if no status file exists for FolderName (never
        started, or already cleanly stopped). If a status file exists,
        confirms the tracked process ID still resolves via Get-Process:
        'Running' if it does, or 'Crashed' if the file exists but the
        process is gone (it exited without going through Stop-GSMServer).
    .PARAMETER FolderName
        The plugin's folder name under Plugins/ (e.g. 'Insurgency2014').
    .EXAMPLE
        Get-GSMServerStatus -FolderName 'Insurgency2014'
    .NOTES
        Does not throw for a missing or unreadable status file; both are
        reported as 'Stopped', since GSM never launched the tracked process,
        or lost track of it starting.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$FolderName
    )

    $statusPath = Get-GSMServerStatusPath -FolderName $FolderName

    if (-not (Test-Path -Path $statusPath -PathType Leaf)) {
        return 'Stopped'
    }

    try {
        $status = Get-Content -Path $statusPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        return 'Stopped'
    }

    $runningProcess = Get-Process -Id $status.ProcessId -ErrorAction SilentlyContinue

    if ($runningProcess) {
        return 'Running'
    }

    return 'Crashed'
}

Export-ModuleMember -Function Start-GSMServer, Stop-GSMServer, Restart-GSMServer, Get-GSMServerStatus
