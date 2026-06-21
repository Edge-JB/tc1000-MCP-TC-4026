# te1000-mcp

MCP server for Beckhoff TwinCAT XAE / TE1000 Automation Interface.

This server uses the locally verified TwinCAT XAE Shell COM ProgID and calls it through 32-bit PowerShell, which matches Beckhoff's TE1000 requirements.

## What It Can Do

- attach to a running XAE Shell instance
- open a solution in XAE Shell
- list and execute XAE/DTE commands
- inspect the active document and selected items
- read the current Error List when available
- clear the visible Error List
- inspect TwinCAT tree items
- list tree children
- export and import tree item XML with `ProduceXml` / `ConsumeXml`
- create, import, export, and delete TwinCAT child items
- link and unlink TwinCAT variables
- get and set the target NetId
- trigger PLC rescans and I/O box scans
- inspect NC tasks and axes
- save the active solution
- clean, build, and rebuild the active solution configuration
- PLC login, download, and logout through XAE commands
- activate configuration
- start or restart the TwinCAT runtime

## v2 Tool Surface (2026-06-11)

The MCP surface was consolidated for agent-context efficiency: 36 tools -> 10,
grouped by noun with `action` enums, compact outputs (raw XML, pruned compact
JSON). The PowerShell bridge is unchanged and still answers the original
fine-grained action names; `index.js` maps onto them (the original v1 tool
surface is preserved in this repo's git history). Old tool names appearing later in this README map as:
`twincat_*_tree_item*`/`twincat_*_child` -> `tc_tree`, `twincat_link/unlink/
resolve_variable*` -> `tc_link`, netid/errors/rescan/scan tools -> `tc_system`,
`nc_*` -> `nc`, `xae_solution_build` -> `xae_build`, `xae_execute_command` ->
`xae_command`, remaining `xae_*` -> `xae`.

- `xae` — status / open_solution / save_all / active_document / selected_items / error_list / clear_error_list / list_commands
- `xae_build` — clean / build / rebuild
- `xae_command` — raw DTE command (guarded)
- `tc_tree` — get / children / exists / exists_batch / get_batch / get_xml / set_xml / set_xml_batch / rename / rename_batch / create / create_batch / delete / delete_batch / import / export / focus
  - `set_xml` returns a compact `{ treePath }` by default; pass `returnXml:true` to also echo the produced XML (with the embedded `TreeImageData16x14` bitmap stripped).
  - **Renaming tree items:** `tc_tree action:rename path:<treePath> newName:<name>` renames an existing item (e.g. an EtherCAT box/terminal) and keeps IO links intact, returning a compact `{ treePath, newName, newPath }`. Do **not** use `set_xml`/`newName` probing for this.
  - **Batch rename:** `tc_tree action:rename_batch path:<basePath> renames:[{name,newName},...]` renames many items under one parent in a single process / DTE attach. Each entry uses `name` (joined to `path` as `"<basePath>^<name>"`) or an explicit `path` (used as-is), plus `newName`. Renames run **sequentially in the given order** and one failure never aborts the rest. Returns a compact roll-up `{ parent, count, succeeded, failed, results }` where each `results[]` entry is `{ name, newName, ok }` (plus `error` on failure) — no per-item XML or path. Example:

    ```
    tc_tree action:rename_batch
      path:"TIID^Device 2 (EtherCAT)^R01.Main.N01 (EK1200)^R06.LDR.N05 (CPX-AP-A-EC-M12)"
      renames:[
        { name:"Module 3 (CPX-AP-A-4IOL-M12 Variant 8)", newName:"Module 3 (Gripper IO-Link)" },
        { name:"Module 4 (CPX-AP-A-4DI-M8-3P)",          newName:"Module 4 (Presence DI)" }
      ]
    ```
  - **Batch set_xml (ConsumeXml):** `tc_tree action:set_xml_batch items:[{path,xml},...]` pushes XML (parameter) changes into many tree items in a single process / DTE attach. Each entry needs an explicit `path` (used as-is) and an `xml` string. Items are consumed **sequentially in the given order** and one failure never aborts the rest. An entry with a missing/blank `path` or `xml` is recorded as `{ path, ok:false, error:'entry needs path and xml' }` and skipped. Returns a compact roll-up `{ count, succeeded, failed, results }` where each `results[]` entry is `{ path, ok }` (plus `error` on failure). Pass `returnXml:true` to also add `xml` (TreeImage-stripped produced XML) to each successful entry. Example:

    ```
    tc_tree action:set_xml_batch
      items:[
        { path:"TIID^Device 2 (EtherCAT)^Box 1^Term 5^Channel 1^PAI Settings",
          xml:"<TreeItem>...</TreeItem>" },
        { path:"TIID^Device 2 (EtherCAT)^Box 1^Term 6^Channel 1^PAI Settings",
          xml:"<TreeItem>...</TreeItem>" }
      ]
    ```
  - **Batch create:** `tc_tree action:create_batch creates:[{parent,name,subType,before?,createInfo?},...]` scaffolds many child nodes in a single process / DTE attach (one attach). Each entry needs `parent` (the `^`-path of the parent), `name`, and a numeric `subType` (plus optional `before` sibling name and `createInfo`). Children are created **sequentially in the given order** and one failure never aborts the rest. An entry missing/blank `parent`/`name`/`subType` is recorded as `{ parent, name, ok:false, error:'entry needs parent, name, subType' }` and skipped. Returns a compact roll-up `{ count, succeeded, failed, results }` where each successful entry is `{ parent, ok:true, child }` (`child` = the `Convert-TreeItem` shape) and a failure is `{ parent, name, ok:false, error }`. Example:

    ```
    tc_tree action:create_batch
      creates:[
        { parent:"TIID^Device 2 (EtherCAT)", name:"Box 7", subType:9099 },
        { parent:"TIID^Device 2 (EtherCAT)", name:"Box 8", subType:9099 }
      ]
    ```
  - **Batch delete:** `tc_tree action:delete_batch deletes:[{parent,name},...]` tears down many child nodes in a single process / DTE attach (one attach). Each entry needs `parent` (the `^`-path of the parent) and `name`. Because each entry addresses its child by **name** under a freshly-looked-up parent, deletes are order-independent; they run sequentially in the given order and one failure never aborts the rest. An entry missing/blank `parent`/`name` is recorded as `{ parent, name, ok:false, error:'entry needs parent, name' }` and skipped. Returns a compact roll-up `{ count, succeeded, failed, results }` where each entry is `{ parent, name, ok }` (plus `error` on failure). Example:

    ```
    tc_tree action:delete_batch
      deletes:[
        { parent:"TIID^Device 2 (EtherCAT)", name:"Box 7" },
        { parent:"TIID^Device 2 (EtherCAT)", name:"Box 8" }
      ]
    ```
  - **Batch read/verify:** `tc_tree action:exists_batch paths:[...]` checks existence for many `^`-paths, and `action:get_batch paths:[...]` looks up their identity (name / pathName / itemType / childCount), each in a **single** process / DTE attach — ideal for verifying many paths after a bulk rename / link / create. Paths run **sequentially in the given order** and a bad path never aborts the rest. `exists_batch` returns `{ count, found, missing, results }` where each entry is `{ path, exists }` (plus `error` if the check threw); `get_batch` returns `{ count, succeeded, failed, results }` where each found entry is the `Convert-TreeItem` shape (`name`, `pathName`, `itemType`, `subType`, `childCount`) plus `path` + `ok:true`, and a miss is `{ path, ok:false, error }`. Examples:

    ```
    tc_tree action:exists_batch
      paths:[
        "TIID^Device 2 (EtherCAT)^Term 1 (EK1200)",
        "TIID^Device 2 (EtherCAT)^Term 2 (EL1008)"
      ]

    tc_tree action:get_batch
      paths:[
        "TIID^Device 2 (EtherCAT)^Term 1 (EK1200)",
        "TIPC^Cabsort Lite^Cabsort Lite Instance"
      ]
    ```
  - `children` returns the standard child tree items (each tagged `kind:"child"`) **and** any addressable coupler sub-modules that live in the box's `ProduceXml()` `<Slot><Module>` collection (CPX-AP / Festo AP modules — IO-Link masters, valve terminals, DI/DO blocks) but are not in the standard `ChildCount`/`Child()` collection. Those are tagged `kind:"module"` and are resolvable by their full `^`-path. `childCount` equals the total number of entries returned (standard children + modules). The module scan is fully defensive — a malformed box or unresolvable module never breaks a normal `children` call.
- `tc_link` — link / unlink / resolve / link_batch / unlink_batch
  - **Batch link/unlink:** `tc_link action:link_batch links:[{a,b},...]` links many variable pairs (and `action:unlink_batch links:[{a,b?},...]` unlinks them — `b` optional, `a` alone removes all of `a`'s links) in a single process / DTE attach. Pairs run **sequentially in the given order** and one failure never aborts the rest. Returns a verbose per-entry roll-up `{ count, succeeded, failed, results }`; each `link_batch` `results[]` entry is `{ a, b, resolvedA, resolvedB, ok }` (the resolved `^`-path forms each side was actually linked through), or `{ a, b, ok:false, error }` on failure. Example:

    ```
    tc_link action:link_batch
      links:[
        { a:"TIPC^Cabsort Lite^Cabsort Lite Instance^PlcTask Inputs^MAIN.bStart",
          b:"TIID^Device 2 (EtherCAT)^Term 1^Channel 1^Input" },
        { a:"TIPC^Cabsort Lite^Cabsort Lite Instance^PlcTask Outputs^MAIN.bRun",
          b:"TIID^Device 2 (EtherCAT)^Term 2^Channel 1^Output" }
      ]
    ```
- `tc_system` — get_netid / set_netid / errors / rescan_plc / scan_io_boxes
- `nc` — tasks / axes / axis
- `plc_download` — bootproject (default, headless ITcPlcProject deploy) or legacy command route
- `twincat_activate_configuration`, `twincat_restart_runtime`

`plc_login`/`plc_logout` were dropped from the surface (the 64-bit shell's DTE
exposes no window automation, so they never worked here); use `xae_command`
with `OtherContextMenus.PlcProject.Login`/`.Logout` on shells where it does.
`progId` is no longer a tool parameter — set env `TE1000_PROGID` to override
the default `TcXaeShell.DTE.17.0`.

High-impact tools are guarded:

- `twincat_activate_configuration` requires `confirm="ALLOW_TWINCAT_ACTIVATE"`
- `twincat_restart_runtime` requires `confirm="ALLOW_TWINCAT_RESTART"`
- `xae_command` requires `confirm="ALLOW_XAE_COMMAND_EXEC"`

## Requirements

- Windows
- Beckhoff TwinCAT XAE Shell / XAE installed
- TE1000 Automation Interface available through `TcXaeShell.DTE.15.0`
- 32-bit Windows PowerShell present at:
  `C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe`
- Node.js 20+

## Install

```powershell
git clone https://github.com/Edge-JB/tc1000-MCP-TC-4026.git
cd tc1000-MCP-TC-4026
npm install
```

## Run

```powershell
node index.js
```

The server speaks MCP over stdio, so it is normally launched by an MCP client
(see below) rather than run by hand. Running it directly just prints
`te1000-mcp server running on stdio` and waits for a client on stdin.

## MCP Client Config Example

Point your MCP client at the absolute path of `index.js` in your clone:

```json
{
  "mcpServers": {
    "te1000": {
      "command": "node",
      "args": [
        "C:\\path\\to\\tc1000-MCP-TC-4026\\index.js"
      ]
    }
  }
}
```

## Tool Notes

`twincat_set_tree_item_xml` is the main path for IO edits. Typical workflow:

1. call `twincat_get_tree_item_xml`
2. edit the returned XML
3. call `twincat_set_tree_item_xml`
4. call `xae_save_all`
5. optionally call `twincat_activate_configuration`

Example TwinCAT tree path:

```text
TIID^Device 1 (EtherCAT)^Term 1 (EK1100)
```

The exact path depends on the project tree in the active XAE session.

Useful discovery helpers:

- `xae_list_commands`
- `xae_get_selected_items`
- `xae_get_error_list`
- `xae_clear_error_list`
- `twincat_test_item_path`
- `twincat_resolve_variable_path`
- `nc_list_tasks`
- `nc_list_axes`

### PLC Variable Paths

PLC struct variables are not always exposed to `ITcSysManager::LinkVariables` with IEC dot syntax all the way down. The top-level PLC variable can use dot syntax after the POU name, but child fields under a mapped struct may be XAE tree subitems and require `^`.

Example:

```text
TIPC^MyPlc^MyPlc Instance^PlcTask Inputs^MAIN.stSlot02_DI^In00
```

not:

```text
TIPC^MyPlc^MyPlc Instance^PlcTask Inputs^MAIN.stSlot02_DI.In00
```

Use `twincat_resolve_variable_path` to test a candidate path and see the valid alternatives. `twincat_link_variables` also resolves these alternatives by default before linking.

## Modal-dialog watchdog

A bridge call drives XAE through a **synchronous DTE/COM call**. If that call makes
XAE raise a *modal* dialog (save-changes, "file changed externally", activate
confirm, a license prompt, etc.), the COM call blocks inside XAE's modal message
loop until a human clicks the dialog — so the MCP call, and the calling agent,
hang indefinitely with no idea why.

`powershell/dialog-watch.ps1` closes that gap. It runs as a short-lived process
alongside every bridge call and, each poll, looks for an **application-modal**
dialog owned by the XAE process (precise signal: a visible/enabled window whose
*owner* window is disabled — docked tool windows and non-modal popups don't
qualify). On finding one it either:

- **auto-dismisses** it — if the dialog matches a rule in
  `powershell/dialog-allowlist.json`, the watcher clicks that rule's button,
  releasing the blocked COM call so the operation completes normally; or
- **reports** it — for any dialog with no matching rule, `index.js` waits a short
  grace period (`TE1000_DIALOG_GRACE_MS`, default 4000 ms), then abandons the
  bridge call and returns an error containing the dialog's **title, body text,
  and buttons**, so the agent knows exactly what is blocking it. The dialog is
  left open on the machine for a human to clear; the operation result is
  indeterminate.

Detection is dialog-driven, **not** a wall-clock timeout, so long legitimate
operations (a multi-minute build) are never killed just for taking a while.

### Pre-flight gate

The watcher above catches dialogs that appear *during* a call. But a dialog that
is **already open before** the command (you edited a file outside XAE, the target
connection dropped, an earlier prompt was never cleared) corrupts the next
command's result — e.g. a build returns a bogus *"No solution is open"* — and on
the old code simply hung. So before every bridge call, `index.js` runs a one-shot
pre-flight probe: it auto-dismisses an allowlisted dialog, and otherwise
**refuses to run the command**, returning the dialog's title/text/buttons instead
of firing into a poisoned XAE.

### Allowlist (`powershell/dialog-allowlist.json`)

Ships with one rule — the *"file has been changed outside the environment →
reload?"* prompt is auto-answered **Yes**, so an agent's own source edits load
into XAE. Each rule: `match` (regex on the title, required), optional `textMatch`
(regex on the body), and `button` (exact label to click). First matching rule
wins; unmatched dialogs are reported, never clicked.

> **Live cell.** Only add dialogs that are safe to auto-answer unattended. Never
> allowlist Activate Configuration / Run-mode / restart / download / safety
> prompts — those must stay human-confirmed. Prefer the non-destructive button.

### Env toggles

| Var | Default | Effect |
|-----|---------|--------|
| `TE1000_DIALOG_WATCH` | on | `0` disables the watchdog entirely |
| `TE1000_DIALOG_AUTODISMISS` | on | `0` = detect + report only, never auto-click |
| `TE1000_DIALOG_GRACE_MS` | `4000` | how long a blocking dialog must persist before the call is abandoned |
| `TE1000_BRIDGE_TIMEOUT_MS` | `0` (off) | optional wall-clock backstop for non-dialog hangs |

Run `dialog-watch.ps1 -Mode probe` at any time to see the current dialog (if any)
as JSON — useful for discovering the exact `title`/`button` strings for a new
allowlist rule.

## PLC session control (auto-logout)

While the IDE is **logged in** to the PLC, TwinCAT will not load source edited
outside the editor — it defers it ("*File will be loaded after logout*"). So an
agent that edits a POU mid-session can't get that change compiled or deployed
until a logout happens. On the 64-bit TcXaeShell the DTE Login/Logout commands
are unreachable (they never report `IsAvailable=true` and have no key binding),
which is why they were dropped from the tool surface.

`powershell/plc-session.ps1` works around this with **UI Automation**: the IDE's
Login/Logout toolbar buttons are reachable even when the DTE commands are not.
Their enabled state is also a reliable session detector (Logout enabled ⇒ logged
in; the two flip on logout).

- **`plc_session` tool** — `action: "status"` (read-only `{ loggedIn }`) or
  `action: "logout"` (invoke the Logout button; guarded with
  `confirm="ALLOW_PLC_LOGOUT"`). It **never invokes Login** — there is no
  auto-login by design.
- **`plc_download` auto-logout** — with `autoLogout` (default `true`), the deploy
  first checks the session and, if logged in, logs out so any deferred source
  edits are applied before the boot project is generated. It never logs back in;
  pass `autoLogout: false` to skip.

## Build Support

Use `xae_solution_build` with:

- `action: "clean"`
- `action: "build"`
- `action: "rebuild"`

This runs through the Visual Studio `SolutionBuild` automation layer, which is the same side Beckhoff points to when PLC compilation is needed through automation.

## PLC Session Commands

The server exposes these non-ADS PLC actions through XAE command execution:

- `plc_login`
- `plc_download`
- `plc_logout`

Current command mappings found in the live XAE shell on this machine:

- login: `OtherContextMenus.PlcProject.Login`
- download: `PLC.Downloadnone`
- logout: `OtherContextMenus.PlcProject.Logout`

These depend on XAE context. If a command is unavailable because the wrong node/editor is active, pass a different `commandName` override or change the active selection in XAE.

## Tree Manipulation

The server exposes TwinCAT tree operations through `ITcSmTreeItem`:

- `twincat_create_child`
- `twincat_delete_child`
- `twincat_import_child`
- `twincat_export_child`

These are powerful but parent-type-specific. `subType` and import compatibility must match what the parent node accepts.

## Targeting And Rescan

- `twincat_get_target_netid`
- `twincat_set_target_netid`
- `twincat_rescan_plc_project`
- `twincat_scan_io_boxes`

`twincat_rescan_plc_project` defaults to `TIPC`.

`twincat_scan_io_boxes` should target a device node such as:

```text
TIID^Device 1 (EtherCAT)
```

## NC Helpers

The server includes NC convenience tools:

- `nc_list_tasks`
- `nc_list_axes`
- `nc_get_axis_info`

A typical NC root pattern is:

```text
TINC^NC-Task 1 SAF^Axes^Axis 1
```

TwinCAT quirk:

- some container/root nodes such as `TIID` and major EtherCAT boxes may return descendant collections rather than a single scalar item payload through COM
- leaf nodes and specific IO terminals are the safer targets for `ProduceXml` / `ConsumeXml`
- if a broad path returns too much data, step down one level and target the exact terminal, box, or variable node
- `xae_focus_tree_item` is best effort only; this environment exposes expand/focus behavior through the backing VS project item, but not a reliable true selection API
- `xae_get_error_list` uses typed `EnvDTE80` interop loaded from the XAE `PublicAssemblies` folder because late-bound `ToolWindows.ErrorList` was returning `null` in this shell
- `xae_clear_error_list` clears the visible Visual Studio/XAE Error List through `OtherContextMenus.ErrorList.Clear`, which is different from `TwinCAT.ClearErrorList`

## Safety

This server intentionally does not auto-activate or auto-restart TwinCAT.

If you expose it to an agent, keep the confirmation guards in place unless you are willing to accept live target changes.

The modal-dialog watchdog (above) is held to the same standard: its allowlist
ships empty, and you should never add rules for Activate Configuration,
Run-mode, restart, download, or safety prompts — those stay human-confirmed.

## License

[MIT](LICENSE).
