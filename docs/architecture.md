# Architecture: Node front + persistent C#/.NET daemon

`te1000-mcp` is two cooperating processes: a **Node MCP front** that owns the MCP
protocol and tool surface, and a **persistent native C#/.NET daemon** that holds the
COM/DTE session and does the actual TwinCAT XAE work. The native C#/.NET daemon is the
**sole backend**; it was ported from an earlier per-call PowerShell COM bridge, which has
since been removed.

```
  MCP client (agent)
        │  stdio (JSON-RPC, MCP)
        ▼
  index.js ───────────────► Te1000Daemon.exe ──COM/DTE──► XAE Shell (TE1000)
   (Node 20)  named pipe     (persistent, x64,            running TwinCAT project
   daemonClient.js           net472, STA COM session)
   toolSchemas.js
```

## Why the daemon exists

The **original** design (since removed) spawned a fresh 32-bit `powershell.exe` bridge —
plus a second `powershell.exe` dialog watcher — on **every** MCP call. Each spawn paid:

1. **A cold per-call process model** — re-acquiring the DTE / `ITcSysManager` COM handles
   via a Running-Object-Table (ROT) walk + `Marshal.GetActiveObject`, and JIT-compiling the
   inline `Add-Type` Win32 helpers, on every call.
2. **An `O(tree-size)` full re-walk** for `plc_pou.find`/`search` — enumerating the whole
   project tree from the root (~2,900 COM round-trips on a full project), so latency grew
   with project size.

The daemon eliminates both: the COM session and the tree/text caches are **persistent**, so
the hot path makes few or zero COM round-trips on a warm cache.

## The Node front (`index.js`, `toolSchemas.js`, `daemonClient.js`)

- **`index.js`** speaks MCP/JSON-RPC over stdio, validates input with
  [zod](https://zod.dev), enforces the confirmation-token guards (off by default), and maps
  each grouped tool `action` onto a fine-grained daemon action name. It routes those actions
  to the daemon.
- **`toolSchemas.js`** is the single source of truth for every tool's input schema, the
  confirmation tokens, and the XAE action map. `index.js` imports from it.
- **`daemonClient.js`** is the named-pipe client. It auto-spawns the daemon on first use,
  reconnects on a dropped pipe, correlates responses by `id`, and maps the daemon's
  `errorKind` back to user-facing error text.

### Daemon routing

The front requires a 64-bit TcXaeShell (detected via
`C:\Program Files\Beckhoff\TcXaeShell\Common7\IDE\PublicAssemblies\envdte.dll`); the native
C#/.NET daemon is the only backend. All actions route to the daemon over the pipe.

## The pipe protocol

Front and daemon exchange **newline-delimited JSON** over `\\.\pipe\te1000-mcp` (name
overridable with `TE1000_DAEMON_PIPE`):

```
  request:   {"id": "<n>", "action": "<bridge_action>", "payload": { … }}
  response:  {"id": "<n>", "ok": true,  "result": { … }}
           | {"id": "<n>", "ok": false, "error": "…",
              "errorKind": "com_error" | "dialog_blocked" | "timeout",
              "dialog": { title, text, buttons, … } }
```

Each request line is one job; each response line carries the matching `id`. The
`PipeServer` accepts multiple concurrent client connections; all of them enqueue to the
single `ComWorker`, so requests are serialized through one STA COM thread (XAE serializes
anyway). Two COM-free meta actions are handled directly in the dispatcher: `ping`
(health/`actionCount`/`pid`) and `list_actions`.

## The daemon process (`daemon/`)

`Program.cs` is the `[STAThread]` entry point. It parses CLI flags
(`--pipe`, `--no-watch`, `--no-autodismiss`, `--grace-ms`, `--allowlist`), takes a
**single-instance mutex** keyed to the pipe name (a duplicate spawn just exits), then starts
the `DialogWatcher`, the `ComWorker`, the `Dispatcher`, and the `PipeServer`.

| File | Responsibility |
|---|---|
| `Program.cs` | STA entry, arg parsing, single-instance mutex, component wiring, default-allowlist discovery. |
| `PipeServer.cs` | `NamedPipeServerStream`, newline-delimited JSON framing, one thread per connection. |
| `Dispatcher.cs` | Action → handler map (registered per tool group), builds `ActionContext`, picks the per-call timeout, runs the handler on the worker, formats the response. |
| `ComWorker.cs` | Owns the single **STA** thread; serializes jobs through a blocking queue; enforces the per-call timeout and the modal-dialog grace; **recycles** the STA thread on a wedge without killing the daemon. |
| `ComSession.cs` | Acquires + caches the DTE and `ITcSysManager` once; ROT-prefers an instance with an open solution (or `TE1000_MCP_SOLUTION_PATH`); health-checks with a cheap property read and transparently reconnects; balanced COM release on dispose. |
| `OleMessageFilter.cs` | `IOleMessageFilter` (registered on the STA thread) so rejected/retry COM calls back off and retry. |
| `TreeCache.cs` | Item-lookup cache, bounded-walk cache, per-object **decl/impl text** cache, and a flat **code-object enumeration** cache, with a leaf-name index. |
| `EditWatcher.cs` | On-demand `DTE.Documents`/`.Saved` dirty check + a `FileSystemWatcher` over the project dir, to keep the text/enum caches from serving stale source. |
| `DialogWatcher.cs` | Background thread polling (~750 ms) for an application-modal dialog owned by the XAE process; allowlist auto-dismiss; exposes the latest snapshot + a "blocking since" timer the worker consults. |
| `PathUtil.cs`, `ComHelpers.cs`, `PlcProjectHelper.cs`, `Json.cs`, `Log.cs` | `^`-path helpers + TISC safety guard, COM convenience wrappers, vtable-only `ITcPlcProject` helpers, the self-contained JSON reader/writer, and the optional diagnostic log. |
| `Actions/*.cs` | The 164 action handlers, one file per tool group (`XaeActions`, `TreeActions`, `LinkActions`, `PlcProjectActions`, `PlcPouActions`, `PlcLibraryActions`, `TaskActions`, `MappingRouteActions`, `FieldbusActions`, `ModuleCppActions`, `MeasurementActions`, `LicenseVariantActions`, `NcActions`, `SessionDownloadActions`). |

### The COM session and worker

All DTE/sysmanager calls run on **one** STA worker thread, fed by a blocking queue. The
`Dispatcher` gives each call a timeout budget: a finite default ceiling (**180 s**) for
ordinary fast COM calls, or **unbounded** (wait indefinitely) for an allowlist of legitimately
long-running actions (solution/C++ builds, activate, restart, download, boot-gen, library/IO
scans, rescan, timed scope record, route broadcast search) — unless the caller passes an
explicit `timeoutMs` in the payload, which always wins.

If a call exceeds its budget, or a non-allowlisted modal dialog persists past the grace
window, the worker **recycles**: it abandons the (likely modal-loop-wedged) STA thread and
spins up a fresh one that re-acquires the session lazily — **without** killing the daemon.
Still-queued sibling jobs are drained and faulted with a clear "retry" error rather than
left to hang. The abandoned thread is a background thread, so it dies with the process if it
ever unblocks.

### Caching and edit-watching — the performance win

`plc_pou.search` was the slowest action because it re-walked the whole tree and re-read every
object's source on every call. `TreeCache` memoizes two things:

- **Per-object decl/impl text** (`DeclarationText` / `ImplementationText` / `Language`),
  keyed by `^`-tree-path, so a repeat read is a dictionary hit, not a COM call.
- **A flat enumeration** of the descendant code-object paths under a search scope, so a warm
  full-project search does **zero** COM tree-walk.

Together these make a warm `plc_pou search` roughly **500× faster** than the cold per-call
model. Invalidation keeps it correct:

- Mutations made **through the daemon** call `Invalidate(path)` (content) or `InvalidateEnum`
  (structural) directly.
- Edits made **in the IDE** are covered by the `EditWatcher`: before a search it does a
  TTL-gated `DTE.Documents`/`.Saved` dirty check (a dirty open editor is re-read live, never
  served from cache), and a `FileSystemWatcher` over the project directory invalidates the
  text cache on a save (and the enumeration cache on create/delete/rename). The
  `FileSystemWatcher` handler runs on its own thread and is strictly COM-free; the dirty check
  runs inline on the STA worker.

## Historical note: the PowerShell bridge

The daemon's action handlers were **ported from** an earlier PowerShell COM bridge
(`powershell/te1000-bridge.ps1`) that the front spawned per call, with a separate
dialog-watcher process and a pre-flight gate. That bridge, its watcher, and the per-call
fallback path have all been **removed** — the native daemon is now the sole backend. The
daemon's `DialogWatcher.cs` is a faithful in-process port of that watcher, and it reads
`dialog-allowlist.json` (repo root). Action handlers are 1:1 ports of the old PS cases (the
porting brief describes the mechanical mapping), so result shapes are byte-identical to what
the bridge produced.

## Safety policy

Nothing in this toolchain writes toward the TwinSAFE/TISC safety system. Authoring actions
reject safety-rooted paths via a **case-insensitive** guard (`PathUtil.AssertNotSafetyPath`;
regex `^\s*TISC(\^|$)`, IgnoreCase). Safety remains read-only/diagnostic. The dialog
allowlist must never auto-answer Activate / Run-mode / restart / download / safety prompts.

## Build & run

See [Build the daemon](../README.md#build-the-daemon) and
[csharp-daemon-validation.md](csharp-daemon-validation.md). In short: `daemon/build.ps1`
builds `daemon/bin/Release/Te1000Daemon.exe` (Release, x64, net472) with the in-box .NET
Framework MSBuild — no SDK, no NuGet, no internet — referencing `TCatSysManagerLib.dll` for
the handful of vtable-only `IUnknown` interfaces. The front auto-spawns the prebuilt exe
(detached, single-instance, `windowsHide`) on first use, and it survives an MCP-front restart.
The Node runtime dependency is retained by design — the daemon replaces the COM hot path, not
the MCP front.
