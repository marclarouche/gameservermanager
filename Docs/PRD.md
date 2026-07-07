# GameServer Manager (GSM) - Product Requirements Document

**Version:** 0.1.0-alpha (Phase 1)
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
- RCON console, Discord notifications, Workshop support (Phase 4)
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
│   ├── Service.psm1         # Phase 2 - wraps servers as genuine Windows Services (NSSM-style)
│   ├── Scheduler.psm1       # Phase 3 - scheduled restarts/updates
│   ├── Backup.psm1          # Phase 3 - backup/restore
│   ├── Firewall.psm1        # Phase 3 - Windows Firewall rule management
│   ├── Reports.psm1         # Phase 3 - ServerHealth.html generation
│   └── Dashboard.psm1       # Phase 4 - live status view
│
├── Plugins/
│   ├── Insurgency2014/
│   │   ├── Plugin.json      # AppID 237410, port 27015, Workshop + RCON
│   │   ├── Install.psm1     # Phase 1 - SteamCMD install call for this game
│   │   ├── Server.psm1      # Phase 1 - launch params, thin Start/Stop/Restart/
│   │   │                    #   Status/Configure wrappers around
│   │   │                    #   Core/ProcessManager.psm1 and Core/ConfigEditor.psm1
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

## 8. Phase 1 deliverables (build order)

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

## 9. Later phases (reference only, not built yet)

| Phase | Focus | Est. lines | Adds |
|---|---|---|---|
| 2 | Server Management | ~2,000 | Update, crash recovery, `Service.psm1` |
| 3 | Administration | ~2,000 | Firewall, Windows Service, Scheduler, Backup, Reports |
| 4 | Professional Features | ~3,000+ | Web dashboard, RCON, Discord, Workshop, plugin marketplace |

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
| v0.2.0 | Server Management |
| v0.3.0 | Administration |
| v0.4.0 | Monitoring |
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
