#Requires -Version 7.0
<#
.SYNOPSIS
    Team Fortress 2 server lifecycle and launch parameters.
.DESCRIPTION
    Phase 1 (launch params, config validation) / Phase 2 (start/stop/restart
    via Core/Service.psm1, the pre-Service.psm1 task in PRD section 8 item
    11). This module only builds the srcds.exe launch parameter string from
    a config object and validates that config object; it does not start,
    stop, or monitor any process.
.NOTES
    Functions implemented: Get-TeamFortress2LaunchArgs,
    Test-TeamFortress2ServerConfig.

    *** MODE-FIELD DESIGN DECISION ***
    Insurgency2014's config has both a Map and a Mode field, because that
    game's internal map-file name does NOT encode its mode (e.g. Market's
    internal file name needs a "_coop"/"_push"/etc. suffix appended at
    launch time to become "market_coop"). Team Fortress 2 is structurally
    different: every stock TF2 map's internal file name is ALREADY
    prefixed with its own mode identifier (cp_, ctf_, koth_, pl_, plr_,
    arena_, sd_, mvm_, rd_, pass_, pd_, vsh_, zi_, tow_, htf_, tr_ - see
    wiki.teamfortress.com/wiki/List_of_maps' "Map types" table). A TF2
    +map argument is simply the map's own internal name with no suffix
    logic needed at all (e.g. +map cp_dustbowl, +map ctf_2fort).

    Given that, this plugin's config intentionally has NO separate "Mode"
    field. Adding one would either (a) duplicate information already
    encoded in Map's own prefix, or (b) risk directly contradicting Map if
    the two ever disagreed (e.g. Map = "cp_dustbowl" but Mode =
    "Capture the Flag"), with no clear rule for which one should win.
    Modes.psm1's Get-TeamFortress2Modes/Test-TeamFortress2Mode are kept as
    reference/documentation helpers (e.g. for a future interactive config
    editor that groups the map picker by mode), but
    Test-TeamFortress2ServerConfig below does not read or require a Mode
    property at all.
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Maps.psm1') -Force
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Modes.psm1') -Force

function Get-TeamFortress2ConfigPropertyValue {
    # Internal helper. Not exported: reads a property from a config psobject
    # via PSObject.Properties, returning $null when it doesn't exist instead
    # of letting dot-notation throw PropertyNotFoundException under
    # Set-StrictMode -Version Latest. Mirrors Get-GSMConfigPropertyValue in
    # Core/Config.psm1 and Get-Insurgency2014ConfigPropertyValue in
    # Insurgency2014's Server.psm1.
    #
    # WorkshopItems is array-valued; every other field this reads is a
    # scalar. See Insurgency2014's Server.psm1 for the full explanation of
    # why array-valued properties need Write-Output -NoEnumerate here to
    # avoid unrolling a single-element array into a bare scalar.
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

function Test-TeamFortress2ServerConfig {
    <#
    .SYNOPSIS
        Validates a config object for launching a Team Fortress 2 server.
    .DESCRIPTION
        Checks that Map is present and recognized (via Test-TeamFortress2Map),
        DefaultPort is an integer between 1 and 65535, and MaxPlayers is an
        integer between 1 and 64. RCONPassword and WorkshopItems are
        optional; if present, RCONPassword must be a string and
        WorkshopItems must be a collection. Throws on the first failure.
        Returns nothing on success.
    .PARAMETER Config
        The config object (e.g. from Core/Config.psm1's Get-GSMConfig) to
        validate.
    .EXAMPLE
        Test-TeamFortress2ServerConfig -Config $cfg
    .NOTES
        This validates Team Fortress 2-specific fields only (Map,
        DefaultPort, MaxPlayers, RCONPassword, WorkshopItems). GameName,
        AppID, and LaunchOptions are Core/Config.psm1's Test-GSMConfig's
        responsibility, not this function's.

        There is intentionally no "Mode" field here - see this module's
        top-of-file .NOTES for the reasoning. TF2 stock map names already
        encode their mode via prefix (cp_, ctf_, koth_, pl_, etc.), so a
        separate Mode field would duplicate or could contradict Map.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Config
    )

    $map = Get-TeamFortress2ConfigPropertyValue -Config $Config -Name 'Map'
    if (-not $map -or $map -isnot [string]) {
        throw "Config is missing required field 'Map'."
    }
    if (-not (Test-TeamFortress2Map -MapName $map)) {
        throw "Config field 'Map' value '$map' is not a recognized Team Fortress 2 stock map."
    }

    $port = Get-TeamFortress2ConfigPropertyValue -Config $Config -Name 'DefaultPort'
    if ($null -ne $port) {
        if (($port -isnot [int] -and $port -isnot [long]) -or $port -lt 1 -or $port -gt 65535) {
            throw "Config field 'DefaultPort' value '$port' is invalid. Must be an integer between 1 and 65535."
        }
    }

    $maxPlayers = Get-TeamFortress2ConfigPropertyValue -Config $Config -Name 'MaxPlayers'
    if (-not $maxPlayers) {
        throw "Config is missing required field 'MaxPlayers'."
    }
    if (($maxPlayers -isnot [int] -and $maxPlayers -isnot [long]) -or $maxPlayers -lt 1 -or $maxPlayers -gt 64) {
        throw "Config field 'MaxPlayers' value '$maxPlayers' is invalid. Must be an integer between 1 and 64."
    }

    $rconPassword = Get-TeamFortress2ConfigPropertyValue -Config $Config -Name 'RCONPassword'
    if ($null -ne $rconPassword -and $rconPassword -isnot [string]) {
        throw "Config field 'RCONPassword' must be a string."
    }

    $workshopItems = Get-TeamFortress2ConfigPropertyValue -Config $Config -Name 'WorkshopItems'
    if ($null -ne $workshopItems -and $workshopItems -isnot [array]) {
        throw "Config field 'WorkshopItems' must be an array."
    }
}

function Get-TeamFortress2LaunchArgs {
    <#
    .SYNOPSIS
        Builds the srcds.exe launch argument list for a Team Fortress 2
        server.
    .DESCRIPTION
        Validates Config with Test-TeamFortress2ServerConfig, then returns
        the launch arguments as a string array (matching the same
        @('-flag', 'value', ...) shape Core/SteamCMD.psm1's Update-SteamApp
        uses for Start-Process -ArgumentList): -console, -port, +map
        (the map's own internal name, with no suffix logic - unlike
        Insurgency2014, TF2 map names already encode their mode via
        prefix), and +maxplayers. +rcon_password is appended only if
        RCONPassword is set, and +sv_workshop_enabled 1 only if
        WorkshopItems is non-empty.
    .PARAMETER Config
        The config object (e.g. from Core/Config.psm1's Get-GSMConfig) to
        build launch arguments from.
    .EXAMPLE
        Get-TeamFortress2LaunchArgs -Config $cfg
    .NOTES
        Does not start any process; the pre-Service.psm1 start/stop/status
        task (PRD section 8 item 11) is responsible for actually launching
        srcds.exe with these arguments.

        The workshop item IDs themselves are not passed on the command
        line: Team Fortress 2 reads them from subscribed_file_ids.txt /
        subscribed_collection_ids.txt next to the server, the same
        mechanism Insurgency2014 uses. Writing that file is out of scope
        here; only the +sv_workshop_enabled 1 flag is.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [psobject]$Config
    )

    Test-TeamFortress2ServerConfig -Config $Config

    $map = (Get-TeamFortress2ConfigPropertyValue -Config $Config -Name 'Map').ToLowerInvariant()
    $port = Get-TeamFortress2ConfigPropertyValue -Config $Config -Name 'DefaultPort'
    $maxPlayers = Get-TeamFortress2ConfigPropertyValue -Config $Config -Name 'MaxPlayers'
    $rconPassword = Get-TeamFortress2ConfigPropertyValue -Config $Config -Name 'RCONPassword'
    $workshopItems = Get-TeamFortress2ConfigPropertyValue -Config $Config -Name 'WorkshopItems'

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

    if ($workshopItems -and $workshopItems.Count -gt 0) {
        $arguments.Add('+sv_workshop_enabled')
        $arguments.Add('1')
    }

    return $arguments.ToArray()
}

Export-ModuleMember -Function Get-TeamFortress2LaunchArgs, Test-TeamFortress2ServerConfig
