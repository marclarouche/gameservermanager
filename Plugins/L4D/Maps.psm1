#Requires -Version 7.0
<#
.SYNOPSIS
    Left 4 Dead (2008) map list and validation.
.DESCRIPTION
    Phase 1. Supplies the confirmed official Left 4 Dead (2008) campaign map
    list and validates map names before they're written to a server config.
.NOTES
    Functions implemented: Get-L4DMaps, Test-L4DMap.

    *** SCOPE - ORIGINAL L4D1 SERVER, NOT THE L4D2 PORTS ***
    The original 2008 release shipped four campaigns (No Mercy, Death Toll,
    Dead Air, Blood Harvest), followed by a free official add-on campaign,
    Crash Course, added via a 2009 update. Source (source: left4dead.fandom.com,
    retrieved 2026-07-06):
      - Campaigns: https://left4dead.fandom.com/wiki/Campaigns
      - No Mercy: https://left4dead.fandom.com/wiki/No_Mercy
      - Death Toll: https://left4dead.fandom.com/wiki/Death_Toll
      - Dead Air: https://left4dead.fandom.com/wiki/Dead_Air
      - Blood Harvest: https://left4dead.fandom.com/wiki/Blood_Harvest
      - Crash Course: https://left4dead.fandom.com/wiki/Crash_Course

    Two later campaigns, The Passing and The Sacrifice, are Left 4 Dead
    2-exclusive: the Wiki's own campaign navigation box (reproduced at the
    bottom of the Death Toll/Dead Air/Blood Harvest pages above) lists both
    exclusively under its "Left 4 Dead 2" column, never under "Left 4 Dead".
    Neither was ever released or ported for the original 2008 game/server, so
    neither is included below.

    *** INTERNAL MAP-FILE NAMES: ORIGINAL L4D1 NAMING, NOT THE L4D2 C#M# PORT NAMING ***
    When No Mercy/Crash Course/Death Toll/Dead Air/Blood Harvest were later
    ported into Left 4 Dead 2 (2011, via the Cold Stream DLC/community
    update), they were re-packaged there under L4D2's own "c#m#_name"
    mission-file convention (e.g. "c8m1_apartment"). That is the L4D2 port's
    internal naming, confirmed via a Steam Guide enumerating L4D2's mission
    files (steamcommunity.com/sharedfiles/filedetails/?id=2375999241) - it is
    NOT what the original standalone Left 4 Dead (AppID 222840) server this
    plugin targets actually uses.
    The original, Turtle Rock/Valve-era L4D1 map-file names instead follow an
    "l4d_<location><NN>_<chaptername>" convention, confirmed independently
    across multiple community references (server-browser map listings on
    tsarvar.com/gs4u.net, cross-checked against each campaign's own chapter
    order on the Left 4 Dead Wiki pages cited above):
      No Mercy:      l4d_hospital01_apartment, l4d_hospital02_subway,
                      l4d_hospital03_sewers, l4d_hospital04_interior,
                      l4d_hospital05_rooftop
      Crash Course:   l4d_garage01_alleys, l4d_garage02_lots
      Death Toll:    l4d_smalltown01_caves, l4d_smalltown02_drainage,
                      l4d_smalltown03_ranchhouse, l4d_smalltown04_mainstreet,
                      l4d_smalltown05_houseboat
      Dead Air:      l4d_airport01_greenhouse, l4d_airport02_offices,
                      l4d_airport03_garage, l4d_airport04_terminal,
                      l4d_airport05_runway
      Blood Harvest: l4d_farm01_hilltop, l4d_farm02_traintunnel,
                      l4d_farm03_bridge, l4d_farm04_barn, l4d_farm05_cornfield

    Custom maps: Test-L4DMap also accepts any map name listed under this
    plugin's own key ("L4D", the plugin folder name) in Config/CustomMaps.json,
    a single shared file (keyed by plugin folder name) covering every Phase 1
    plugin, not one file per plugin. Missing file, missing key, or an empty
    key all fall back to the official list with no error - custom maps are
    optional. This is also the path for any third-party/community campaign,
    since only Valve's own official campaigns are enumerated below.
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../../Core/Utilities.psm1')
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../../Core/Logging.psm1')

# Confirmed official Left 4 Dead (2008) campaign maps, as internal map-file
# identifiers (lowercase), grouped by campaign:
#   No Mercy (c1): apartment, subway, sewers, interior, rooftop
#   Crash Course (c2): alleys, lots
#   Death Toll (c3): caves, drainage, ranchhouse, mainstreet, houseboat
#   Dead Air (c4): greenhouse, offices, garage, terminal, runway
#   Blood Harvest (c5): hilltop, traintunnel, bridge, barn, cornfield
[string[]]$script:L4DMaps = @(
    'l4d_hospital01_apartment',
    'l4d_hospital02_subway',
    'l4d_hospital03_sewers',
    'l4d_hospital04_interior',
    'l4d_hospital05_rooftop',
    'l4d_garage01_alleys',
    'l4d_garage02_lots',
    'l4d_smalltown01_caves',
    'l4d_smalltown02_drainage',
    'l4d_smalltown03_ranchhouse',
    'l4d_smalltown04_mainstreet',
    'l4d_smalltown05_houseboat',
    'l4d_airport01_greenhouse',
    'l4d_airport02_offices',
    'l4d_airport03_garage',
    'l4d_airport04_terminal',
    'l4d_airport05_runway',
    'l4d_farm01_hilltop',
    'l4d_farm02_traintunnel',
    'l4d_farm03_bridge',
    'l4d_farm04_barn',
    'l4d_farm05_cornfield'
)

function Get-L4DCustomMaps {
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
        Write-GSMLog -Level Warning -Message "Failed to read '$customMapsPath', falling back to the official Left 4 Dead map list only: $($_.Exception.Message)"
        return [string[]]@()
    }

    $property = $customMapsConfig.PSObject.Properties['L4D']
    if ($null -eq $property -or $null -eq $property.Value) {
        return [string[]]@()
    }

    return [string[]]$property.Value
}

function Get-L4DMaps {
    <#
    .SYNOPSIS
        Returns the confirmed official Left 4 Dead (2008) campaign map list.
    .DESCRIPTION
        Returns the internal map-file identifiers (lowercase) for every
        official campaign chapter shipped in the original Left 4 Dead: No
        Mercy, Crash Course, Death Toll, Dead Air, and Blood Harvest.
    .EXAMPLE
        Get-L4DMaps
    .NOTES
        This is the stock map list only; it does not include custom maps
        from Config/CustomMaps.json. Test-L4DMap validates against both;
        this function returns the official list alone.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    return [string[]]$script:L4DMaps
}

function Test-L4DMap {
    <#
    .SYNOPSIS
        Checks whether a map name is one of the confirmed official Left 4
        Dead (2008) campaign maps, or a custom map registered for this
        plugin in Config/CustomMaps.json.
    .DESCRIPTION
        Case-insensitive comparison against Get-L4DMaps, merged with this
        plugin's own entries (if any) from the shared Config/CustomMaps.json.
    .PARAMETER MapName
        The map name to validate, e.g. 'l4d_hospital01_apartment'.
    .EXAMPLE
        Test-L4DMap -MapName 'l4d_hospital01_apartment'
    .NOTES
        Third-party/community campaigns must be registered under this
        plugin's "L4D" key in Config/CustomMaps.json to validate here - only
        Valve's five official campaigns are recognized out of the box.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$MapName
    )

    $customMaps = @(Get-L4DCustomMaps) | ForEach-Object { $_.ToLowerInvariant() }
    $allMaps = @($script:L4DMaps) + @($customMaps)

    return ($allMaps -contains $MapName.ToLowerInvariant())
}

Export-ModuleMember -Function Get-L4DMaps, Test-L4DMap
