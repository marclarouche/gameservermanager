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

## Results

Fill in `Actual` and `Pass/Fail` for every row before considering this
checklist complete. A single `Fail` blocks Phase 6 close-out.

| # | Step | Expected | Actual | Pass/Fail |
|---|------|----------|--------|-----------|
| 1 | Extract package | Files present | | |
| 3 | Configure | Exit 0, `Config/Insurgency2014.json` created | | |
| 4 | Read configured port | Port value recorded: _____ | | |
| 5 | Install | Exit 0, `srcds.exe` installed | | |
| 6 | Start | Exit 0 | | |
| 7 | Process check (after Start) | Process running | | |
| 8 | Port check (after Start) | Configured port listening | | |
| 9 | Stop | Exit 0 | | |
| 10 | Process check (after Stop) | No process running | | |
| 11 | Restart | Exit 0 | | |
| 12 | Process check (after Restart) | Process running | | |
| 13 | Port check (after Restart) | Configured port listening | | |

**Run by:** _____________________ **Date:** _____________________

**GSM version tested:** _____________________

**Notes / anomalies observed:**
