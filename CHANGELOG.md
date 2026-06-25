# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.2.0] — 2026-06-24

### Added
- **Interactive watchdog resolution.** An un-allowlisted modal dialog is no longer
  a dead-end: the blocked-call error now surfaces the dialog's title/text/buttons
  and instructs the calling agent to **ask the user** which button to press and
  whether to remember it. A new COM-free meta action **`xae dialog_resolve {button,
  remember?}`** clicks the chosen button on the live dialog and, with
  `remember:true`, appends a **specific** auto-dismiss rule — the exact dialog
  title **and** its body text, so it cannot later match an unrelated dialog that
  merely shares a title — to `dialog-allowlist.json` **and** hot-applies it to the
  running watcher (no daemon restart). Disruptive prompts (activate config /
  run-mode / restart / download / boot project / TwinSAFE / safety) are **refused
  for auto-remember** — the one-time human-chosen click still happens, but no rule
  is persisted, and the response reports `rememberRefused` with the reason.
  (`DialogWatcher.AddRule`/`HasRuleFor`/`AllowlistPath`,
  `Dispatcher.dialog_resolve`.)

### Removed
- **Legacy PowerShell COM bridge fallback removed.** Deleted
  `powershell/te1000-bridge.ps1`, `powershell/dialog-watch.ps1`, and the
  `powershell/test-code-engine*.ps1` probes. The native C# daemon
  (`Te1000Daemon.exe`) is now the **sole backend**; it requires a 64-bit
  TcXaeShell.
- **`TE1000_NO_DAEMON` env knob removed**, along with the `index.js` per-call
  legacy dialog gate/watcher spawn. There is no longer a non-daemon mode and no
  per-call PowerShell preflight — the daemon's internal `DialogWatcher.cs` thread
  handles modal dialogs in-process for every call.

### Changed
- **`dialog-allowlist.json` moved from `powershell/` to the repo root** and now
  **ships empty (report-only by default)** — a fresh clone auto-clicks nothing.
  Build the allowlist up yourself, by hand or via `xae dialog_resolve {button,
  remember:true}`. Same schema; only the path and the shipped ruleset changed.

> `powershell/plc-session.ps1` (the UI-Automation PLC-logout helper used by
> `plc_session` / `plc_download` auto-logout) and `daemon/build.ps1` (the daemon
> build script) are **retained**.

### Fixed
- **Watcher safety backstop.** The dialog watcher now **never auto-clicks** a
  dialog whose title/body matches the disruptive-operation pattern (activate config
  / run-mode / restart / download / boot project / TwinSAFE / safety), even if an
  allowlist rule would otherwise match it. Previously a remembered rule was
  persisted by title only, so a later same-title disruptive prompt could be
  auto-dismissed; the denylist is now a shared single source of truth
  (`DialogPolicy`) checked at both remember-time and click-time, and remembered
  rules persist the exact title **and** body text.
- **The allowlist file is never wiped on a failed write.** `AppendAllowlistRule`
  swaps the updated file into place with `File.Replace` (keeping a backup) instead
  of deleting the original before the move — a transient I/O failure now leaves the
  existing `dialog-allowlist.json` intact.
- **`dialog_resolve` reports an in-memory-only remember.** When a remembered rule
  is hot-applied to the watcher but the file write fails, the result says so
  explicitly instead of reporting a clean success.
- The watcher's copy-on-write rule list is published/read with
  `Volatile.Write`/`Volatile.Read`, so a hot-applied rule is reliably visible to
  the poll thread; and the `index.js` result discriminator is narrowed so it cannot
  mis-render an unrelated daemon result that happens to carry a `resolved` field.
- **Docs genericized.** README / SECURITY / operations / tools / examples and the
  tool-action descriptions no longer assume a specific "live cell" or running
  machine — this MCP drives an XAE instance and makes no assumption about what (if
  anything) is behind it. The `TE1000_DIALOG_WATCH` / `TE1000_DIALOG_AUTODISMISS` /
  `TE1000_DIALOG_GRACE_MS` knobs are now documented as applied at **daemon spawn**
  (an already-running single-instance daemon must be killed for a change to take
  effect), and `SECURITY.md` cites the C# `PathUtil.AssertNotSafetyPath` guard
  (not the removed PowerShell name).

## [2.1.2] — 2026-06-24

### Fixed
- **Dialog watchdog missed owner-less `#32770` prompts** (e.g. the TwinCAT
  System Manager's *"Unrestored variables links found"* dialog). `DlgWatch.Find`
  only recognized a window as a modal dialog when it was *visible AND enabled AND
  had an owner window that was disabled* — the classic application-modal trait.
  That System-Manager prompt is a top-level standard dialog-box (`#32770`) that is
  **owner-less**, does **not** disable the main XAE window, and is itself
  **`WS_DISABLED`** (a nested confirm can sit on top) — so it failed every branch
  of the heuristic and was silently skipped, leaving the blocked COM call to hang
  or proceed unnoticed (verified live: `owner=0`, `dlgEn=False`, `mainEn=True`).
  `Find` now ALSO matches a visible `#32770` standard dialog box that shows the
  **abnormal** modal trait the owner-disabled heuristic misses — **owner-less or
  self-`WS_DISABLED`** — requiring real content (a button or message) to guard
  against transient empty shells. A normal owned, self-**enabled** `#32770` is a
  *modeless* tool window (Find/Replace, Go To Line, Find Symbol Results) and is
  deliberately **excluded**, so leaving one open no longer spuriously trips the
  grace recycle and fails unrelated commands. The existing owner-disabled path for
  WPF/WinForms modals is unchanged. Mirrored in the PowerShell `dialog-watch.ps1`
  so both detectors stay in sync. The cross-process window-text reads in `Find`
  now use `SendMessageTimeout(SMTO_ABORTIFHUNG)` so a wedged XAE UI thread can
  never hang the watcher poll or a `dialog_probe` call.

### Added
- **`xae dialog_probe`** — a read-only diagnostic action (COM-free daemon meta
  action) that reports whether a modal dialog is currently blocking XAE and, if so,
  its title / body / buttons. Never clicks anything (report-only), so it is always
  safe to run — it just answers "is XAE wedged on a prompt right now, and on
  what?". Backed by `ComWorker.Watcher` + `DialogWatcher.Probe(doDismiss:false)`.
  In report-only mode `blocking` reflects whether the dialog would persist — a
  dialog matching an auto-dismiss allowlist rule reports `blocking:false`, since
  the watcher will clear it — so the probe does not cry wolf on allowlisted prompts.

## [2.1.1] — 2026-06-24

### Fixed
- **`xae error_list` always reported "error list unavailable".** The 2.1.0 daemon
  port read the Error List through raw IDispatch late binding
  (`dynamic dte.ToolWindows.ErrorList`), which returns **null** on TcXaeShell —
  `EnvDTE80.ToolWindows.get_ErrorList` is not reachable that way. `ReadErrorList`
  now uses the **strongly-typed `DTE2`** cast (`GetTypedObjectForIUnknown`), exactly
  like the PS bridge's `XaeErrorListProbe`, and again returns the live error/warning
  list. The broad `catch → null` that masked the failure now surfaces the actual
  exception in an `error` field (rendered as `error list unavailable: <reason>`).
  DTE acquisition (`ctx.Dte` / `GetIUnknownForObject`) is now inside the guarded
  block, so a dead/absent XAE takes the graceful `{available:false, error:…}`
  path instead of escaping as a hard `com_error`.
- Added typed `EnvDTE` / `EnvDTE80` / `Microsoft.VisualStudio.Interop` references
  (resolved at runtime from the TcXaeShell `PublicAssemblies` dir by the new
  `VsInterop` AssemblyResolve handler — not copied local, not GAC-dependent), for
  the DTE members raw IDispatch cannot reach. Mirrors the existing typed
  `TCatSysManagerLib` reference for vtable-only interfaces.

## [2.1.0] — 2026-06-24

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
  JSON. Components: persistent cached COM session (`ComSession` — ROT probe + `Get-Dte`
  + `Get-SysManager` + health-check/reconnect), single STA `ComWorker` queue with
  per-call timeout and modal-dialog-grace recycle, `IOleMessageFilter`, native
  `DialogWatcher` thread (allowlist auto-dismiss, multi-process-name aware), self-
  contained JSON, dependency-free build. The daemon is single-instance per pipe name
  (named mutex) and runs over a named pipe with newline-delimited JSON
  (`{id,action,payload}` → `{id,ok,result?|error?,errorKind?,dialog?}`); it also
  answers two COM-free meta actions, `ping` and `list_actions`.
- **Two-layer search cache** (`TreeCache`): per-object decl/impl source text **plus** a
  flat enumeration of the project's code objects, so a warm `plc_pou search` does zero
  COM tree-walk (~**500×** faster than the cold per-call model). An `EditWatcher`
  (on-demand `DTE.Documents`/`.Saved` dirty check + a `FileSystemWatcher` over the
  project directory) invalidates the cache so it never serves stale source for an object
  open/edited in the IDE or changed on disk. Item/walk caches do subtree invalidation;
  the enumeration cache is invalidated only on structural (create/delete/rename/move)
  changes.
- `daemonClient.js` — named-pipe client; auto-spawns the daemon (detached,
  single-instance) and reconnects; maps daemon `errorKind` to the existing
  user-facing error messages.
- `daemon/build.ps1`, `daemon/test-ping.js` (no-XAE end-to-end proof).
- `docs/architecture.md`, `docs/csharp-daemon-{plan,coverage,validation}.md`.
- New env knobs: `TE1000_DAEMON_PIPE`, `TE1000_DAEMON_CONNECT_MS`,
  `TE1000_DAEMON_REQUEST_MS` (Node-side per-request ceiling, default 1900000 ms),
  `TE1000_MCP_SOLUTION_PATH` (pin the daemon to a specific open solution),
  `TE1000_DAEMON_DEBUG` / `TE1000_DAEMON_LOG` (daemon diagnostic log).

### Changed
- `index.js` routes `runBridge` to the daemon by default; the legacy PowerShell
  bridge is kept intact as a full fallback behind `TE1000_NO_DAEMON=1`, and is also
  used automatically when no 64-bit TcXaeShell is detected or the daemon can't
  start. The per-call dialog-watch/preflight spawn is skipped in daemon mode (the
  daemon watches internally). Server version → 2.1.0 (`package.json` aligned).
- **Tool input schemas single-sourced** into `toolSchemas.js` (with the confirmation
  tokens and XAE action map); `index.js` imports them rather than redefining inline.

### Fixed
- **`plc_pou import_template` Windows-path corruption**: each `paths[]` element is
  now passed verbatim to `CreateChild(null, 58, "", vInfo)` — never split on `:`.
- **`plc_pou` find/search/tree + tree walks**: scoped to the requested subtree with
  a bounded depth and `TreeCache` memoization, replacing the per-call root re-walk.
- **Review hardening** (HIGH/MED/LOW):
  - **Per-request timeouts**: a Node-side `TE1000_DAEMON_REQUEST_MS` ceiling rejects a
    request whose reply never arrives (wedged daemon or a dropped/malformed frame that
    never matches its `id`), instead of hanging forever; on the daemon side a finite
    default per-call ceiling (~180 s) recycles a wedged non-dialog COM call, with a
    long-running-action allowlist (builds/activate/download/scans) that keeps the
    legacy infinite wait unless the caller passes an explicit `timeoutMs`.
  - **Recycle drain**: on a worker recycle, still-queued sibling jobs are faulted with
    a clear "retry" error instead of hanging on the abandoned STA thread.
  - **Fallback latch**: the first daemon-unavailable failure latches the front to the
    legacy bridge for the rest of the process (and re-applies the dialog pre-flight gate
    on the fallback path) so subsequent calls don't re-pay the connect timeout.
  - **COM release**: `ComSession.Dispose` balances ROT-probe RCWs and releases the
    cached DTE/sysmanager proxies down to a zero ref count; the recycle path only marks
    the old session stale (no cross-thread release of a still-in-use proxy).
  - **Cache-invalidation / safety guards**: structural edits made through `tc_tree` drop
    the stale enumeration cache; the TISC safety-path rejection was closed against a
    case bypass (the guard is case-insensitive).

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

[2.2.0]: https://github.com/Edge-JB/TwinCAT-XAE-MCP/releases/tag/v2.2.0
[2.1.0]: https://github.com/Edge-JB/TwinCAT-XAE-MCP/releases/tag/v2.1.0
[2.0.0]: https://github.com/Edge-JB/TwinCAT-XAE-MCP/releases
[1.0.0]: https://github.com/Edge-JB/TwinCAT-XAE-MCP/releases
