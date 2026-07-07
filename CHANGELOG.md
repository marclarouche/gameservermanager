# Changelog

## [0.1.0-alpha] - 2026-07-07

### Status
Phase 1 complete. All 13 deliverables shipped: eight Core modules (Config,
Logging, Utilities, PluginLoader, Menu, SteamCMD, ServiceAccount) and five
game plugins (Insurgency2014, TeamFortress2, CounterStrikeSource, L4D, L4D2).
262/262 tests passing, PSScriptAnalyzer clean except pre-accepted
`PSUseShouldProcessForStateChangingFunctions` and `PSUseSingularNouns`
warnings (see PRD decisions log).

Known gap: `Set-GSMServiceAccountRights`'s `secedit`/`Set-Acl` calls are
implemented but not unit tested (mocking `Get-Acl`/`Set-Acl`/`secedit` was
out of scope for that task). Needs a real test pass before Phase 2 work
touches ServiceAccount.

Next: Phase 2 - Server Management (Core/Service.psm1, update/crash recovery).

### Added
- Repository scaffold and folder layout
- PRD (`Docs/PRD.md`)
- Module stubs for Phase 1: Menu, Config, Logging, SteamCMD, PluginLoader,
  Utilities, ServiceAccount
- Plugin stubs for Phase 1 games (Plugin.json, Install, Server, Maps, Modes):
  Insurgency2014, TeamFortress2, CounterStrikeSource, L4D, L4D2
- Full plugin implementations for all five Phase 1 games (Install, Server, Maps, Modes, Config template) with shared `Config/CustomMaps.json` custom-map system
