# te1000 C#/.NET daemon — validation & cut-over guide

This is the persistent native daemon that **replaced** the per-call `powershell.exe` spawn
model — it is now the sole backend. It is **built and proven without XAE** (process start +
named pipe + JSON round-trip). Live-XAE validation is intentionally left to you because XAE is
unstable and another agent + the running MCP share this machine.

> The legacy PowerShell COM bridge and its fallback have been **removed** (the daemon's
> handlers were ported from it). The daemon requires a 64-bit TcXaeShell; there is no
> non-daemon mode.

## What was already validated (no XAE)
- `daemon/build.ps1` builds `Te1000Daemon.exe` clean (Release, x64, net472) with
  the in-box .NET Framework MSBuild — no SDK/NuGet/internet.
- `node daemon/test-ping.js` -> `RESULT: PASS` (spawns the daemon on a test pipe,
  round-trips `ping`, `list_actions`, and an unknown-action error).
- `runViaDaemon("ping")` through `daemonClient.js` auto-spawns the daemon,
  connects, and reports `actionCount = 164` (full coverage).
- `node --check index.js` and `node --check daemonClient.js` pass.

## Build / rebuild
```powershell
powershell -ExecutionPolicy Bypass -File C:\ProgramData\te1000-mcp-daemon\daemon\build.ps1
# -> C:\ProgramData\te1000-mcp-daemon\daemon\bin\Release\Te1000Daemon.exe
```
If TwinCAT is installed somewhere other than the default, edit the
`TCatSysManagerLib` `<HintPath>` in `daemon/Te1000Daemon.csproj` and rebuild.

## How the daemon turns on
`index.js` requires the 64-bit TcXaeShell
(`C:\Program Files\Beckhoff\TcXaeShell\Common7\IDE\PublicAssemblies\envdte.dll`) and routes
every action to the daemon — it is the only backend. The front auto-spawns the daemon exe on
first use and reconnects if the pipe drops.

Env knobs (all optional). The full table — what reads each one and its default — is in the
[README](../README.md#environment-variables); the daemon-relevant ones:
- `TE1000_DAEMON_PIPE=<name>` — pipe name (default `te1000-mcp`); daemon + client must match.
- `TE1000_DAEMON_CONNECT_MS=N` — connect/spawn wait before the call errors (default 20000).
- `TE1000_DAEMON_REQUEST_MS=N` — Node-side per-request ceiling (default 1900000; `0` disables).
  Kept above the daemon's own ~180 s per-call ceiling so it never pre-empts a long call.
- `TE1000_MCP_SOLUTION_PATH=<full path>` — pin the daemon to the XAE instance whose open
  solution matches, when several are running (read by the daemon).
- `TE1000_DAEMON_DEBUG=1` — write a daemon log to `%TEMP%\te1000-daemon-<pipe>.log`
  (or set `TE1000_DAEMON_LOG=<path>` for an explicit location).

The dialog watcher is configured by daemon CLI flags (`--no-watch`, `--no-autodismiss`,
`--grace-ms`, `--allowlist`). The Node front reads the `TE1000_DIALOG_WATCH` /
`TE1000_DIALOG_AUTODISMISS` / `TE1000_DIALOG_GRACE_MS` env vars (see the
[README](../README.md#environment-variables)) and translates them into those flags **when it spawns
the daemon**, so the env knobs work, applied at spawn time. Since the daemon is single-instance per
pipe, a changed value only takes effect once the daemon is killed and re-spawned. The grace window
defaults to 4000 ms.

## Live smoke test — start READ-ONLY
With XAE open on the solution, run these in order. Each should return quickly and
the daemon process should persist between calls (that's the whole point — no
re-spawn, no re-attach).

1. `xae` action `status` — confirms DTE attach + sysManager available.
2. `tc_tree` get on a known path (e.g. `TIID`) — confirms `LookupTreeItem`.
3. `plc_pou` `get_impl` on a known POU (e.g. `MAIN`) — confirms PLC text read.
4. `plc_pou` `find` / `search` — **the perf win**: should be fast and roughly
   constant-time on repeat calls (served from the tree cache; no root re-walk).
5. `tc_task` `list`, `nc` `list_tasks`, `plc_library` `list_references` — more reads.

Watch for: identical result shapes vs. the legacy bridge, and the daemon PID
staying constant across calls (`Get-Process Te1000Daemon`).

## Then exercise a safe mutation (offline config only)
- `plc_pou` `create` a throwaway POU, `get_impl` it, then `delete` it. Confirm the
  tree cache invalidates (a `tc_tree`/`find` after the create reflects the change).
- Verify guard tokens still gate: a `tc_tree delete` without `ALLOW_TWINCAT_DELETE`,
  `xae_command` without `ALLOW_XAE_COMMAND_EXEC`, etc. (index.js enforces these
  before the call reaches the daemon — unchanged.)
- Verify the **TISC safety rejection**: any `plc_pou`/tree authoring action toward
  a `TISC...` path must be refused with the "targets the TISC safety project"
  error. Nothing may write toward the safety system.

## Modal-dialog behavior to confirm
- An allowlisted dialog (see `dialog-allowlist.json` at the repo root, e.g. "changed
  outside the environment" -> Yes) should be auto-clicked by the daemon's watcher
  thread, and the call should complete normally.
- A non-allowlisted modal left open should, after the grace window
  (`--grace-ms`, default 4000 ms), make the in-flight call fail with the familiar
  "XAE is blocked on a modal dialog…" message (title/body/buttons), and the daemon
  should recover (recycle the COM worker) — **without** the whole daemon dying.
  Subsequent calls should work once the dialog is cleared.

## Restart / recover
To force a clean daemon, kill any running instance with
`Get-Process Te1000Daemon | Stop-Process` and restart the MCP; the front auto-spawns a
fresh daemon on the next call.
