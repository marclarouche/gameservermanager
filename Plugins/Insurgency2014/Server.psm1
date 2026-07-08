#Requires -Version 7.0
<#
.SYNOPSIS
    Insurgency (2014) server lifecycle and launch parameters.
.DESCRIPTION
    Phase 1 (launch params, config validation) / Phase 2 (start/stop/restart
    via Core/Service.psm1, the pre-Service.psm1 task in PRD section 8 item
    11). This module only builds the srcds.exe launch parameter string from
    a config object and validates that config object; it does not start,
    stop, or monitor any process.
.NOTES
    Functions implemented: Get-Insurgency2014LaunchArgs,
    Test-Insurgency2014ServerConfig, Start-Insurgency2014Server,
    Stop-Insurgency2014Server, Restart-Insurgency2014Server,
    Get-Insurgency2014ServerStatus, New-Insurgency2014Config.

    Start/Stop/Restart/Status (PRD section 8 item 11) and Configure (item
    12) are now implemented as thin wrappers around Core/Service.psm1
    and Core/ConfigEditor.psm1 respectively: this module only supplies its
    own identity (FolderName, Executable, AppID, DefaultPort) and the names
    of its own Get-Insurgency2014LaunchArgs / Get-Insurgency2014Maps /
    Get-Insurgency2014Modes / Test-Insurgency2014ServerConfig functions; the
    actual Scheduled Task lifecycle and interactive prompting/backup/write
    logic lives entirely in those two Core modules.
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Maps.psm1') -Force
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Modes.psm1') -Force
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../../Core/Service.psm1') -Force
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../../Core/ConfigEditor.psm1') -Force

# Maps each confirmed display-name mode to the internal suffix srcds.exe
# expects after the map name in +map <mapname>_<suffix>. Almost all modes
# are 1:1 with their display name; Checkpoint is the confirmed exception
# (its internal suffix is "coop", a holdover from when Checkpoint was
# Insurgency's original cooperative mode before the 2014 standalone
# release). "coop" is also accepted directly as a $Mode input, in case a
# caller already has the raw suffix rather than the display name.
$script:Insurgency2014ModeSuffixMap = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$script:Insurgency2014ModeSuffixMap.Add('checkpoint', 'coop')
$script:Insurgency2014ModeSuffixMap.Add('coop', 'coop')
$script:Insurgency2014ModeSuffixMap.Add('push', 'push')
$script:Insurgency2014ModeSuffixMap.Add('firefight', 'firefight')
$script:Insurgency2014ModeSuffixMap.Add('skirmish', 'skirmish')
$script:Insurgency2014ModeSuffixMap.Add('ambush', 'ambush')
$script:Insurgency2014ModeSuffixMap.Add('strike', 'strike')
$script:Insurgency2014ModeSuffixMap.Add('occupy', 'occupy')
$script:Insurgency2014ModeSuffixMap.Add('elimination', 'elimination')
$script:Insurgency2014ModeSuffixMap.Add('conquer', 'conquer')
$script:Insurgency2014ModeSuffixMap.Add('hunt', 'hunt')
$script:Insurgency2014ModeSuffixMap.Add('outpost', 'outpost')
$script:Insurgency2014ModeSuffixMap.Add('survival', 'survival')
$script:Insurgency2014ModeSuffixMap.Add('flashpoint', 'flashpoint')

function Get-Insurgency2014ConfigPropertyValue {
    # Internal helper. Not exported: reads a property from a config psobject
    # via PSObject.Properties, returning $null when it doesn't exist instead
    # of letting dot-notation throw PropertyNotFoundException under
    # Set-StrictMode -Version Latest. Mirrors Get-GSMConfigPropertyValue in
    # Core/Config.psm1.
    #
    # WorkshopItems is array-valued; every other field this reads is a
    # scalar. A plain "return $property.Value" unrolls an array-valued
    # property onto the output stream, so a caller capturing a
    # single-element WorkshopItems array back into a variable would get a
    # bare scalar instead of a 1-element array. Write-Output -NoEnumerate
    # avoids that unrolling, but only gets used for array values: -NoEnumerate
    # on a scalar backfires, because Write-Output's -InputObject parameter is
    # typed [PSObject[]], so PowerShell wraps a scalar into a 1-element array
    # to bind it, and -NoEnumerate then preserves that wrapper instead of
    # unwrapping it - turning a plain string into a 1-element array of that
    # string. (Core/Config.psm1's Get-GSMConfigPropertyValue and
    # Core/PluginLoader.psm1's Get-GSMPluginPropertyValue have the same
    # plain "return $property.Value" shape as the array case here, but
    # neither has ever been used to read an array-typed field, so that half
    # of the bug has never surfaced there.)
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

function Test-Insurgency2014ServerConfig {
    <#
    .SYNOPSIS
        Validates a config object for launching an Insurgency (2014)
        server.
    .DESCRIPTION
        Checks that Map and Mode are present and recognized (via
        Test-Insurgency2014Map / Test-Insurgency2014Mode, with "coop"
        additionally accepted as a Mode value), DefaultPort is an integer
        between 1 and 65535, and MaxPlayers is an integer between 1 and 64.
        RCONPassword and WorkshopItems are optional; if present,
        RCONPassword must be a string and WorkshopItems must be a
        collection. Throws on the first failure. Returns nothing on
        success.
    .PARAMETER Config
        The config object (e.g. from Core/Config.psm1's Get-GSMConfig) to
        validate.
    .EXAMPLE
        Test-Insurgency2014ServerConfig -Config $cfg
    .NOTES
        This validates Insurgency-specific fields only (Map, Mode,
        DefaultPort, MaxPlayers, RCONPassword, WorkshopItems). GameName,
        AppID, and LaunchOptions are Core/Config.psm1's Test-GSMConfig's
        responsibility, not this function's.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Config
    )

    $map = Get-Insurgency2014ConfigPropertyValue -Config $Config -Name 'Map'
    if (-not $map -or $map -isnot [string]) {
        throw "Config is missing required field 'Map'."
    }
    if (-not (Test-Insurgency2014Map -MapName $map)) {
        throw "Config field 'Map' value '$map' is not a recognized Insurgency (2014) stock map."
    }

    $mode = Get-Insurgency2014ConfigPropertyValue -Config $Config -Name 'Mode'
    if (-not $mode -or $mode -isnot [string]) {
        throw "Config is missing required field 'Mode'."
    }
    if (-not (Test-Insurgency2014Mode -ModeName $mode) -and $mode.ToLowerInvariant() -ne 'coop') {
        throw "Config field 'Mode' value '$mode' is not a recognized Insurgency (2014) game mode."
    }

    $port = Get-Insurgency2014ConfigPropertyValue -Config $Config -Name 'DefaultPort'
    if ($null -ne $port) {
        if (($port -isnot [int] -and $port -isnot [long]) -or $port -lt 1 -or $port -gt 65535) {
            throw "Config field 'DefaultPort' value '$port' is invalid. Must be an integer between 1 and 65535."
        }
    }

    $maxPlayers = Get-Insurgency2014ConfigPropertyValue -Config $Config -Name 'MaxPlayers'
    if (-not $maxPlayers) {
        throw "Config is missing required field 'MaxPlayers'."
    }
    if (($maxPlayers -isnot [int] -and $maxPlayers -isnot [long]) -or $maxPlayers -lt 1 -or $maxPlayers -gt 64) {
        throw "Config field 'MaxPlayers' value '$maxPlayers' is invalid. Must be an integer between 1 and 64."
    }

    $rconPassword = Get-Insurgency2014ConfigPropertyValue -Config $Config -Name 'RCONPassword'
    if ($null -ne $rconPassword -and $rconPassword -isnot [string]) {
        throw "Config field 'RCONPassword' must be a string."
    }

    $workshopItems = Get-Insurgency2014ConfigPropertyValue -Config $Config -Name 'WorkshopItems'
    if ($null -ne $workshopItems -and $workshopItems -isnot [array]) {
        throw "Config field 'WorkshopItems' must be an array."
    }
}

function Get-Insurgency2014LaunchArgs {
    <#
    .SYNOPSIS
        Builds the srcds.exe launch argument list for an Insurgency (2014)
        server.
    .DESCRIPTION
        Validates Config with Test-Insurgency2014ServerConfig, then returns
        the launch arguments as a string array (matching the same
        @('-flag', 'value', ...) shape Core/SteamCMD.psm1's Update-SteamApp
        uses for Start-Process -ArgumentList): -console, -port, +map
        (combining Map and Mode's internal suffix, e.g. 'market_coop' for
        Map 'Market' and Mode 'Checkpoint'), and +maxplayers. +rcon_password
        is appended only if RCONPassword is set, and +sv_workshop_enabled 1
        only if WorkshopItems is non-empty.
    .PARAMETER Config
        The config object (e.g. from Core/Config.psm1's Get-GSMConfig) to
        build launch arguments from.
    .EXAMPLE
        Get-Insurgency2014LaunchArgs -Config $cfg
    .NOTES
        Does not start any process; the pre-Service.psm1 start/stop/status
        task (PRD section 8 item 11) is responsible for actually launching
        srcds.exe with these arguments.

        The workshop item IDs themselves are not passed on the command
        line: Insurgency (2014) reads them from subscribed_file_ids.txt /
        subscribed_collection_ids.txt next to the server. Writing that file
        is out of scope here; only the +sv_workshop_enabled 1 flag is.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [psobject]$Config
    )

    Test-Insurgency2014ServerConfig -Config $Config

    $map = (Get-Insurgency2014ConfigPropertyValue -Config $Config -Name 'Map').ToLowerInvariant()
    $mode = Get-Insurgency2014ConfigPropertyValue -Config $Config -Name 'Mode'
    $port = Get-Insurgency2014ConfigPropertyValue -Config $Config -Name 'DefaultPort'
    $maxPlayers = Get-Insurgency2014ConfigPropertyValue -Config $Config -Name 'MaxPlayers'
    $rconPassword = Get-Insurgency2014ConfigPropertyValue -Config $Config -Name 'RCONPassword'
    $workshopItems = Get-Insurgency2014ConfigPropertyValue -Config $Config -Name 'WorkshopItems'

    $modeSuffix = $script:Insurgency2014ModeSuffixMap[$mode]

    $arguments = [System.Collections.Generic.List[string]]::new()
    $arguments.Add('-console')

    if ($null -ne $port) {
        $arguments.Add('-port')
        $arguments.Add("$port")
    }

    $arguments.Add('+map')
    $arguments.Add("${map}_${modeSuffix}")
    $arguments.Add('+maxplayers')
    $arguments.Add("$maxPlayers")

    if ($rconPassword) {
        $arguments.Add('+rcon_password')
        $arguments.Add($rconPassword)
    }

    if ($workshopItems -and $workshopItems.Count -gt 0) {
        $arguments.Add('+sv_workshop_enabled')
        $arguments.Add('1')
    }

    return $arguments.ToArray()
}

function Start-Insurgency2014Server {
    <#
    .SYNOPSIS
        Starts the Insurgency2014 server via Core/Service.psm1.
    .DESCRIPTION
        Thin wrapper: delegates to Start-GSMServer with this plugin's
        FolderName, Executable, and launch-argument function name. See
        Core/Service.psm1 for the actual Scheduled Task lifecycle.
    .EXAMPLE
        Start-Insurgency2014Server
    .NOTES
        Throws under the same conditions as Start-GSMServer: missing
        config, missing executable, or Scheduled Task registration/start
        failure.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    return Start-GSMServer -FolderName 'Insurgency2014' -Executable 'srcds.exe' -GetLaunchArgsFunctionName 'Get-Insurgency2014LaunchArgs'
}

function Stop-Insurgency2014Server {
    <#
    .SYNOPSIS
        Stops the Insurgency2014 server via Core/Service.psm1.
    .DESCRIPTION
        Thin wrapper: delegates to Stop-GSMServer with this plugin's
        FolderName.
    .EXAMPLE
        Stop-Insurgency2014Server
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    return Stop-GSMServer -FolderName 'Insurgency2014'
}

function Restart-Insurgency2014Server {
    <#
    .SYNOPSIS
        Restarts the Insurgency2014 server via Core/Service.psm1.
    .DESCRIPTION
        Thin wrapper: delegates to Restart-GSMServer with this plugin's
        FolderName, Executable, and launch-argument function name.
    .EXAMPLE
        Restart-Insurgency2014Server
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    return Restart-GSMServer -FolderName 'Insurgency2014' -Executable 'srcds.exe' -GetLaunchArgsFunctionName 'Get-Insurgency2014LaunchArgs'
}

function Get-Insurgency2014ServerStatus {
    <#
    .SYNOPSIS
        Reports the Insurgency2014 server's running status.
    .DESCRIPTION
        Thin wrapper: delegates to Get-GSMServerStatus with this plugin's
        FolderName. Returns 'Running', 'Stopped', or 'Crashed'.
    .EXAMPLE
        Get-Insurgency2014ServerStatus
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return Get-GSMServerStatus -FolderName 'Insurgency2014'
}

function New-Insurgency2014Config {
    <#
    .SYNOPSIS
        Interactively creates or updates Insurgency2014's server config.
    .DESCRIPTION
        Thin wrapper: delegates to New-GSMServerConfig with this plugin's
        FolderName, GameName, AppID, DefaultPort, Maps/ServerConfig/Modes
        function names, -RequiresMode, and -SupportsWorkshop (Insurgency
        2014 has both selectable game modes and Workshop support).
    .EXAMPLE
        New-Insurgency2014Config
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    return New-GSMServerConfig -FolderName 'Insurgency2014' -GameName 'Insurgency' -AppID '237410' -DefaultPort 27015 `
        -GetMapsFunctionName 'Get-Insurgency2014Maps' -TestServerConfigFunctionName 'Test-Insurgency2014ServerConfig' `
        -RequiresMode -GetModesFunctionName 'Get-Insurgency2014Modes' -SupportsWorkshop
}

Export-ModuleMember -Function Get-Insurgency2014LaunchArgs, Test-Insurgency2014ServerConfig, Start-Insurgency2014Server, Stop-Insurgency2014Server, Restart-Insurgency2014Server, Get-Insurgency2014ServerStatus, New-Insurgency2014Config
