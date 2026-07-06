#Requires -Version 7.0
<#
.SYNOPSIS
    Left 4 Dead (2008) game mode list and validation.
.DESCRIPTION
    Phase 1. Supplies the confirmed official Left 4 Dead (2008) game modes
    and validates mode names before they're written to a server config.
.NOTES
    Functions implemented: Get-L4DModes, Test-L4DMode.

    Confirmed mode roster (source: left4dead.fandom.com/wiki/Gameplay_Modes,
    "Gameplay Modes" article, retrieved 2026-07-06), which states plainly:
    "There are currently 4 Gameplay Modes in Left 4 Dead, and 8 Gameplay
    Modes in Left 4 Dead 2." The four confirmed as "Available in Left 4 Dead"
    on that page are:
      - Campaign (co-op, the base campaign mode)
      - Versus
      - Survival (added later via the free "Survival Pack" update,
        April 21, 2009, but confirmed shipped for the original L4D1, not
        L4D2-exclusive)
      - Single Player (a local/offline solo variant of Campaign with
        AI-controlled teammates, not a distinct dedicated-server game mode)

    Scavenge is explicitly confirmed L4D2-exclusive on the same page: it is
    grouped under "Introduced in Left 4 Dead 2" alongside Realism,
    Mutations, Realism Versus, and Versus Survival, and the page states it
    is available in Left 4 Dead 2 only. It is NOT included below.

    Single Player and Split Screen are local-play presentation variants of
    Campaign (no bots-vs-network distinction relevant to a dedicated
    server config) rather than a distinct ruleset a dedicated server
    launches into, so only Campaign, Versus, and Survival are modeled here
    as dedicated-server-selectable modes.

    *** MODE-FIELD DESIGN DECISION (see this plugin's Server.psm1 for the
    validation side) ***
    Unlike Team Fortress 2 (map names self-encode mode via prefix, e.g.
    cp_dustbowl), Left 4 Dead map names carry no mode information at all:
    "l4d_hospital01_apartment" is the same physical map file whether the
    server runs it as Campaign, Versus, or Survival - the ruleset is chosen
    by a separate mode convar (mp_gamemode "coop" / "versus" / "survival")
    at launch, not by loading a differently-named map file. Because the same
    Map value genuinely means something different depending on Mode (unlike
    TF2, where a separate Mode field would be redundant with the map
    prefix), this plugin follows Insurgency2014's precedent: Server.psm1's
    Test-L4DServerConfig validates a required "Mode" config field against
    Get-L4DModes/Test-L4DMode, and Get-L4DLaunchArgs uses it to build the
    mp_gamemode launch argument.
#>

Set-StrictMode -Version Latest

# Confirmed official Left 4 Dead (2008) game modes (internal mp_gamemode
# convar values, lowercase).
[string[]]$script:L4DModes = @(
    'coop',
    'versus',
    'survival'
)

function Get-L4DModes {
    <#
    .SYNOPSIS
        Returns the confirmed official Left 4 Dead (2008) game mode list.
    .DESCRIPTION
        Returns the mp_gamemode convar identifiers (lowercase) for every
        confirmed official Left 4 Dead (2008) game mode: Campaign (coop),
        Versus, and Survival.
    .EXAMPLE
        Get-L4DModes
    .NOTES
        Scavenge and Realism-family modes are Left 4 Dead 2-exclusive per
        left4dead.fandom.com/wiki/Gameplay_Modes and are intentionally not
        included. See this module's top-of-file .NOTES for the mode-field
        design decision and sourcing.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    return [string[]]$script:L4DModes
}

function Test-L4DMode {
    <#
    .SYNOPSIS
        Checks whether a mode name is one of the confirmed official Left 4
        Dead (2008) game modes.
    .DESCRIPTION
        Case-insensitive comparison against Get-L4DModes.
    .PARAMETER ModeName
        The mode name to validate, e.g. 'Versus' or 'versus'.
    .EXAMPLE
        Test-L4DMode -ModeName 'Versus'
    .NOTES
        Unlike Team Fortress 2's Modes.psm1, this module's Test-L4DMode is
        used by Server.psm1's Test-L4DServerConfig as part of required
        config validation, not kept reference-only - see this file's
        top-of-file .NOTES for why L4D's Map/Mode relationship differs from
        TF2's.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$ModeName
    )

    return ($script:L4DModes -contains $ModeName.ToLowerInvariant())
}

Export-ModuleMember -Function Get-L4DModes, Test-L4DMode
