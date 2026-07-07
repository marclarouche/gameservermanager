#Requires -Version 7.0
<#
.SYNOPSIS
    Left 4 Dead 2 server lifecycle and launch parameters.
.DESCRIPTION
    Phase 1 (launch params, config validation) / Phase 2 (start/stop/restart
    via Core/Service.psm1, the pre-Service.psm1 task in PRD section 8 item
    11). This module only builds the srcds.exe launch parameter string from
    a config object and validates that config object; it does not start,
    stop, or monitor any process.
.NOTES
    Functions implemented: Get-L4D2LaunchArgs, Test-L4D2ServerConfig.

    New-L4D2Config (the interactive "Configure" action) is intentionally out
    of scope for this pass, matching every other Phase 1 plugin's Server.psm1.

    *** WORKSHOP SUPPORT ***
    Plugin.json declares "SupportsWorkshop": true for this plugin, unlike
    Left 4 Dead (2008) and Counter-Strike: Source. This module has a
    WorkshopItems config field (optional array) and Get-L4D2LaunchArgs emits
    +sv_workshop_enabled 1 whenever it is non-empty, the same pattern
    Insurgency2014's and Team Fortress 2's Server.psm1 use.

    *** MODE-FIELD DESIGN DECISION ***
    See Plugins/L4D2/Modes.psm1's top-of-file .NOTES for the full reasoning
    and sourcing. In short: Left 4 Dead 2's internal map-file names follow a
    "c#m#_name" convention that identifies campaign and chapter only, never
    game mode - Valve's own mission-file documentation confirms the same
    map bsp is routinely reused, unchanged, across the coop/versus/scavenge/
    realism "modes" blocks of a single campaign. This was independently
    verified for Left 4 Dead 2 (not assumed from Left 4 Dead's precedent),
    and the conclusion is the same: because Map alone cannot disambiguate
    the ruleset, this plugin follows Left 4 Dead's and Insurgency2014's
    precedent, not Team Fortress 2's - a required "Mode" config field,
    validated against Modes.psm1's Get-L4D2Modes/Test-L4D2Mode, and
    consumed here to build the +mp_gamemode launch argument.

    *** MAXPLAYERS RANGE ***
    MaxPlayers is validated as 1-8, the same narrowed range Left 4 Dead
    (2008) uses, not the generic 1-64 range Insurgency2014/Team Fortress 2/
    Counter-Strike: Source use. This was independently re-verified for Left
    4 Dead 2 rather than assumed from Left 4 Dead's precedent: the game's
    own gamemodes.txt script (the file that actually defines each mode's
    "maxplayers" value) caps every stable mode at 8 (Versus and Scavenge) or
    4 (Campaign/Coop, Realism, Survival), and every numbered Mutation/
    Community variant checked also tops out at 8. There is no Left 4 Dead 2
    mode, official or Mutation-based, that raises the ceiling above 8 - the
    4-Survivors-vs-up-to-4-Special-Infected structure is a hard engine limit
    carried over unchanged from Left 4 Dead, so the same narrowed 1-8 range
    applies here for the same real, game-specific reason.
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Maps.psm1') -Force
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Modes.psm1') -Force

function Get-L4D2ConfigPropertyValue {
    # Internal helper. Not exported: reads a property from a config psobject
    # via PSObject.Properties, returning $null when it doesn't exist instead
    # of letting dot-notation throw PropertyNotFoundException under
    # Set-StrictMode -Version Latest. Mirrors Get-GSMConfigPropertyValue in
    # Core/Config.psm1 and the equivalent helpers in Insurgency2014's and
    # TeamFortress2's Server.psm1.
    #
    # WorkshopItems is array-valued; every other field this reads is a
    # scalar. A plain "return $property.Value" unrolls an array-valued
    # property onto the output stream, so a caller capturing a
    # single-element WorkshopItems array back into a variable would get a
    # bare scalar instead of a 1-element array. Write-Output -NoEnumerate
    # avoids that unrolling, but only gets used for array values - see
    # Insurgency2014's Server.psm1 for the full explanation of why a scalar
    # value must not take the -NoEnumerate path.
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

function Test-L4D2ServerConfig {
    <#
    .SYNOPSIS
        Validates a config object for launching a Left 4 Dead 2 server.
    .DESCRIPTION
        Checks that Map and Mode are present and recognized (via
        Test-L4D2Map / Test-L4D2Mode), DefaultPort is an integer between 1
        and 65535, and MaxPlayers is an integer between 1 and 8.
        RCONPassword and WorkshopItems are optional; if present,
        RCONPassword must be a string and WorkshopItems must be a
        collection. Throws on the first failure. Returns nothing on
        success.
    .PARAMETER Config
        The config object (e.g. from Core/Config.psm1's Get-GSMConfig) to
        validate.
    .EXAMPLE
        Test-L4D2ServerConfig -Config $cfg
    .NOTES
        This validates Left 4 Dead 2-specific fields only (Map, Mode,
        DefaultPort, MaxPlayers, RCONPassword, WorkshopItems). GameName,
        AppID, and LaunchOptions are Core/Config.psm1's Test-GSMConfig's
        responsibility, not this function's.

        MaxPlayers is validated as 1-8, not the 1-64 range Insurgency2014
        and Team Fortress 2 use - see this module's top-of-file .NOTES for
        why that narrower range is independently justified for Left 4 Dead
        2, not just inherited from Left 4 Dead.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Config
    )

    $map = Get-L4D2ConfigPropertyValue -Config $Config -Name 'Map'
    if (-not $map -or $map -isnot [string]) {
        throw "Config is missing required field 'Map'."
    }
    if (-not (Test-L4D2Map -MapName $map)) {
        throw "Config field 'Map' value '$map' is not a recognized Left 4 Dead 2 campaign map."
    }

    $mode = Get-L4D2ConfigPropertyValue -Config $Config -Name 'Mode'
    if (-not $mode -or $mode -isnot [string]) {
        throw "Config is missing required field 'Mode'."
    }
    if (-not (Test-L4D2Mode -ModeName $mode)) {
        throw "Config field 'Mode' value '$mode' is not a recognized Left 4 Dead 2 game mode."
    }

    $port = Get-L4D2ConfigPropertyValue -Config $Config -Name 'DefaultPort'
    if ($null -ne $port) {
        if (($port -isnot [int] -and $port -isnot [long]) -or $port -lt 1 -or $port -gt 65535) {
            throw "Config field 'DefaultPort' value '$port' is invalid. Must be an integer between 1 and 65535."
        }
    }

    $maxPlayers = Get-L4D2ConfigPropertyValue -Config $Config -Name 'MaxPlayers'
    if (-not $maxPlayers) {
        throw "Config is missing required field 'MaxPlayers'."
    }
    if (($maxPlayers -isnot [int] -and $maxPlayers -isnot [long]) -or $maxPlayers -lt 1 -or $maxPlayers -gt 8) {
        throw "Config field 'MaxPlayers' value '$maxPlayers' is invalid. Must be an integer between 1 and 8."
    }

    $rconPassword = Get-L4D2ConfigPropertyValue -Config $Config -Name 'RCONPassword'
    if ($null -ne $rconPassword -and $rconPassword -isnot [string]) {
        throw "Config field 'RCONPassword' must be a string."
    }

    $workshopItems = Get-L4D2ConfigPropertyValue -Config $Config -Name 'WorkshopItems'
    if ($null -ne $workshopItems -and $workshopItems -isnot [array]) {
        throw "Config field 'WorkshopItems' must be an array."
    }
}

function Get-L4D2LaunchArgs {
    <#
    .SYNOPSIS
        Builds the srcds.exe launch argument list for a Left 4 Dead 2
        server.
    .DESCRIPTION
        Validates Config with Test-L4D2ServerConfig, then returns the launch
        arguments as a string array (matching the same @('-flag', 'value',
        ...) shape Core/SteamCMD.psm1's Update-SteamApp uses for
        Start-Process -ArgumentList): -console, -port, +map (the map's own
        internal name, unchanged), +maxplayers, and +mp_gamemode (built
        from Mode). +rcon_password is appended only if RCONPassword is set,
        and +sv_workshop_enabled 1 only if WorkshopItems is non-empty.
    .PARAMETER Config
        The config object (e.g. from Core/Config.psm1's Get-GSMConfig) to
        build launch arguments from.
    .EXAMPLE
        Get-L4D2LaunchArgs -Config $cfg
    .NOTES
        Does not start any process; the pre-Service.psm1 start/stop/status
        task (PRD section 8 item 11) is responsible for actually launching
        srcds.exe with these arguments.

        The workshop item IDs themselves are not passed on the command
        line: Left 4 Dead 2 reads them from subscribed_file_ids.txt /
        subscribed_collection_ids.txt next to the server, the same
        mechanism Insurgency2014 and Team Fortress 2 use. Writing that file
        is out of scope here; only the +sv_workshop_enabled 1 flag is.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [psobject]$Config
    )

    Test-L4D2ServerConfig -Config $Config

    $map = (Get-L4D2ConfigPropertyValue -Config $Config -Name 'Map').ToLowerInvariant()
    $mode = (Get-L4D2ConfigPropertyValue -Config $Config -Name 'Mode').ToLowerInvariant()
    $port = Get-L4D2ConfigPropertyValue -Config $Config -Name 'DefaultPort'
    $maxPlayers = Get-L4D2ConfigPropertyValue -Config $Config -Name 'MaxPlayers'
    $rconPassword = Get-L4D2ConfigPropertyValue -Config $Config -Name 'RCONPassword'
    $workshopItems = Get-L4D2ConfigPropertyValue -Config $Config -Name 'WorkshopItems'

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

    if ($workshopItems -and $workshopItems.Count -gt 0) {
        $arguments.Add('+sv_workshop_enabled')
        $arguments.Add('1')
    }

    return $arguments.ToArray()
}

Export-ModuleMember -Function Get-L4D2LaunchArgs, Test-L4D2ServerConfig
