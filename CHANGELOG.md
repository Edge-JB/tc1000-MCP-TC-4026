# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
