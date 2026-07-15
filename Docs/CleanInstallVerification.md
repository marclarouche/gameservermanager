# Clean-Install Verification (Phase 6, Workstream B)

> **Status: outstanding since Phase 2.** Every Start/Stop/Restart test GSM has
> ever run has been against mocked cmdlets (`Core/Service.psm1`'s Pester
> suite) or a dev-machine checkout that already had `Config/`, a service
> account, scheduled tasks, and firewall rules left over from earlier manual
> testing. This checklist is the **first time** those three actions are
> exercised against a real, installed instance on a genuinely clean machine
> state. It is a manual checklist, not an automated test - there is no Pester
> equivalent for "does a real Windows Service actually bind a real port."
>
> **Phase 6 cannot close until this checklist has been run once, in full,
> with a Pass result recorded for every row of the results table below.**

## Prerequisites

### 0. Rebuild and redeploy the package after ANY code change

The package is a point-in-time snapshot. An extracted `GSM-Test` copy does
**not** pick up edits to the dev tree - fixes only reach it when the package
is rebuilt *and* re-extracted. Running the checklist against a stale
extraction tests old code and produces a meaningless result (this has
already burned one run: a SteamCMD-bootstrap fix looked like it "didn't
work" because the deployed zip predated it). So before every run, from the
dev checkout:

```powershell
cd D:\Projects\GSM\GameServerManager
./Build-GSMPackage.ps1                       # rebuild from the current tree
Remove-Item -Recurse -Force E:\GSM-Test      # wipe the previous extraction
New-Item -ItemType Directory -Path E:\GSM-Test | Out-Null
Expand-Archive -Path .\Build\GameServerManager-v<version>.zip -DestinationPath E:\GSM-Test
```

Prefer building from a committed tree, so the package corresponds to a known
commit rather than uncommitted working-tree state. Confirm the deployed code
actually contains your change before trusting a run - e.g.
`Select-String -Path E:\GSM-Test\Plugins\L4D\Install.psm1 -Pattern 'Test-SteamCMDPresent'`
should find the bootstrap guard.

### 1. A fresh target path

Pick a folder that has **never** had GSM unzipped, run, or configured into it
before - any drive letter works (e.g. `C:\GSM-Test\` or `D:\GSM-Test\`). It
must not be this repo's own dev checkout path
(`D:\Projects\GSM\GameServerManager`): re-running against the dev path would
retest state (config, service account, scheduled tasks, firewall rules) that
already exists there, which proves nothing about a real fresh install.

### 2. Confirm no prior `Config/` for this instance

```powershell
Test-Path 'C:\GSM-Test\GameServerManager\Config\Insurgency2014.json'
```

Expected: `False`. If `True`, pick a different target path or delete the file
before starting - a leftover config would mean `Start-GSMServer` never
exercises the actual `Install-GSMServerService` (NSSM service registration)
path this checklist is meant to prove out.

### 3. Confirm no prior GSM service account

```powershell
Get-LocalUser -Name 'GSM-ServiceAccount' -ErrorAction SilentlyContinue
```

Expected: no output. This account is shared across every instance on a
machine (`Core/ServiceAccount.psm1`'s `New-GSMServiceAccount`, default name
`GSM-ServiceAccount`), so if a prior GSM install or test run on this same
*machine* (not just this folder) already created it, `New-GSMServiceAccount`
will no-op rather than exercise its account-creation path. If you need a
truly clean account state, remove it first with an elevated session:

```powershell
Remove-LocalUser -Name 'GSM-ServiceAccount'
```

### 4. Confirm no prior scheduled task

```powershell
Get-ScheduledTask -TaskName 'GSM-Insurgency2014-*' -ErrorAction SilentlyContinue
```

Expected: no output. GSM names its per-instance scheduled tasks
`GSM-Insurgency2014-NightlyRestart`, `GSM-Insurgency2014-NightlyUpdateCheck`,
and `GSM-Insurgency2014-WorkshopRefresh` (`Core/Scheduler.psm1`'s
`Get-GSMSchedulerTaskName`). None of these are created by this checklist's
steps below (they're separate, already-verified Phase 3/6 functionality) -
this check just confirms no leftover task from a prior session on this
machine could make a later status check misleading.

### 5. Confirm no prior GSM firewall rule

```powershell
Get-NetFirewallRule -DisplayName 'GSM-Insurgency2014-*' -ErrorAction SilentlyContinue
```

Expected: no output. GSM names firewall rules
`GSM-Insurgency2014-<Port>-<Protocol>` (`Core/Firewall.psm1`'s
`Get-GSMFirewallRuleName`). This checklist does not call
`Add-GSMFirewallRule` itself (opening the port is Phase 3 functionality,
already covered by `Core/Firewall.psm1`'s own Pester suite) - this check just
confirms a leftover rule from a prior session isn't masking a real bind
failure with an already-open port.

## Step-by-step

Run every step from an **elevated** PowerShell 7+ session (required by
`New-GSMServiceAccount`).

| # | Command | What to check |
|---|---------|----------------|
| 1 | Copy `Build/GameServerManager-v<version>.zip` to the target machine and extract it to the fresh path (e.g. `C:\GSM-Test\GameServerManager\`) | Extraction succeeds; `GSM.ps1`, `Core/`, `Plugins/`, `Config/SteamCMD.json`, `Config/NSSM.json` are all present |
| 2 | `cd C:\GSM-Test\GameServerManager` | - |
| 3 | `./GSM.ps1 -FolderName Insurgency2014 -Action Configure` | Prompts appear (map, mode, port - accept the default port of `27015` unless you deliberately want to test a non-default port); exits 0; `Config/Insurgency2014.json` now exists |
| 4 | `Get-Content .\Config\Insurgency2014.json \| ConvertFrom-Json \| Select DefaultPort` | Note the actual `DefaultPort` value - this is the port every later step in this checklist checks against, **not** an assumed `27015` |
| 5 | `./GSM.ps1 -FolderName Insurgency2014 -Action Install` | Runs `Install-SteamCMD` (first-run only) then `Update-SteamApp -AppID '237410'`; exits 0; `Servers/Insurgency2014/srcds.exe` exists afterward |
| 6 | `./GSM.ps1 -FolderName Insurgency2014 -Action Start` | Exits 0. This is the step that exercises `New-GSMServiceAccount` (creates `GSM-ServiceAccount` if absent), `Set-GSMServiceAccountRights`, and `Install-GSMServerService` (registers Windows Service `GSM-Insurgency2014` via NSSM) for the first time against a real instance |
| 7 | `Get-Process -Name srcds -ErrorAction SilentlyContinue` | A process is listed |
| 8 | `Get-NetTCPConnection -LocalPort <DefaultPort from step 4> -State Listen -ErrorAction SilentlyContinue` (add `-ErrorAction SilentlyContinue` and check UDP too if the game only listens on UDP: `Get-NetUDPEndpoint -LocalPort <DefaultPort>`) | The configured port is listening |
| 9 | `./GSM.ps1 -FolderName Insurgency2014 -Action Stop` | Exits 0 |
| 10 | `Get-Process -Name srcds -ErrorAction SilentlyContinue` | No process is listed |
| 11 | `./GSM.ps1 -FolderName Insurgency2014 -Action Restart` | Exits 0 |
| 12 | `Get-Process -Name srcds -ErrorAction SilentlyContinue` | A process is listed again |
| 13 | `Get-NetTCPConnection -LocalPort <DefaultPort from step 4> -State Listen -ErrorAction SilentlyContinue` | The configured port is listening again |

## Troubleshooting

**Install fails with SteamCMD state `0x602` ("Corrupt update files") after a
long download, e.g. a validation log line like**
`Validation: N chunks corrupt of M total in file "..."` **followed by**
`update canceled : Staged file validation failed`**:** this is transient
Steam CDN corruption on a large download, not a GSM bug - the `validate`
flag in `Update-SteamApp` caught it correctly rather than silently leaving
a broken install. The partial download is staged under
`Servers/<FolderName>/steamapps/downloading/<AppID>/`, not lost. Simply
re-run the Install action: SteamCMD resumes from the staged files and
re-downloads only the corrupt chunk(s), not the whole game. If it fails
identically on a second attempt, delete that `downloading/<AppID>` folder
and retry from a clean state.

## Results

Fill in `Actual` and `Pass/Fail` for every row before considering this
checklist complete. A single `Fail` blocks Phase 6 close-out.

**Run by:** Marc Larouche, with Claude Code diagnosing/fixing between
attempts. **Date:** 2026-07-13 to 2026-07-15. **Target:** `E:\GSM-Test`.
**Instance tested:** Insurgency2014 (Map: Tell, Mode: Checkpoint).

| # | Step | Expected | Actual | Pass/Fail |
|---|------|----------|--------|-----------|
| 1 | Extract package | Files present | Files present | Pass |
| 3 | Configure | Exit 0, `Config/Insurgency2014.json` created | Exit 0, file created | Pass |
| 4 | Read configured port | Port value recorded: _____ | `27015` | Pass |
| 5 | Install | Exit 0, `srcds.exe` installed | Exit 0 after 2 fixes (SteamCMD auto-bootstrap; `+force_install_dir` before `+login`) and one transient CDN corruption (resolved by re-running Install, per Troubleshooting above); `srcds.exe` present at `Servers/Insurgency2014/srcds.exe` | Pass |
| 6 | Start | Exit 0 | Exit 0 after 2 fixes (service account auto-bootstrap via `New-GSMServiceAccount`/`Set-GSMServiceAccountRights`; NSSM's `ObjectName` needs the `.\` local-account qualifier, a bare name is rejected by `ChangeServiceConfig`) | Pass |
| 7 | Process check (after Start) | Process running | `srcds` process running (verified via `Get-Process`) | Pass |
| 8 | Port check (after Start) | Configured port listening | Port 27015 listening on TCP and UDP (verified via `Get-NetTCPConnection`/`Get-NetUDPEndpoint`); service confirmed running as `.\GSM-ServiceAccount`, not `LocalSystem` | Pass |
| 9 | Stop | Exit 0 | Exit 0 (`STOP: The operation completed successfully`) | Pass |
| 10 | Process check (after Stop) | No process running | Confirmed via NSSM's own subsequent Restart output (`STOP: The service has not been started` - only printed when NSSM's stop sub-step finds it already stopped) | Pass |
| 11 | Restart | Exit 0 | Exit 0, full re-registration cycle succeeded cleanly (no errors) | Pass |
| 12 | Process check (after Restart) | Process running | New `srcds` process (different PID than pre-Restart, confirming a genuine stop/start rather than the old process persisting) | Pass |
| 13 | Port check (after Restart) | Configured port listening | Port 27015 listening again on TCP and UDP | Pass |

**All steps pass.** Four real product bugs were found and fixed via this
run (none catchable by mocked tests, since none launch real `steamcmd.exe`/
NSSM or run a multi-dispatch session): the `Utilities.psm1`/`Logging.psm1`
`-Force` import crash (fixed 2026-07-13, see
`Docs/CleanInstallVerification.md`'s git history and
`Core/*.psm1`'s import lines), the missing SteamCMD bootstrap, the
`+force_install_dir`/`+login` argument order, and the missing
ServiceAccount bootstrap plus its `.\` qualifier requirement. See
`CHANGELOG.md` and `PRD.md` section 13 for the consolidated record.

**Run by:** _____________________ **Date:** _____________________

**GSM version tested:** _____________________

**Notes / anomalies observed:**
