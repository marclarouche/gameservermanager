#Requires -Version 7.0
<#
.SYNOPSIS
    Left 4 Dead (2008) server lifecycle and launch parameters.
.DESCRIPTION
    Phase 1 (launch params, config validation) / Phase 2 (start/stop/restart
    via Core/Service.psm1, the pre-Service.psm1 task in PRD section 8 item
    11). This module only builds the srcds.exe launch parameter string from
    a config object and validates that config object; it does not start,
    stop, or monitor any process.
.NOTES
    Functions implemented: Get-L4DLaunchArgs, Test-L4DServerConfig,
    Start-L4DServer, Stop-L4DServer, Restart-L4DServer,
    Get-L4DServerStatus, New-L4DConfig.

    Start/Stop/Restart/Status (PRD section 8 item 11) and Configure (item
    12) are now implemented as thin wrappers around Core/ProcessManager.psm1
    and Core/ConfigEditor.psm1 respectively: this module only supplies its
    own identity (FolderName, Executable, AppID, DefaultPort) and the names
    of its own Get-L4DLaunchArgs / Get-L4DMaps / Get-L4DModes /
    Test-L4DServerConfig functions; the actual Scheduled Task lifecycle and
    interactive prompting/backup/write logic lives entirely in those two
    Core modules.

    *** NO WORKSHOP SUPPORT ***
    Plugin.json declares "SupportsWorkshop": false for this plugin: Left 4
    Dead (2008) predates Steam Workshop entirely (Workshop launched in 2011;
    L4D shipped in 2008), so this module has no WorkshopItems config field
    and Get-L4DLaunchArgs never emits +sv_workshop_enabled or any
    workshop-related argument, unlike Insurgency2014 and Team Fortress 2.

    *** MODE-FIELD DESIGN DECISION ***
    See Plugins/L4D/Modes.psm1's top-of-file .NOTES for the full reasoning.
    In short: unlike Team Fortress 2, where every stock map name already
    encodes its mode via prefix (cp_, ctf_, etc.), Left 4 Dead map names
    (e.g. l4d_hospital01_apartment) carry no mode information - the exact
    same map file is played under Campaign, Versus, or Survival depending
    only on a separate mp_gamemode convar set at launch. Because Map alone
    is ambiguous without Mode for this game, this plugin follows
    Insurgency2014's precedent instead of Team Fortress 2's: a required
    "Mode" config field, validated against Modes.psm1's Get-L4DModes /
    Test-L4DMode, and consumed here to build the +mp_gamemode launch
    argument.
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Maps.psm1') -Force
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Modes.psm1') -Force
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../../Core/ProcessManager.psm1') -Force
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../../Core/ConfigEditor.psm1') -Force

function Get-L4DConfigPropertyValue {
    # Internal helper. Not exported: reads a property from a config psobject
    # via PSObject.Properties, returning $null when it doesn't exist instead
    # of letting dot-notation throw PropertyNotFoundException under
    # Set-StrictMode -Version Latest. Mirrors Get-GSMConfigPropertyValue in
    # Core/Config.psm1 and the equivalent helpers in Insurgency2014's and
    # TeamFortress2's Server.psm1.
    #
    # Every field this plugin reads is a scalar (there is no array-valued
    # field like WorkshopItems here, since this plugin does not support
    # Workshop), so unlike the other two plugins' equivalent helpers, no
    # Write-Output -NoEnumerate branch is needed. The plain "return
    # $property.Value" shape is kept identical in structure regardless, for
    # consistency with the other plugins and in case an array-valued field
    # is ever added later.
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

function Test-L4DServerConfig {
    <#
    .SYNOPSIS
        Validates a config object for launching a Left 4 Dead (2008)
        server.
    .DESCRIPTION
        Checks that Map and Mode are present and recognized (via
        Test-L4DMap / Test-L4DMode), DefaultPort is an integer between 1
        and 65535, and MaxPlayers is an integer between 1 and 8.
        RCONPassword is optional; if present, it must be a string. Throws
        on the first failure. Returns nothing on success.
    .PARAMETER Config
        The config object (e.g. from Core/Config.psm1's Get-GSMConfig) to
        validate.
    .EXAMPLE
        Test-L4DServerConfig -Config $cfg
    .NOTES
        This validates Left 4 Dead-specific fields only (Map, Mode,
        DefaultPort, MaxPlayers, RCONPassword). GameName, AppID, and
        LaunchOptions are Core/Config.psm1's Test-GSMConfig's
        responsibility, not this function's.

        There is no WorkshopItems field to validate: this plugin does not
        support Workshop (Plugin.json's SupportsWorkshop is false), since
        the original 2008 release predates Steam Workshop entirely.

        MaxPlayers is validated as 1-8, not the 1-64 range Insurgency2014
        and Team Fortress 2 use: unlike those games, L4D has a hard game
        ceiling of 8 concurrent players (4 Survivors + 4 Special Infected
        in Versus), confirmed by product decision to special-case this
        plugin rather than keep the cross-plugin-consistent 1-64 range.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Config
    )

    $map = Get-L4DConfigPropertyValue -Config $Config -Name 'Map'
    if (-not $map -or $map -isnot [string]) {
        throw "Config is missing required field 'Map'."
    }
    if (-not (Test-L4DMap -MapName $map)) {
        throw "Config field 'Map' value '$map' is not a recognized Left 4 Dead campaign map."
    }

    $mode = Get-L4DConfigPropertyValue -Config $Config -Name 'Mode'
    if (-not $mode -or $mode -isnot [string]) {
        throw "Config is missing required field 'Mode'."
    }
    if (-not (Test-L4DMode -ModeName $mode)) {
        throw "Config field 'Mode' value '$mode' is not a recognized Left 4 Dead game mode."
    }

    $port = Get-L4DConfigPropertyValue -Config $Config -Name 'DefaultPort'
    if ($null -ne $port) {
        if (($port -isnot [int] -and $port -isnot [long]) -or $port -lt 1 -or $port -gt 65535) {
            throw "Config field 'DefaultPort' value '$port' is invalid. Must be an integer between 1 and 65535."
        }
    }

    $maxPlayers = Get-L4DConfigPropertyValue -Config $Config -Name 'MaxPlayers'
    if (-not $maxPlayers) {
        throw "Config is missing required field 'MaxPlayers'."
    }
    if (($maxPlayers -isnot [int] -and $maxPlayers -isnot [long]) -or $maxPlayers -lt 1 -or $maxPlayers -gt 8) {
        throw "Config field 'MaxPlayers' value '$maxPlayers' is invalid. Must be an integer between 1 and 8."
    }

    $rconPassword = Get-L4DConfigPropertyValue -Config $Config -Name 'RCONPassword'
    if ($null -ne $rconPassword -and $rconPassword -isnot [string]) {
        throw "Config field 'RCONPassword' must be a string."
    }
}

function Get-L4DLaunchArgs {
    <#
    .SYNOPSIS
        Builds the srcds.exe launch argument list for a Left 4 Dead (2008)
        server.
    .DESCRIPTION
        Validates Config with Test-L4DServerConfig, then returns the launch
        arguments as a string array (matching the same @('-flag', 'value',
        ...) shape Core/SteamCMD.psm1's Update-SteamApp uses for
        Start-Process -ArgumentList): -console, -port, +map (the map's own
        internal name, unchanged), +maxplayers, and +mp_gamemode (built
        from Mode). +rcon_password is appended only if RCONPassword is set.
    .PARAMETER Config
        The config object (e.g. from Core/Config.psm1's Get-GSMConfig) to
        build launch arguments from.
    .EXAMPLE
        Get-L4DLaunchArgs -Config $cfg
    .NOTES
        Does not start any process; the pre-Service.psm1 start/stop/status
        task (PRD section 8 item 11) is responsible for actually launching
        srcds.exe with these arguments.

        No Workshop-related argument is ever emitted: this plugin does not
        support Workshop (Plugin.json's SupportsWorkshop is false). See this
        module's top-of-file .NOTES.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [psobject]$Config
    )

    Test-L4DServerConfig -Config $Config

    $map = (Get-L4DConfigPropertyValue -Config $Config -Name 'Map').ToLowerInvariant()
    $mode = (Get-L4DConfigPropertyValue -Config $Config -Name 'Mode').ToLowerInvariant()
    $port = Get-L4DConfigPropertyValue -Config $Config -Name 'DefaultPort'
    $maxPlayers = Get-L4DConfigPropertyValue -Config $Config -Name 'MaxPlayers'
    $rconPassword = Get-L4DConfigPropertyValue -Config $Config -Name 'RCONPassword'

    $arguments = [System.Collections.Generic.List[string]]::new()
    $arguments.Add('-console')

    if ($null -ne $port) {
        $arguments.Add('-port')
        $arguments.Add("$port")
    }

    $arguments.Add('+map')
    $arguments.Add($map)
    $arguments.Add('+maxplayers')
    $arguments.Add("$maxPlayers")
    $arguments.Add('+mp_gamemode')
    $arguments.Add($mode)

    if ($rconPassword) {
        $arguments.Add('+rcon_password')
        $arguments.Add($rconPassword)
    }

    return $arguments.ToArray()
}

function Start-L4DServer {
    <#
    .SYNOPSIS
        Starts the L4D server via Core/ProcessManager.psm1.
    .DESCRIPTION
        Thin wrapper: delegates to Start-GSMServer with this plugin's
        FolderName, Executable, and launch-argument function name. See
        Core/ProcessManager.psm1 for the actual Scheduled Task lifecycle.
    .EXAMPLE
        Start-L4DServer
    .NOTES
        Throws under the same conditions as Start-GSMServer: missing
        config, missing executable, or Scheduled Task registration/start
        failure.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    return Start-GSMServer -FolderName 'L4D' -Executable 'srcds.exe' -GetLaunchArgsFunctionName 'Get-L4DLaunchArgs'
}

function Stop-L4DServer {
    <#
    .SYNOPSIS
        Stops the L4D server via Core/ProcessManager.psm1.
    .DESCRIPTION
        Thin wrapper: delegates to Stop-GSMServer with this plugin's
        FolderName.
    .EXAMPLE
        Stop-L4DServer
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    return Stop-GSMServer -FolderName 'L4D'
}

function Restart-L4DServer {
    <#
    .SYNOPSIS
        Restarts the L4D server via Core/ProcessManager.psm1.
    .DESCRIPTION
        Thin wrapper: delegates to Restart-GSMServer with this plugin's
        FolderName, Executable, and launch-argument function name.
    .EXAMPLE
        Restart-L4DServer
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    return Restart-GSMServer -FolderName 'L4D' -Executable 'srcds.exe' -GetLaunchArgsFunctionName 'Get-L4DLaunchArgs'
}

function Get-L4DServerStatus {
    <#
    .SYNOPSIS
        Reports the L4D server's running status.
    .DESCRIPTION
        Thin wrapper: delegates to Get-GSMServerStatus with this plugin's
        FolderName. Returns 'Running', 'Stopped', or 'Crashed'.
    .EXAMPLE
        Get-L4DServerStatus
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return Get-GSMServerStatus -FolderName 'L4D'
}

function New-L4DConfig {
    <#
    .SYNOPSIS
        Interactively creates or updates L4D's server config.
    .DESCRIPTION
        Thin wrapper: delegates to New-GSMServerConfig with this plugin's
        FolderName, GameName, AppID, DefaultPort, Maps/ServerConfig/Modes
        function names, and -RequiresMode (Left 4 Dead has a genuine
        selectable Mode, e.g. coop). -SupportsWorkshop is deliberately NOT
        passed: this plugin's Plugin.json has SupportsWorkshop: false.
    .EXAMPLE
        New-L4DConfig
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    return New-GSMServerConfig -FolderName 'L4D' -GameName 'Left4Dead' -AppID '222840' -DefaultPort 27015 `
        -GetMapsFunctionName 'Get-L4DMaps' -TestServerConfigFunctionName 'Test-L4DServerConfig' `
        -RequiresMode -GetModesFunctionName 'Get-L4DModes'
}

Export-ModuleMember -Function Get-L4DLaunchArgs, Test-L4DServerConfig, Start-L4DServer, Stop-L4DServer, Restart-L4DServer, Get-L4DServerStatus, New-L4DConfig
