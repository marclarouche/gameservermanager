#Requires -Version 7.0
<#
.SYNOPSIS
    Team Fortress 2 map list and validation.
.DESCRIPTION
    Phase 1. Supplies a curated list of long-standing, Valve-developed
    Team Fortress 2 stock maps and validates map names before they're
    written to a server config.
.NOTES
    Functions implemented: Get-TeamFortress2Maps, Test-TeamFortress2Map.

    *** SCOPE FLAG - READ BEFORE RELYING ON THIS LIST ***
    Unlike Insurgency2014 (16 stock maps total, a small closed list),
    Team Fortress 2's official map roster is NOT a small closed list.
    Per wiki.teamfortress.com/wiki/List_of_maps (retrieved 2026-07-06),
    TF2 ships with over 220 official maps across 19 map-type categories,
    added incrementally over nearly two decades of updates, and a large
    fraction of them are community-developed maps that Valve later
    adopted into the game (the wiki itself marks these in italics to
    distinguish them from Valve's own 91 in-house maps, per
    wiki.teamfortress.com/wiki/Category:Valve_maps). There is no single
    small "confirmed stock list" the way Insurgency2014 has one, and
    there is no authoritative small "default server rotation" either -
    TF2's old Quickplay system used its own separate 45-map curated list
    (now deprecated in favor of Casual matchmaking), and dedicated
    servers' mapcycle.txt is operator-defined, not Valve-fixed.

    Given that, the list below is a deliberately curated subset: the
    long-standing, iconic, Valve-developed launch-era and early-update
    maps that are universally recognized as TF2 "stock" maps across every
    source consulted (wiki.teamfortress.com, Wikipedia's Team Fortress 2
    article), one per mode-prefix family, using internal map-file names
    verified against wiki.teamfortress.com. It is NOT exhaustive and is
    NOT a claim that every other official map is somehow non-stock - it
    is a confidence-scoped subset chosen because attempting to hand
    -transcribe all 220+ entries (many sharing base map names across
    multiple mode-variant releases, e.g. Well/Granary/Badlands/Nucleus/
    Sawmill each shipping as different map files for different modes)
    from scraped wiki tables carries a real risk of silent transcription
    errors. This scope decision should be reviewed before this plugin is
    treated as feature-complete; expanding Get-TeamFortress2Maps later is
    a non-breaking, additive change.

    Custom maps: Test-TeamFortress2Map also accepts any map name listed
    under this plugin's own key ("TeamFortress2", the plugin folder name)
    in Config/CustomMaps.json, a single shared file (keyed by plugin
    folder name) covering every Phase 1 plugin, not one file per plugin.
    Missing file, missing key, or an empty key all fall back to the
    curated list with no error - custom maps are optional. This is the
    normal, expected path for adding any of the 200+ official maps not
    included in the curated list below, as well as Workshop maps.
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../../Core/Utilities.psm1')
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../../Core/Logging.psm1')

# Curated subset of long-standing, Valve-developed Team Fortress 2 stock
# maps (internal map-file identifiers, lowercase), one representative per
# major mode-prefix family. See the SCOPE FLAG in this file's .NOTES: this
# is NOT the full 220+ map official roster.
#   Capture the Flag (ctf_): 2fort, well, doublecross, sawmill
#   Control Point standard (cp_): granary, well, badlands, gullywash
#   Control Point Attack/Defend (cp_): dustbowl, gravelpit, egypt, junction
#   Territorial Control (tc_): hydro
#   Payload (pl_): goldrush, badwater, thundermountain, upward
#   Arena (arena_): granary, well, badlands, lumberyard
#   Payload Race (plr_): pipeline, hightower
#   King of the Hill (koth_): nucleus, viaduct, sawmill
[string[]]$script:TeamFortress2Maps = @(
    'ctf_2fort',
    'ctf_well',
    'ctf_doublecross',
    'ctf_sawmill',
    'cp_granary',
    'cp_well',
    'cp_badlands',
    'cp_gullywash',
    'cp_dustbowl',
    'cp_gravelpit',
    'cp_egypt',
    'cp_junction',
    'tc_hydro',
    'pl_goldrush',
    'pl_badwater',
    'pl_thundermountain',
    'pl_upward',
    'arena_granary',
    'arena_well',
    'arena_badlands',
    'arena_lumberyard',
    'plr_pipeline',
    'plr_hightower',
    'koth_nucleus',
    'koth_viaduct',
    'koth_sawmill'
)

function Get-TeamFortress2CustomMaps {
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
        Write-GSMLog -Level Warning -Message "Failed to read '$customMapsPath', falling back to the official Team Fortress 2 map list only: $($_.Exception.Message)"
        return [string[]]@()
    }

    $property = $customMapsConfig.PSObject.Properties['TeamFortress2']
    if ($null -eq $property -or $null -eq $property.Value) {
        return [string[]]@()
    }

    return [string[]]$property.Value
}

function Get-TeamFortress2Maps {
    <#
    .SYNOPSIS
        Returns the curated Team Fortress 2 stock map list.
    .DESCRIPTION
        Returns the internal map-file identifiers (lowercase) for this
        plugin's curated subset of long-standing, Valve-developed Team
        Fortress 2 stock maps. See this module's .NOTES for why this is a
        deliberately scoped subset, not the full 220+ map official roster.
    .EXAMPLE
        Get-TeamFortress2Maps
    .NOTES
        This is the curated list only; it does not include custom maps
        from Config/CustomMaps.json. Test-TeamFortress2Map validates
        against both; this function returns the curated list alone.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    return [string[]]$script:TeamFortress2Maps
}

function Test-TeamFortress2Map {
    <#
    .SYNOPSIS
        Checks whether a map name is one of the curated Team Fortress 2
        stock maps, or a custom map registered for this plugin in
        Config/CustomMaps.json.
    .DESCRIPTION
        Case-insensitive comparison against Get-TeamFortress2Maps, merged
        with this plugin's own entries (if any) from the shared
        Config/CustomMaps.json.
    .PARAMETER MapName
        The map name to validate, e.g. 'cp_dustbowl' or 'CP_DUSTBOWL'.
    .EXAMPLE
        Test-TeamFortress2Map -MapName 'cp_dustbowl'
    .NOTES
        Any of TF2's 200+ official maps not included in the curated stock
        list, as well as Workshop maps, must be registered under this
        plugin's "TeamFortress2" key in Config/CustomMaps.json to validate
        here - see this file's SCOPE FLAG .NOTES for why the stock list is
        intentionally not exhaustive.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$MapName
    )

    $customMaps = @(Get-TeamFortress2CustomMaps) | ForEach-Object { $_.ToLowerInvariant() }
    $allMaps = @($script:TeamFortress2Maps) + @($customMaps)

    return ($allMaps -contains $MapName.ToLowerInvariant())
}

Export-ModuleMember -Function Get-TeamFortress2Maps, Test-TeamFortress2Map
