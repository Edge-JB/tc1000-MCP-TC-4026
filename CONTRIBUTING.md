# Contributing

Thanks for your interest in improving `te1000-mcp`. This document covers the architecture, the
contract between the Node front and the native daemon, and the rules every change must respect. For
the full design, see [docs/architecture.md](docs/architecture.md).

By participating, you agree to abide by our [Code of Conduct](CODE_OF_CONDUCT.md). Found a security
issue — including a way to bypass the confirmation guards or reach the safety project? **Don't open a
public issue**; follow the [Security Policy](SECURITY.md) instead.

## Architecture

```
MCP client ──stdio──► index.js (Node 20) ──named pipe──► Te1000Daemon.exe ──COM/DTE──► XAE Shell
                       toolSchemas.js       (JSON)        (persistent, x64, net472)
                       daemonClient.js
```

- **`index.js`** — registers MCP tools, validates input with [zod](https://zod.dev), enforces
  confirmation-token guards, and maps each tool `action` onto a fine-grained bridge action name.
  Routes those actions to the daemon over the named pipe.
- **`toolSchemas.js`** — the **single source of truth** for every tool's input schema, the
  confirmation tokens, and the XAE action map. `index.js` imports from here; do not duplicate a
  schema in `index.js`.
- **`daemonClient.js`** — named-pipe client: auto-spawns the daemon (detached, single-instance),
  reconnects on pipe drop, correlates responses by `id`, and maps the daemon's `errorKind` back to
  user-facing error text.
- **`daemon/` (C#/.NET, net472/x64)** — the persistent COM bridge. `Program.cs` (STA entry,
  single-instance mutex, arg parsing) → `PipeServer.cs` (newline-delimited JSON) → `Dispatcher.cs`
  (action → handler, builds `ActionContext`) → `ComWorker.cs` (single STA queue, per-call timeout,
  modal-grace recycle) over `ComSession.cs` (cached DTE + sysmanager). `TreeCache.cs` +
  `EditWatcher.cs` are the caching/edit-watching layer; `DialogWatcher.cs` is the internal modal
  watcher. The 164 action handlers live under `daemon/Actions/*.cs`, one file per tool group.
- **`dialog-allowlist.json`**, **`powershell/plc-session.ps1`** — the reliability layer: the
  daemon reads the allowlist for the internal dialog watcher, and `plc-session.ps1` is the live
  UI-Automation helper for PLC logout (see [docs/operations.md](docs/operations.md)).

## Development

```powershell
git clone https://github.com/Edge-JB/TwinCAT-XAE-MCP.git
cd TwinCAT-XAE-MCP
npm install
npm run check        # node --check index.js — syntax-validate the front
node index.js        # smoke test — prints "running on stdio" and waits
```

### Working on the daemon (C#)

```powershell
# Stop any running daemon FIRST — it locks the exe and the build will fail otherwise.
Get-Process Te1000Daemon -ErrorAction SilentlyContinue | Stop-Process

powershell -ExecutionPolicy Bypass -File daemon\build.ps1   # Release, x64, net472 (in-box MSBuild)
node daemon\test-ping.js                                    # no-XAE: process + pipe + JSON round-trip
```

- The build uses the **in-box** .NET Framework MSBuild — no SDK/NuGet/internet. The in-box
  compiler is **C# 5 only**; keep handler code C# 5-clean (no string interpolation, `out var`,
  expression-bodied members, pattern matching, `nameof`, or tuples). See
  [docs/_porting-brief.md](docs/_porting-brief.md) for the handler conventions.
- An action handler talks to XAE via late-bound `dynamic` COM, returning a `data` JSON shape; the
  dispatcher wraps it as `{ok:true, result:<data>}`. Throw `BridgeException` for handled errors.
- For pure-Node work (front, schemas, client) you don't need to rebuild the daemon, but a built
  `Te1000Daemon.exe` must be present for the front to serve calls end to end.

CI runs `npm run check` on every push and pull request. There is no automated test of the live
TwinCAT path — that requires a real XAE installation and is exercised manually against a project.
`node daemon/test-ping.js` validates the daemon end to end **without** XAE.

## Adding or changing a tool

1. Keep the **noun-grouped, action-enum** shape. New capabilities are usually a new `action` on an
   existing tool, not a new top-level tool.
2. Define the input schema in **`toolSchemas.js`** (the single source of truth) — not inline in
   `index.js`.
3. Implement the handler as a C# handler in `daemon/Actions/<group>Actions.cs` (registered in
   `Dispatcher.cs`), returning a `data` JSON shape the front can consume.
4. Prefer a **`*_batch`** form for anything that operates on more than one item — one DTE attach,
   continue-on-error roll-up `{count, succeeded, failed, results}`.
5. Return **compact** output. Slice/grep large reads; echo full XML only on explicit request.
6. Update the [tool reference](docs/tools.md), the README table, the daemon
   [coverage checklist](docs/csharp-daemon-coverage.md), and [CHANGELOG.md](CHANGELOG.md).

## Non-negotiable safety rules

- **Guard every runtime-affecting, destructive, or licensing action** with a `confirm` token,
  enforced in `index.js` (and re-checked defensively in the daemon). Off by default.
- **Never write toward the safety project.** Authoring tools must refuse safety-rooted (`TISC`)
  paths — `PathUtil.AssertNotSafetyPath` in the daemon. The guard is **case-insensitive** (regex
  `^\s*TISC(\^|$)`, IgnoreCase). Nothing in this toolchain may write toward the TwinSAFE/TISC
  safety system; safety stays read-only/diagnostic.
- **Never auto-answer destructive dialogs.** The dialog allowlist (read by the daemon's internal
  watcher) must not contain Activate Configuration, Run-mode, restart, download, or safety prompts.

## Commits & pull requests

- Use clear, conventional commit subjects (`feat(plc_pou): …`, `fix(tc_tree): …`, `docs: …`).
- Describe what you verified and on what (build green? run against a live XAE? syntax check only?).
- Keep documentation in lockstep with behaviour changes.
