# Changelog

## [Unreleased]

## [1.0.0] - 2026-07-15

### Status
Phase 6 (packaging + deployment hardening) complete - stable release.
558/558 tests passing via `Tests/Run-AllTests.ps1`, PSScriptAnalyzer clean
except the two pre-accepted `PSUseShouldProcessForStateChangingFunctions`
and `PSUseSingularNouns` categories. `Docs/CleanInstallVerification.md`'s
full Start/Stop/Restart cycle passed against a real installed instance on
a genuinely clean machine (`E:\GSM-Test`) for the first time since Phase 2
- every prior verification of this code path was against mocked cmdlets.

### Added
- `Build-GSMPackage.ps1`: builds a distributable `Build/GameServerManager-v<version>.zip`
  from a clean copy of `GSM.ps1`, `Core/`, `Plugins/`, the SteamCMD/NSSM
  pinned-hash seed config, and empty runtime folders - excludes `Tests/`,
  `.git/`, `Docs/`, `.claude/`. Prints a manifest of everything included so
  a bad include/exclude list is obvious immediately.
- `Docs/CleanInstallVerification.md`: the manual checklist that ran the
  first real (non-mocked) Start/Stop/Restart verification, deferred since
  Phase 2.

### Fixed
- **Live crash in the interactive menu**: every `Core/*.psm1` module and
  plugin file did `Import-Module ...Utilities.psm1 -Force` /
  `...Logging.psm1 -Force` at its own top. Repeated `-Force` reimports of
  the same shared dependency module across a long-lived session silently
  invalidate other already-loaded modules' compiled references to it (e.g.
  `Core/PluginLoader.psm1`'s `Find-GSMPlugins` default parameter value) -
  confirmed at exactly 2 `Invoke-GSMAction` dispatches in one session,
  regardless of plugin or action, crashing the whole process with
  `Get-GSMRootPath: term not recognized` on the third. Fixed by dropping
  `-Force` from all 53 occurrences across 27 files; re-importing an
  already-loaded module without it safely reuses the existing instance.
- **SteamCMD never actually installed itself**: `Install-SteamCMD` was
  referenced only in docstrings, never called anywhere in the product, so
  every first Install on a clean machine failed with "SteamCMD is not
  installed." Each plugin's `Install-<Game>Server` now bootstraps SteamCMD
  first if absent, mirroring how `Install-GSMServerService` already
  bootstraps NSSM.
- **SteamCMD argument order**: `Update-SteamApp` built its command as
  `+login anonymous` before `+force_install_dir`; SteamCMD requires the
  reverse, failing otherwise with "Please use force_install_dir before
  logon!" (exit code 7). A mocked test had actually codified the wrong
  order - not catchable without launching the real `steamcmd.exe`.
- **Service account never actually provisioned**: `New-GSMServiceAccount`
  and `Set-GSMServiceAccountRights` were likewise never called anywhere in
  the product, so every first Start failed with "No stored credential
  found... Run New-GSMServiceAccount first." `Install-GSMServerService` now
  bootstraps the account and its rights first if not already fully set up.
- **NSSM `ObjectName` rejected a valid local account**: Windows'
  `ChangeServiceConfig` (what NSSM's `set ObjectName` calls internally)
  rejects a bare local account name with "The account name is invalid or
  does not exist, or the password is invalid," even though the account
  genuinely exists - it needs the `.\` local-machine qualifier. Qualified
  only at this call site, not on the shared credential object, since
  `Core/ProcessManager.psm1`'s Scheduled-Task backend consumes the same
  credential without this requirement.

## [0.5.0-alpha] - 2026-07-11

### Status
Phase 5 (Workshop Support) complete. 518/518 tests passing via
`Tests/Run-AllTests.ps1`, PSScriptAnalyzer clean except the two
pre-accepted `PSUseShouldProcessForStateChangingFunctions` and
`PSUseSingularNouns` categories.

Next: not yet scoped - see Known gaps below (nightly refresh integration,
the subscribe/unsubscribe asymmetry on a failed placement, and live
install verification) for candidate follow-up work.

### Added
- `Core/Workshop.psm1`: generic SteamCMD Workshop mechanics -
  `Add-GSMWorkshopItem`, `Remove-GSMWorkshopItem`, `Get-GSMWorkshopItems`,
  `Update-GSMWorkshopItems` - backed by the existing `WorkshopItems` array
  in `Config/<FolderName>.json` (previously populated by hand via
  `Core/ConfigEditor.psm1`; this is the first thing to populate it
  automatically). Gated on `Plugin.json`'s `SupportsWorkshop` field, the
  same fail-closed pattern used elsewhere for gated features.
- Workshop placement/removal logic added to each Workshop-capable plugin's
  `Install.psm1`: Insurgency2014 links downloaded content as a directory
  junction (avoids duplicating large map packages on disk), TeamFortress2
  and L4D2 copy it instead (VPK-based content, compatibility over disk
  savings).
- `Core/Menu.psm1`: "Manage Workshop Items" action, shown only when the
  selected plugin's `SupportsWorkshop` is true, with add/remove/list/
  refresh sub-actions dispatched through `Core/Workshop.psm1`'s own
  `Show-GSMWorkshopMenu`.
- CounterStrikeSource and L4D reject Workshop calls with a clear error via
  the existing `SupportsWorkshop: false` gate - no plugin-specific code
  needed for either.

### Fixed
- Two instances of the same `Set-StrictMode`-visible gotcha: `return
  $array` enumerates an array onto the output pipeline, so a
  zero-element array returns as `$null`, not an empty array - one in
  `Workshop.psm1`'s internal item-list reader (`Get-GSMWorkshopItemsArray`,
  now uses `Write-Output -NoEnumerate`), one in `Show-GSMWorkshopMenu`'s
  List branch, where a redundant `@(...)` wrap around an already-array
  result risked nesting a real multi-item list into a single element.

### Known gaps (carried forward)
- A failed placement after a successful SteamCMD download leaves files in
  SteamCMD's own workshop content folder without recording the
  subscription - a minor subscribe/unsubscribe asymmetry, not a data-loss
  risk.
- Nightly Workshop refresh via `Core/Scheduler.psm1` is not yet wired in -
  `Update-GSMWorkshopItems` is manual-only, invoked from the menu.
- Live Start/Stop/Restart verification against a real installed instance
  is still outstanding, pending an installable package to test against.

## [0.4.0-alpha] - 2026-07-11

### Status
Phase 4 (Professional Features) complete. Both deliverables shipped:
a Source RCON console (`Core/RCON.psm1`) and a local web dashboard
(`Core/Dashboard.psm1`). Discord notifications were dropped from Phase 4
scope entirely (Marc doesn't plan to use it), the plugin marketplace was
cut entirely (doesn't fit an offline-first, zero-telemetry tool), and
Workshop support was deferred to a new Phase 5 (see the PRD decisions
log). 484/484 tests passing via `Tests/Run-AllTests.ps1`, PSScriptAnalyzer
clean except the two pre-accepted `PSUseShouldProcessForStateChangingFunctions`
and `PSUseSingularNouns` categories. One genuine finding surfaced and was
fixed during this phase: `PSAvoidUsingEmptyCatchBlock` in `Dashboard.psm1`'s
best-effort "send a 500 back to the client" catch, which now logs a
warning instead of silently swallowing the exception.

Next: Phase 5 - Workshop Support (Steam Workshop item install/update for
Workshop-capable plugins).

### Added
- `Core/RCON.psm1`: `Send-GSMRCONCommand` (stateless one-shot: connect,
  auth, send one command, read one response, close) and
  `Start-GSMRCONConsole` (a thin interactive REPL built on the same
  connect/auth logic, kept in one place so the two never duplicate it).
  Implements Valve's Source RCON Protocol (TCP, binary packets) as one
  generic module - all five plugins are Source engine and share the same
  protocol, so there is no per-plugin RCON code. Resolves the target
  instance's port from `Plugin.json`'s `DefaultPort` and its RCON password
  from `Config/<FolderName>.json`'s `RCONPassword`; connects to `127.0.0.1`
  only. `New-GSMRCONConnection` is the module's sole seam for Pester
  mocking (an in-memory stream pair stands in for the real TCP socket).
  v1 reads a single response packet only - it does not reassemble a
  response split across multiple `SERVERDATA_RESPONSE_VALUE` packets, so
  very long command output (e.g. `status` on a full server) may be
  truncated; this is documented in the function's own `.NOTES`, not a
  silent gap. Connection-refused, authentication-failure, and timeout
  each produce a distinct, clear error message, and `RCONPassword` is
  never written to a log message or surfaced in an error string. Wired
  into `Core/Menu.psm1` as a new "RCON Console" action, dispatched
  directly rather than through `Invoke-GSMAction`'s
  `$script:GSMActionFunctionTemplates` table, since it's blocking/
  interactive with no simple success/failure result to report.
- `Core/Dashboard.psm1`: `Start-GSMDashboard`, a local web dashboard
  served over `System.Net.HttpListener` bound to `127.0.0.1` only - no
  external dependency, consistent with the project's PowerShell-7-only
  dependency rule, and no auth layer added since that trust boundary
  (loopback-only) needs none. Serves a single static HTML/vanilla-JS page
  at `/` (no external JS library, no server-side templating - all dynamic
  data is fetched client-side), a polled JSON status endpoint at
  `GET /api/status` (reusing `Core/Reports.psm1`'s own
  `Get-GSMServerHealthReportData` rather than duplicating instance/system
  discovery), and two POST endpoints: `/api/action`
  (`{ FolderName, Action }`, Start/Stop/Restart dispatched through
  `Core/Menu.psm1`'s `Invoke-GSMAction`) and `/api/rcon`
  (`{ FolderName, Command }`, dispatched through `Core/RCON.psm1`'s
  `Send-GSMRCONCommand`). Both dispatch endpoints reuse the console's own
  dispatch functions, so logging and behavior never diverge between the
  console and the dashboard. `Invoke-GSMDashboardRequest` routes an
  already-parsed Method/Path/Body to the right handler and is the
  module's sole seam for Pester - `Start-GSMDashboard`'s real
  `HttpListener` loop is not unit tested directly, the same way
  `RCON.psm1`'s real TCP connection isn't. Interactive from v1: run as a
  foreground blocking loop from a new "Dashboard" `Menu.psm1` action
  (Ctrl+C to stop), not a background service. Wired into `Menu.psm1` as a
  top-level choice alongside "Exit" (not inside the per-game action list),
  since the dashboard spans every instance rather than acting on one
  selected game; `Core/Dashboard.psm1` is imported lazily inside that menu
  branch rather than at `Menu.psm1`'s own top level, since
  `Dashboard.psm1` itself imports `Menu.psm1` (for `Invoke-GSMAction`) and
  an unconditional top-level import the other way would be a circular
  `Import-Module -Force` loop.
- `Core/Reports.psm1`'s `Get-GSMServerHealthReportData` is now exported
  (previously internal-only) so `Core/Dashboard.psm1` can reuse it - no
  logic changes, just an added export.

## [0.3.0-alpha] - 2026-07-08

### Status
Phase 3 (Administration) complete. All 4 deliverables shipped:
firewall rule management (`Core/Firewall.psm1`), scheduled nightly
restart/update-check maintenance (`Core/Scheduler.psm1`), config/state
backup and restore (`Core/Backup.psm1`), and a static HTML server health
report (`Core/Reports.psm1`). All four are Core-level and instance-generic,
driven entirely by existing `Plugin.json` metadata and instance config -
no plugin-specific code changed (see the wire-through check in the PRD
decisions log). 457/457 tests passing via `Tests/Run-AllTests.ps1`,
PSScriptAnalyzer clean except the two pre-accepted
`PSUseShouldProcessForStateChangingFunctions` and `PSUseSingularNouns`
categories (see PRD decisions log). Two rounds of fixes were needed after
the first local test run: a `@(...)`-wrapping-`$null` gotcha in
`Firewall.psm1`/`Reports.psm1` under `Set-StrictMode -Version Latest`
(`Get-NetFirewallRule`/`Measure-Object` returning `$null` on no matches
wraps to a one-element array containing `$null`, not an empty array), and
three genuine PSScriptAnalyzer findings (`PSUseOutputTypeCorrectly` in
`Backup.psm1`/`Firewall.psm1`, `PSAvoidUsingPlainTextForPassword` in
`Scheduler.psm1`).

Next: Phase 4 - Professional Features (web dashboard, RCON, Discord,
Workshop, plugin marketplace).

### Added
- `Core/Firewall.psm1`: `Add-GSMFirewallRule`, `Remove-GSMFirewallRule`,
  `Get-GSMFirewallRuleStatus`, built on the built-in NetSecurity module
  (`New-NetFirewallRule`/`Remove-NetFirewallRule`/`Get-NetFirewallRule`).
  Reads the instance's `Plugin.json` `DefaultPort` and an optional
  `Protocol` field (defaulting to both TCP and UDP - none of the five
  Phase 1 plugins set `Protocol`, so all five get both). Rule identity is
  `GSM-<FolderName>-<Port>-<Protocol>`: the task's original
  `GSM-<PluginFolderName>-<InstanceName>-<Port>` naming collapses the
  `InstanceName` segment (GSM has no multi-instance-per-plugin concept -
  every plugin folder is one instance) and adds a `<Protocol>` suffix,
  since `New-NetFirewallRule`'s `-Name` must be unique per protocol and one
  port opened for both TCP and UDP is two rule objects, not one. All three
  functions are idempotent.
- `Core/Scheduler.psm1`: `Register-GSMScheduledMaintenance`,
  `Unregister-GSMScheduledMaintenance`, `Get-GSMScheduledMaintenanceStatus`.
  Registers two Scheduled Tasks per instance - nightly restart (default
  04:00, calls `Core/Service.psm1`'s `Restart-GSMServer`) and nightly
  update check (default 04:15, calls `Core/Update.psm1`'s
  `Update-GSMServer`, staggered so it doesn't race the restart) - reusing
  `Core/ProcessManager.psm1`'s Scheduled Task cmdlet/credential pattern.
  Each trigger runs in a fresh `pwsh.exe` process via a base64
  `-EncodedCommand`, importing the target plugin through
  `Core/PluginLoader.psm1`. `GetLaunchArgsFunctionName` is derived from the
  `Get-<FolderName>LaunchArgs` naming convention already followed by all
  five plugins, not stored anywhere new.
- `Config/<FolderName>.json` gained optional `RestartTime` and
  `UpdateCheckTime` fields (24-hour `HH:mm`, defaulting to `'04:00'`/
  `'04:15'` when absent) and an optional `BackupRetentionCount` field
  (positive integer, defaulting to 5 when absent), all validated in
  `Core/Config.psm1`'s `Test-GSMConfig` only when present.
- `Core/Backup.psm1`: `New-GSMBackup`, `Restore-GSMBackup`,
  `Get-GSMBackupList`, built on the built-in `Compress-Archive`/
  `Expand-Archive` cmdlets. Backs up config/state only - `Config/<FolderName>.json`,
  any per-server `.cfg` overrides under `Servers/<FolderName>` (none exist
  yet, but the scan is recursive and forward-compatible), and this
  instance's own slice of the shared `Config/CustomMaps.json` - never the
  full game install. Output is `Backups/<FolderName>-<yyyyMMdd-HHmmss>.zip`,
  pruned to the instance's `BackupRetentionCount` (default 5) after each
  backup. `Restore-GSMBackup` takes a fresh safety backup of the live state
  first (skipped with a warning if there's no live config yet), validates
  the restored config via `Core/Config.psm1`'s `Get-GSMConfig` before
  applying anything, and fails closed - an invalid restored config applies
  nothing and leaves the safety backup in place. Restoring merges only this
  instance's own key back into the shared `CustomMaps.json`, never
  overwriting the whole file, so one instance's restore can't roll back
  another instance's custom maps.
- `Core/Reports.psm1`: `New-GSMServerHealthReport`, producing
  `Reports/ServerHealth-<yyyyMMdd-HHmmss>.html` as a single
  PowerShell-generated HTML string (no external templating library).
  Covers installed plugins, SteamCMD install/pinned-verification status,
  per-instance install/running status, config summary (`RCONPassword`
  redacted), custom maps, firewall rule status (cross-referencing
  `Core/Firewall.psm1`), backup status (cross-referencing
  `Core/Backup.psm1`), and host Windows version/CPU/memory/disk usage.
  States plainly that update history isn't tracked as structured data
  anywhere in Phase 1-2, rather than fabricating a history section.
  Data-gathering and HTML rendering are separate internal functions so
  Pester can test the gathered data without diffing rendered HTML.

## [0.2.0-alpha] - 2026-07-08

### Status
Phase 2 complete. All 6 deliverables shipped: NSSM binary bundling
(`Core/NSSM.psm1`), NSSM-backed service management with crash recovery
(`Core/Service.psm1`, a drop-in replacement for `Core/ProcessManager.psm1`),
all five plugins repointed to it, and a stop/update/verify/restart lifecycle
(`Core/Update.psm1`). 391/391 tests passing via `Tests/Run-AllTests.ps1`,
PSScriptAnalyzer clean except the two pre-accepted
`PSUseShouldProcessForStateChangingFunctions` and `PSUseSingularNouns`
categories (see PRD decisions log).

Next: Phase 3 - Administration (`Core/Firewall.psm1`, `Core/Scheduler.psm1`,
`Core/Backup.psm1`, `Core/Reports.psm1`).

### Added
- `Core/NSSM.psm1`: downloads, hash-verifies, and extracts the NSSM binary,
  mirroring `Core/SteamCMD.psm1`'s install pattern. Pinned installer URL and
  SHA-256 hash live in `Config/NSSM.json`.
- `Core/Service.psm1`: NSSM-backed `Start-GSMServer`, `Stop-GSMServer`,
  `Restart-GSMServer`, `Get-GSMServerStatus`, plus
  `Install-GSMServerService`/`Uninstall-GSMServerService` and
  `Set-GSMServiceCrashRecovery` (NSSM `AppExit=Restart`, 5s restart delay,
  10s throttle). Same exported function names and parameters as
  `Core/ProcessManager.psm1`, so it's a drop-in replacement. Registers each
  server as a genuine Windows Service running under GSM's service account.
- `Config/<FolderName>.json` gained an optional `ProcessManager` field
  (`'NSSM'`, the default, or `'ScheduledTask'`) - `Core/Service.psm1`'s
  dispatcher reads it and delegates to `Core/ProcessManager.psm1`'s original
  Scheduled Task logic when set to `'ScheduledTask'`, so existing configs
  keep working unmodified.
- All five plugins' `Server.psm1` wrappers (Insurgency2014, TeamFortress2,
  CounterStrikeSource, L4D, L4D2) repointed from `Core/ProcessManager.psm1`
  to `Core/Service.psm1` - no wrapper-level call-site changes needed.
- `Core/Update.psm1`: `Update-GSMServer`, a thin orchestration function
  composing `Stop-GSMServer`, `Update-SteamApp`, and `Start-GSMServer` into
  a single update lifecycle. Leaves the server stopped, with a clear error,
  rather than restarting into a possibly broken install if the SteamCMD
  update fails.

### Fixed
- `Core/Menu.psm1`'s `Invoke-GSMAction` dispatched by Plugin.json's `GameName`
  only, so plugins sharing a `GameName` (L4D and L4D2 both report
  `Left4Dead`) collided: `Select-Object -First 1` silently picked L4D,
  making L4D2 unreachable via the interactive menu or `GSM.ps1 -GameName`.
  `Invoke-GSMAction` now accepts an optional `-FolderName` (always
  unambiguous) alongside `-GameName`; a `-GameName` that matches more than
  one plugin now returns `$false` with a logged error instead of silently
  picking one. `Show-MainMenu`'s game list now displays and selects by
  `FolderName`. `GSM.ps1` gained a `-FolderName` parameter as a non-breaking
  alternative to `-GameName` for the non-interactive path.

## [0.1.0-alpha] - 2026-07-07

### Status
Phase 1 complete. All 13 deliverables shipped, including start/stop/restart/
status (`Core/ProcessManager.psm1`, Scheduled Task-based) and the interactive
config editor (`Core/ConfigEditor.psm1`) across all five game plugins: nine
Core modules (Config, Logging, Utilities, PluginLoader, Menu, SteamCMD,
ServiceAccount, ProcessManager, ConfigEditor) and five game plugins
(Insurgency2014, TeamFortress2, CounterStrikeSource, L4D, L4D2), each
implementing Install, Start, Stop, Restart, Status, and Configure. 325/325
tests passing via `Tests/Run-AllTests.ps1` (runs each file in its own
process - see that script's header for why a shared-process full-suite run
isn't reliable here), PSScriptAnalyzer clean except pre-accepted
`PSUseShouldProcessForStateChangingFunctions` and `PSUseSingularNouns`
warnings (see PRD decisions log).

Next: Phase 2 - Server Management (`Core/Service.psm1`: wraps servers as
genuine Windows Services via a service-wrapper tool, replacing today's
Scheduled Task approach; update/crash recovery).

### Added
- Repository scaffold and folder layout
- PRD (`Docs/PRD.md`)
- Module stubs for Phase 1: Menu, Config, Logging, SteamCMD, PluginLoader,
  Utilities, ServiceAccount
- Plugin stubs for Phase 1 games (Plugin.json, Install, Server, Maps, Modes):
  Insurgency2014, TeamFortress2, CounterStrikeSource, L4D, L4D2
- Full plugin implementations for all five Phase 1 games (Install, Server, Maps, Modes, Config template) with shared `Config/CustomMaps.json` custom-map system
- `Core/ProcessManager.psm1`: Scheduled Task-based Start/Stop/Restart/Status for any plugin's server, running under the ServiceAccount identity
- `Core/ConfigEditor.psm1`: generic interactive config editor (`New-GSMServerConfig`), with auto-backup before overwrite
- `ServiceAccount.psm1`: added `SeBatchLogonRight` (needed for Scheduled Task launches), a `Servers` folder ACL, and `Get-GSMServiceAccountCredential`
- `Start-<Game>Server`, `Stop-<Game>Server`, `Restart-<Game>Server`, `Get-<Game>ServerStatus`, and `New-<Game>Config` thin wrappers in all five plugins' `Server.psm1`
- `Restart` action wired into `Menu.psm1`/`GSM.ps1` dispatch
- `Tests/Run-AllTests.ps1`: runs the full test suite with per-file process isolation
