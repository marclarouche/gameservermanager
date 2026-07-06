#Requires -Version 7.0
<#
.SYNOPSIS
    Counter-Strike: Source server lifecycle and launch parameters.
.DESCRIPTION
    Phase 1 (launch params, config validation) / Phase 2 (start/stop/restart
    via Core/Service.psm1, the pre-Service.psm1 task in PRD section 8 item
    11). This module only builds the srcds.exe launch parameter string from
    a config object and validates that config object; it does not start,
    stop, or monitor any process.
.NOTES
    Functions implemented: Get-CounterStrikeSourceLaunchArgs,
    Test-CounterStrikeSourceServerConfig.

    *** NO WORKSHOP SUPPORT ***
    Plugin.json declares "SupportsWorkshop": false for this plugin, so this
    module has no WorkshopItems config field and
    Get-CounterStrikeSourceLaunchArgs never emits +sv_workshop_enabled or
    any workshop-related argument, unlike Insurgency2014 and Team Fortress
    2. This matches Left 4 Dead's Server.psm1 shape.

    *** MODE-FIELD DESIGN DECISION ***
    Every official Counter-Strike: Source stock map name is already
    prefixed with its own objective type: de_ for Bomb Defusal (e.g.
    de_dust2), cs_ for Hostage Rescue (e.g. cs_office). Unlike Left 4 Dead,
    where the same map file plays under Campaign, Versus, or Survival
    depending on a separate mp_gamemode convar, a Counter-Strike: Source map
    file only ever plays as the one objective type its own prefix encodes -
    there is no separate convar that changes de_dust2 into a hostage map or
    vice versa. This is structurally the same situation Team Fortress 2 is
    in (cp_, ctf_, koth_, etc.), confirmed by checking Valve's own official
    map table on developer.valvesoftware.com/wiki/Counter-Strike:_Source,
    which lists only cs_ and de_ prefixed gameplay maps - no third prefix
    family exists that would leave Map ambiguous without a separate Mode
    value. Given that, this plugin follows Team Fortress 2's precedent, not
    Left 4 Dead's: there is intentionally no separate "Mode" field.
    Modes.psm1's Get-CounterStrikeSourceModes/Test-CounterStrikeSourceMode
    are kept as reference/documentation helpers only, and
    Test-CounterStrikeSourceServerConfig below does not read or require a
    Mode property at all.
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Maps.psm1') -Force
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Modes.psm1') -Force

function Get-CounterStrikeSourceConfigPropertyValue {
    # Internal helper. Not exported: reads a property from a config psobject
    # via PSObject.Properties, returning $null when it doesn't exist instead
    # of letting dot-notation throw PropertyNotFoundException under
    # Set-StrictMode -Version Latest. Mirrors Get-GSMConfigPropertyValue in
    # Core/Config.psm1 and the equivalent helpers in the other plugins'
    # Server.psm1 modules.
    #
    # Every field this plugin reads is a scalar (there is no array-valued
    # field like WorkshopItems here, since this plugin does not support
    # Workshop), so unlike Insurgency2014's and Team Fortress 2's equivalent
    # helpers, no Write-Output -NoEnumerate branch is needed. This mirrors
    # L4D's Server.psm1 exactly.
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

function Test-CounterStrikeSourceServerConfig {
    <#
    .SYNOPSIS
        Validates a config object for launching a Counter-Strike: Source
        server.
    .DESCRIPTION
        Checks that Map is present and recognized (via
        Test-CounterStrikeSourceMap), DefaultPort is an integer between 1
        and 65535, and MaxPlayers is an integer between 1 and 64.
        RCONPassword is optional; if present, it must be a string. Throws
        on the first failure. Returns nothing on success.
    .PARAMETER Config
        The config object (e.g. from Core/Config.psm1's Get-GSMConfig) to
        validate.
    .EXAMPLE
        Test-CounterStrikeSourceServerConfig -Config $cfg
    .NOTES
        This validates Counter-Strike: Source-specific fields only (Map,
        DefaultPort, MaxPlayers, RCONPassword). GameName, AppID, and
        LaunchOptions are Core/Config.psm1's Test-GSMConfig's
        responsibility, not this function's.

        There is no WorkshopItems field to validate: this plugin does not
        support Workshop (Plugin.json's SupportsWorkshop is false).

        There is intentionally no "Mode" field here - see this module's
        top-of-file .NOTES for the reasoning. Counter-Strike: Source stock
        map names already encode their objective type via prefix (de_,
        cs_), so a separate Mode field would duplicate or could contradict
        Map.

        MaxPlayers keeps the shared 1-64 range used by Insurgency2014 and
        Team Fortress 2, rather than narrowing it the way Left 4 Dead does.
        Unlike L4D's hard 8-player engine ceiling (4 Survivors + 4 Special
        Infected), classic Source-engine Counter-Strike: Source dedicated
        servers commonly run 32-player public servers and support up to 64
        slots with SourceTV/mods enabled, with no fixed game-imposed
        headcount the way L4D has. There is no comparable game-specific
        reason to narrow this range below the generic default.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Config
    )

    $map = Get-CounterStrikeSourceConfigPropertyValue -Config $Config -Name 'Map'
    if (-not $map -or $map -isnot [string]) {
        throw "Config is missing required field 'Map'."
    }
    if (-not (Test-CounterStrikeSourceMap -MapName $map)) {
        throw "Config field 'Map' value '$map' is not a recognized Counter-Strike: Source stock map."
    }

    $port = Get-CounterStrikeSourceConfigPropertyValue -Config $Config -Name 'DefaultPort'
    if ($null -ne $port) {
        if (($port -isnot [int] -and $port -isnot [long]) -or $port -lt 1 -or $port -gt 65535) {
            throw "Config field 'DefaultPort' value '$port' is invalid. Must be an integer between 1 and 65535."
        }
    }

    $maxPlayers = Get-CounterStrikeSourceConfigPropertyValue -Config $Config -Name 'MaxPlayers'
    if (-not $maxPlayers) {
        throw "Config is missing required field 'MaxPlayers'."
    }
    if (($maxPlayers -isnot [int] -and $maxPlayers -isnot [long]) -or $maxPlayers -lt 1 -or $maxPlayers -gt 64) {
        throw "Config field 'MaxPlayers' value '$maxPlayers' is invalid. Must be an integer between 1 and 64."
    }

    $rconPassword = Get-CounterStrikeSourceConfigPropertyValue -Config $Config -Name 'RCONPassword'
    if ($null -ne $rconPassword -and $rconPassword -isnot [string]) {
        throw "Config field 'RCONPassword' must be a string."
    }
}

function Get-CounterStrikeSourceLaunchArgs {
    <#
    .SYNOPSIS
        Builds the srcds.exe launch argument list for a Counter-Strike:
        Source server.
    .DESCRIPTION
        Validates Config with Test-CounterStrikeSourceServerConfig, then
        returns the launch arguments as a string array (matching the same
        @('-flag', 'value', ...) shape Core/SteamCMD.psm1's Update-SteamApp
        uses for Start-Process -ArgumentList): -console, -port, +map (the
        map's own internal name, with no suffix logic - Counter-Strike:
        Source map names already encode their objective type via prefix),
        and +maxplayers. +rcon_password is appended only if RCONPassword is
        set.
    .PARAMETER Config
        The config object (e.g. from Core/Config.psm1's Get-GSMConfig) to
        build launch arguments from.
    .EXAMPLE
        Get-CounterStrikeSourceLaunchArgs -Config $cfg
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

    Test-CounterStrikeSourceServerConfig -Config $Config

    $map = (Get-CounterStrikeSourceConfigPropertyValue -Config $Config -Name 'Map').ToLowerInvariant()
    $port = Get-CounterStrikeSourceConfigPropertyValue -Config $Config -Name 'DefaultPort'
    $maxPlayers = Get-CounterStrikeSourceConfigPropertyValue -Config $Config -Name 'MaxPlayers'
    $rconPassword = Get-CounterStrikeSourceConfigPropertyValue -Config $Config -Name 'RCONPassword'

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

    if ($rconPassword) {
        $arguments.Add('+rcon_password')
        $arguments.Add($rconPassword)
    }

    return $arguments.ToArray()
}

Export-ModuleMember -Function Get-CounterStrikeSourceLaunchArgs, Test-CounterStrikeSourceServerConfig
