#Requires -Version 7.0
<#
.SYNOPSIS
    Counter-Strike: Source map list and validation.
.DESCRIPTION
    Phase 1. Supplies the confirmed official Counter-Strike: Source stock
    map list and validates map names before they're written to a server
    config.
.NOTES
    Functions implemented: Get-CounterStrikeSourceMaps, Test-CounterStrikeSourceMap.

    Confirmed official map roster (source: the "Official Maps" table on
    developer.valvesoftware.com/wiki/Counter-Strike:_Source, retrieved
    2026-07-06). That table is Valve's own authoritative list of every map
    shipped with Counter-Strike: Source and lists exactly 18 gameplay maps,
    all prefixed with either cs_ (Hostage Rescue) or de_ (Bomb Defusal):
      Hostage Rescue (cs_): assault, compound, havana, italy, militia, office
      Bomb Defusal (de_): aztec, cbble, chateau, dust, dust2, inferno, nuke,
        piranesi, port, prodigy, tides, train

    This is a small, closed, unambiguous list - unlike Team Fortress 2's
    220+ map roster, there is no curation judgment call to make here. Two
    additional non-gameplay utility maps (test_speakers, an audio
    configuration test map; test_hardware, a CPU/GPU benchmark map) are
    listed on the same Valve wiki page but are intentionally excluded below:
    neither is a playable game mode map, neither can be meaningfully
    launched as a dedicated server round, and test_speakers was removed from
    the game's own menu system in a 2010 update.

    *** MAP-ROSTER HISTORY - CHECKED, NOT AMBIGUOUS FOR THIS PLUGIN ***
    The Valve wiki table also tracks each map's status in later, separate
    games (CS:GO / CS2), where several of these maps (aztec, dust, tides)
    are marked "Removed". That removal happened in those later games, not
    in Counter-Strike: Source itself - the same table lists all 18 as
    shipped Counter-Strike: Source maps with no CS:S-side removal noted.
    de_prodigy was researched specifically because the task brief flagged a
    possible "de_prodigy became de_shortdust" rename: that turned out to
    refer to Shortdust, a Dust-derived Demolition/Wingman map added to
    CS:GO's Operation Vanguard in 2017 and removed from CS:GO again in the
    same year - a CS:GO-only map with no connection to Prodigy and no
    Counter-Strike: Source release at all. Prodigy itself shipped in every
    Counter-Strike release except CS:GO/CS2, including Source. There is no
    map-roster ambiguity affecting the Counter-Strike: Source stock list
    used here.

    Also checked: Assassination-type maps (as_ prefix, e.g. as_oilrig) were
    never part of Counter-Strike: Source at all - that game mode was
    dropped starting with Source per counterstrike.fandom.com/wiki/Assassination,
    so no as_-prefixed map appears in the Valve wiki's Counter-Strike: Source
    table. This confirms cs_/de_ is exhaustive for this game's official
    stock maps; no third prefix family exists to account for.

    Custom maps: Test-CounterStrikeSourceMap also accepts any map name
    listed under this plugin's own key ("CounterStrikeSource", the plugin
    folder name) in Config/CustomMaps.json, a single shared file (keyed by
    plugin folder name) covering every Phase 1 plugin, not one file per
    plugin. Missing file, missing key, or an empty key all fall back to the
    official list with no error - custom maps are optional. This is the
    normal path for any community/Workshop-style map, since only Valve's 18
    official maps are enumerated below.
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../../Core/Utilities.psm1') -Force
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../../Core/Logging.psm1') -Force

# Confirmed official Counter-Strike: Source stock maps, as internal map-file
# identifiers (lowercase), grouped by objective type:
#   Hostage Rescue (cs_): assault, compound, havana, italy, militia, office
#   Bomb Defusal (de_): aztec, cbble, chateau, dust, dust2, inferno, nuke,
#     piranesi, port, prodigy, tides, train
[string[]]$script:CounterStrikeSourceMaps = @(
    'cs_assault',
    'cs_compound',
    'cs_havana',
    'cs_italy',
    'cs_militia',
    'cs_office',
    'de_aztec',
    'de_cbble',
    'de_chateau',
    'de_dust',
    'de_dust2',
    'de_inferno',
    'de_nuke',
    'de_piranesi',
    'de_port',
    'de_prodigy',
    'de_tides',
    'de_train'
)

function Get-CounterStrikeSourceCustomMaps {
    # Internal helper. Not exported: reads Config/CustomMaps.json (shared
    # across every Phase 1 plugin, keyed by plugin folder name) and returns
    # this plugin's own array of extra custom map names. Returns an empty
    # array - not an error - when the file doesn't exist, this plugin's key
    # is missing, or the key's array is empty: custom maps are optional. A
    # malformed CustomMaps.json logs a warning and also falls back to an
    # empty array, since a typo in an optional file shouldn't block server
    # config validation.
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    $customMapsPath = Join-Path -Path (Get-GSMRootPath) -ChildPath 'Config/CustomMaps.json'

    if (-not (Test-Path -Path $customMapsPath -PathType Leaf)) {
        return [string[]]@()
    }

    try {
        $customMapsConfig = Get-Content -Path $customMapsPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Write-GSMLog -Level Warning -Message "Failed to read '$customMapsPath', falling back to the official Counter-Strike: Source map list only: $($_.Exception.Message)"
        return [string[]]@()
    }

    $property = $customMapsConfig.PSObject.Properties['CounterStrikeSource']
    if ($null -eq $property -or $null -eq $property.Value) {
        return [string[]]@()
    }

    return [string[]]$property.Value
}

function Get-CounterStrikeSourceMaps {
    <#
    .SYNOPSIS
        Returns the confirmed official Counter-Strike: Source stock map
        list.
    .DESCRIPTION
        Returns the internal map-file identifiers (lowercase) for every
        official gameplay map shipped with Counter-Strike: Source, per
        developer.valvesoftware.com's "Official Maps" table.
    .EXAMPLE
        Get-CounterStrikeSourceMaps
    .NOTES
        This is the stock map list only; it does not include custom maps
        from Config/CustomMaps.json. Test-CounterStrikeSourceMap validates
        against both; this function returns the official list alone.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    return [string[]]$script:CounterStrikeSourceMaps
}

function Test-CounterStrikeSourceMap {
    <#
    .SYNOPSIS
        Checks whether a map name is one of the confirmed official
        Counter-Strike: Source stock maps, or a custom map registered for
        this plugin in Config/CustomMaps.json.
    .DESCRIPTION
        Case-insensitive comparison against Get-CounterStrikeSourceMaps,
        merged with this plugin's own entries (if any) from the shared
        Config/CustomMaps.json.
    .PARAMETER MapName
        The map name to validate, e.g. 'de_dust2' or 'DE_DUST2'.
    .EXAMPLE
        Test-CounterStrikeSourceMap -MapName 'de_dust2'
    .NOTES
        Community and Workshop-style maps must be registered under this
        plugin's "CounterStrikeSource" key in Config/CustomMaps.json to
        validate here - only Valve's 18 official maps are recognized out of
        the box.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$MapName
    )

    $customMaps = @(Get-CounterStrikeSourceCustomMaps) | ForEach-Object { $_.ToLowerInvariant() }
    $allMaps = @($script:CounterStrikeSourceMaps) + @($customMaps)

    return ($allMaps -contains $MapName.ToLowerInvariant())
}

Export-ModuleMember -Function Get-CounterStrikeSourceMaps, Test-CounterStrikeSourceMap
