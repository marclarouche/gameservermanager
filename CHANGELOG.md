# Changelog

## [Unreleased] - 2026-07-08

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
