# GSM Phase 3 - Session Status

Last updated: 2026-07-08

## Where things stand: Phase 3 is fully complete

All 4 Phase 3 deliverables are shipped, tested, and ready to commit/push.
Nothing is left pending from Phase 3's scope.

| Deliverable | Module |
|---|---|
| Windows Firewall rule management (idempotent add/remove/status) | `Core/Firewall.psm1` |
| Nightly restart + update-check Scheduled Task maintenance | `Core/Scheduler.psm1` |
| Config/state backup and restore, fail-closed with retention | `Core/Backup.psm1` |
| Static HTML server health report | `Core/Reports.psm1` |
| `RestartTime`/`UpdateCheckTime`/`BackupRetentionCount` schema fields | `Core/Config.psm1` |
| CHANGELOG.md / PRD.md Phase 3 close-out | `CHANGELOG.md`, `Docs/PRD.md` |

Test count: **457/457 passing**, run via `Tests/Run-AllTests.ps1`.
PSScriptAnalyzer is clean project-wide except the two pre-accepted
categories: `PSUseShouldProcessForStateChangingFunctions` and
`PSUseSingularNouns`.

## What got built this phase (in order)

1. **`Core/Firewall.psm1`** (new) - `Add-GSMFirewallRule`,
   `Remove-GSMFirewallRule`, `Get-GSMFirewallRuleStatus`, on the built-in
   NetSecurity module. Reads `Plugin.json`'s `DefaultPort` and an optional
   `Protocol` field (defaults to both TCP and UDP - none of the five
   plugins set it). Rule identity is `GSM-<FolderName>-<Port>-<Protocol>`:
   the task's original `<PluginFolderName>-<InstanceName>-<Port>` naming
   collapsed (GSM has no multi-instance-per-plugin concept) and gained a
   `<Protocol>` suffix (`New-NetFirewallRule` needs a unique name per
   protocol). `Get-GSMFirewallRuleStatus` parses protocol/port back out of
   the rule's own name rather than querying `Get-NetFirewallPortFilter`,
   which needs a genuine CimInstance and can't be unit-tested with fake
   rule objects.
2. **`Config/<FolderName>.json` gained `RestartTime`/`UpdateCheckTime`**
   (optional, `HH:mm`, default `'04:00'`/`'04:15'`) and later
   **`BackupRetentionCount`** (optional positive integer, default 5), both
   validated only when present in `Core/Config.psm1`'s `Test-GSMConfig`.
3. **`Core/Scheduler.psm1`** (new) - `Register-GSMScheduledMaintenance`,
   `Unregister-GSMScheduledMaintenance`, `Get-GSMScheduledMaintenanceStatus`.
   Reuses `Core/ProcessManager.psm1`'s Scheduled Task cmdlet/credential
   pattern (that module doesn't export it as a helper, so this mirrors the
   cmdlet sequence rather than importing one). Each trigger runs in a
   fresh `pwsh.exe` via a base64 `-EncodedCommand` (avoids nested-quoting
   hazards), importing the plugin and calling `Restart-GSMServer` or
   `Update-GSMServer`. `GetLaunchArgsFunctionName` is derived from the
   `Get-<FolderName>LaunchArgs` convention already followed by all five
   plugins - confirmed against all five before relying on it, not stored
   anywhere new.
4. **`Core/Backup.psm1`** (new) - `New-GSMBackup`, `Restore-GSMBackup`,
   `Get-GSMBackupList`, on `Compress-Archive`/`Expand-Archive`. Backs up
   `Config/<FolderName>.json`, any `.cfg` overrides under
   `Servers/<FolderName>` (none exist yet; scan is recursive and
   forward-compatible), and only this instance's own key from the shared
   `Config/CustomMaps.json` - never the whole shared file, since that
   would let restoring one instance clobber every other instance's custom
   maps. `Restore-GSMBackup` takes a safety backup first (skipped with a
   warning if there's no live config to protect yet), validates via
   `Get-GSMConfig` before applying anything, and fails closed on an
   invalid restored config.
5. **`Core/Reports.psm1`** (new) - `New-GSMServerHealthReport`, a single
   PowerShell-generated `Reports/ServerHealth-<timestamp>.html`. Covers
   installed plugins, SteamCMD status, per-instance config (RCON password
   redacted)/custom maps/firewall rules/backup status, and host
   Windows/CPU/memory/disk info. States plainly that update history isn't
   tracked as structured data anywhere in Phase 1-2 rather than fabricating
   one. Data-gathering and HTML rendering are separate internal functions.
6. **Wire-through check** - confirmed none of the above needed any
   plugin-specific code changes; all four modules are Core-level and
   instance-generic.
7. **Documentation close-out** - `CHANGELOG.md` gained a `[0.3.0-alpha]`
   entry, `Docs/PRD.md` section 8 gained a Phase 3 subsection, section 9's
   "later phases" table dropped the now-complete Phase 3 row, section 12
   marks v0.3.0 complete, and a new decisions-log entry documents the
   InstanceName-collapse and Protocol-suffix naming calls. `VERSION`
   bumped to `0.3.0-alpha`.

Two rounds of local test fixes after the first `Run-AllTests.ps1` pass (4
failures) and first `Invoke-ScriptAnalyzer` pass (3 findings):
- `@(Get-NetFirewallRule ...)` / `@(Get-ChildItem ... | Measure-Object -Sum).Sum`
  wrapping a `$null`/no-output result into a one-element array or throwing
  on property access - `Set-StrictMode -Version Latest` catches both.
  Fixed with `| Where-Object { $_ }` before wrapping, and a `.Count -gt 0`
  guard before calling `Measure-Object`.
- `PSUseOutputTypeCorrectly` on `Get-GSMBackupList`/
  `Get-GSMFirewallProtocolList` - returning a piped/wrapped `@(...)`
  result doesn't type-match a declared `[psobject[]]`/`[string[]]`
  `OutputType` as cleanly as building a typed `List<T>` and calling
  `.ToArray()` directly (the pattern `Find-GSMPlugins` already used).
- `PSAvoidUsingPlainTextForPassword` on `Scheduler.psm1`'s internal
  `-PlainPassword` parameter - the rule flags password-like *parameters*
  regardless of purpose. Removed the parameter; the plaintext is now
  extracted from `-Credential` inside the one function that needs it and
  dropped immediately after.

## Key naming convention (re-confirm if it comes up again)

Everything is keyed by the plugin's **folder name**, never `Plugin.json`'s
`GameName` field: `L4D` and `L4D2` both have `GameName: "Left4Dead"`, so
`Config/<FolderName>.json`, the NSSM service name `GSM-<FolderName>`
(`Core/Service.psm1`), Scheduled Task names `GSM-<FolderName>-*`
(`Core/ProcessManager.psm1`, `Core/Scheduler.psm1`), firewall rule names
`GSM-<FolderName>-*` (`Core/Firewall.psm1`), and backup file names
`<FolderName>-*.zip` (`Core/Backup.psm1`) all use the folder name
specifically to avoid the two plugins silently colliding. GSM has no
multi-instance-per-plugin concept - one plugin folder is always exactly
one server instance (confirmed with Marc during Phase 3; see PRD section
13's Phase 3 decisions-log entry).

## Workflow reminders for continuing this

- Marc runs Pester/PSScriptAnalyzer/git himself on his Windows machine
  (`D:\Projects\GSM\GameServerManager`) and pastes output back - this
  sandbox has no PowerShell installed. Always hand him ready-to-run git
  commands rather than attempting git operations from this sandbox (stale
  `.git/index.lock` issues on the Windows-mounted filesystem).
- Run tests file-by-file in a fresh `pwsh -NoProfile` process (or via
  `Tests/Run-AllTests.ps1` for the whole suite) - do not chain many
  `Invoke-Pester` calls in one long-lived console session or run the whole
  `Tests\` directory in one process; both cause cross-file state pollution
  that produces phantom failures unrelated to the actual code.
- Two PSScriptAnalyzer categories are pre-accepted project-wide and don't
  need fixing: `PSUseShouldProcessForStateChangingFunctions`,
  `PSUseSingularNouns`. Everything else must be genuinely fixed.
- When a test needs to see a command that lives inside another module's
  own private scope (e.g. a plugin's `Server.psm1` doing a nested
  `Import-Module Core/Service.psm1 -Force` internally, or any of Phase 3's
  new internal/non-exported functions), a bare `Get-Command`/`Get-Module`
  lookup from the test file's global scope won't find it - use Pester's
  `InModuleScope <ModuleName> { ... }` instead, which runs the check from
  inside that module's own session state.
- Under `Set-StrictMode -Version Latest`, wrapping a cmdlet's result in
  `@(...)` before checking `.Count` is not enough on its own when that
  cmdlet can return `$null` for "no results" (e.g. `Get-NetFirewallRule`,
  `Get-CimInstance`) - `@($null)` is a one-element array, not an empty
  one. Pipe through `Where-Object { $_ }` first.

## Next: Phase 4 - Professional Features

Not started. Per the PRD (`Docs/PRD.md` section 9), Phase 4 (~3,000+
lines) adds a web dashboard, RCON console, Discord notifications, Workshop
support, and a plugin marketplace.

No scope, design, or file-list decisions have been made for Phase 4 yet -
that's the first thing to work out whenever this picks back up.
