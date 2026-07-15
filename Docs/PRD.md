# GameServer Manager (GSM) - Product Requirements Document

**Version:** 0.4.0-alpha (Phase 4)
**Platform:** Windows 11, PowerShell 7+
**License:** MIT
**Author:** Marc Larouche

## 1. Problem

Managing a dedicated Insurgency (2014) server today means hand-running SteamCMD,
editing config files by hand, and manually tracking updates, backups, and firewall
rules. There's no single tool that does this on Windows without a heavyweight panel
or a paid product.

## 2. Recommendation

Build GSM as a modular PowerShell framework with a plugin system. Phase 1 proves
the plugin architecture out across four Source-engine games at once (Insurgency
2014, Team Fortress 2, Counter-Strike: Source, Left 4 Dead, Left 4 Dead 2), so the
`Plugin.json` contract and `PluginLoader` get validated against real differences
(Workshop support, RCON, port defaults) instead of a single happy path. Adding a
sixth game later is still just a new folder, no core changes.

## 3. Goals

- Install, update, start, stop, and monitor dedicated servers for Insurgency
  (2014), Team Fortress 2, Counter-Strike: Source, Left 4 Dead, and Left 4 Dead 2,
  entirely through GSM, with no manual SteamCMD or config editing.
- Plugin system where a new game is added by dropping a folder into `Plugins/`,
  no core code changes.
- Servers run under a dedicated least-privilege local account, not the
  interactive admin account.
- Fully offline: no telemetry, no cloud auth, no accounts.
- PSScriptAnalyzer-clean, comment-based help on every function, Pester tests on
  every module.

## 4. Non-goals (Phase 1)

- Web dashboard (Phase 4)
- RCON console (Phase 4)
- Workshop support (Phase 5)
- Any game plugin beyond the five listed in section 3
- Running servers as a genuine Windows Service (that's `Core/Service.psm1`,
  Phase 2, via a service-wrapper tool); Phase 1 wires the ServiceAccount into
  Scheduled Task-based start/stop instead (`Core/ProcessManager.psm1`), since
  dedicated-server executables don't implement the Service Control Manager
  protocol
- Multi-server orchestration (each instance manages its own servers)

## 5. Users

Primarily Marc, running Insurgency and Source-engine servers for personal/community
use. Secondary: anyone self-hosting Source-engine dedicated servers on Windows who
wants a scriptable, auditable alternative to commercial panels.

## 6. Architecture

```
GameServerManager/
├── GSM.ps1                  # Entry point, loads Core + Plugins, shows menu
├── README.md
├── CHANGELOG.md
├── LICENSE
├── VERSION
├── CLAUDE.md                # Coding standards for Claude Code sessions
│
├── Core/
│   ├── Menu.psm1            # Phase 1 - navigation, game selection
│   ├── Config.psm1          # Phase 1 - JSON config read/write/validate
│   ├── Logging.psm1         # Phase 1 - daily rotation, chained-hash log integrity
│   ├── SteamCMD.psm1        # Phase 1 - install/update SteamCMD, app installs
│   ├── PluginLoader.psm1    # Phase 1 - discover/validate Plugin.json, load modules
│   ├── Utilities.psm1       # Phase 1 - shared helpers (paths, hashing, prompts)
│   ├── ServiceAccount.psm1  # Phase 1 - least-privilege local account provisioning
│   ├── ProcessManager.psm1  # Phase 1 - Scheduled Task-based start/stop/restart/status
│   ├── ConfigEditor.psm1    # Phase 1 - generic interactive config editor
│   ├── NSSM.psm1            # Phase 2 - NSSM binary bundling (download/hash-verify/extract)
│   ├── Service.psm1         # Phase 2 - NSSM-backed Windows Service start/stop/restart/status,
│   │                        #   drop-in replacement for ProcessManager.psm1, with crash recovery
│   ├── Update.psm1          # Phase 2 - stop/SteamCMD update/verify/restart lifecycle
│   ├── Scheduler.psm1       # Phase 3 - scheduled restarts/updates
│   ├── Backup.psm1          # Phase 3 - backup/restore
│   ├── Firewall.psm1        # Phase 3 - Windows Firewall rule management
│   ├── Reports.psm1         # Phase 3 - ServerHealth.html generation
│   ├── RCON.psm1            # Phase 4 - Source RCON console
│   └── Dashboard.psm1       # Phase 4 - local web dashboard
│
├── Plugins/
│   ├── Insurgency2014/
│   │   ├── Plugin.json      # AppID 237410, port 27015, Workshop + RCON
│   │   ├── Install.psm1     # Phase 1 - SteamCMD install call for this game
│   │   ├── Server.psm1      # Phase 1/2 - launch params, thin Start/Stop/Restart/
│   │   │                    #   Status/Configure wrappers around
│   │   │                    #   Core/Service.psm1 and Core/ConfigEditor.psm1
│   │   ├── Maps.psm1        # Phase 1 - map list, validation
│   │   └── Modes.psm1       # Phase 1 - game mode list, validation
│   ├── TeamFortress2/       # AppID 232250, port 27015, Workshop + RCON
│   ├── CounterStrikeSource/ # AppID 232330, port 27015, RCON (no Workshop)
│   ├── L4D/                 # AppID 222840, port 27015, RCON (no Workshop)
│   └── L4D2/                # AppID 222860, port 27015, Workshop + RCON
│   (TeamFortress2, CounterStrikeSource, L4D, L4D2 each mirror the same five
│   files as Insurgency2014: Plugin.json, Install.psm1, Server.psm1, Maps.psm1,
│   Modes.psm1)
│
├── Config/       # Generated per-server JSON configs (gitignored)
├── Logs/         # Daily rotated logs (gitignored)
├── Reports/      # Generated ServerHealth.html (gitignored)
├── Backups/      # Config/save backups (gitignored)
├── SteamCMD/     # SteamCMD binary + app installs (gitignored)
├── Docs/         # PRD.md, architecture notes
├── Tests/        # Pester tests, one per Core/Plugin module
└── Assets/       # Icons, templates
```

## 7. Plugin contract

Every plugin folder must contain a `Plugin.json` matching this schema. The
`PluginLoader` module rejects anything that doesn't validate.

```json
{
  "GameName": "Insurgency",
  "Version": "2014",
  "AppID": "237410",
  "Engine": "Source",
  "Executable": "srcds.exe",
  "DefaultPort": 27015,
  "SupportsWorkshop": true,
  "SupportsRCON": true
}
```

Every plugin supplies, at minimum: maps, modes, startup parameters, one config
template, update logic (delegates to `Core/SteamCMD.psm1`), and validation rules.

The five Phase 1 plugins, with their confirmed dedicated server AppIDs:

| Plugin folder | Game | AppID | Workshop | RCON |
|---|---|---|---|---|
| `Insurgency2014` | Insurgency (2014) | 237410 | Yes | Yes |
| `TeamFortress2` | Team Fortress 2 | 232250 | Yes | Yes |
| `CounterStrikeSource` | Counter-Strike: Source | 232330 | No | Yes |
| `L4D` | Left 4 Dead | 222840 | No | Yes |
| `L4D2` | Left 4 Dead 2 | 222860 | Yes | Yes |

## 8. Deliverables (build order)

### Phase 1 (complete)

1. Repository structure (this scaffold)
2. `Core/Config.psm1` - JSON config engine
3. `Core/Logging.psm1` - daily rotation, chained-hash integrity
4. `Core/Menu.psm1` - main menu and navigation
5. `Core/SteamCMD.psm1` - download/update SteamCMD
6. `Core/PluginLoader.psm1` - discovery + `Plugin.json` validation
7. `Core/ServiceAccount.psm1` - least-privilege local account provisioning
8. `Plugins/Insurgency2014/` - full plugin implementation
9. `Plugins/TeamFortress2/`, `Plugins/CounterStrikeSource/`, `Plugins/L4D/`,
   `Plugins/L4D2/` - full plugin implementation, same shape as Insurgency2014
10. Dedicated server installation via SteamCMD, for all five games
11. Start / stop / restart / status (basic, pre-Service.psm1), running under the
    ServiceAccount identity
12. Interactive config editor
13. Pester tests for every module above

**Exit criteria:** GSM installs, configures, starts, stops, and reports status on
real dedicated servers for all five Phase 1 games, running under a dedicated
least-privilege account, with no manual file editing.

### Phase 2 (complete)

1. `Core/NSSM.psm1` - NSSM binary bundling (download, hash-verify, extract),
   mirroring `Core/SteamCMD.psm1`'s install pattern
2. `ServiceAccount.psm1` doc update - `SeServiceLogonRight` documented as
   used by `Core/Service.psm1`'s NSSM-backed service registration (the
   account already held both `SeServiceLogonRight` and `SeBatchLogonRight`
   since Phase 1; no functional change)
3. `Core/Service.psm1` - NSSM-backed `Start-GSMServer`, `Stop-GSMServer`,
   `Restart-GSMServer`, `Get-GSMServerStatus`, `Install-GSMServerService`,
   `Uninstall-GSMServerService`, and `Set-GSMServiceCrashRecovery`; a
   drop-in replacement for `Core/ProcessManager.psm1` (same exported
   function names/parameters)
4. All five plugins' `Server.psm1` wrappers repointed from
   `Core/ProcessManager.psm1` to `Core/Service.psm1`
5. `Core/Update.psm1` - `Update-GSMServer`, a stop/SteamCMD
   update/verify/restart lifecycle, thin orchestration over `Service.psm1`
   and `SteamCMD.psm1`
6. This documentation update (CHANGELOG.md, PRD.md)

**Exit criteria:** Every plugin's server runs as a genuine NSSM-managed
Windows Service with automatic crash recovery.
`Config/<FolderName>.json`'s optional `ProcessManager` field selects NSSM
(default) or the original Scheduled Task backend per server, so Phase 1's
approach is superseded as the default, not removed. `Update-GSMServer`
provides a single update lifecycle that never restarts a server into a
possibly broken install. 391/391 tests passing, PSScriptAnalyzer clean
except the two pre-accepted categories (section 13).

### Phase 3 (complete)

1. `Core/Firewall.psm1` - `Add-GSMFirewallRule`, `Remove-GSMFirewallRule`,
   `Get-GSMFirewallRuleStatus`, on the built-in NetSecurity module
2. `Config/<FolderName>.json` gained optional `RestartTime` and
   `UpdateCheckTime` fields (default `'04:00'`/`'04:15'`)
3. `Core/Scheduler.psm1` - `Register-GSMScheduledMaintenance`,
   `Unregister-GSMScheduledMaintenance`, `Get-GSMScheduledMaintenanceStatus`;
   nightly restart via `Service.psm1`, nightly update check via
   `Update.psm1`, reusing `ProcessManager.psm1`'s Scheduled Task pattern
4. `Config/<FolderName>.json` gained an optional `BackupRetentionCount`
   field (default 5)
5. `Core/Backup.psm1` - `New-GSMBackup`, `Restore-GSMBackup`,
   `Get-GSMBackupList`, on the built-in Compress-Archive/Expand-Archive
   cmdlets; config/state only, fail-closed restore with a pre-restore
   safety backup
6. `Core/Reports.psm1` - `New-GSMServerHealthReport`, a single
   PowerShell-generated `Reports/ServerHealth-<timestamp>.html`,
   cross-referencing `Firewall.psm1` and `Backup.psm1`
7. This documentation update (CHANGELOG.md, PRD.md)

**Exit criteria:** Every server instance can have its game port firewalled,
nightly restart/update-check maintenance scheduled, its config/state
backed up and restored with a validation gate, and a single health report
generated covering plugins, ports, firewall rules, backups, and host
system status. All four modules are Core-level and instance-generic - no
plugin-specific code changed (PRD section 13 decisions log).

### Phase 4 (complete)

1. `Core/RCON.psm1` - `Send-GSMRCONCommand` (stateless one-shot: connect,
   auth, send one command, read one response, close) and
   `Start-GSMRCONConsole` (a thin interactive REPL on the same connect/auth
   logic). Implements Valve's Source RCON Protocol as one generic module -
   all five plugins are Source engine and share it. Wired into
   `Menu.psm1` as a new "RCON Console" action.
2. `Core/Dashboard.psm1` - `Start-GSMDashboard`, a local web dashboard over
   `System.Net.HttpListener` bound to `127.0.0.1` only. Serves a static
   HTML/vanilla-JS page, a polled JSON status endpoint (reusing
   `Reports.psm1`'s `Get-GSMServerHealthReportData`), and Start/Stop/
   Restart + RCON command dispatch through the existing `Invoke-GSMAction`
   and `Send-GSMRCONCommand`. Wired into `Menu.psm1` as a new "Dashboard"
   top-level choice.
3. `Core/Reports.psm1`'s `Get-GSMServerHealthReportData` exported
   (previously internal-only) for `Dashboard.psm1` to reuse
4. This documentation update (CHANGELOG.md, PRD.md)

**Exit criteria:** Every server instance's RCON console is reachable both
from the interactive menu and from a local web dashboard that also
exposes live status and Start/Stop/Restart, with no plugin-specific code
needed for either (PRD section 13 decisions log).

## 9. Later phases (reference only, not built yet)

| Phase | Focus | Est. lines | Adds |
|---|---|---|---|
| 5 | Workshop Support | TBD | Steam Workshop item install/update for Workshop-capable plugins |

## 10. Security requirements (all phases)

- SHA-256 integrity checks on all downloaded files
- Chained-hash log integrity (tamper-evident)
- Config validation: reject invalid ports, duplicate settings, malformed JSON,
  unsafe launch options
- Least privilege: dedicated service account where practical, not full admin
- Auto-backup before any update or config change
- Zero telemetry, zero cloud auth, zero analytics

## 11. Coding standards

- PSScriptAnalyzer compliant, strict mode enabled
- Comment-based help (`.DESCRIPTION`, `.PARAMETER`, `.EXAMPLE`, `.NOTES`) on every
  exported function
- Verb-Noun naming, Try/Catch on all I/O and external process calls
- No hard-coded paths, JSON-driven config
- Pester test per module

## 12. Versioning

| Version | Milestone |
|---|---|
| v0.1.0 | Phase 1 complete: full framework, all five game plugins, tests passing |
| v0.2.0 | Phase 2 complete: NSSM-backed `Service.psm1`, crash recovery, `Update.psm1` |
| v0.3.0 | Phase 3 complete: `Firewall.psm1`, `Scheduler.psm1`, `Backup.psm1`, `Reports.psm1` |
| v0.4.0 | Phase 4 complete: `Core/RCON.psm1`, `Core/Dashboard.psm1` |
| v0.5.0 | Phase 5 complete: Workshop support |
| v1.0.0 | Stable release |

## 13. Decisions log

- Phase 1 covers five games: Insurgency (2014), Team Fortress 2,
  Counter-Strike: Source, Left 4 Dead, and Left 4 Dead 2.
- Least-privilege service account provisioning moves into Phase 1
  (`Core/ServiceAccount.psm1`). Wiring that account into actual service
  start/stop still happens in `Core/Service.psm1`, Phase 2.
- v0.1.0 tag marks Phase 1 completion (full framework + five plugins), not
  just the initial scaffold. The §12 table description was written early
  and undersold what Phase 1 actually delivered; this entry documents the
  correction so later phase versioning isn't read against a stale baseline.
- PRD items 11 (start/stop/restart/status) and 12 (interactive config
  editor) are now implemented across all five plugins via
  `Core/ProcessManager.psm1` (Scheduled Task-based, since dedicated-server
  executables aren't Service Control Manager-aware) and
  `Core/ConfigEditor.psm1`. Section 8's exit criteria is now genuinely met,
  not just the framework/plugin-shape milestone the v0.1.0 tag originally
  covered.
- The CHANGELOG's earlier "known gap: ServiceAccount secedit/Set-Acl calls
  are not unit tested" note was inaccurate and has been removed:
  `Tests/ServiceAccount.Tests.ps1` has had mocked coverage of those calls
  since before that note was written.
- Phase 2 (`Core/NSSM.psm1`, `Core/Service.psm1`, `Core/Update.psm1`) is
  complete. `Service.psm1` is a drop-in replacement for
  `Core/ProcessManager.psm1` (same exported function names/parameters), not
  a rename - `Config/<FolderName>.json`'s optional `ProcessManager` field
  lets a server opt back into the original Scheduled Task backend, so
  Phase 1's approach isn't removed, only superseded as the default.
  `Update-GSMServer` deliberately leaves a server stopped, not restarted,
  when a SteamCMD update fails - restarting into a possibly broken install
  was judged worse than a clear, visible failure.
- Phase 3 (`Core/Firewall.psm1`, `Core/Scheduler.psm1`, `Core/Backup.psm1`,
  `Core/Reports.psm1`) is complete. GSM has no multi-instance-per-plugin
  concept (section 4's "Multi-server orchestration" non-goal) - every
  plugin folder is exactly one server instance - so the original
  `<PluginFolderName>-<InstanceName>-...` naming convention for firewall
  rules and backup files collapses to just `<FolderName>-...`;
  `Firewall.psm1`'s rule names add a `<Protocol>` suffix instead, since
  `New-NetFirewallRule`'s `-Name` must be unique per protocol. The stale
  "Windows Service" mention under Phase 3's scope was already removed from
  section 9 during the Phase 2 closeout, not this one - there was nothing
  left to drop here. `Scheduler.psm1` derives each plugin's
  `GetLaunchArgsFunctionName` from the `Get-<FolderName>LaunchArgs` naming
  convention already followed by all five plugins, rather than adding a
  new stored field - confirmed against all five before relying on it.
  `Backup.psm1` snapshots and restores only each instance's own key in the
  shared `Config/CustomMaps.json`, never the whole file, so restoring one
  instance can't roll back another's custom maps. Pester tests were
  written for all four modules and the new `Config.psm1` schema fields but
  not executed as part of this work: the sandbox this was built in has no
  PowerShell installed. Test counts and any PSScriptAnalyzer findings are
  pending Marc's local run.
- Phase 4 drops Discord notifications from scope - Marc doesn't plan to use
  it. Phase 4 is now: web dashboard, RCON console. RCON ships first (`Core/RCON.psm1`), then the web dashboard
  (`Core/Dashboard.psm1`), which depends on RCON for its command box. RCON
  scope: one generic module (all five plugins are Source engine, same
  protocol), `Send-GSMRCONCommand` as a stateless one-shot primitive
  (connect/auth/send/read/close, using the existing per-instance
  `RCONPassword` config field and `DefaultPort`), `Start-GSMRCONConsole` as
  a thin REPL built on top of it, wired into `Menu.psm1` as a new action.
  Commands sent are written to the chained-hash audit log via
  `Core/Logging.psm1` - command text and target instance, never the
  password. Dashboard scope: `System.Net.HttpListener` (no external
  dependency, consistent with the project's PowerShell-7-only dependency
  rule), bound to `127.0.0.1` only (no auth layer needed at that trust
  boundary), reusing `Reports.psm1`'s existing data-gathering functions for
  a polled JSON status endpoint, interactive from v1 - start/stop/restart
  dispatched through the existing `Invoke-GSMAction` and an RCON command
  box dispatched through `Send-GSMRCONCommand`, both inheriting the same
  logging their console equivalents get. Launched as a blocking loop from a
  new Menu.psm1 action (Ctrl+C to stop), not a background service, for v1.
- Phase 4 narrowed further: the plugin marketplace is cut entirely, not
  deferred - it doesn't fit an offline-first, zero-telemetry tool (section
  10's security requirements rule out any external index/download source
  a marketplace would need). Workshop support is deferred to a new Phase 5
  (section 9) rather than dropped - Workshop is per-plugin functionality
  (`SupportsWorkshop` already exists in the `Plugin.json` contract and
  three of five Phase 1 plugins set it true), unrelated in scope to RCON or
  the dashboard, and not yet designed. Phase 4 is now exactly two
  deliverables: RCON console, then the web dashboard.
- Phase 4 (`Core/RCON.psm1`, `Core/Dashboard.psm1`) is complete. 484/484
  tests passing, PSScriptAnalyzer clean except the two pre-accepted
  categories; one genuine finding (`PSAvoidUsingEmptyCatchBlock` in
  `Dashboard.psm1`'s best-effort "send a 500 back to the client" catch)
  was fixed by logging a warning instead of swallowing the exception.
  `RCON.psm1` has no existing TCP-mocking precedent in this codebase, so
  it introduces one: `New-GSMRCONConnection` is the module's sole seam,
  swapped out in tests for an in-memory stream pair rather than a real
  socket - the same shape of seam `Dashboard.psm1` then reuses for its own
  `Invoke-GSMDashboardRequest` (an already-parsed Method/Path/Body in,
  StatusCode/ContentType/Body out), so neither module's real network I/O
  (a TCP connection, an `HttpListener` loop) is unit tested directly.
  `Show-MainMenu`'s game/action prompt structure changed to accommodate
  Dashboard: it sits as a top-level choice alongside "Exit", not inside
  the per-game action list RCON Console was added to, since the dashboard
  spans every instance rather than acting on one selected game.
  `Dashboard.psm1` imports `Menu.psm1` (for `Invoke-GSMAction`) and
  `RCON.psm1` (for `Send-GSMRCONCommand`) directly rather than assuming
  either is already loaded globally, matching this codebase's established
  convention of always importing what a module calls rather than relying
  on ambient session state - which in turn means `Menu.psm1` cannot import
  `Dashboard.psm1` at its own top level without creating a circular
  `Import-Module -Force` loop, so that one import is done lazily inside
  the "Dashboard" menu branch instead.
- Phase 6 (packaging + deployment hardening) is complete; v1.0.0 tagged as
  the stable release per this section's own milestone table. Two
  deliverables: `Build-GSMPackage.ps1` (a distributable release zip) and
  `Docs/CleanInstallVerification.md` (the first-ever real, non-mocked
  Start/Stop/Restart verification, deferred since Phase 2 - every prior
  test of that path was against mocked NSSM/SteamCMD/secedit calls).
  Running that checklist against a genuinely clean machine surfaced four
  real, previously-shipped bugs no mocked test could have caught, all
  fixed as part of this phase: a live interactive-session crash from
  repeated `Import-Module -Force` on shared `Utilities.psm1`/`Logging.psm1`
  corrupting other modules' already-compiled references to them; SteamCMD
  and the service account both having full provisioning functions
  (`Install-SteamCMD`, `New-GSMServiceAccount`/`Set-GSMServiceAccountRights`)
  that existed but were never actually called anywhere in the product, so
  every fresh-machine first Install/Start failed; SteamCMD's
  `+force_install_dir`/`+login` argument order being backwards (SteamCMD
  requires the former first); and NSSM's `ObjectName` rejecting a bare
  local account name, requiring a `.\` qualifier. See `CHANGELOG.md`'s
  `[1.0.0]` entry for the full list with fix details.
