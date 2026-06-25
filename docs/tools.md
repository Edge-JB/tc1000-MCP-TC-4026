# Tool reference

Complete reference for the 25 tools `te1000-mcp` registers. For a high-level map and the
safety model, see the [README](../README.md). For the underlying API these tools are carved
from, see [automation-interface.md](automation-interface.md).

All tree paths use `^` separators and a root token:

| Root | Domain |
|---|---|
| `TIPC` | PLC projects |
| `TIID` | IO / fieldbus devices |
| `TINC` | NC motion |
| `TIRC` | Realtime / license |
| `TIRR` | ADS routes |
| `TIAN` | Measurement / Analytics |
| `TISC` | Safety — **refused** by all authoring tools |

> 🔒 marks a confirmation-gated action. The required `confirm` token is listed with each one
> and summarised in the [README's Safety & guards](../README.md#safety--guards) section.

---

## Batch-first principle

When a job touches more than one item, use the matching `*_batch` action. Each batch runs
N operations in **one** DTE attach — versus a process spawn + COM attach per single call —
and returns a compact, continue-on-error roll-up:

```jsonc
{ "count": 3, "succeeded": 2, "failed": 1,
  "results": [ { "...": "...", "ok": true }, { "...": "...", "ok": false, "error": "…" } ] }
```

One failed entry never aborts the rest. Mutating batches (`set_xml_batch`, `rename_batch`,
`create_batch`, `delete_batch`, `link_batch`, `unlink_batch`) accept `save: true` to save the
solution **once** after the batch, adding a `saved` boolean to the roll-up.

| Job | One item | Many items |
|---|---|---|
| Look up identity | `tc_tree get` | `tc_tree get_batch` (`paths: [...]`) |
| Test a path exists | `tc_tree exists` | `tc_tree exists_batch` (`paths: [...]`) |
| Push params (ConsumeXml) | `tc_tree set_xml` | `tc_tree set_xml_batch` (`items: [{path, xml}]`) |
| Rename | `tc_tree rename` | `tc_tree rename_batch` (`renames: [{name\|path, newName}]`) |
| Create child node | `tc_tree create` | `tc_tree create_batch` (`creates: [{parent, name, subType}]`) |
| Delete child node | `tc_tree delete` | `tc_tree delete_batch` (`deletes: [{parent, name}]`) |
| Link variables | `tc_link link` | `tc_link link_batch` (`links: [{a, b}]`) |
| Unlink variables | `tc_link unlink` | `tc_link unlink_batch` (`links: [{a, b?}]`) |

No batch form (inherently single / read-all): `children`, `get_xml`, `import`, `export`,
`focus`, `tc_link resolve`, `tc_link links`.

---

## Engineering & build

### `xae`
XAE shell and solution control.

- `status` — is the server attached and a solution open.
- `open_solution` (`solutionPath`) — open a solution. `closeExisting: true` closes the current
  one first (save-first by default; add `discardChanges: true` to close **without** saving).
- `save_all`, `active_document`, `selected_items`, `error_list`, `clear_error_list`.
- `list_commands` (`filter` regex, `limit`) — discover available DTE command names.

### `xae_build`
Compile the active configuration through the DTE `SolutionBuild` automation layer (the same
path Beckhoff uses for PLC compilation via automation).

- `clean` · `build` · `rebuild` — waits for completion by default (`waitForFinish`, `timeoutMs`).

> **Build ≠ activate ≠ download.** A green build only means the project *compiles*. It has no
> effect on the target runtime until you activate the configuration and/or download.

### `xae_command` 🔒 `ALLOW_XAE_COMMAND_EXEC`
Execute a raw XAE/DTE command by name (e.g. `View.SolutionExplorer`). Escape hatch for
commands without a dedicated tool; guarded because it is unconstrained.

---

## System Manager tree — `tc_tree`

Read and write any item in the System Manager tree.

- **Read identity** — `get` / `get_batch` → `{ name, pathName, itemType, subType, childCount }`.
- **Test existence** — `exists` / `exists_batch`.
- **Read XML** — `get_xml` returns the raw `ProduceXml()` blob (~15k tokens for an EtherCAT
  box). Pass `summary: true` for a compact identity + parsed slot-module list instead.
- **Write params** — `set_xml` / `set_xml_batch` push `ConsumeXml()` parameter changes. Compact
  return by default; `returnXml: true` echoes the produced XML (TreeImage bitmap stripped).
- **Rename** — `rename` / `rename_batch` keep IO links intact. Use this, not `set_xml` probing.
- **Create** — `create` / `create_batch`. See the ghost guard below.
- **Delete** — `delete` / `delete_batch` 🔒. Guarded: pass `dryRun: true` to preview which
  children exist, or `confirm: "ALLOW_TWINCAT_DELETE"` to actually delete.
- **Read-all** — `children` (standard child items **plus** addressable CPX-AP/Festo coupler
  sub-modules tagged `kind: "module"`), `import` (`.xti`), `export`, `focus` (Solution Explorer).

### Create result validation (ghost guard)

`ITcSmTreeItem.CreateChild(name, subType, before, createInfo)` can return SUCCESS while
inserting a malformed, blank-named "ghost" child when the `subType`/`createInfo` is not valid
for that parent. Both `create` and `create_batch` validate the returned child immediately and
treat the create as **failed** if the name is blank, doesn't match the request, or the child
landed under the wrong parent. A stray child is cleaned up (best-effort `DeleteChild`); `create`
then throws and `create_batch` records `ok: false`. A ghost is never reported as success.

To add EtherCAT terminals/boxes, prefer **`tc_ethercat`** (below) — it uses the correct
ESI-based route.

---

## Native EtherCAT builder — `tc_ethercat`

Builds **fully-populated** EtherCAT boxes (terminals/couplers) by the GUI's own "Add Box"
route: `CreateChild(name, 9099, before, "<productString>")`, where the 4th argument is the
plain product string (e.g. `"EL1008"`), **not** identity XML. TwinCAT expands the box from its
own ESI, so the result is non-hollow for any device class — digital, analog (in and out),
IO-Link, mailbox, DC, couplers — with correct identity, SyncManagers, FMMUs, and PDOs.

One unified shape — a single box, a batch, and a full rack are the same operation:

```jsonc
{
  "racks": [
    {
      "parent": "TIID^Device 2 (EtherCAT)^R01.Main.N01 (EK1200)",
      "modules": [
        { "type": "EL1008", "name": "R01.Main.N15 (EL1008)" },
        { "type": "EL2008" },
        { "type": "EL3064" },
        { "type": "EL4004" },
        { "type": "EL6224" }
      ]
    }
  ],
  "save": true
}
```

- Each rack's `parent` is the coupler/master tree path; `modules[]` are created in array order
  (left-to-right terminal order). Terminals must go under a **coupler** (e.g. `EK1200`/`EK1100`),
  not directly under the EtherCAT device.
- `name` defaults to `type`; `before` inserts ahead of a named sibling.
- **Revision pinning** — a bare `type` selects the latest ESI revision. Pin an older one with
  `revision: "<pppp>-<rrrr>"` (decimal product-variant and revision; e.g. `"0000-0017"`), or
  pass the full pinned string `"EL1008-0000-0017"` verbatim.
- Modules are processed sequentially, continue-on-error. Returns a flat roll-up across all racks:
  `{ count, succeeded, failed, results: [{ parent, type, name, ok, error?, path?, createInfo? }] }`.
  There is no hand-rolled `.xti` fallback — an unknown product string is a clean `ok: false`.

---

## Variable linking — `tc_link`

- `link` / `link_batch` — link producer↔consumer variables. Dot-form PLC subfields auto-resolve
  to XAE `^` subitem form. `link_batch` returns `{ a, b, resolvedA, resolvedB, ok }` per pair.
- `unlink` / `unlink_batch` — `b` optional; `a` alone removes all of `a`'s links.
- `resolve` — test a candidate variable path and see valid alternatives.
- `links` (`a: <item path>`) — read what an item is currently linked to (the discover → act →
  **verify** loop). Returns `{ path, count, links: [{ varA, varB, offsA?, offsB?, size? }] }`.
  Querying a leaf variable returns its `<LinkedWith>` endpoints directly; querying a box/terminal
  walks descendant leaves and collects each one's links.

### PLC variable path quirk

Struct fields under a mapped PLC struct may be XAE tree sub-items requiring `^`, not IEC dot
syntax all the way down:

```text
TIPC^MyPlc^MyPlc Instance^PlcTask Inputs^MAIN.stSlot02_DI^In00     ✅
TIPC^MyPlc^MyPlc Instance^PlcTask Inputs^MAIN.stSlot02_DI.In00     ❌
```

Use `tc_link resolve` to test a candidate; `tc_link link` resolves alternatives before linking.

---

## Other tree, IO & motion tools

### `tc_system`
- `get_netid` / `set_netid` (`netId`) — target AMS NetId.
- `errors` — latest System Manager messages.
- `rescan_plc` (`path`, default `TIPC`) — rescan a PLC project.
- `scan_io_boxes` (`path` = IO device node, e.g. `TIID^Device 1 (EtherCAT)`).

### `tc_mapping`
Bulk variable mapping via `ProduceMappingInfo` / `ConsumeMappingInfo` / `ClearMappingInfo`:
`produce`, `consume`, `clear`.

### `nc`
NC motion tree: `tasks` (list under `TINC`), `axes` (`path` = task, default first), `axis`
(`path` = full axis path, returns info + children). Typical root: `TINC^NC-Task 1 SAF^Axes^Axis 1`.

---

## PLC project & code

### `plc_project`
PLC project lifecycle: `create_from_template`, `open`, `info`, `set_boot_flags`,
`generate_boot_project` 🔒, `online` 🔒 (Login/Start/Stop/Reset), `plcopen_export`,
`plcopen_import`, `save_as_library`. The two 🔒 actions touch the target runtime/boot dir and
require `confirm: "ALLOW_PLC_DOWNLOAD"`.

### `plc_pou`
Author and surgically edit PLC objects — **offline engineering only** (edits land in memory and
reach the target runtime only via a later guarded `plc_download` + restart). All write/rename/move/delete
paths refuse `TISC` (safety) paths.

- **Author** — `create`, `create_batch`, `import_template`, `create_folder`, `create_folder_batch`.
- **Read** — `get_decl`, `get_impl`, `get_document`, `get_graphical`, `outline`. `get_decl`/`get_impl`
  accept a `range: {start, end}` slice **or** `grep: {pattern, context}` so you read only the lines
  you need.
- **Inspect graphical code (read-only)** — `get_graphical` returns the `<Implementation>` network
  XML for LD/FBD/IL/SFC/CFC bodies (which have no authoritative text). Diagnostic only — graphical
  bodies are not text-editable here.
- **Whole-section write** — `set_decl`, `set_decl_batch`, `set_impl`, `set_impl_batch`, `set_document`.
- **Surgical edit (read-modify-write)** — `replace` (literal substring + `expectCount` gate),
  `replace_lines` (1-based inclusive span), `insert` (`at`/`after`/`before`), `insert_in_var_block`,
  `append`. These return **only the changed region ±2 context lines**, preserve CRLF/LF byte-for-byte,
  and fail without writing on non-unique/zero-match anchors. `validate: true` runs CheckAllObjects after.
- **Discover** — `tree` (recursive read-only walk, `typeFilter`/`depth`), `find` (resolve a `^`-path),
  `search` (project-wide grep over decl + ST impl).
- **Lifecycle** — `rename` (in place), `move` (reparent via export-import-delete), `delete` 🔒
  (`dryRun: true` to preview or `confirm: "ALLOW_TWINCAT_DELETE"`), `check_objects` (CheckAllObjects).

### `plc_library`
Library refs / placeholders / repos via `ITcPlcLibraryManager`: `list`, `scan`, `repos`,
`add_library`, `add_placeholder`, `set_resolution`, `freeze`, `remove_reference`,
`install_library`, `uninstall_library`, plus repository administration
(`insert_repository`, `remove_repository`, `move_repository`) 🔒 `ALLOW_PLC_LIBRARY_REPO`.

> `.plcproj` reference edits need a solution **close + reopen** in XAE to take effect.

### `plc_download` 🔒 `ALLOW_PLC_DOWNLOAD`
Deploy the active PLC project. `method: "bootproject"` (default, headless `ITcPlcProject`
boot-project deploy) or the legacy command route. With `autoLogout` (default `true`) it logs out
first so deferred source edits compile before the boot project is generated; it never logs back in.

### `plc_session`
Online-session control via UI Automation (DTE Login/Logout are unreachable on the 64-bit shell).
- `status` — read-only `{ loggedIn }`.
- `logout` 🔒 `ALLOW_PLC_LOGOUT` — invokes the Logout toolbar button. Never invokes Login.

---

## Realtime, fieldbus & platform

### `tc_task`
RT task / RT-core / linked-task config: `list`, `get`, `create`, `set_params`, `add_image_var`,
`get_rt_settings`, `set_rt_settings`, `bind_cpu`, `get_linked_task`, `set_linked_task`.

### `tc_route`
ADS routes via `TIRR`: `list`, `broadcast_search`, `search_host`, `add_route` 🔒, `add_project_route` 🔒.
Route writes require `confirm: "ALLOW_TWINCAT_ROUTE_WRITE"`.

### `tc_settings`
XAE engineering settings & packaging: `get_silent_mode`/`set_silent_mode`,
`get_target_platform`/`set_target_platform`, `save_solution_archive`, `save_plc_archive`,
`get_independent_file`/`set_independent_file`, `get_disabled`/`set_disabled`.

### `tc_fieldbus`
Non-EtherCAT fieldbuses (PROFINET / PROFIBUS / CANopen / DeviceNet / EAP): `create_device`,
`create_batch`, `list_resources`, `claim_resources`, `create_gsd_box`, `add_netvar`,
`set_station_address`, `import_dbc`, `get_xml`, `set_xml`. Refuses `TISC` paths.

### `tc_module`
TcCOM module objects: `list`, `create`, `get_xml`, `set_xml`, `enable_symbols`,
`set_context` 🔒 `ALLOW_TWINCAT_MODULE_CONTEXT`. Refuses `TISC` paths.

### `tc_cpp`
TwinCAT C++ projects/modules: `create_project`, `create_module`, `open`, `tmc_codegen`,
`set_props`, `build`, `publish` 🔒 `ALLOW_CPP_PUBLISH`. Refuses `TISC` paths.

### `tc_measurement`
Scope + Analytics (`TIAN`): `scope_create`, `scope_add_child`, `scope_rename`,
`scope_record` 🔒 `ALLOW_MEASUREMENT_RECORD`, `analytics_create`, `logger_create`,
`logger_delete` 🔒, `stream_create`, `stream_delete` 🔒. For raw `ProduceXml`/`ConsumeXml`
on a logger/stream node, use `tc_tree get_xml`/`set_xml`.

### `tc_license`
TwinCAT licensing on `TIRC^License`: `list`, `add`, `activate_response` 🔒 `ALLOW_LICENSE_ACTIVATE`.

### `tc_variant`
Project variant management via `iTcSysManager14` / `ITcSmTreeItem9`: `get_config`, `get_current`,
`set_config`, `select`, `disable`, `enable`. Refuses `TISC` (safety) paths.

---

## Runtime (guarded)

### `twincat_activate_configuration` 🔒 `ALLOW_TWINCAT_ACTIVATE`
Activate the TwinCAT configuration on the target.

### `twincat_restart_runtime` 🔒 `ALLOW_TWINCAT_RESTART`
Start/restart the TwinCAT runtime on the target.

---

## TwinCAT tree gotchas

- Container/root nodes such as `TIID` and major EtherCAT boxes may return descendant
  *collections* rather than a single scalar payload through COM. Leaf nodes and specific IO
  terminals are the safer targets for `ProduceXml`/`ConsumeXml`.
- If a broad path returns too much data, step down one level and target the exact terminal,
  box, or variable node.
- `tc_tree focus` is best-effort; this environment exposes expand/focus through the backing VS
  project item but not a reliable true-selection API.
