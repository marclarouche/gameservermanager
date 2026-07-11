# CLAUDE.md - GameServer Manager

Instructions for Claude Code when working in this repo.

## Scope

Only build what's listed as Phase 1 in `Docs/PRD.md` unless explicitly told
otherwise. Don't implement Phase 2-4 modules early, even if it seems convenient.
Files for later phases exist as stubs with a `# PHASE X - TODO` header only.

Phase 1 covers five games: Insurgency2014, TeamFortress2, CounterStrikeSource,
L4D, and L4D2. Build the same five files (Plugin.json, Install.psm1, Server.psm1,
Maps.psm1, Modes.psm1) for each. Don't add a sixth game plugin unless asked.

`Core/ServiceAccount.psm1` (least-privilege account provisioning) is Phase 1.
`Core/Service.psm1` (start/stop/restart as a Windows service) stays Phase 2,
even though it will eventually run under the account ServiceAccount.psm1
creates.

## Standards

- PowerShell 7+, `Set-StrictMode -Version Latest` at the top of every module.
- Every exported function needs comment-based help: `.DESCRIPTION`, `.PARAMETER`,
  `.EXAMPLE`, `.NOTES`.
- Verb-Noun naming (`Get-`, `Set-`, `Install-`, `Start-`, etc.), matching
  PowerShell approved verbs.
- Try/Catch around every file I/O, process start, and network call. No bare
  catches, log the error and rethrow or return a typed result.
- No hard-coded paths. Read paths from `Config/` JSON via `Core/Config.psm1`.
- Must pass PSScriptAnalyzer with default rules before considering a module done.
- One Pester test file per module in `Tests/`, named `<Module>.Tests.ps1`.

## Workflow

- Build one module at a time, in the order listed in PRD section 8.
- After writing a module, write its Pester tests, then run PSScriptAnalyzer.
- Don't touch other modules to make one module's tests pass, fix the module.
- Keep changes surgical: if a task is "build Config.psm1", don't also edit
  Logging.psm1 unless the task requires it.
- No telemetry, no analytics, no cloud auth, ever. Network calls are limited
  to Steam's own CDN via SteamCMD, RCON connections to the game server's own
  port (Phase 4), and the web dashboard's HTTP listener bound to
  `127.0.0.1` only (Phase 4) - nothing leaves the local machine.

## What not to add

- No web dashboard or RCON code until Phase 4 is explicitly started. Phase 4
  is exactly these two deliverables now - Discord notifications are dropped
  entirely (Marc doesn't plan to use it) and the plugin marketplace is cut
  entirely (doesn't fit an offline-first, zero-telemetry tool). Workshop
  support is deferred to a future Phase 5, not part of Phase 4.
- No abstractions for games beyond Insurgency 2014 until a second plugin is
  actually requested.
- No dependencies outside what ships with PowerShell 7+ and SteamCMD, unless
  approved first.
