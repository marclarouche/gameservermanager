# GSM Phase 1 Plugins - Session Status

Last updated: 2026-07-06

## Where things stand

All five Phase 1 plugins are now implemented, tested, and committed:

| Plugin | AppID | Workshop | Mode field | Map list | Status |
|---|---|---|---|---|---|
| Insurgency2014 | 237410 | Yes | Yes (suffix quirk: Checkpoint->coop) | 16 maps, closed list | Committed |
| TeamFortress2 | 232250 | Yes | No (map prefix encodes mode) | 26 curated (of 220+ official) | Committed |
| L4D | 222840 | No | Yes (mp_gamemode convar) | 22 maps, closed list | Committed |
| CounterStrikeSource | 232330 | No | No (map prefix encodes mode) | 18 maps, closed list | Committed |
| L4D2 | 222860 | Yes | Not started | Not started | **Not started** |

Each plugin has the same four modules (Install.psm1, Server.psm1, Maps.psm1, Modes.psm1), a Config.template.json, and four Pester test files (Tests/<Plugin>.Install/Maps/Modes/Server.Tests.ps1).

Current full-suite Pester count: **214/214 passing** (as of the CounterStrikeSource commit). PSScriptAnalyzer is clean on every plugin except the two pre-accepted categories: `PSUseShouldProcessForStateChangingFunctions` and `PSUseSingularNouns`.

Insurgency2014's Maps.psm1 was retrofitted this session to read the shared `Config/CustomMaps.json` file (previously had no custom-map support at all) - this was committed as its own separate commit, before the four new-game plugins started.

## Next task: L4D2

Plugin.json already exists (do not touch it): `{"GameName": "Left4Dead", "Version": "2", "AppID": "222860", "Engine": "Source", "Executable": "srcds.exe", "DefaultPort": 27015, "SupportsWorkshop": true, "SupportsRCON": true}`.

Build via a dedicated subagent (same pattern used for TeamFortress2/L4D/CounterStrikeSource): Install.psm1, Server.psm1, Maps.psm1, Modes.psm1, Config.template.json, and four test files, matching the conventions of all four existing plugins.

Key things the subagent will need to get right (flag ambiguity rather than guess, per standing instruction):
- L4D2 DOES support Workshop (unlike L4D/CounterStrikeSource) - include the `+sv_workshop_enabled` launch-arg pattern from Insurgency2014/TeamFortress2.
- L4D2's map roster is much larger than L4D's: the 5 original L4D campaigns were ported in via Cold Stream/Last Stand updates using L4D2's own `c#m#_name` naming (different from L4D's `l4d_<location><NN>_<name>` naming - do not reuse L4D's internal map names), plus L4D2's own original campaigns (Dead Center, Dark Carnival, Swamp Fever, Hard Rain, The Parish) and DLC campaigns (The Passing, Cold Stream, The Sacrifice - verify each via an authoritative source such as left4dead.fandom.com, don't guess). This may end up being a TeamFortress2-style curated-subset situation or an L4D-style clean closed list - let the subagent determine which and document its reasoning either way, same as the prior two plugins did.
- L4D2 game modes: Campaign, Versus, Survival, Scavenge, plus L4D2-added modes (Realism, Mutations, Realism Versus, Versus Survival per L4D's Modes.psm1 research notes) - verify against left4dead.fandom.com's Gameplay Modes page rather than assuming L4D's list plus Scavenge.
- Same Mode-field design question as L4D (map names likely don't encode mode) vs TeamFortress2 (prefix encodes mode) - the subagent should verify which applies to L4D2, not assume it copies L4D's answer.
- MaxPlayers range: L4D was narrowed to 1-8 per an explicit product decision (L4D2 has the same 4v4 Versus structure, so the same reasoning likely applies, but confirm rather than assume).
- Known PSScriptAnalyzer gotchas from this session, worth passing to the subagent again:
  1. Never let a comment-help continuation line start with a recognized keyword like `.NOTES` (corrupts the whole help block, causes a false PSProvideCommentHelp finding) - keep such references on one line.
  2. Avoid pasting long verbatim web quotes into comments; paraphrase and stick to plain ASCII punctuation (no curly quotes, em-dashes, or ellipsis characters) to avoid a spurious `PSUseBOMForUnicodeEncodedFile` finding.
  3. Every `return` path in a function declared `[OutputType([string[]])]` must be cast (`[string[]]$x` or `[string[]]@()`), even early-return empty-array branches, or PSScriptAnalyzer flags `PSUseOutputTypeCorrectly`.

## Workflow reminders for continuing this

- Marc runs Pester/PSScriptAnalyzer himself on his Windows machine (`D:\Projects\GSM\GameServerManager`) and pastes output back - this sandbox has no PowerShell installed.
- Build each remaining plugin via a dedicated general-purpose subagent (per Marc's explicit instruction), verify the subagent's files directly (Read tool) before presenting to Marc, run the fix-review-rerun loop until clean, then commit with a message naming that specific game. One commit per plugin, not batched.
- `Config/CustomMaps.json` is gitignored and already has all five plugin keys (`Insurgency2014`, `TeamFortress2`, `CounterStrikeSource`, `L4D`, `L4D2` - the `L4D2` key is present and empty, ready to use).
- After L4D2 is done: final report needed - total Pester test count, confirmation all five Phase 1 plugins share the same shape, and confirmation of the Insurgency2014 Maps.psm1 retrofit.
