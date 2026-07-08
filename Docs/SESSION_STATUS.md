# GSM Phase 2 - Session Status

Last updated: 2026-07-08

## Where things stand: Phase 2 is fully complete

All 6 Phase 2 deliverables are shipped, tested, and ready to commit/push.
Nothing is left pending from Phase 2's scope.

| Deliverable | Module |
|---|---|
| NSSM binary bundling (download/hash-verify/extract) | `Core/NSSM.psm1` |
| ServiceAccount rights doc update (folded into Service.psm1 commit) | `Core/ServiceAccount.psm1` |
| NSSM-backed Start/Stop/Restart/Status + crash recovery, drop-in for `ProcessManager.psm1` | `Core/Service.psm1` |
| All five plugins repointed to `Core/Service.psm1` | `Plugins/*/Server.psm1` |
| Stop/SteamCMD update/verify/restart lifecycle | `Core/Update.psm1` |
| CHANGELOG.md / PRD.md Phase 2 close-out | `CHANGELOG.md`, `Docs/PRD.md` |

Test count: **391/391 passing**, run via `Tests/Run-AllTests.ps1`.
PSScriptAnalyzer is clean project-wide except the two pre-accepted
categories: `PSUseShouldProcessForStateChangingFunctions` and
`PSUseSingularNouns`.

## What got built this phase (in order)

1. **`Core/NSSM.psm1`** (new) - mirrors `Core/SteamCMD.psm1`'s
   download/hash-verify/extract pattern. NSSM's zip nests `win32`/`win64`
   builds under a version folder, so install extracts to a temp dir, locates
   `win64/nssm.exe` by path suffix, hash-verifies it, then copies only that
   file to `Tools/NSSM/nssm.exe`. Pinned URL/hash in `Config/NSSM.json`.
2. **`ServiceAccount.psm1` doc update** - the account already held both
   `SeServiceLogonRight` and `SeBatchLogonRight` since Phase 1; only the
   doc comments describing their purpose changed. Folded into the
   `Service.psm1` commit rather than shipped separately, per Marc's call.
3. **`Core/Service.psm1`** (new) - NSSM-backed `Start-GSMServer`,
   `Stop-GSMServer`, `Restart-GSMServer`, `Get-GSMServerStatus`,
   `Install-GSMServerService`, `Uninstall-GSMServerService`,
   `Set-GSMServiceCrashRecovery` (NSSM `AppExit=Restart`, 5s restart delay,
   10s throttle - well above NSSM's stock 1500ms since game servers take
   longer to bind ports/load maps). Same exported function
   names/parameters as `Core/ProcessManager.psm1`, so it's a drop-in
   replacement. `Config/<FolderName>.json` gained an optional
   `ProcessManager` field (`'NSSM'` default, or `'ScheduledTask'` to keep
   using the Phase 1 backend per server).
4. **Repointed all five plugins' `Server.psm1`** from
   `Core/ProcessManager.psm1` to `Core/Service.psm1` (built via five
   parallel subagents, then independently re-verified file-by-file).
   Bundled as one commit rather than five, since the diff was mechanically
   identical across all five plugins.
5. **`Core/Update.psm1`** (new) - `Update-GSMServer`, thin orchestration
   only (no process-management or SteamCMD logic of its own). Composes
   `Stop-GSMServer` -> `Update-SteamApp` -> `Start-GSMServer`. On update
   failure, the server is left stopped with a clear error rather than
   restarted into a possibly broken install.
6. **Documentation close-out** - `CHANGELOG.md` gained a `[0.2.0-alpha]`
   entry, `Docs/PRD.md` section 8 restructured into Phase 1/Phase 2
   subsections with Phase 2's build order and exit criteria, section 9's
   "later phases" table dropped the now-complete Phase 2 row (and the
   stale "Windows Service" mention under Phase 3, which Phase 2 already
   delivered), section 12's versioning table marks v0.2.0 complete, and a
   new decisions-log entry documents the drop-in-replacement design and the
   leave-stopped-on-failure choice. `VERSION` bumped to `0.2.0-alpha`.

## Key naming convention (re-confirm if it comes up again)

Everything is keyed by the plugin's **folder name**, never `Plugin.json`'s
`GameName` field: `L4D` and `L4D2` both have `GameName: "Left4Dead"`, so
`Config/<FolderName>.json`, the NSSM service name `GSM-<FolderName>`
(`Core/Service.psm1`), and the Scheduled Task name `GSM-<FolderName>`
(`Core/ProcessManager.psm1`) all use the folder name specifically to avoid
the two plugins silently colliding.

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
  `Import-Module Core/Service.psm1 -Force` internally), a bare
  `Get-Command`/`Get-Module` lookup from the test file's global scope won't
  find it - use Pester's `InModuleScope <ModuleName> { ... }` instead, which
  runs the check from inside that module's own session state.

## Next: Phase 3 - Administration

Not started. Per the PRD (`Docs/PRD.md` section 9), Phase 3 (~2,000 lines)
adds `Core/Firewall.psm1` (Windows Firewall rule management),
`Core/Scheduler.psm1` (scheduled restarts/updates), `Core/Backup.psm1`
(backup/restore), and `Core/Reports.psm1` (`ServerHealth.html` generation).

No scope, design, or file-list decisions have been made for Phase 3 yet -
that's the first thing to work out whenever this picks back up.
