<p align="center">
  <img src="docs/assets/te1000-banner.png" alt="TE1000 MCP — MCP server for Beckhoff TwinCAT XAE / TE1000 Automation Interface" width="100%">
</p>

# te1000-mcp

> A [Model Context Protocol](https://modelcontextprotocol.io) server for **Beckhoff TwinCAT 3** engineering automation — drive the **TE1000 / XAE Automation Interface** from an AI agent or any MCP client.

[![CI](https://github.com/Edge-JB/TwinCAT-XAE-MCP/actions/workflows/ci.yml/badge.svg)](https://github.com/Edge-JB/TwinCAT-XAE-MCP/actions/workflows/ci.yml)
[![MCP](https://img.shields.io/badge/MCP-server-blue)](https://modelcontextprotocol.io)
[![Node](https://img.shields.io/badge/node-%3E%3D20-339933?logo=node.js&logoColor=white)](https://nodejs.org)
[![TwinCAT](https://img.shields.io/badge/TwinCAT-3%20%2F%20TE1000-orange)](https://www.beckhoff.com/twincat)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

`te1000-mcp` exposes the TwinCAT XAE engineering surface — the System Manager tree,
PLC project authoring, IO/EtherCAT configuration, variable linking, builds, and
runtime deployment — as a compact set of MCP tools. It talks to a **running XAE Shell**
through the TE1000 Automation Interface (COM/DTE), so an agent can configure and build
a TwinCAT project the same way an engineer would in the GUI.

A Node MCP front (`index.js`) owns the MCP protocol, tool schemas, and confirmation
guards; the COM/DTE work runs in a **persistent native C#/.NET daemon**
(`Te1000Daemon.exe`) that the front talks to over a Windows named pipe. The daemon is
the sole backend. See [How it works](#how-it-works).

> [!IMPORTANT]
> This server drives a **real engineering tool** and can deploy to a **live PLC**.
> Every action that touches the running target (activate, restart, download, deletes,
> licensing) is **confirmation-gated** and off by default. See [Safety & guards](#safety--guards).

---

## Contents

- [Highlights](#highlights)
- [How it works](#how-it-works)
- [Requirements](#requirements)
- [Install](#install)
- [Build the daemon](#build-the-daemon)
- [Configure your MCP client](#configure-your-mcp-client)
- [Environment variables](#environment-variables)
- [Quickstart](#quickstart)
- [Tool reference](#tool-reference)
- [Safety & guards](#safety--guards)
- [Reliability: dialog watchdog & PLC session control](#reliability-dialog-watchdog--plc-session-control)
- [Troubleshooting](#troubleshooting)
- [Examples](#examples)
- [Documentation](#documentation)
- [Contributing](#contributing)
- [License](#license)

---

## Highlights

- **25 noun-grouped tools** covering the automatable TE1000 surface — tree, IO/EtherCAT,
  linking, PLC project & POU authoring, libraries, tasks, mapping, routes, fieldbuses,
  TcCOM, C++, measurement/scope, licensing, and variants.
- **Batch-first** — every multi-item operation has a `*_batch` form that runs N operations
  in **one** DTE attach and returns a compact continue-on-error roll-up, instead of paying
  a process spawn + attach per call.
- **Native EtherCAT builder** — `tc_ethercat` creates fully-populated EtherCAT boxes
  (correct identity, SyncManagers, FMMUs, PDOs) for any device class by the GUI's own
  "Add Box" route, driven from the device's ESI.
- **Surgical PLC code edits** — `plc_pou` reads, greps, and patches declaration/implementation
  text in place and returns only the changed region, keeping agent context small.
- **Safe by default** — destructive and live-target actions are confirmation-gated; the
  safety project is never written to, by policy.
- **Resilient to GUI modals** — a dialog watchdog detects and (optionally) auto-dismisses
  modal dialogs that would otherwise hang a synchronous COM call forever.
- **Persistent native daemon** — a long-lived C#/.NET daemon holds the COM session and
  caches the project tree and POU source text, so warm `plc_pou search` runs roughly
  **500× faster** than the old per-call spawn model.

## How it works

```
  MCP client (agent)
        │  stdio (JSON-RPC, MCP)
        ▼
  index.js ───────────────► Te1000Daemon.exe ──COM/DTE──► XAE Shell (TE1000)
   (Node 20)  named pipe     (persistent, x64,            running TwinCAT project
   daemonClient.js           net472, STA COM session)
   toolSchemas.js
```

Two cooperating processes:

- **Node MCP front (`index.js`)** — speaks MCP/JSON-RPC over stdio, validates input with
  [zod](https://zod.dev), single-sources every tool's input schema from `toolSchemas.js`,
  enforces the confirmation-token guards, and maps each tool `action` onto a fine-grained
  bridge action name. It routes those actions to the daemon over a named pipe
  (`daemonClient.js`).
- **Native daemon (`daemon/Te1000Daemon.exe`)** — a persistent net472/x64 process that
  acquires the DTE + `ITcSysManager` **once** and keeps them, runs the dialog watchdog on
  an internal thread, caches the System Manager tree and POU source text, and serves the
  front over the pipe. It implements the **same 164 bridge actions** and returns the
  **same JSON**, so the tool surface is unchanged.

### Pipe protocol

The front and daemon exchange **newline-delimited JSON** over `\\.\pipe\te1000-mcp`
(name overridable via `TE1000_DAEMON_PIPE`):

```
  request:   {"id": "<n>", "action": "<bridge_action>", "payload": { … }}
  response:  {"id": "<n>", "ok": true,  "result": { … }}
           | {"id": "<n>", "ok": false, "error": "…", "errorKind": "com_error|dialog_blocked|timeout", "dialog": { … }}
```

Responses are correlated by `id`. The daemon serializes every COM call through a single
**STA worker thread**, so concurrent pipe clients are safe (XAE serializes anyway). The
daemon also answers two COM-free meta actions used for health checks: `ping` and
`list_actions`.

### Why a daemon — the performance win

An earlier model spawned a fresh 32-bit `powershell.exe` bridge (plus a second watcher
process) on **every** call. Each spawn re-acquired the DTE/`ITcSysManager` COM handles
(a Running-Object-Table walk + `Marshal.GetActiveObject`), JIT-compiled the inline
`Add-Type` Win32 helpers, and — for `plc_pou.find`/`search` — re-walked the entire
project tree from the root (`O(tree-size)`, ~2,900 COM round-trips on a full project),
so latency grew with project size.

The persistent daemon removes all of that from the hot path:

- **Persistent COM session** (`ComSession.cs`) — the DTE + sysmanager are acquired once,
  health-checked with a cheap property read, and transparently reconnected if stale.
- **Two-layer tree cache** (`TreeCache.cs`) — per-object decl/impl source text **and** a
  flat enumeration of the project's code objects are memoized, so a warm full-project
  search does *zero* COM tree-walk. This is the **~500×** warm-`search` speed-up.
- **Edit watcher** (`EditWatcher.cs`) — an on-demand `DTE.Documents`/`.Saved` dirty check
  plus a `FileSystemWatcher` over the project directory invalidate the cache so it never
  serves stale source for an object you are editing in the IDE (or that changed on disk).
- **Internal dialog watcher** (`DialogWatcher.cs`) — runs on its own thread, so there is
  no per-call watcher process. See [Reliability](#reliability-dialog-watchdog--plc-session-control).

Build the daemon with `daemon/build.ps1` (in-box .NET Framework MSBuild — no SDK/NuGet).
The daemon requires the **64-bit** TcXaeShell (DTE.17.0).
See **[docs/architecture.md](docs/architecture.md)** for the end-to-end design and
**[docs/csharp-daemon-validation.md](docs/csharp-daemon-validation.md)** for the
build/cut-over/validation guide.

## Requirements

| | |
|---|---|
| **OS** | Windows |
| **TwinCAT** | TwinCAT 3 XAE Shell / XAE installed, with the TE1000 Automation Interface |
| **Node.js** | 20 or newer (the MCP front; the daemon does not remove the Node dependency) |
| **A running XAE Shell** | the server attaches to an already-open instance (it does not launch XAE) |
| **Daemon (required backend)** | the **64-bit** TcXaeShell, a .NET Framework 4.x install (for the in-box MSBuild + net472 runtime), and `TCatSysManagerLib.dll` (ships with TwinCAT) |

The XAE ProgID defaults to `TcXaeShell.DTE.17.0`. Override it with the `TE1000_PROGID`
environment variable if your installation differs.

The daemon is **not** auto-built — build it once with `daemon/build.ps1` (see
[Build the daemon](#build-the-daemon)); thereafter the MCP front auto-spawns the prebuilt
`Te1000Daemon.exe` on first use. If the exe is absent, build it before the front can serve
calls.

## Install

```powershell
git clone https://github.com/Edge-JB/TwinCAT-XAE-MCP.git
cd TwinCAT-XAE-MCP
npm install
```

Verify the server starts:

```powershell
node index.js
# -> te1000-mcp server running on stdio   (Ctrl-C to exit)
```

The server communicates over stdio and is normally launched **by an MCP client**, not by
hand. Running it directly just waits for a client on stdin.

## Build the daemon

The native daemon is the backend, which you build **once**:

```powershell
powershell -ExecutionPolicy Bypass -File daemon\build.ps1
# -> daemon\bin\Release\Te1000Daemon.exe   (Release, x64, net472)
```

- Uses the **in-box** .NET Framework MSBuild
  (`C:\Windows\Microsoft.NET\Framework64\v4.0.30319\MSBuild.exe`) — **no .NET SDK, no
  NuGet, no internet**. The csproj is old-style (non-SDK) and targets `net472`; the
  produced x64 exe also runs on the net48 runtime.
- References `TCatSysManagerLib.dll` (embedded interop) for the handful of vtable-only
  `IUnknown` interfaces that late-bound `dynamic` can't reach (`ITcPlcProject`, etc.).
  `build.ps1` probes the known TwinCAT install paths; if yours differs, edit the
  `<HintPath>` in `daemon/Te1000Daemon.csproj` and rebuild. Pass `-Debug` for a Debug build.
- After building, the MCP front **auto-spawns** the exe (detached, `windowsHide`) on the
  first call and connects to its pipe. The daemon is **single-instance per pipe name**
  (named mutex), so duplicate spawns are harmless, and it is **detached** so it survives an
  MCP-front restart. Verify it independently with no XAE attached:

  ```powershell
  node daemon\test-ping.js     # spawns the daemon on a test pipe, round-trips ping
  ```

> [!NOTE]
> The running daemon **locks** `Te1000Daemon.exe`. To rebuild after a code change, stop any
> running instance first: `Get-Process Te1000Daemon | Stop-Process`.

## Configure your MCP client

Point your client at the absolute path of `index.js` in your clone. Example
(Claude Desktop / Claude Code / any MCP client that reads this shape):

```jsonc
{
  "mcpServers": {
    "te1000": {
      "command": "node",
      "args": ["C:\\path\\to\\TwinCAT-XAE-MCP\\index.js"]
    }
  }
}
```

A ready-to-edit copy lives at [`examples/mcp-config.json`](examples/mcp-config.json).

### Environment variables

All optional. The first group is read by the Node front (`index.js` / `daemonClient.js`);
the second by the native daemon process. Defaults are from the source.

**Read by the Node front:**

| Variable | Default | Purpose |
|---|---|---|
| `TE1000_PROGID` | `TcXaeShell.DTE.17.0` | XAE Shell COM ProgID to attach to (passed through to the daemon as `progId`). |
| `TE1000_DAEMON_PIPE` | `te1000-mcp` | Named-pipe name. The front and the daemon it spawns share this, so a custom value applies to both. |
| `TE1000_DAEMON_CONNECT_MS` | `20000` | How long the client waits to connect to (and, if needed, spawn) the daemon before failing the request. |
| `TE1000_DAEMON_REQUEST_MS` | `1900000` | Node-side per-request ceiling: if no matching response arrives, the request is failed. Set comfortably above the daemon's own ~180 s ceiling so it never pre-empts a legitimately long call. `0` disables it. |
| `TE1000_DIALOG_WATCH` | on | `0` disables the daemon's internal modal-dialog watchdog. |
| `TE1000_DIALOG_AUTODISMISS` | on | `0` = detect + report dialogs only, never auto-click an allowlisted one. |
| `TE1000_DIALOG_GRACE_MS` | `4000` | How long a blocking dialog must persist before the daemon recycles its COM worker. |

**Read by the daemon:**

| Variable | Default | Purpose |
|---|---|---|
| `TE1000_MCP_SOLUTION_PATH` | unset | When multiple XAE instances are running, prefer the one whose open solution's full path matches this (otherwise the daemon prefers any instance with an open solution). |
| `TE1000_DAEMON_DEBUG` | unset | `1` enables a diagnostic log at `%TEMP%\te1000-daemon-<pipe>.log`. |
| `TE1000_DAEMON_LOG` | unset | Explicit path for the daemon diagnostic log (implies logging on, overrides the default location). |

> The daemon also accepts CLI flags (`--pipe`, `--no-watch`, `--no-autodismiss`,
> `--grace-ms`, `--allowlist`). The front sets these from the dialog-watch env vars above
> when it spawns the daemon — you normally don't pass them by hand.

## Quickstart

With XAE Shell open on your solution, an agent can drive a full configure → build loop.
A typical session (tool name + arguments shown):

```text
# 1. Confirm the server is attached and a solution is open
xae            action: "status"

# 2. Inspect the IO tree
tc_tree        action: "children"  path: "TIID^Device 2 (EtherCAT)"

# 3. Add a populated EtherCAT rack from its ESI (digital in/out + analog)
tc_ethercat    racks: [{
                 parent: "TIID^Device 2 (EtherCAT)^R01.Main.N01 (EK1200)",
                 modules: [{ type: "EL1008" }, { type: "EL2008" }, { type: "EL3064" }]
               }]
               save: true

# 4. Link a PLC input to a terminal channel
tc_link        action: "link"
               a: "TIPC^Cabsort Lite^Cabsort Lite Instance^PlcTask Inputs^MAIN.bStart"
               b: "TIID^Device 2 (EtherCAT)^Term 1^Channel 1^Input"

# 5. Build the solution
xae_build      action: "build"

# 6. (Optional, guarded) deploy to the live target
plc_download   confirm: "ALLOW_PLC_DOWNLOAD"
```

More end-to-end recipes — bulk linking, parameter edits via `set_xml`, POU authoring —
are in [`examples/`](examples/).

## Tool reference

Paths into the System Manager tree use `^` separators, e.g.
`TIID^Device 2 (EtherCAT)^Box 1^Term 5^Channel 1`. The leading token is the tree root
(`TIPC` = PLC, `TIID` = IO, `TINC` = NC, `TIRC` = realtime/license, …).

### Engineering & build

| Tool | Purpose | Key actions |
|---|---|---|
| `xae` | XAE shell & solution control | `status`, `open_solution`, `save_all`, `active_document`, `selected_items`, `error_list`, `clear_error_list`, `list_commands` |
| `xae_build` | Compile the active configuration | `clean`, `build`, `rebuild` |
| `xae_command` | Run a raw DTE command 🔒 | any command name (guarded) |

### System Manager tree, IO & linking

| Tool | Purpose | Key actions |
|---|---|---|
| `tc_tree` | Read/write any tree item (identity, XML params, rename, create, delete) | `get`, `children`, `exists`, `get_xml`, `set_xml`, `rename`, `create`, `delete`, `import`, `export`, `focus` — each with a `*_batch` form |
| `tc_ethercat` | Build fully-populated EtherCAT boxes from their ESI | `racks: [{ parent, modules: [{ type, name?, revision? }] }]` |
| `tc_link` | Link/unlink variables; verify existing links | `link`, `unlink`, `resolve`, `links`, `link_batch`, `unlink_batch` |
| `tc_system` | Target & rescan helpers | `get_netid`, `set_netid`, `errors`, `rescan_plc`, `scan_io_boxes` |
| `tc_mapping` | Bulk variable mapping | `produce`, `consume`, `clear` |
| `nc` | NC motion tree | `tasks`, `axes`, `axis` |

### PLC project & code

| Tool | Purpose | Key actions |
|---|---|---|
| `plc_project` | PLC project lifecycle | `create_from_template`, `open`, `info`, `set_boot_flags`, `generate_boot_project` 🔒, `online` 🔒, `plcopen_export`, `plcopen_import`, `save_as_library` |
| `plc_pou` | Author + surgically edit POUs/DUTs/GVLs (offline) | author (`create`, `import_template`), read (`get_decl`, `get_impl`, `outline`, `get_graphical`), surgical (`replace`, `replace_lines`, `insert`, `append`), discover (`tree`, `find`, `search`), lifecycle (`rename`, `move`, `delete` 🔒) |
| `plc_library` | Library refs / placeholders / repos | `list`, `scan`, `add_library`, `add_placeholder`, `set_resolution`, `freeze`, `remove_reference`, `install_library` 🔒, … |
| `plc_download` | Deploy the active PLC project 🔒 | boot-project (default) or legacy command route |
| `plc_session` | Online-session control via UI Automation | `status`, `logout` 🔒 |

### Realtime, fieldbus & platform

| Tool | Purpose | Key actions |
|---|---|---|
| `tc_task` | RT tasks / cores / linked tasks | `list`, `get`, `create`, `set_params`, `add_image_var`, `get/set_rt_settings`, `bind_cpu`, `get/set_linked_task` |
| `tc_route` | ADS routes | `list`, `broadcast_search`, `search_host`, `add_route` 🔒, `add_project_route` 🔒 |
| `tc_settings` | Engineering settings & archives | `get/set_silent_mode`, `get/set_target_platform`, `save_solution_archive`, `save_plc_archive`, `get/set_independent_file`, `get/set_disabled` |
| `tc_fieldbus` | Non-EtherCAT fieldbuses (PROFINET/PROFIBUS/CANopen/DeviceNet/EAP) | `create_device`, `create_gsd_box`, `add_netvar`, `set_station_address`, `import_dbc`, `get/set_xml` |
| `tc_module` | TcCOM module objects | `list`, `create`, `get/set_xml`, `enable_symbols`, `set_context` 🔒 |
| `tc_cpp` | TwinCAT C++ projects/modules | `create_project`, `create_module`, `tmc_codegen`, `set_props`, `build`, `publish` 🔒 |
| `tc_measurement` | Scope + Analytics (TIAN) | `scope_create`, `scope_record` 🔒, `analytics_create`, `logger_create`, `stream_create`, … |
| `tc_license` | TwinCAT licensing | `list`, `add`, `activate_response` 🔒 |
| `tc_variant` | Project variant management | `get_config`, `get_current`, `set_config`, `select`, `enable`, `disable` |

### Runtime (guarded)

| Tool | Purpose |
|---|---|
| `twincat_activate_configuration` 🔒 | Activate the configuration on the target |
| `twincat_restart_runtime` 🔒 | Start/restart the TwinCAT runtime |

🔒 = confirmation-gated. See [Safety & guards](#safety--guards). Full action signatures,
batch semantics, and return shapes are documented in **[docs/tools.md](docs/tools.md)**.

## Safety & guards

The server **never auto-activates, auto-restarts, or auto-deploys**. Any action that
changes the live target, deletes a node, or alters licensing is blocked unless you pass
the matching `confirm` token:

| Confirm token | Unlocks |
|---|---|
| `ALLOW_TWINCAT_ACTIVATE` | `twincat_activate_configuration` |
| `ALLOW_TWINCAT_RESTART` | `twincat_restart_runtime` |
| `ALLOW_PLC_DOWNLOAD` | `plc_download`, `plc_project` boot/online |
| `ALLOW_XAE_COMMAND_EXEC` | `xae_command` |
| `ALLOW_PLC_LOGOUT` | `plc_session logout` |
| `ALLOW_TWINCAT_DELETE` | node/object deletes (or use `dryRun: true` to preview) |
| `ALLOW_PLC_LIBRARY_REPO` | machine-wide library repository administration |
| `ALLOW_TWINCAT_ROUTE_WRITE` | ADS route writes |
| `ALLOW_TWINCAT_MODULE_CONTEXT` | TcCOM context changes |
| `ALLOW_CPP_PUBLISH` | C++ driver publish |
| `ALLOW_MEASUREMENT_RECORD` | live scope acquisition |
| `ALLOW_LICENSE_ACTIVATE` | license activation |

**Safety project policy.** Nothing in this toolchain writes toward the TwinSAFE safety
project. Every authoring tool refuses safety-rooted (`TISC`) paths via an internal guard.
Safety remains read-only/diagnostic.

## Reliability: dialog watchdog & PLC session control

A synchronous DTE/COM call blocks inside XAE's modal message loop if XAE raises a modal
dialog (save-changes, "file changed externally", activate confirm, license prompt) — which
would hang the MCP call and the calling agent indefinitely.

- **Dialog watchdog.** This runs as an **internal thread** of the daemon
  (`DialogWatcher.cs`) that polls (~750 ms) for an application-modal dialog owned by the XAE
  process. It detects application-modal dialogs owned by XAE and either
  **auto-dismisses** them (if they match a rule in `dialog-allowlist.json`) or **reports** the
  dialog's title, body, and buttons back to the agent and abandons the call. If a
  non-allowlisted modal persists past `TE1000_DIALOG_GRACE_MS`, the daemon recycles its COM
  worker thread (re-acquiring the session on a fresh STA thread) **without** killing the
  daemon, so subsequent calls recover once the dialog is cleared. Detection is dialog-driven,
  not a wall-clock timeout, so long legitimate builds are never killed. The allowlist ships
  minimal and must never auto-answer Activate / Run-mode / restart / download / safety prompts.
- **Interactive resolution.** When a dialog is *not* in the allowlist, the reported error tells
  the agent to **ask the user** which button to press (and whether to remember it), then call
  **`xae dialog_resolve {button, remember?}`**. That action clicks the chosen button on the live
  dialog; with `remember:true` it appends an auto-dismiss rule to `dialog-allowlist.json` and
  hot-applies it to the running watcher (no restart). Destructive prompts (activate / run-mode /
  restart / download / boot project / TwinSAFE / safety) are **refused for auto-remember** — the
  one-time chosen click still happens, but no rule is persisted (`rememberRefused` is reported).
  Use `xae dialog_probe` (read-only) to inspect the current dialog first.
- **PLC session control** (`powershell/plc-session.ps1`) uses UI Automation to read and toggle
  the Login/Logout state (the DTE Login/Logout commands are unreachable on the 64-bit shell).
  `plc_download` auto-logs-out first (by default) so deferred source edits compile before the
  boot project is generated. It never logs back in.

Full details: **[docs/operations.md](docs/operations.md)**.

## Troubleshooting

- **`Te1000Daemon.exe not found`** — build it: `daemon\build.ps1`. The front cannot serve
  calls until the daemon is built.
- **Build fails on `TCatSysManagerLib`** — the DLL wasn't found at the probed TwinCAT paths.
  Edit the `<HintPath>` in `daemon/Te1000Daemon.csproj` to your install and rebuild.
- **Rebuild fails with the exe locked** — a daemon is still running. Stop it first:
  `Get-Process Te1000Daemon | Stop-Process`, then rebuild.
- **Daemon won't start / stale behavior** — kill it (above) and let the front re-spawn a fresh
  one on the next call. Enable `TE1000_DAEMON_DEBUG=1` to capture
  `%TEMP%\te1000-daemon-<pipe>.log`.
- **Wrong XAE instance picked** (several open) — set `TE1000_MCP_SOLUTION_PATH` to the
  solution's full path to pin the daemon to that instance.
- **A modal dialog is blocking calls** — clear it on the machine, or add a rule to
  `dialog-allowlist.json` (never for Activate / restart / download / safety prompts). The
  daemon picks up the allowlist on start.

## Examples

The [`examples/`](examples/) directory contains:

- [`mcp-config.json`](examples/mcp-config.json) — a drop-in client configuration.
- [`README.md`](examples/README.md) — copy-pasteable recipes: building an EtherCAT rack,
  bulk-linking IO, editing terminal parameters via `set_xml`, authoring a POU, and a safe
  build → activate → download flow.

## Documentation

| Document | What's in it |
|---|---|
| [docs/architecture.md](docs/architecture.md) | The Node-front + persistent C#/.NET daemon design end to end — pipe protocol, COM session, caching, edit-watching |
| [docs/tools.md](docs/tools.md) | Complete tool & action reference — signatures, batch semantics, return shapes |
| [docs/operations.md](docs/operations.md) | Dialog watchdog, PLC session control, and the safety/guard model in depth |
| [docs/automation-interface.md](docs/automation-interface.md) | Survey of the full TE1000 Automation Interface surface (the menu these tools are carved from) |
| [docs/csharp-daemon-coverage.md](docs/csharp-daemon-coverage.md) | The 164-action port coverage checklist (bridge action → C# handler) |
| [docs/csharp-daemon-validation.md](docs/csharp-daemon-validation.md) | Build, cut-over, and live-XAE smoke-test guide for the daemon |
| [docs/notes.md](docs/notes.md) | Running engineering notes / backlog discovered on real projects |
| [CHANGELOG.md](CHANGELOG.md) | Version history |

## Contributing

Contributions are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md) for the architecture,
the daemon build/dev loop, the action-handler contract, and the safety rules every change
must respect. In short:

```powershell
npm run check                                          # node --check index.js — syntax-validate the front
node daemon\test-ping.js                               # daemon process + pipe + JSON round-trip (no XAE)
powershell -ExecutionPolicy Bypass -File daemon\build.ps1   # rebuild the daemon after a C# change
```

## License

[MIT](LICENSE) © Edge Automation.

## Legal & trademarks

This is an **independent, third-party project**. It is **not affiliated with, endorsed by,
sponsored by, or supported by Beckhoff Automation GmbH & Co. KG**.

All product names, logos, and brands are the property of their respective owners:

- **Beckhoff®**, **TwinCAT®**, **TE1000**, and **XAE Shell** are trademarks or registered
  trademarks of **Beckhoff Automation GmbH & Co. KG**.
- **EtherCAT®** is a registered trademark and patented technology, licensed by
  **Beckhoff Automation GmbH, Germany**.

These names are used for identification and descriptive purposes only; their use does not
imply any affiliation with or endorsement by the trademark holders.

This project does **not** include, bundle, or redistribute any Beckhoff software. It automates
a separately installed and licensed TwinCAT 3 / TE1000 environment that you must obtain from
Beckhoff yourself. **You are responsible** for complying with all applicable Beckhoff license
terms and for any action this tool performs against your engineering or runtime systems.

The software is provided **"AS IS"**, without warranty of any kind, under the [MIT License](LICENSE).
See [NOTICE](NOTICE) for the full attributions.
