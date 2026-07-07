#Requires -Version 7.0
<#
.SYNOPSIS
    Left 4 Dead 2 game mode list and validation.
.DESCRIPTION
    Phase 1. Supplies the confirmed stable Left 4 Dead 2 game modes and
    validates mode names before they're written to a server config.
.NOTES
    Functions implemented: Get-L4D2Modes, Test-L4D2Mode.

    Sources consulted (retrieved 2026-07-07):
      - left4dead.fandom.com/wiki/Gameplay_Modes - lists Campaign, Single
        Player, Split Screen, and Survival as introduced in Left 4 Dead, and
        Scavenge, Realism, Mutation, Realism Versus, and Versus Survival as
        introduced in Left 4 Dead 2.
      - developer.valvesoftware.com/wiki/L4D2_Mission_Files - documents the
        mission-file "modes" block and lists the base gamemode script names a
        campaign can define maps for: coop, versus, survival, scavenge (with
        realism layered on top of coop/campaign maps).
      - The actual gamemodes.txt game script shipped with Left 4 Dead 2
        (cross-checked against a public mirror of the extracted VPK content
        and against developer.valvesoftware.com/wiki/L4D2_Gamemodes.txt_File's
        description of the file format) - this is the closest thing to
        primary-source ground truth for which mp_gamemode string values
        actually exist.

    *** CONFIRMED STABLE, DEDICATED-SERVER-SELECTABLE MODES ***
    The gamemodes.txt script defines exactly five modes with their own
    stable, human-readable top-level name: coop, realism, survival, versus,
    and scavenge. Every one of these is directly usable as an mp_gamemode
    value and keeps the same name release over release, so all five are
    included below.

    *** MUTATIONS - INTENTIONALLY EXCLUDED, INCLUDING THE TWO THAT BECAME
    PERMANENT MODES ***
    Left 4 Dead 2 also ships roughly thirty numbered "Mutation" and
    "Community" gamemode entries (mutation1 through mutation20, community1
    through community6, plus a few extras like horde/hordehc) in the same
    gamemodes.txt file. These rotate, are not a small fixed list, and (per
    the task's own guidance for this plugin) are not suitable for a config
    validation enum. Notably, this exclusion also covers Realism Versus and
    Versus Survival even though the fandom wiki and the in-game menu present
    both as permanent, first-class modes since 2010 and 2012 respectively:
    under the hood, gamemodes.txt still implements them as mutation12 and
    mutation15, not as their own stable script name the way coop/realism/
    survival/versus/scavenge are. Exposing "mutation12"/"mutation15" as
    config values would be a non-obvious, renumbering-fragile identifier, so
    both are left out of Get-L4D2Modes/Test-L4D2Mode. A server operator who
    wants either mode can still reach it via a plugin/SourceMod config
    outside GSM's scope; this is the same kind of documented scope
    limitation Team Fortress 2's Maps.psm1 uses for its curated map subset.

    *** MODE-FIELD DESIGN DECISION (see this plugin's Server.psm1 for the
    validation side) ***
    Left 4 Dead 2 map file names follow a "c#m#_name" convention that
    identifies campaign and chapter only, never mode: per Valve's own
    mission-file documentation, the very same map bsp is commonly reused
    across the coop/versus/scavenge/realism "modes" blocks of a single
    mission file with no separate name, exactly the situation Left 4 Dead
    (2008) has with its l4d_<location><NN>_<name> maps. This was verified
    independently for Left 4 Dead 2 rather than assumed from Left 4 Dead's
    precedent: because Map alone still cannot tell coop from versus from
    survival here, this plugin follows Left 4 Dead's precedent (and
    Insurgency2014's), not Team Fortress 2's - Server.psm1's
    Test-L4D2ServerConfig requires a separate "Mode" field, validated here,
    and Get-L4D2LaunchArgs uses it to build the +mp_gamemode launch
    argument.
#>

Set-StrictMode -Version Latest

# Confirmed stable Left 4 Dead 2 game modes (internal mp_gamemode convar
# values, lowercase). See this file's top-of-file .NOTES for why the
# rotating Mutation/Community roster (including the "graduated" Realism
# Versus/Versus Survival mutation slots) is intentionally not included.
[string[]]$script:L4D2Modes = @(
    'coop',
    'realism',
    'survival',
    'versus',
    'scavenge'
)

function Get-L4D2Modes {
    <#
    .SYNOPSIS
        Returns the confirmed stable Left 4 Dead 2 game mode list.
    .DESCRIPTION
        Returns the mp_gamemode convar identifiers (lowercase) for every
        confirmed stable Left 4 Dead 2 game mode: Campaign (coop), Realism,
        Survival, Versus, and Scavenge.
    .EXAMPLE
        Get-L4D2Modes
    .NOTES
        Mutations (including the numbered mutation12/mutation15 slots that
        back the permanent Realism Versus and Versus Survival menu options)
        are intentionally not included. See this module's top-of-file notes
        section for the full reasoning and sourcing.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    return [string[]]$script:L4D2Modes
}

function Test-L4D2Mode {
    <#
    .SYNOPSIS
        Checks whether a mode name is one of the confirmed stable Left 4
        Dead 2 game modes.
    .DESCRIPTION
        Case-insensitive comparison against Get-L4D2Modes.
    .PARAMETER ModeName
        The mode name to validate, e.g. 'Versus' or 'versus'.
    .EXAMPLE
        Test-L4D2Mode -ModeName 'Versus'
    .NOTES
        Unlike Team Fortress 2's Modes.psm1, this module's Test-L4D2Mode is
        used by Server.psm1's Test-L4D2ServerConfig as part of required
        config validation, not kept reference-only - see this file's
        top-of-file .NOTES for why L4D2's Map/Mode relationship differs from
        TF2's.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$ModeName
    )

    return ($script:L4D2Modes -contains $ModeName.ToLowerInvariant())
}

Export-ModuleMember -Function Get-L4D2Modes, Test-L4D2Mode
