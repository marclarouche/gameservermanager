#Requires -Version 7.0
<#
.SYNOPSIS
    Insurgency (2014) map list and validation.
.DESCRIPTION
    Phase 1. Supplies the confirmed official Insurgency (2014) stock map
    list and validates map names before they're written to a server config.
.NOTES
    Functions to implement: Get-Insurgency2014Maps, Test-Insurgency2014Map.

    Custom maps: Test-Insurgency2014Map also accepts any map name listed
    under this plugin's own key ("Insurgency2014", the plugin folder name)
    in Config/CustomMaps.json, a single shared file (keyed by plugin folder
    name) covering every Phase 1 plugin, not one file per plugin. Missing
    file, missing key, or an empty key all fall back to the official list
    with no error - custom maps are optional.
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../../Core/Utilities.psm1')
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../../Core/Logging.psm1')

# Confirmed official Insurgency (2014) stock maps, as internal map-file
# identifiers (lowercase, no spaces): Market, Siege, Contact, Uprising,
# Ministry, District, Peak, Heights, Tell, Sinjar, Panj, Buhriz, Revolt,
# Station, Dry Canal, Kandagal.
[string[]]$script:Insurgency2014Maps = @(
    'market',
    'siege',
    'contact',
    'uprising',
    'ministry',
    'district',
    'peak',
    'heights',
    'tell',
    'sinjar',
    'panj',
    'buhriz',
    'revolt',
    'station',
    'drycanal',
    'kandagal'
)

function Get-Insurgency2014CustomMaps {
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
        Write-GSMLog -Level Warning -Message "Failed to read '$customMapsPath', falling back to the official Insurgency (2014) map list only: $($_.Exception.Message)"
        return [string[]]@()
    }

    $property = $customMapsConfig.PSObject.Properties['Insurgency2014']
    if ($null -eq $property -or $null -eq $property.Value) {
        return [string[]]@()
    }

    return [string[]]$property.Value
}

function Get-Insurgency2014Maps {
    <#
    .SYNOPSIS
        Returns the confirmed official Insurgency (2014) stock map list.
    .DESCRIPTION
        Returns the internal map-file identifiers (lowercase, no spaces) for
        every official Insurgency (2014) stock map.
    .EXAMPLE
        Get-Insurgency2014Maps
    .NOTES
        This is the stock map list only; it does not include custom maps
        from Config/CustomMaps.json. Test-Insurgency2014Map validates
        against both; this function returns the official list alone.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    return [string[]]$script:Insurgency2014Maps
}

function Test-Insurgency2014Map {
    <#
    .SYNOPSIS
        Checks whether a map name is one of the confirmed official
        Insurgency (2014) stock maps, or a custom map registered for this
        plugin in Config/CustomMaps.json.
    .DESCRIPTION
        Case-insensitive comparison against Get-Insurgency2014Maps, merged
        with this plugin's own entries (if any) from the shared
        Config/CustomMaps.json.
    .PARAMETER MapName
        The map name to validate, e.g. 'Market' or 'market'.
    .EXAMPLE
        Test-Insurgency2014Map -MapName 'Market'
    .NOTES
        Workshop maps that aren't also listed in Config/CustomMaps.json
        still return $false; this only recognizes the stock list plus
        explicitly registered custom maps.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$MapName
    )

    $customMaps = @(Get-Insurgency2014CustomMaps) | ForEach-Object { $_.ToLowerInvariant() }
    $allMaps = @($script:Insurgency2014Maps) + @($customMaps)

    return ($allMaps -contains $MapName.ToLowerInvariant())
}

Export-ModuleMember -Function Get-Insurgency2014Maps, Test-Insurgency2014Map
