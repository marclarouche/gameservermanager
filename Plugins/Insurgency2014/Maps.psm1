#Requires -Version 7.0
<#
.SYNOPSIS
    Insurgency (2014) map list and validation.
.DESCRIPTION
    Phase 1. Supplies the confirmed official Insurgency (2014) stock map
    list and validates map names before they're written to a server config.
.NOTES
    Functions to implement: Get-Insurgency2014Maps, Test-Insurgency2014Map.
#>

Set-StrictMode -Version Latest

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
        This is the stock map list only; it does not include Workshop maps,
        which are arbitrary and validated separately (if at all).
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
        Insurgency (2014) stock maps.
    .DESCRIPTION
        Case-insensitive comparison against Get-Insurgency2014Maps.
    .PARAMETER MapName
        The map name to validate, e.g. 'Market' or 'market'.
    .EXAMPLE
        Test-Insurgency2014Map -MapName 'Market'
    .NOTES
        Returns $false for Workshop or custom maps; it only recognizes the
        stock map list.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$MapName
    )

    return ($script:Insurgency2014Maps -contains $MapName.ToLowerInvariant())
}

Export-ModuleMember -Function Get-Insurgency2014Maps, Test-Insurgency2014Map
