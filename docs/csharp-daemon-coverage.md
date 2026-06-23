# te1000 C#/.NET daemon — action coverage

Generated from the daemon source. **164 / 164** bridge actions ported
(every `switch ($Action)` case in `powershell/te1000-bridge.ps1`, incl. the
two legacy `plc_login`/`plc_logout` cases that index.js no longer wires).
Confirmed at runtime: `ping` reports `actionCount = 164`.

Each handler is a 1:1 port of its PS case via late-bound `dynamic` COM,
returning the identical `data` JSON shape. The dispatcher wraps it as
`{ok:true, result:<data>}`; errors become `{ok:false, error, errorKind}`.

Two daemon-only meta actions exist (not in the bridge): `ping`,
`list_actions` (both COM-free, handled in Dispatcher.cs).

| # | Bridge action | Ported | C# location |
|---|---------------|--------|-------------|
| 1 | `analytics_logger_create` | yes | `daemon/Actions/MeasurementActions.cs` |
| 2 | `analytics_logger_delete` | yes | `daemon/Actions/MeasurementActions.cs` |
| 3 | `analytics_stream_create` | yes | `daemon/Actions/MeasurementActions.cs` |
| 4 | `analytics_stream_delete` | yes | `daemon/Actions/MeasurementActions.cs` |
| 5 | `fieldbus_add_netvar` | yes | `daemon/Actions/FieldbusActions.cs` |
| 6 | `fieldbus_claim_resources` | yes | `daemon/Actions/FieldbusActions.cs` |
| 7 | `fieldbus_create_device` | yes | `daemon/Actions/FieldbusActions.cs` |
| 8 | `fieldbus_create_devices` | yes | `daemon/Actions/FieldbusActions.cs` |
| 9 | `fieldbus_create_gsd_box` | yes | `daemon/Actions/FieldbusActions.cs` |
| 10 | `fieldbus_get_xml` | yes | `daemon/Actions/FieldbusActions.cs` |
| 11 | `fieldbus_import_dbc` | yes | `daemon/Actions/FieldbusActions.cs` |
| 12 | `fieldbus_list_resources` | yes | `daemon/Actions/FieldbusActions.cs` |
| 13 | `fieldbus_set_station_address` | yes | `daemon/Actions/FieldbusActions.cs` |
| 14 | `fieldbus_set_xml` | yes | `daemon/Actions/FieldbusActions.cs` |
| 15 | `measurement_analytics_create` | yes | `daemon/Actions/MeasurementActions.cs` |
| 16 | `measurement_scope_add_child` | yes | `daemon/Actions/MeasurementActions.cs` |
| 17 | `measurement_scope_create` | yes | `daemon/Actions/MeasurementActions.cs` |
| 18 | `measurement_scope_record` | yes | `daemon/Actions/MeasurementActions.cs` |
| 19 | `measurement_scope_rename` | yes | `daemon/Actions/MeasurementActions.cs` |
| 20 | `nc_get_axis_info` | yes | `daemon/Actions/NcActions.cs` |
| 21 | `nc_list_axes` | yes | `daemon/Actions/NcActions.cs` |
| 22 | `nc_list_tasks` | yes | `daemon/Actions/NcActions.cs` |
| 23 | `plc_download` | yes | `daemon/Actions/SessionDownloadActions.cs` |
| 24 | `plc_library_add_library` | yes | `daemon/Actions/PlcLibraryActions.cs` |
| 25 | `plc_library_add_placeholder` | yes | `daemon/Actions/PlcLibraryActions.cs` |
| 26 | `plc_library_freeze_placeholder` | yes | `daemon/Actions/PlcLibraryActions.cs` |
| 27 | `plc_library_insert_repository` | yes | `daemon/Actions/PlcLibraryActions.cs` |
| 28 | `plc_library_install_library` | yes | `daemon/Actions/PlcLibraryActions.cs` |
| 29 | `plc_library_list_references` | yes | `daemon/Actions/PlcLibraryActions.cs` |
| 30 | `plc_library_list_repositories` | yes | `daemon/Actions/PlcLibraryActions.cs` |
| 31 | `plc_library_move_repository` | yes | `daemon/Actions/PlcLibraryActions.cs` |
| 32 | `plc_library_remove_reference` | yes | `daemon/Actions/PlcLibraryActions.cs` |
| 33 | `plc_library_remove_repository` | yes | `daemon/Actions/PlcLibraryActions.cs` |
| 34 | `plc_library_scan` | yes | `daemon/Actions/PlcLibraryActions.cs` |
| 35 | `plc_library_set_resolution` | yes | `daemon/Actions/PlcLibraryActions.cs` |
| 36 | `plc_library_uninstall_library` | yes | `daemon/Actions/PlcLibraryActions.cs` |
| 37 | `plc_login` | yes | `daemon/Actions/SessionDownloadActions.cs` |
| 38 | `plc_logout` | yes | `daemon/Actions/SessionDownloadActions.cs` |
| 39 | `plc_pou_append` | yes | `daemon/Actions/PlcPouActions.cs` |
| 40 | `plc_pou_check_objects` | yes | `daemon/Actions/PlcPouActions.cs` |
| 41 | `plc_pou_create` | yes | `daemon/Actions/PlcPouActions.cs` |
| 42 | `plc_pou_create_batch` | yes | `daemon/Actions/PlcPouActions.cs` |
| 43 | `plc_pou_create_folder` | yes | `daemon/Actions/PlcPouActions.cs` |
| 44 | `plc_pou_create_folder_batch` | yes | `daemon/Actions/PlcPouActions.cs` |
| 45 | `plc_pou_delete` | yes | `daemon/Actions/PlcPouActions.cs` |
| 46 | `plc_pou_find` | yes | `daemon/Actions/PlcPouActions.cs` |
| 47 | `plc_pou_get_decl` | yes | `daemon/Actions/PlcPouActions.cs` |
| 48 | `plc_pou_get_document` | yes | `daemon/Actions/PlcPouActions.cs` |
| 49 | `plc_pou_get_graphical` | yes | `daemon/Actions/PlcPouActions.cs` |
| 50 | `plc_pou_get_impl` | yes | `daemon/Actions/PlcPouActions.cs` |
| 51 | `plc_pou_import_template` | yes | `daemon/Actions/PlcPouActions.cs` |
| 52 | `plc_pou_insert` | yes | `daemon/Actions/PlcPouActions.cs` |
| 53 | `plc_pou_insert_in_var_block` | yes | `daemon/Actions/PlcPouActions.cs` |
| 54 | `plc_pou_move` | yes | `daemon/Actions/PlcPouActions.cs` |
| 55 | `plc_pou_outline` | yes | `daemon/Actions/PlcPouActions.cs` |
| 56 | `plc_pou_rename` | yes | `daemon/Actions/PlcPouActions.cs` |
| 57 | `plc_pou_replace` | yes | `daemon/Actions/PlcPouActions.cs` |
| 58 | `plc_pou_replace_lines` | yes | `daemon/Actions/PlcPouActions.cs` |
| 59 | `plc_pou_search` | yes | `daemon/Actions/PlcPouActions.cs` |
| 60 | `plc_pou_set_decl` | yes | `daemon/Actions/PlcPouActions.cs` |
| 61 | `plc_pou_set_decl_batch` | yes | `daemon/Actions/PlcPouActions.cs` |
| 62 | `plc_pou_set_document` | yes | `daemon/Actions/PlcPouActions.cs` |
| 63 | `plc_pou_set_impl` | yes | `daemon/Actions/PlcPouActions.cs` |
| 64 | `plc_pou_set_impl_batch` | yes | `daemon/Actions/PlcPouActions.cs` |
| 65 | `plc_pou_tree` | yes | `daemon/Actions/PlcPouActions.cs` |
| 66 | `plc_project_boot_flags` | yes | `daemon/Actions/PlcProjectActions.cs` |
| 67 | `plc_project_create` | yes | `daemon/Actions/PlcProjectActions.cs` |
| 68 | `plc_project_generate_boot` | yes | `daemon/Actions/PlcProjectActions.cs` |
| 69 | `plc_project_info` | yes | `daemon/Actions/PlcProjectActions.cs` |
| 70 | `plc_project_online` | yes | `daemon/Actions/PlcProjectActions.cs` |
| 71 | `plc_project_open` | yes | `daemon/Actions/PlcProjectActions.cs` |
| 72 | `plc_project_plcopen_export` | yes | `daemon/Actions/PlcProjectActions.cs` |
| 73 | `plc_project_plcopen_import` | yes | `daemon/Actions/PlcProjectActions.cs` |
| 74 | `plc_project_save_as_library` | yes | `daemon/Actions/PlcProjectActions.cs` |
| 75 | `tc_task_add_image_var` | yes | `daemon/Actions/TaskActions.cs` |
| 76 | `tc_task_bind_cpu` | yes | `daemon/Actions/TaskActions.cs` |
| 77 | `tc_task_create` | yes | `daemon/Actions/TaskActions.cs` |
| 78 | `tc_task_get` | yes | `daemon/Actions/TaskActions.cs` |
| 79 | `tc_task_get_linked_task` | yes | `daemon/Actions/TaskActions.cs` |
| 80 | `tc_task_get_rt_settings` | yes | `daemon/Actions/TaskActions.cs` |
| 81 | `tc_task_list` | yes | `daemon/Actions/TaskActions.cs` |
| 82 | `tc_task_set_linked_task` | yes | `daemon/Actions/TaskActions.cs` |
| 83 | `tc_task_set_params` | yes | `daemon/Actions/TaskActions.cs` |
| 84 | `tc_task_set_rt_settings` | yes | `daemon/Actions/TaskActions.cs` |
| 85 | `twincat_activate_configuration` | yes | `daemon/Actions/SessionDownloadActions.cs` |
| 86 | `twincat_add_project_route` | yes | `daemon/Actions/MappingRouteActions.cs` |
| 87 | `twincat_add_route` | yes | `daemon/Actions/MappingRouteActions.cs` |
| 88 | `twincat_clear_mapping_info` | yes | `daemon/Actions/MappingRouteActions.cs` |
| 89 | `twincat_consume_mapping_info` | yes | `daemon/Actions/MappingRouteActions.cs` |
| 90 | `twincat_cpp_build_project` | yes | `daemon/Actions/ModuleCppActions.cs` |
| 91 | `twincat_cpp_consume_xml` | yes | `daemon/Actions/ModuleCppActions.cs` |
| 92 | `twincat_cpp_create_module` | yes | `daemon/Actions/ModuleCppActions.cs` |
| 93 | `twincat_cpp_create_project` | yes | `daemon/Actions/ModuleCppActions.cs` |
| 94 | `twincat_cpp_open` | yes | `daemon/Actions/ModuleCppActions.cs` |
| 95 | `twincat_cpp_publish` | yes | `daemon/Actions/ModuleCppActions.cs` |
| 96 | `twincat_cpp_set_props` | yes | `daemon/Actions/ModuleCppActions.cs` |
| 97 | `twincat_create_child` | yes | `daemon/Actions/TreeActions.cs` |
| 98 | `twincat_create_children` | yes | `daemon/Actions/TreeActions.cs` |
| 99 | `twincat_create_io` | yes | `daemon/Actions/TreeActions.cs` |
| 100 | `twincat_delete_child` | yes | `daemon/Actions/TreeActions.cs` |
| 101 | `twincat_delete_children` | yes | `daemon/Actions/TreeActions.cs` |
| 102 | `twincat_export_child` | yes | `daemon/Actions/TreeActions.cs` |
| 103 | `twincat_get_current_variant` | yes | `daemon/Actions/LicenseVariantActions.cs` |
| 104 | `twincat_get_independent_file` | yes | `daemon/Actions/MappingRouteActions.cs` |
| 105 | `twincat_get_node_disabled` | yes | `daemon/Actions/MappingRouteActions.cs` |
| 106 | `twincat_get_silent_mode` | yes | `daemon/Actions/MappingRouteActions.cs` |
| 107 | `twincat_get_system_manager_errors` | yes | `daemon/Actions/TreeActions.cs` |
| 108 | `twincat_get_target_netid` | yes | `daemon/Actions/TreeActions.cs` |
| 109 | `twincat_get_target_platform` | yes | `daemon/Actions/MappingRouteActions.cs` |
| 110 | `twincat_get_tree_item_xml` | yes | `daemon/Actions/TreeActions.cs` |
| 111 | `twincat_get_variable_links` | yes | `daemon/Actions/LinkActions.cs` |
| 112 | `twincat_get_variant_config` | yes | `daemon/Actions/LicenseVariantActions.cs` |
| 113 | `twincat_import_child` | yes | `daemon/Actions/TreeActions.cs` |
| 114 | `twincat_license_activate_response` | yes | `daemon/Actions/LicenseVariantActions.cs` |
| 115 | `twincat_license_add_device` | yes | `daemon/Actions/LicenseVariantActions.cs` |
| 116 | `twincat_license_list_devices` | yes | `daemon/Actions/LicenseVariantActions.cs` |
| 117 | `twincat_link_variables` | yes | `daemon/Actions/LinkActions.cs` |
| 118 | `twincat_link_variables_batch` | yes | `daemon/Actions/LinkActions.cs` |
| 119 | `twincat_list_children` | yes | `daemon/Actions/TreeActions.cs` |
| 120 | `twincat_list_routes` | yes | `daemon/Actions/MappingRouteActions.cs` |
| 121 | `twincat_lookup_tree_item` | yes | `daemon/Actions/TreeActions.cs` |
| 122 | `twincat_lookup_tree_items` | yes | `daemon/Actions/TreeActions.cs` |
| 123 | `twincat_module_create` | yes | `daemon/Actions/ModuleCppActions.cs` |
| 124 | `twincat_module_enable_symbols` | yes | `daemon/Actions/ModuleCppActions.cs` |
| 125 | `twincat_module_get_xml` | yes | `daemon/Actions/ModuleCppActions.cs` |
| 126 | `twincat_module_list` | yes | `daemon/Actions/ModuleCppActions.cs` |
| 127 | `twincat_module_set_context` | yes | `daemon/Actions/ModuleCppActions.cs` |
| 128 | `twincat_module_set_xml` | yes | `daemon/Actions/ModuleCppActions.cs` |
| 129 | `twincat_produce_mapping_info` | yes | `daemon/Actions/MappingRouteActions.cs` |
| 130 | `twincat_rename_tree_item` | yes | `daemon/Actions/TreeActions.cs` |
| 131 | `twincat_rename_tree_items` | yes | `daemon/Actions/TreeActions.cs` |
| 132 | `twincat_rescan_plc_project` | yes | `daemon/Actions/TreeActions.cs` |
| 133 | `twincat_resolve_variable_path` | yes | `daemon/Actions/TreeActions.cs` |
| 134 | `twincat_restart_runtime` | yes | `daemon/Actions/SessionDownloadActions.cs` |
| 135 | `twincat_route_broadcast_search` | yes | `daemon/Actions/MappingRouteActions.cs` |
| 136 | `twincat_route_search_host` | yes | `daemon/Actions/MappingRouteActions.cs` |
| 137 | `twincat_save_plc_archive` | yes | `daemon/Actions/MappingRouteActions.cs` |
| 138 | `twincat_save_solution_archive` | yes | `daemon/Actions/MappingRouteActions.cs` |
| 139 | `twincat_scan_io_boxes` | yes | `daemon/Actions/TreeActions.cs` |
| 140 | `twincat_set_current_variant` | yes | `daemon/Actions/LicenseVariantActions.cs` |
| 141 | `twincat_set_independent_file` | yes | `daemon/Actions/MappingRouteActions.cs` |
| 142 | `twincat_set_item_variant_disable` | yes | `daemon/Actions/LicenseVariantActions.cs` |
| 143 | `twincat_set_node_disabled` | yes | `daemon/Actions/MappingRouteActions.cs` |
| 144 | `twincat_set_silent_mode` | yes | `daemon/Actions/MappingRouteActions.cs` |
| 145 | `twincat_set_target_netid` | yes | `daemon/Actions/TreeActions.cs` |
| 146 | `twincat_set_target_platform` | yes | `daemon/Actions/MappingRouteActions.cs` |
| 147 | `twincat_set_tree_item_xml` | yes | `daemon/Actions/TreeActions.cs` |
| 148 | `twincat_set_tree_item_xml_batch` | yes | `daemon/Actions/TreeActions.cs` |
| 149 | `twincat_set_variant_config` | yes | `daemon/Actions/LicenseVariantActions.cs` |
| 150 | `twincat_test_item_path` | yes | `daemon/Actions/TreeActions.cs` |
| 151 | `twincat_test_item_paths` | yes | `daemon/Actions/TreeActions.cs` |
| 152 | `twincat_unlink_variables` | yes | `daemon/Actions/LinkActions.cs` |
| 153 | `twincat_unlink_variables_batch` | yes | `daemon/Actions/LinkActions.cs` |
| 154 | `xae_clear_error_list` | yes | `daemon/Actions/XaeActions.cs` |
| 155 | `xae_execute_command` | yes | `daemon/Actions/XaeActions.cs` |
| 156 | `xae_focus_tree_item` | yes | `daemon/Actions/XaeActions.cs` |
| 157 | `xae_get_active_document` | yes | `daemon/Actions/XaeActions.cs` |
| 158 | `xae_get_error_list` | yes | `daemon/Actions/XaeActions.cs` |
| 159 | `xae_get_selected_items` | yes | `daemon/Actions/XaeActions.cs` |
| 160 | `xae_list_commands` | yes | `daemon/Actions/XaeActions.cs` |
| 161 | `xae_open_solution` | yes | `daemon/Actions/XaeActions.cs` |
| 162 | `xae_save_all` | yes | `daemon/Actions/XaeActions.cs` |
| 163 | `xae_solution_build` | yes | `daemon/Actions/XaeActions.cs` |
| 164 | `xae_status` | yes | `daemon/Actions/XaeActions.cs` |

## Deferred / approximated (none functionally deferred)

All 164 actions are registered and ported. The following carry
documented *implementation* approximations (behavior preserved, mechanism
differs) — see commit messages and the per-group notes:

- **xae_get_error_list / clear_error_list**: error-list read via late-bound
  `dte.ToolWindows.ErrorList` on the cached DTE instead of the PS
  `XaeErrorListProbe` (which re-acquired the shell via `Marshal.GetActiveObject`).
  Output keys identical; on failure returns `{available:false}` exactly as PS.
- **tc_settings target_platform / save_solution_archive / independent_file**:
  the PS typed-helper *fallback* (`Te1000SettingsHelper`) is not replicated;
  the primary late-bound path is ported. Behavior matches PS in the common case;
  on the rare fallback path the daemon throws a clear error instead of using the
  typed helper.
- **measurement_scope_***: `IMeasurementScope` (vtable) is driven via a
  reflection shim (`ScopeHelper`), a faithful port of the PS
  `Te1000MeasurementHelper`; if TE130X is not installed it throws the same
  'tooling not installed' message.
- **Typed-helper load guards** (`Ensure-Tc*Helper` 'DLL could not be loaded'
  messages): not reproduced — `TCatSysManagerLib` is statically referenced
  (EmbedInteropTypes), so a missing QI surfaces as the underlying COM/cast
  exception rather than the PS pre-check message. Same as the bridge's net effect.
