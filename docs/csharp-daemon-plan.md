# te1000-mcp → Full Native C#/.NET Daemon — Implementation Plan

> **Historical planning document.** This is the plan written *before* the port. The work is
> now complete and merged on `feat/csharp-daemon`; a few decisions changed during
> implementation — the authoritative description of the shipped design is
> **[architecture.md](architecture.md)**. Notably: the daemon targets **net472** (not net48)
> and builds with the **in-box .NET Framework MSBuild** (no SDK/NuGet); JSON is a
> **self-contained** reader/writer (`Json.cs`), not `System.Text.Json`/Newtonsoft; the typed
> `TCatSysManagerLib` interop is referenced (EmbedInteropTypes) for vtable-only interfaces;
> and the worktree lives at `C:\ProgramData\te1000-mcp-daemon`. Coverage and validation
> records are in [csharp-daemon-coverage.md](csharp-daemon-coverage.md) and
> [csharp-daemon-validation.md](csharp-daemon-validation.md).

## Goal
Replace the per-call `powershell.exe` spawn model with a **persistent C#/.NET daemon** that
implements the entire te1000 action surface **natively** (no PowerShell in the hot path), driving
XAE through the TwinCAT Automation Interface / EnvDTE COM. The daemon is long-lived: it acquires the
DTE + `ITcSysManager` **once**, caches them, caches the project tree, runs the dialog watchdog as an
internal thread, and serves the Node MCP host over a named pipe.

This kills both root causes found in the perf investigation:
1. **Cold per-call process model** (spawn ×2 + ROT walk + Add-Type JIT + Get-SysManager every call) →
   eliminated by persistence.
2. **O(tree-size) full re-walk per find/search** (`Invoke-PlcTreeWalk -MaxDepth 0` from root,
   bridge L6927) → eliminated by scoped/bounded walks + a tree cache.

## Repo / isolation
- Repo: `C:\ProgramData\te1000-mcp` (git, on `main`). **This is the LIVE MCP this machine uses.**
- Work in an **isolated git worktree** of a new branch so the deployed copy stays pristine and the
  running MCP/other agent are undisturbed:
  `git -C C:/ProgramData/te1000-mcp worktree add ../te1000-mcp-daemon -b feat/csharp-daemon`
  then do ALL work in `C:\ProgramData\te1000-mcp-daemon`.
- **Do NOT** restart/kill the running te1000 MCP server, kill `powershell.exe`/`node` of the running
  MCP, or drive live XAE in automated tests (XAE is unstable; another agent is using it).
- Commit incrementally on the branch. Do **not** merge or push unless asked.
- Safety policy (from CLAUDE.md): nothing may write toward the TwinSAFE system; TISC-rooted paths
  stay rejected exactly as the PS bridge rejects them.

## Key engineering decisions
1. **Late-bound `dynamic` COM, mirroring the PS bridge 1:1.** PowerShell drives DTE/sysmanager via
   IDispatch late binding (`$sysManager.LookupChild($path)`, `$item.Child($i)`, etc.). Do the same in
   C# with `dynamic` — no strongly-typed TwinCAT interop assembly required, and the port becomes
   nearly mechanical (PS line → C# line). Reference `Microsoft.CSharp` for `dynamic`.
2. **Target `net48`, `x64`.** `Marshal.GetActiveObject` and ROT P/Invoke are simplest on .NET
   Framework; x64 matches modern TcXaeShell (DTE.17.0 — confirmed by the `use64` envdte.dll check in
   index.js:162). If only a 32-bit shell (DTE.15.0) is detected at runtime, daemon-mode is skipped
   and index.js falls back to the legacy PS spawn (document this; don't build a 2nd bitness one-shot).
3. **Single STA COM worker thread.** XAE automation is single-threaded STA. All DTE calls run on one
   STA worker via a request queue; requests are serialized (XAE serializes anyway). Register the
   `IOleMessageFilter` (port `Ensure-ComMessageFilter`, bridge L116-174 — already C#) on that thread
   so rejected/retry COM calls behave as today.
4. **Hang recovery without killing the daemon.** A non-dismissable modal blocks the COM call inside
   XAE's modal loop; the worker thread can't be interrupted. On hard-timeout/persistent-block:
   abandon that worker thread, return the dialog-blocked/timeout error (same message shape as
   index.js:210-218/232), and re-acquire the session on a fresh STA worker. Allowlisted dialogs are
   auto-clicked by the watcher so the COM call returns normally and no recycle is needed.
5. **Preserve the wire contract.** index.js's 25 tools + their response relaying must keep working
   unchanged. The daemon returns the **same JSON result string** per action that the PS bridge
   produced. Action names + payload schema + result shapes are preserved exactly.

## Component layout (`daemon/`)
- `Te1000Daemon.csproj` — net48, x64, `<LangVersion>latest`, refs: `Microsoft.CSharp`,
  `EnvDTE` (COM, envdte.dll from TcXaeShell PublicAssemblies), `System.Text.Json` (NuGet) or
  Newtonsoft.Json. Output `Te1000Daemon.exe`.
- `Program.cs` — STA entry; parse pipe name/args; start `ComWorker`, `DialogWatcher`, `PipeServer`;
  graceful shutdown; single-instance guard (named mutex keyed to pipe name).
- `ComSession.cs` — acquire/cache DTE (`Get-Dte` modes active/new — port ROT enumeration
  `Get-PreferredDteFromRot` L286-371 + `Marshal.GetActiveObject` fallback L533-579) and
  `ITcSysManager` (`Get-SysManager` L623-676); health-check (cheap property read) + reconnect.
- `OleMessageFilter.cs` — port `Ensure-ComMessageFilter` (IOleMessageFilter, retry at 150ms up to
  60s — bridge L116-174).
- `ComWorker.cs` — STA thread, BlockingCollection request queue, per-request hard timeout, recycle.
- `PipeServer.cs` — `NamedPipeServerStream`, newline-delimited JSON. Request
  `{id, action, payload}`; response `{id, ok, result?|error?, errorKind?}`. Multiple concurrent
  client connections allowed; all enqueue to the single ComWorker.
- `DialogWatcher.cs` — lift the `DlgWatch` Win32 class verbatim from dialog-watch.ps1 (already C#:
  EnumWindows/owner-disabled modal detection L46-141), background thread polling ~750ms, allowlist
  (`dialog-allowlist.json`) auto-dismiss, expose latest snapshot + a "blockingSince" timer the
  ComWorker consults.
- `TreeCache.cs` — cache `LookupChild` results + bounded-walk results keyed by `^`-path; invalidate
  affected subtree on any mutating action (create/delete/import/rename/move/set_*/consume/clear).
- `PathUtil.cs` — `^`-separator path traversal, dot-form PLC subfield resolution (port the
  auto-resolve logic), TISC rejection.
- `Actions/*.cs` — one file per MCP tool group, each porting that group's actions. Map from
  `index.js` `server.registerTool` blocks (25 tools) and the bridge `switch ($Action)` (L3688).
  Groups (confirm against source): `tc_tree`, `tc_link`, `tc_mapping`, `tc_ethercat`, `tc_fieldbus`,
  `tc_module`, `tc_task`, `tc_mapping`, `tc_system`, `tc_route`, `tc_license`, `tc_settings`,
  `tc_variant`, `tc_measurement`, `tc_cpp`, `nc`, `plc_project`, `plc_pou`, `plc_library`,
  `plc_session`, `plc_download`, `xae`, `xae_build`, `xae_command`, `twincat_activate_configuration`,
  `twincat_restart_runtime`.

## Action-porting method (the bulk of the work)
1. **Enumerate** every action: parse `switch ($Action)` at bridge L3688 + the nested per-tool
   switches (e.g. L1272, L5460) + each `server.registerTool` action enum in index.js → produce a
   **coverage checklist** `docs/csharp-daemon-coverage.md` (action → ported? → C# location).
2. For each action: read its PS handler, reimplement in C# using `dynamic` sysmanager/DTE calls,
   returning JSON identical in shape to the PS output. Preserve guards (delete confirm token
   `ALLOW_TWINCAT_DELETE`, TISC rejection, batch continue-on-error roll-up
   `{count,succeeded,failed,results:[...]}`).
3. **Perf fixes baked in:**
   - `plc_pou.find`/`search` + `tc_tree` walks: default to the requested subtree with a bounded
     depth; resolve known full paths via `LookupChild` instead of root `MaxDepth 0` enumeration;
     serve from `TreeCache` when warm.
   - Fix the `import_template` colon bug (bridge L6135-6136): pass each `paths[]` element verbatim to
     `CreateChild(null, 58, "", vInfo)` — never split a Windows path on `:`.
4. To achieve full coverage in ONE pass, you are authorized to **spawn parallel sub-agents** (Agent
   tool), one per tool-group, each porting its group against this plan + the shared ComSession/COM
   conventions. Then do an integration pass (build, wire dispatch, dedupe helpers). Keep a single
   source of truth for ComSession/PathUtil/TreeCache that all handlers use.

## Node host changes (`index.js`)
- New `daemonClient.js`: connect to the named pipe; if connect fails, spawn `Te1000Daemon.exe`
  detached, wait for the pipe (timeout), then connect; correlate responses by `id`; reconnect on
  pipe drop.
- `runBridge(action, payload)` → daemon client by default; legacy PS spawn path kept intact behind
  `TE1000_NO_DAEMON=1` (full safety fallback — do not delete the PS bridge).
- In daemon mode, remove the per-call watcher spawn (index.js:188-195) — the daemon watches.
- Map daemon `errorKind` (`dialog_blocked`, `timeout`, `com_error`) to the existing user-facing error
  messages (index.js:210-218, 232) so agent-visible behavior is unchanged.
- Bump server version; `bitness != x64 shell` → auto-fallback to legacy.

## Build & validation (must NOT touch live XAE)
- Verify toolchain early: prefer `dotnet build`; else MSBuild/`csc` for net48. Report if absent.
- `dotnet build -c Release` (or msbuild) → `Te1000Daemon.exe` builds clean, x64.
- Add a daemon `ping` action (no COM): validates process start + pipe + JSON round-trip end-to-end.
- `node --check index.js` passes; a small node script connects to a daemon started on a TEST pipe
  name and round-trips `ping` (no XAE).
- **Defer live-XAE validation to the user.** Provide `docs/csharp-daemon-validation.md`: how to point
  the MCP at the daemon, env flags, and a checklist of actions to smoke-test against the live cell
  when safe (start with read-only: `xae.status`, `tc_tree get`, `plc_pou get_impl`).

## Deliverables / acceptance
- [ ] Feature branch `feat/csharp-daemon` (in a worktree); incremental commits; not merged/pushed.
- [ ] `daemon/` C# project builds clean (Release, x64, net48).
- [ ] Persistent late-bound COM session: cached DTE + sysmanager, health-check, reconnect,
      IOleMessageFilter.
- [ ] Native dialog watcher thread + allowlist auto-dismiss (no per-call watcher process).
- [ ] Tree cache + bounded find/search; `import_template` colon bug fixed.
- [ ] **Coverage checklist**: every bridge action accounted for (ported, or explicitly listed as
      deferred with reason). Aim for 100%.
- [ ] index.js rewired to the daemon w/ auto-start + `TE1000_NO_DAEMON=1` legacy fallback; per-call
      watcher removed in daemon mode; error messages preserved.
- [ ] `ping` round-trips end-to-end without XAE; `node --check` clean.
- [ ] CHANGELOG.md + README.md + `docs/csharp-daemon-{plan,coverage,validation}.md` updated.
- [ ] Final report: what's ported, what's deferred, build status, exact manual steps for the user to
      validate against live XAE and to flip the MCP over to daemon mode.
