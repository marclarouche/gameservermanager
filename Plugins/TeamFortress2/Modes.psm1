#Requires -Version 7.0
<#
.SYNOPSIS
    Team Fortress 2 game mode list and validation.
.DESCRIPTION
    Phase 1. Supplies the confirmed official Team Fortress 2 game modes and
    validates mode names for reference/documentation purposes.
.NOTES
    Functions implemented: Get-TeamFortress2Modes, Test-TeamFortress2Mode.

    Confirmed mode roster (source: wiki.teamfortress.com/wiki/List_of_game_modes,
    "List of game modes" article, retrieved 2026-07-06), 20 official game
    modes plus Training Mode:
      - Capture the Flag (ctf_)
      - Control Point (cp_) - covers Standard/5CP, Attack/Defend, and Domination
      - Territorial Control (tc_)
      - Payload (pl_)
      - Arena (arena_)
      - Payload Race (plr_)
      - King of the Hill (koth_)
      - Medieval Mode (cp_, a Control Point ruleset variant)
      - Special Delivery (sd_)
      - Mann vs. Machine (mvm_)
      - Robot Destruction (rd_)
      - Mannpower (ctf_, a Capture the Flag ruleset variant)
      - PASS Time (pass_)
      - Player Destruction (pd_)
      - Versus Saxton Hale (vsh_)
      - Zombie Infection (zi_)
      - Tug of War (tow_)
      - Hold the Flag (htf_)
      - Competitive Mode (ruleset overlay, not a map prefix)
      - Training Mode (tr_)

    UNLIKE Insurgency2014, this module's role is reference/documentation
    only: Server.psm1's Test-TeamFortress2ServerConfig does NOT validate a
    separate "Mode" config field against this list. See Server.psm1's own
    .NOTES for the reasoning: every stock TF2 map name is itself prefixed
    with its mode (cp_, ctf_, koth_, pl_, plr_, arena_, sd_, mvm_, rd_,
    pass_, pd_, vsh_, zi_, tow_, htf_, tr_), so a separate Mode field on the
    config would either duplicate or directly contradict the Map field.
    Get-TeamFortress2Modes/Test-TeamFortress2Mode are kept for callers that
    want to enumerate or sanity-check mode names for display purposes (e.g.
    a future interactive config editor grouping maps by mode).
#>

Set-StrictMode -Version Latest

# Confirmed official Team Fortress 2 game modes (display names, lowercase).
[string[]]$script:TeamFortress2Modes = @(
    'capture-the-flag',
    'control-point',
    'territorial-control',
    'payload',
    'arena',
    'payload-race',
    'king-of-the-hill',
    'medieval-mode',
    'special-delivery',
    'mann-vs-machine',
    'robot-destruction',
    'mannpower',
    'pass-time',
    'player-destruction',
    'versus-saxton-hale',
    'zombie-infection',
    'tug-of-war',
    'hold-the-flag',
    'competitive-mode',
    'training-mode'
)

function Get-TeamFortress2Modes {
    <#
    .SYNOPSIS
        Returns the confirmed official Team Fortress 2 game mode list.
    .DESCRIPTION
        Returns the display-name mode identifiers (lowercase, hyphenated)
        for every confirmed official Team Fortress 2 game mode, per
        wiki.teamfortress.com/wiki/List_of_game_modes.
    .EXAMPLE
        Get-TeamFortress2Modes
    .NOTES
        Reference/documentation list only. Not used by
        Test-TeamFortress2ServerConfig, since TF2 stock map names already
        encode their mode via prefix (cp_, ctf_, koth_, pl_, etc.) - see
        Server.psm1's .NOTES.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    return [string[]]$script:TeamFortress2Modes
}

function Test-TeamFortress2Mode {
    <#
    .SYNOPSIS
        Checks whether a mode name is one of the confirmed official Team
        Fortress 2 game modes.
    .DESCRIPTION
        Case-insensitive comparison against Get-TeamFortress2Modes.
    .PARAMETER ModeName
        The mode name to validate, e.g. "Payload" or "payload".
    .EXAMPLE
        Test-TeamFortress2Mode -ModeName "King of the Hill"
    .OUTPUTS
        System.Boolean
    .NOTES
        Reference/documentation helper only. See Get-TeamFortress2Modes'
        notes above for why this is not part of config validation.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$ModeName
    )

    return ($script:TeamFortress2Modes -contains $ModeName.ToLowerInvariant())
}

Export-ModuleMember -Function Get-TeamFortress2Modes, Test-TeamFortress2Mode
