# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.1.0] — Unreleased (branch `feat/csharp-daemon`)

A **persistent native C#/.NET daemon** replaces the per-call `powershell.exe` spawn
model for the hot path. The daemon acquires the DTE + `ITcSysManager` **once**,
caches them and the project tree, runs the dialog watchdog as an internal thread,
and serves the Node host over a named pipe. This eliminates the two root causes of
the old latency: the cold per-call process model (spawn ×2 + ROT walk + Add-Type
JIT + sysmanager re-acquire every call) and the O(tree-size) full re-walk on every
`plc_pou.find`/`search`/`tc_tree` call.

### Added
- `daemon/` — `Te1000Daemon.exe` (net472/x64; builds with the in-box .NET
  Framework MSBuild, no SDK/NuGet/internet). All **164** bridge actions ported to
  native C# handlers via late-bound `dynamic` COM, returning byte-identical `data`
  JSON. Components: persistent cached COM session (ROT probe + `Get-Dte` +
  `Get-SysManager` + health-check/reconnect), single STA `ComWorker` queue with
  per-call timeout and modal-dialog-grace recycle, `IOleMessageFilter`, native
  `DialogWatcher` thread (allowlist auto-dismiss), `TreeCache` (bounded walks +
  subtree invalidation), self-contained JSON, dependency-free build.
- `daemonClient.js` — named-pipe client; auto-spawns the daemon (detached,
  single-instance) and reconnects; maps daemon `errorKind` to the existing
  user-facing error messages.
- `daemon/build.ps1`, `daemon/test-ping.js` (no-XAE end-to-end proof).
- `docs/csharp-daemon-{plan,coverage,validation}.md`.

### Changed
- `index.js` routes `runBridge` to the daemon by default; the legacy PowerShell
  bridge is kept intact as a full fallback behind `TE1000_NO_DAEMON=1`, and is also
  used automatically when no 64-bit TcXaeShell is detected or the daemon can't
  start. The per-call dialog-watch/preflight spawn is skipped in daemon mode (the
  daemon watches internally). Server version → 2.1.0.

### Fixed
- **`plc_pou import_template` Windows-path corruption**: each `paths[]` element is
  now passed verbatim to `CreateChild(null, 58, "", vInfo)` — never split on `:`.
- **`plc_pou` find/search/tree + tree walks**: scoped to the requested subtree with
  a bounded depth and `TreeCache` memoization, replacing the per-call root re-walk.

### Wire contract
Unchanged. Same 25 tools, action names, payload schemas, result shapes (incl. batch
roll-ups `{count,succeeded,failed,results}` and guard tokens). The daemon returns the
same JSON the PowerShell bridge produced. TISC safety-path rejection preserved.

## [2.0.0]

The tool surface was consolidated for agent-context efficiency and then expanded to cover
nearly the entire automatable TE1000 surface.

### Changed
- **Consolidated 36 fine-grained tools into noun-grouped tools** with `action` enums and
  compact outputs (raw XML, pruned JSON). The PowerShell bridge still answers the original
  fine-grained action names; `index.js` maps onto them. The original v1 tool surface is
  preserved in git history.
- Old names map as: `twincat_*_tree_item*` / `*_child` → `tc_tree`;
  `twincat_link/unlink/resolve_variable*` → `tc_link`; netid/errors/rescan/scan → `tc_system`;
  `nc_*` → `nc`; `xae_solution_build` → `xae_build`; `xae_execute_command` → `xae_command`;
  remaining `xae_*` → `xae`.

### Added
- **AI-surface buildout** — noun-grouped tools closing the automatable gaps in the
  Automation Interface survey: `plc_project`, `plc_pou`, `plc_library`, `tc_task`, `tc_mapping`,
  `tc_route`, `tc_settings`, `tc_fieldbus`, `tc_module`, `tc_cpp`, `tc_measurement`,
  `tc_license`, `tc_variant`. **Total registered tools: 25.**
- **`tc_ethercat`** — native EtherCAT box builder. Creates fully-populated terminals/couplers
  for any device class via the GUI's own ESI-based "Add Box" route, with revision pinning and a
  unified single-box / batch / full-rack input shape.
- **Batch-first operations** — `*_batch` forms across `tc_tree` and `tc_link` that run N
  operations in one DTE attach and return a continue-on-error roll-up, with optional `save: true`.
- **Surgical POU editing** — `plc_pou` read-modify-write actions (`replace`, `replace_lines`,
  `insert`, `append`, …) that return only the changed region and preserve CRLF/LF.
- **Create result validation (ghost guard)** — `tc_tree create`/`create_batch` validate the
  created child and fail loudly on a malformed/blank-named "ghost" instead of silently succeeding.
- **Modal-dialog watchdog** and **pre-flight gate** — detect application-modal dialogs that would
  hang a synchronous COM call, auto-dismissing allowlisted ones and reporting the rest.
- **PLC session control** via UI Automation (`plc_session`), with `plc_download` auto-logout so
  deferred source edits compile before a boot project is generated.

### Removed
- `plc_login` / `plc_logout` from the tool surface — the 64-bit shell's DTE exposes no usable
  window automation for them. Use `xae_command` with `OtherContextMenus.PlcProject.Login/.Logout`
  on shells where they are available, or `plc_session` for logout via UI Automation.
- `progId` as a per-call tool parameter — set the `TE1000_PROGID` environment variable instead.

### Security
- Confirmation-token guards on every live-target, destructive, and licensing action.
- All authoring tools refuse safety-project (`TISC`) paths — nothing writes toward TwinSAFE.

## [1.0.0]

- Initial MCP server: attach to XAE Shell, open/build/save solutions, tree
  `ProduceXml`/`ConsumeXml`, variable linking, NetId targeting, rescans, NC inspection, and
  guarded activate/restart/download.

[2.0.0]: https://github.com/Edge-JB/TwinCAT-XAE-MCP/releases
[1.0.0]: https://github.com/Edge-JB/TwinCAT-XAE-MCP/releases
