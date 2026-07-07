#Requires -Version 7.0
<#
.SYNOPSIS
    Left 4 Dead 2 map list and validation.
.DESCRIPTION
    Phase 1. Supplies the confirmed official Left 4 Dead 2 campaign map list
    and validates map names before they're written to a server config.
.NOTES
    Functions implemented: Get-L4D2Maps, Test-L4D2Map.

    *** SCOPE - FULL CLOSED LIST, NOT A CURATED SUBSET ***
    Unlike Team Fortress 2 (220+ maps, no small authoritative "stock" set),
    Left 4 Dead 2's entire official campaign roster is small, numbered, and
    fully documented by Valve itself: every campaign has its own "campaignN"
    identifier (campaign1 through campaign13) baked into the game's own
    mission-file system. That makes it possible to hand-transcribe the whole
    list with confidence, the same way Left 4 Dead (2008)'s 5-campaign, 22-map
    list is a full closed list rather than a curated subset.

    Scope is Valve's own 13 in-house campaigns (campaign1 through campaign13)
    only. "The Last Stand" (see the flagged-and-resolved note below) is
    intentionally excluded from this official list on product-decision
    grounds: it is community-authored, not Valve in-house, even though Valve
    distributed it for free.

    Sources consulted (retrieved 2026-07-07), cross-checked against each
    other for every campaign/map pair below:
      - developer.valvesoftware.com/wiki/L4D2_Mission_Files - documents
        Valve's own "campaign1" through "campaign13" identifiers:
        campaign1 Dead Center, campaign2 Dark Carnival, campaign3 Swamp
        Fever, campaign4 Hard Rain, campaign5 The Parish, campaign6 The
        Passing, campaign7 The Sacrifice, campaign8 No Mercy, campaign9
        Crash Course, campaign10 Death Toll, campaign11 Dead Air, campaign12
        Blood Harvest, campaign13 Cold Stream.
      - commands.gg/l4d2/map - a full, independently cross-checked table of
        every internal c#m#_name map identifier for campaigns 1-13.
      - steamcommunity.com/sharedfiles/filedetails/?id=2375999241 (a Steam
        Guide enumerating the same c#m#_name identifiers by campaign,
        including The Sacrifice's 3-map structure) and
        steamcommunity.com/sharedfiles/filedetails/?id=3364422759 (confirms
        The Sacrifice's map count and chapter order), used to resolve The
        Sacrifice ambiguity flagged in this task: The Sacrifice IS a real,
        playable in-game campaign (campaign7, 3 maps), not a comic-only
        tie-in - it has its own mission-file entry and its own map-model
        swap example on Valve's own Mission Files documentation page.

    *** THE FIVE PORTED LEFT 4 DEAD (2008) CAMPAIGNS ***
    No Mercy, Crash Course, Death Toll, Dead Air, and Blood Harvest were
    ported into Left 4 Dead 2 alongside the Cold Stream DLC (2011) using
    Left 4 Dead 2's own c#m# naming (campaign8 through campaign12), distinct
    from Left 4 Dead (2008)'s own l4d_<location><NN>_<name> internal names
    for the same content (see Plugins/L4D/Maps.psm1). Cold Stream itself is
    a separate, thirteenth campaign (campaign13, 4 maps), not merely an
    umbrella name for the five ports.

    *** THE PARISH - "_sndscape" VARIANT EXCLUDED ***
    commands.gg's table lists both "c5m1_waterfront" and
    "c5m1_waterfront_sndscape" for The Parish's first chapter. The
    "_sndscape" entry is a background-ambiance/soundscape-only technical
    variant, not a second playable chapter, so only "c5m1_waterfront" is
    included below, keeping The Parish at 5 real maps like every other
    5-chapter campaign.

    *** RESOLVED JUDGMENT CALL - "THE LAST STAND" EXCLUDED ***
    The Last Stand Community Update (September 2020) added a fourteenth,
    2-map campaign, "The Last Stand" (c14m1_junkyard, c14m2_lighthouse). It
    was built by community developers rather than Valve in-house. Valve
    published it as a free update to the base Left 4 Dead 2 client (no
    separate purchase or Workshop subscription needed), the same
    distribution model as Left 4 Dead (2008)'s free Crash Course add-on that
    Plugins/L4D/Maps.psm1 includes in its own official list - but by product
    decision, community authorship (rather than distribution model) is what
    determines "official" here, so The Last Stand is excluded from the
    13-campaign list below. A server operator who wants it can register
    c14m1_junkyard/c14m2_lighthouse under this plugin's "L4D2" key in
    Config/CustomMaps.json.

    Custom maps: Test-L4D2Map also accepts any map name listed under this
    plugin's own key ("L4D2", the plugin folder name) in Config/CustomMaps.json,
    a single shared file (keyed by plugin folder name) covering every Phase 1
    plugin, not one file per plugin. Missing file, missing key, or an empty
    key all fall back to the official list with no error - custom maps are
    optional. This is also the path for any Workshop or third-party campaign.
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../../Core/Utilities.psm1') -Force
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../../Core/Logging.psm1') -Force

# Confirmed official Left 4 Dead 2 campaign maps, as internal map-file
# identifiers (lowercase), grouped by campaign. See this file's top-of-file
# notes section for sourcing and the flagged campaign14 judgment call.
#   Dead Center (c1): hotel, streets, mall, atrium
#   Dark Carnival (c2): highway, fairgrounds, coaster, barns, concert
#   Swamp Fever (c3): plankcountry, swamp, shantytown, plantation
#   Hard Rain (c4): milltown_a, sugarmill_a, sugarmill_b, milltown_b, milltown_escape
#   The Parish (c5): waterfront, park, cemetery, quarter, bridge
#   The Passing (c6): riverbank, bedlam, port
#   The Sacrifice (c7): docks, barge, port
#   No Mercy (c8, ported from Left 4 Dead): apartment, subway, sewers, interior, rooftop
#   Crash Course (c9, ported from Left 4 Dead): alleys, lots
#   Death Toll (c10, ported from Left 4 Dead): caves, drainage, ranchhouse, mainstreet, houseboat
#   Dead Air (c11, ported from Left 4 Dead): greenhouse, offices, garage, terminal, runway
#   Blood Harvest (c12, ported from Left 4 Dead): hilltop, traintunnel, bridge, barn, cornfield
#   Cold Stream (c13): alpinecreek, southpinestream, memorialbridge, cutthroatcreek
# The Last Stand (community-authored; excluded, see .NOTES) is intentionally
# not listed here - register it via Config/CustomMaps.json if needed.
[string[]]$script:L4D2Maps = @(
    'c1m1_hotel',
    'c1m2_streets',
    'c1m3_mall',
    'c1m4_atrium',
    'c2m1_highway',
    'c2m2_fairgrounds',
    'c2m3_coaster',
    'c2m4_barns',
    'c2m5_concert',
    'c3m1_plankcountry',
    'c3m2_swamp',
    'c3m3_shantytown',
    'c3m4_plantation',
    'c4m1_milltown_a',
    'c4m2_sugarmill_a',
    'c4m3_sugarmill_b',
    'c4m4_milltown_b',
    'c4m5_milltown_escape',
    'c5m1_waterfront',
    'c5m2_park',
    'c5m3_cemetery',
    'c5m4_quarter',
    'c5m5_bridge',
    'c6m1_riverbank',
    'c6m2_bedlam',
    'c6m3_port',
    'c7m1_docks',
    'c7m2_barge',
    'c7m3_port',
    'c8m1_apartment',
    'c8m2_subway',
    'c8m3_sewers',
    'c8m4_interior',
    'c8m5_rooftop',
    'c9m1_alleys',
    'c9m2_lots',
    'c10m1_caves',
    'c10m2_drainage',
    'c10m3_ranchhouse',
    'c10m4_mainstreet',
    'c10m5_houseboat',
    'c11m1_greenhouse',
    'c11m2_offices',
    'c11m3_garage',
    'c11m4_terminal',
    'c11m5_runway',
    'c12m1_hilltop',
    'c12m2_traintunnel',
    'c12m3_bridge',
    'c12m4_barn',
    'c12m5_cornfield',
    'c13m1_alpinecreek',
    'c13m2_southpinestream',
    'c13m3_memorialbridge',
    'c13m4_cutthroatcreek'
)

function Get-L4D2CustomMaps {
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
        Write-GSMLog -Level Warning -Message "Failed to read '$customMapsPath', falling back to the official Left 4 Dead 2 map list only: $($_.Exception.Message)"
        return [string[]]@()
    }

    $property = $customMapsConfig.PSObject.Properties['L4D2']
    if ($null -eq $property -or $null -eq $property.Value) {
        return [string[]]@()
    }

    return [string[]]$property.Value
}

function Get-L4D2Maps {
    <#
    .SYNOPSIS
        Returns the confirmed official Left 4 Dead 2 campaign map list.
    .DESCRIPTION
        Returns the internal map-file identifiers (lowercase) for every
        official campaign chapter shipped in Left 4 Dead 2, across all 13
        Valve in-house campaigns: Dead Center, Dark Carnival, Swamp Fever,
        Hard Rain, The Parish, The Passing, The Sacrifice, No Mercy, Crash
        Course, Death Toll, Dead Air, Blood Harvest, and Cold Stream.
    .EXAMPLE
        Get-L4D2Maps
    .NOTES
        This is the stock map list only; it does not include custom maps
        from Config/CustomMaps.json. Test-L4D2Map validates against both;
        this function returns the official list alone. See this module's
        top-of-file .NOTES for sourcing and why the community-authored "The
        Last Stand" campaign is excluded from this list.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    return [string[]]$script:L4D2Maps
}

function Test-L4D2Map {
    <#
    .SYNOPSIS
        Checks whether a map name is one of the confirmed official Left 4
        Dead 2 campaign maps, or a custom map registered for this plugin in
        Config/CustomMaps.json.
    .DESCRIPTION
        Case-insensitive comparison against Get-L4D2Maps, merged with this
        plugin's own entries (if any) from the shared Config/CustomMaps.json.
    .PARAMETER MapName
        The map name to validate, e.g. 'c1m1_hotel'.
    .EXAMPLE
        Test-L4D2Map -MapName 'c1m1_hotel'
    .NOTES
        Workshop campaigns and third-party custom campaigns must be
        registered under this plugin's "L4D2" key in Config/CustomMaps.json
        to validate here - only Valve's official campaigns are recognized
        out of the box.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$MapName
    )

    $customMaps = @(Get-L4D2CustomMaps) | ForEach-Object { $_.ToLowerInvariant() }
    $allMaps = @($script:L4D2Maps) + @($customMaps)

    return ($allMaps -contains $MapName.ToLowerInvariant())
}

Export-ModuleMember -Function Get-L4D2Maps, Test-L4D2Map
