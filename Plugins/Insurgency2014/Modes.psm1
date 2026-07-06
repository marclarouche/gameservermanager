#Requires -Version 7.0
<#
.SYNOPSIS
    Insurgency (2014) game mode list and validation.
.DESCRIPTION
    Phase 1. Supplies the confirmed Insurgency (2014) game modes and
    validates mode names before they're written to a server config.
.NOTES
    Functions to implement: Get-Insurgency2014Modes, Test-Insurgency2014Mode.

    Confirmed mode roster, by category (source: Marc Larouche, verified
    against Insurgency (2014) server documentation rather than guessed):
      - Sustained Combat: Occupy, Push, Skirmish, Strike
      - Tactical Operations: Ambush, Elimination, Firefight
      - Cooperative: Conquer, Checkpoint, Hunt, Outpost, Survival
      - Competitive Matches: Firefight (same mode as Tactical Operations)
      - Flashpoint (additional confirmed mode, not part of the four
        categories above)

    Display names are used here. The internal map-file suffix used to
    build a +map argument (e.g. Checkpoint -> "coop") is a launch-mechanics
    concern, not a mode-identity concern, and lives in Server.psm1 instead.
#>

Set-StrictMode -Version Latest

# Confirmed Insurgency (2014) game modes (display names, lowercase).
[string[]]$script:Insurgency2014Modes = @(
    'checkpoint',
    'push',
    'firefight',
    'skirmish',
    'ambush',
    'strike',
    'occupy',
    'elimination',
    'conquer',
    'hunt',
    'outpost',
    'survival',
    'flashpoint'
)

function Get-Insurgency2014Modes {
    <#
    .SYNOPSIS
        Returns the confirmed Insurgency (2014) game mode list.
    .DESCRIPTION
        Returns the display-name mode identifiers (lowercase) for every
        confirmed Insurgency (2014) game mode, covering the Sustained
        Combat, Tactical Operations, Cooperative, and Competitive Matches
        categories, plus Flashpoint.
    .EXAMPLE
        Get-Insurgency2014Modes
    .NOTES
        These are display-name identifiers, not the internal +map file
        suffixes (Server.psm1's Get-Insurgency2014LaunchArgs handles that
        translation, since Checkpoint's suffix is "coop", not "checkpoint").
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    return [string[]]$script:Insurgency2014Modes
}

function Test-Insurgency2014Mode {
    <#
    .SYNOPSIS
        Checks whether a mode name is one of the confirmed Insurgency
        (2014) game modes.
    .DESCRIPTION
        Case-insensitive comparison against Get-Insurgency2014Modes.
    .PARAMETER ModeName
        The mode name to validate, e.g. 'Checkpoint' or 'checkpoint'.
    .EXAMPLE
        Test-Insurgency2014Mode -ModeName 'Checkpoint'
    .NOTES
        Does not accept the internal "coop" map-file suffix as a mode name;
        that's a launch-mechanics alias handled in Server.psm1, not a mode
        identity.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$ModeName
    )

    return ($script:Insurgency2014Modes -contains $ModeName.ToLowerInvariant())
}

Export-ModuleMember -Function Get-Insurgency2014Modes, Test-Insurgency2014Mode
