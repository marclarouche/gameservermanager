#Requires -Version 7.0
<#
.SYNOPSIS
    Counter-Strike: Source game mode list and validation.
.DESCRIPTION
    Phase 1. Supplies the confirmed official Counter-Strike: Source
    objective types and validates mode names for reference/documentation
    purposes.
.NOTES
    Functions implemented: Get-CounterStrikeSourceModes,
    Test-CounterStrikeSourceMode.

    Confirmed mode roster (source: developer.valvesoftware.com/wiki/Counter-Strike:_Source's
    "Official Maps" table, and counterstrike.fandom.com's Bomb Defusal and
    Hostage Rescue articles, retrieved 2026-07-06). Counter-Strike: Source
    ships exactly two objective types, and every one of its 18 official
    maps is prefixed with one or the other:
      - Bomb Defusal (de_) - Terrorists plant a bomb at one of the map's
        bombsites; Counter-Terrorists must defuse it or run out the clock.
      - Hostage Rescue (cs_) - Counter-Terrorists must escort hostages held
        near the Terrorist spawn to a rescue zone.

    Assassination (the as_ prefix used by the original Counter-Strike, e.g.
    as_oilrig) was dropped starting with Counter-Strike: Source and never
    shipped for this game - see counterstrike.fandom.com/wiki/Assassination.
    It is intentionally not included below.

    UNLIKE Left 4 Dead, this module's role is reference/documentation only:
    Server.psm1's Test-CounterStrikeSourceServerConfig does NOT validate a
    separate "Mode" config field against this list.
    See Server.psm1's own .NOTES for the reasoning: every official
    Counter-Strike: Source map name is itself prefixed with its objective
    type (de_ for Bomb Defusal, cs_ for Hostage Rescue), so a separate Mode
    field on the config would either duplicate or directly contradict the
    Map field - the same situation Team Fortress 2 is in, and for the same
    reason. Get-CounterStrikeSourceModes/Test-CounterStrikeSourceMode are
    kept for callers that want to enumerate or sanity-check objective-type
    names for display purposes (e.g. a future interactive config editor
    grouping maps by objective type).
#>

Set-StrictMode -Version Latest

# Confirmed official Counter-Strike: Source objective types (display names,
# lowercase, hyphenated).
[string[]]$script:CounterStrikeSourceModes = @(
    'bomb-defusal',
    'hostage-rescue'
)

function Get-CounterStrikeSourceModes {
    <#
    .SYNOPSIS
        Returns the confirmed official Counter-Strike: Source objective
        type list.
    .DESCRIPTION
        Returns the display-name identifiers (lowercase, hyphenated) for
        both confirmed official Counter-Strike: Source objective types:
        Bomb Defusal and Hostage Rescue.
    .EXAMPLE
        Get-CounterStrikeSourceModes
    .NOTES
        Reference/documentation list only. Not used by
        Test-CounterStrikeSourceServerConfig, since Counter-Strike: Source
        stock map names already encode their objective type via prefix
        (de_, cs_) - see Server.psm1's .NOTES.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    return [string[]]$script:CounterStrikeSourceModes
}

function Test-CounterStrikeSourceMode {
    <#
    .SYNOPSIS
        Checks whether a mode name is one of the confirmed official
        Counter-Strike: Source objective types.
    .DESCRIPTION
        Case-insensitive comparison against Get-CounterStrikeSourceModes.
    .PARAMETER ModeName
        The mode name to validate, e.g. 'Bomb Defusal' or 'bomb-defusal'.
    .EXAMPLE
        Test-CounterStrikeSourceMode -ModeName 'bomb-defusal'
    .NOTES
        Reference/documentation helper only. See Get-CounterStrikeSourceModes'
        notes above for why this is not part of config validation.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$ModeName
    )

    return ($script:CounterStrikeSourceModes -contains $ModeName.ToLowerInvariant())
}

Export-ModuleMember -Function Get-CounterStrikeSourceModes, Test-CounterStrikeSourceMode
