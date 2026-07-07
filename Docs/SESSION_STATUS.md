# GSM Phase 1 - Session Status

Last updated: 2026-07-07

## Where things stand: Phase 1 is fully complete

All 13 PRD deliverables are shipped, tested, committed, and pushed. Nothing
is left pending from Phase 1's scope.

Every one of the five plugins (Insurgency2014, TeamFortress2,
CounterStrikeSource, L4D, L4D2) now implements all six lifecycle actions
consistently:

| Action | Implemented via |
|---|---|
| Install | Plugin's own `Install.psm1`, calling `Core/SteamCMD.psm1` |
| Start / Stop / Restart / Status | Thin wrappers in each plugin's `Server.psm1`, delegating to `Core/ProcessManager.psm1` |
| Configure | Thin wrapper `New-<Game>Config` in each plugin's `Server.psm1`, delegating to `Core/ConfigEditor.psm1` |

Test count: **325/325 passing**, run via `Tests/Run-AllTests.ps1` (not a bare
`Invoke-Pester -Path .\Tests\` - see below). PSScriptAnalyzer is clean
project-wide except the two pre-accepted categories:
`PSUseShouldProcessForStateChangingFunctions` and `PSUseSingularNouns`.

## What got built this session (in order)

1. **L4D2 plugin** (last of the five Phase 1 games) - Install/Server/Maps/
   Modes/Config.template.json + four test files. Two judgment calls resolved
   with Marc: exclude "The Last Stand" (community campaign, not Valve
   in-house) from the map list, and exclude Realism Versus/Versus Survival
   from the validated Mode enum (they're numbered Mutation slots
   internally, not stable `mp_gamemode` values).
2. **Documentation close-out #1** - CHANGELOG.md/PRD.md updated to mark
   v0.1.0 as "Phase 1 complete" (at the time, that meant framework + five
   plugins only - items 11/12 below didn't exist yet).
3. **PRD items 11 & 12** (the actual big lift this session):
   - `Core/ServiceAccount.psm1`: added `SeBatchLogonRight` (alongside the
     existing `SeServiceLogonRight`), a `Servers` folder ACL entry, and
     `Get-GSMServiceAccountCredential`.
   - `Core/ProcessManager.psm1` (new): `Start-GSMServer`, `Stop-GSMServer`,
     `Restart-GSMServer`, `Get-GSMServerStatus`. Launches servers via a
     per-plugin **Scheduled Task** (not a native Windows Service) running as
     the ServiceAccount - dedicated-server executables like `srcds.exe`
     don't implement the Service Control Manager protocol, so registering
     them as a real Windows Service would get them killed by Windows after
     ~30 seconds. Native-service wrapping (via an NSSM-style tool) is still
     Phase 2's `Core/Service.psm1`.
   - `Core/ConfigEditor.psm1` (new): `New-GSMServerConfig`, a generic
     interactive config editor taking Maps/Modes/validation function names
     as parameters. Auto-backs up the existing config before overwriting.
   - Five per-plugin `Server.psm1` files each got
     `Start-<Game>Server`/`Stop-<Game>Server`/`Restart-<Game>Server`/
     `Get-<Game>ServerStatus`/`New-<Game>Config` thin wrappers (built via
     five parallel subagents, then independently re-verified file-by-file).
   - `Menu.psm1`/`GSM.ps1` gained the `Restart` action.
4. **Documentation close-out #2** - CHANGELOG.md/PRD.md updated again to
   reflect that items 11/12 are genuinely done now, and to remove an
   inaccurate "known gap" note about ServiceAccount's `secedit`/`Set-Acl`
   calls being untested (they always had solid mocked coverage; the
   original note was simply wrong).
5. **`Tests/Run-AllTests.ps1`** (new, permanent fix) - runs every
   `Tests/*.Tests.ps1` file in its own fresh `pwsh -NoProfile` child
   process and aggregates pass/fail. This exists because a bare
   `Invoke-Pester -Path .\Tests\` run shares one process across every test
   file, and several plugins share bare module names (`Install`, `Server`,
   `Maps`, `Modes`) - leftover global module state from one file's fixtures
   was observed causing `Tests/Menu.Tests.ps1`'s dispatch tests to fail
   only when run as part of the full suite, never in isolation. **Use this
   script for the full suite from now on, not a bare `Invoke-Pester -Path
   .\Tests\`.**

## Key naming convention (re-confirm if it comes up again)

Everything is keyed by the plugin's **folder name**, never `Plugin.json`'s
`GameName` field: `L4D` and `L4D2` both have `GameName: "Left4Dead"`, so
`Config/<FolderName>.json`, `Config/ServerStatus/<FolderName>.json`,
`Backups/<FolderName>-<timestamp>.json`, and Scheduled Task name
`GSM-<FolderName>` all use the folder name specifically to avoid the two
plugins silently colliding.

## Workflow reminders for continuing this

- Marc runs Pester/PSScriptAnalyzer/git himself on his Windows machine
  (`D:\Projects\GSM\GameServerManager`) and pastes output back - this
  sandbox has no PowerShell installed, and the bash-mounted copy of the repo
  can lag behind real edits (confirmed stale at least twice this session) -
  always verify file contents via the Read/Grep/Edit tools, not bash.
- Run tests file-by-file in a fresh `pwsh -NoProfile` process (or via
  `Tests/Run-AllTests.ps1` for the whole suite) - do not chain many
  `Invoke-Pester` calls in one long-lived console session or run the whole
  `Tests\` directory in one process; both cause cross-file state pollution
  that produces phantom failures unrelated to the actual code.
- Two PSScriptAnalyzer categories are pre-accepted project-wide and don't
  need fixing: `PSUseShouldProcessForStateChangingFunctions`,
  `PSUseSingularNouns`. Everything else must be genuinely fixed.

## Next task (do this first, before Phase 2): fix Menu.psm1's GameName dispatch bug

Found while walking Marc through how to use the tool - not caught by any
test because no test exercises the interactive menu with two plugins
sharing a `GameName`.

**The bug:** `Core/Menu.psm1`'s `Invoke-GSMAction` looks up the target
plugin by `Plugin.json`'s `GameName` field:
```powershell
$plugin = $plugins | Where-Object { $_.GameName -eq $GameName } | Select-Object -First 1
```
L4D and L4D2 both have `GameName: "Left4Dead"` (only `Version` differs).
`Select-Object -First 1` silently picks whichever one `Find-GSMPlugins`
happens to return first (alphabetical folder scan order - L4D). Worse,
`Show-MainMenu`'s game-selection prompt builds its choice list via
`$plugins.GameName | Select-Object -Unique`, so "Left4Dead" appears in the
menu exactly once - **L4D2 is currently unreachable through the interactive
menu or `GSM.ps1 -GameName ... -Action ...` at all.**

This is the exact same GameName-vs-FolderName collision that was already
fixed for config/status/backup file naming and Scheduled Task names earlier
this session - it just wasn't caught in the dispatch/lookup path itself.

**The fix:** `Invoke-GSMAction` and `GSM.ps1`/`Show-MainMenu` need to key
off `FolderName`, not `GameName`. Likely shape:
- Change `Invoke-GSMAction`'s parameter (or add one) to take `-FolderName`
  instead of/alongside `-GameName`, and look up the plugin via
  `Where-Object { $_.FolderName -eq $FolderName }`.
- `Show-MainMenu`'s game list needs to display something that disambiguates
  L4D from L4D2 (e.g. show `FolderName` instead of `GameName`, or show both:
  `"$($plugin.GameName) ($($plugin.FolderName))"`).
- `GSM.ps1`'s `-GameName` parameter likely needs to become `-FolderName` (or
  gain a `-FolderName` alternative) for the non-interactive path too - this
  is a breaking change to the CLI contract, worth flagging to Marc explicitly
  rather than silently deciding.
- Update `Tests/Menu.Tests.ps1` and `Tests/PluginLoader.Tests.ps1` (if it
  touches this) accordingly, and add a regression test with two fake plugins
  sharing a `GameName` but different `FolderName`s, asserting both are
  independently reachable - this is exactly the gap that let the bug ship.

Workaround in the meantime (already given to Marc): bypass the menu and
call the plugin's own FolderName-keyed functions directly, e.g.
`Import-Module .\Plugins\L4D2\Install.psm1, .\Plugins\L4D2\Server.psm1
-Force` then `Install-L4D2Server`, `New-L4D2Config`, `Start-L4D2Server`,
`Get-L4D2ServerStatus`. Insurgency2014, TeamFortress2, and
CounterStrikeSource are unaffected since each has a unique `GameName`.

## Next: Phase 2 - Server Management

Not started. Per the PRD (`Docs/PRD.md` section 9), Phase 2 (~2,000 lines)
adds:
- `Core/Service.psm1`: wraps servers as genuine Windows Services via a
  service-wrapper tool (e.g. NSSM), replacing today's Scheduled-Task-based
  `Core/ProcessManager.psm1` approach.
- Update and crash recovery.

No scope, design, or file-list decisions have been made for Phase 2 yet -
that's the first thing to work out whenever this picks back up.
