#!/usr/bin/env node
// te1000-mcp: MCP server for the Beckhoff TwinCAT XAE / TE1000 Automation
// Interface. Every action is served by a persistent native C#/.NET daemon
// (daemon/Te1000Daemon.exe) over a named pipe (see daemonClient.js): it acquires
// DTE+sysmanager ONCE and watches for modal dialogs on an internal thread,
// eliminating the per-call powershell.exe spawn and the O(tree-size) re-walk.
// v2: tool surface grouped by noun with action enums, terse schemas, compact
// outputs — agent context is the scarce resource. The daemon answers the
// original fine-grained action names; this file maps the merged tools onto them.
// plc_login/plc_logout were dropped from the surface (DTE on the 64-bit shell
// exposes no window automation, so they never worked here); reach them via
// xae_command if ever needed on another shell.
"use strict";

const { spawn } = require("child_process");
const path = require("path");
const { McpServer } = require("@modelcontextprotocol/sdk/server/mcp.js");
const { StdioServerTransport } = require("@modelcontextprotocol/sdk/server/stdio.js");
const daemonClient = require("./daemonClient.js");
// Tool input schemas are defined ONCE in toolSchemas.js (single source of truth);
// registerTool below looks them up by name. The confirmation tokens and XAE action
// map also live there (the schema descriptions interpolate the tokens), and are
// re-imported here so the handlers reference the same definitions.
const { toolSchemas, XAE_ACTIONS } = require("./toolSchemas.js");

// Confirmation tokens are defined in toolSchemas.js (so the schema descriptions and
// the handler guards share one definition) and re-exported on that module.
const {
  ACTIVATE_CONFIRMATION,
  RESTART_CONFIRMATION,
  XAE_COMMAND_CONFIRMATION,
  PLC_LOGOUT_CONFIRMATION,
  DELETE_CONFIRMATION,
  PLC_DOWNLOAD_CONFIRMATION,
  PLC_LIBRARY_REPO_CONFIRMATION,
  ROUTE_WRITE_CONFIRMATION,
  MODULE_CONTEXT_CONFIRMATION,
  CPP_PUBLISH_CONFIRMATION,
  MEASUREMENT_RECORD_CONFIRMATION,
  LICENSE_ACTIVATE_CONFIRMATION,
} = require("./toolSchemas.js");

// 64-bit TcXaeShell (DTE.17.0) implies a 64-bit Windows, so the live UIA helper
// (sessionCall below) runs under 64-bit Windows PowerShell.
function ps64Exe() {
  const winDir = process.env.WINDIR || "C:\\Windows";
  return path.join(winDir, "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
}

// PLC online-session control via UI Automation (powershell/plc-session.ps1).
// The 64-bit shell's DTE can't log the PLC out (Logout command never IsAvailable,
// no key binding), but the IDE's Login/Logout toolbar buttons are reachable via
// UIA. mode "status" reports { loggedIn, ... }; mode "logout" invokes the Logout
// button (never Login). Returns the parsed snapshot, or null if it couldn't run.
function sessionCall(mode) {
  return new Promise((resolve) => {
    const psExe = ps64Exe();
    const scriptPath = path.join(__dirname, "powershell", "plc-session.ps1");
    const args = ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", scriptPath, "-Mode", mode];
    let out = "";
    let done = false;
    const finish = (v) => { if (!done) { done = true; resolve(v); } };
    try {
      const c = spawn(psExe, args, { stdio: ["ignore", "pipe", "ignore"] });
      c.stdout.on("data", (d) => { out += d.toString(); });
      c.on("error", () => finish(null));
      c.on("close", () => {
        const line = out.trim().split(/\r?\n/).filter(Boolean).pop();
        try { finish(JSON.parse(line)); } catch { finish(null); }
      });
      setTimeout(() => { try { c.kill(); } catch {} finish(null); }, 30000);
    } catch { finish(null); }
  });
}

async function bridgeCall(action, payload = {}) {
  if (process.env.TE1000_PROGID && !payload.progId) payload.progId = process.env.TE1000_PROGID;
  return runBridge(action, payload);
}

function runBridge(action, payload = {}) {
  return daemonClient.runViaDaemon(action, payload);
}

function text(s) {
  return { content: [{ type: "text", text: s }] };
}

// Drop null/empty values recursively so responses carry only signal.
function prune(v) {
  if (Array.isArray(v)) {
    const a = v.map(prune).filter((x) => x !== undefined);
    return a.length ? a : undefined;
  }
  if (v && typeof v === "object") {
    const o = {};
    for (const [k, x] of Object.entries(v)) {
      const p = prune(x);
      if (p !== undefined) o[k] = p;
    }
    return Object.keys(o).length ? o : undefined;
  }
  return v === null || v === "" ? undefined : v;
}

function textResult(data) {
  if (data && typeof data === "object") {
    if ("resolved" in data && ("clicked" in data || data.resolved === false)) {
      if (data.resolved === false) return text(`no modal dialog open (${data.reason || "nothing to resolve"})`);
      const lines = [
        `${data.clicked ? "clicked" : "FAILED to click"} [${data.button}] on "${data.title || ""}"`,
      ];
      if (data.remembered) {
        // remembered:true means the rule was applied in-memory (hot-applied to the
        // watcher). A refuseReason alongside it means the FILE write failed — surface
        // it so the user knows it won't persist across a daemon restart.
        if (data.refuseReason) lines.push(`remembered IN-MEMORY only (hot-applied to the watcher) — NOT persisted: ${data.refuseReason}`);
        else lines.push("remembered: added an auto-dismiss rule to dialog-allowlist.json (hot-applied to the watcher)");
      } else if (data.rememberRefused) lines.push(`NOT remembered: ${data.refuseReason || "disruptive prompt refused for auto-remember"}`);
      else if (data.refuseReason) lines.push(`NOT remembered: ${data.refuseReason}`);
      return text(lines.join("\n"));
    }
    if ("watching" in data && "found" in data) {
      if (!data.watching) return text("dialog watcher is disabled (daemon started with --no-watch)");
      if (!data.found) return text("no modal dialog open in XAE");
      const s = data.snapshot || {};
      const buttons = Array.isArray(s.buttons) ? s.buttons.join(", ") : "";
      return text(
        [
          `modal dialog ${data.blocking ? "BLOCKING" : "present"}${data.blockingForMs ? ` (open ${data.blockingForMs} ms)` : ""}`,
          `title:   ${s.title || ""}`,
          s.text ? `text:    ${s.text}` : null,
          `class:   ${s.class || ""}`,
          buttons ? `buttons: ${buttons}` : null,
          s.dismissed ? `dismissed via: ${s.dismissedButton}` : null,
        ].filter(Boolean).join("\n"),
      );
    }
    if (typeof data.xml === "string") return text(data.xml); // raw XML beats JSON-escaped XML
    if (Array.isArray(data.commands)) return text(`${data.count} commands\n${data.commands.join("\n")}`);
    if (Array.isArray(data.items) && "available" in data) {
      if (!data.available) return text(data.error ? `error list unavailable: ${data.error}` : "error list unavailable");
      const lines = data.items.map((it) =>
        `${it.errorLevel || "?"}  ${it.fileName || ""}(${it.line ?? ""}): ${it.description || ""}${it.project ? ` [${it.project}]` : ""}`);
      return text([`${data.returned}/${data.count} items`, ...lines].join("\n"));
    }
  }
  const p = prune(data);
  return text(p === undefined ? "ok" : typeof p === "string" ? p : JSON.stringify(p));
}

function need(params, keys, action) {
  for (const k of keys) {
    if (params[k] === undefined || params[k] === "") throw new Error(`'${k}' is required for action=${action}`);
  }
}

const server = new McpServer({ name: "te1000-mcp", version: "2.2.0" });

server.registerTool(
  "xae",
  toolSchemas.xae,
  async ({ action, solutionPath, closeExisting, discardChanges, filter, limit, severityFilter, button, remember, mode }) => {
    const payload = { mode };
    if (action === "open_solution") {
      need({ solutionPath }, ["solutionPath"], action);
      Object.assign(payload, { solutionPath, visible: true, closeExisting: closeExisting || false, discardChanges: discardChanges === true, mode: mode || "activeOrCreate" });
    }
    if (action === "list_commands") Object.assign(payload, { filter, limit });
    if (action === "error_list") Object.assign(payload, { limit, severityFilter });
    if (action === "dialog_resolve") {
      need({ button }, ["button"], action);
      Object.assign(payload, { button, remember: remember === true });
    }
    return textResult(await bridgeCall(XAE_ACTIONS[action], payload));
  },
);

server.registerTool(
  "xae_build",
  toolSchemas.xae_build,
  async (params) => textResult(await bridgeCall("xae_solution_build", params)),
);

server.registerTool(
  "xae_command",
  toolSchemas.xae_command,
  async ({ confirm, commandName, args }) => {
    if (confirm !== XAE_COMMAND_CONFIRMATION) {
      throw new Error(`Blocked. Re-run with confirm="${XAE_COMMAND_CONFIRMATION}" to execute an arbitrary XAE/DTE command.`);
    }
    return textResult(await bridgeCall("xae_execute_command", { commandName, args }));
  },
);

server.registerTool(
  "tc_tree",
  toolSchemas.tc_tree,
  async (p) => {
    const t = { treePath: p.path };
    switch (p.action) {
      case "get": need(p, ["path"], p.action); return textResult(await bridgeCall("twincat_lookup_tree_item", t));
      case "children": need(p, ["path"], p.action); return textResult(await bridgeCall("twincat_list_children", t));
      case "exists": need(p, ["path"], p.action); return textResult(await bridgeCall("twincat_test_item_path", t));
      case "exists_batch":
        need(p, ["paths"], p.action);
        return textResult(await bridgeCall("twincat_test_item_paths", { paths: p.paths }));
      case "get_batch":
        need(p, ["paths"], p.action);
        return textResult(await bridgeCall("twincat_lookup_tree_items", { paths: p.paths }));
      case "get_xml":
        need(p, ["path"], p.action);
        return textResult(await bridgeCall("twincat_get_tree_item_xml", { ...t, summary: p.summary === true }));
      case "set_xml":
        need(p, ["path", "xml"], p.action);
        return textResult(await bridgeCall("twincat_set_tree_item_xml", { ...t, xml: p.xml, returnXml: p.returnXml === true }));
      case "set_xml_batch":
        need(p, ["items"], p.action);
        return textResult(await bridgeCall("twincat_set_tree_item_xml_batch", { items: p.items, returnXml: p.returnXml === true, save: p.save === true }));
      case "rename":
        need(p, ["path", "newName"], p.action);
        return textResult(await bridgeCall("twincat_rename_tree_item", { treePath: p.path, newName: p.newName }));
      case "rename_batch":
        need(p, ["renames"], p.action);
        return textResult(await bridgeCall("twincat_rename_tree_items", { basePath: p.path, renames: p.renames, save: p.save === true }));
      case "create":
        need(p, ["path", "name", "subType"], p.action);
        return textResult(await bridgeCall("twincat_create_child", { parentPath: p.path, childName: p.name, subType: p.subType, beforeChildName: p.before, createInfo: p.createInfo }));
      case "create_batch":
        need(p, ["creates"], p.action);
        return textResult(await bridgeCall("twincat_create_children", { creates: p.creates, save: p.save === true }));
      case "delete":
        need(p, ["path", "name"], p.action);
        return textResult(await bridgeCall("twincat_delete_child", { parentPath: p.path, childName: p.name }));
      case "delete_batch":
        need(p, ["deletes"], p.action);
        if (p.dryRun !== true && p.confirm !== DELETE_CONFIRMATION) {
          throw new Error('Blocked. delete_batch removes ' + p.deletes.length + ' nodes. Re-run with dryRun:true to preview what would be deleted, or confirm="' + DELETE_CONFIRMATION + '" to actually delete.');
        }
        return textResult(await bridgeCall("twincat_delete_children", { deletes: p.deletes, dryRun: p.dryRun === true, save: p.save === true }));
      case "import":
        need(p, ["path", "file"], p.action);
        return textResult(await bridgeCall("twincat_import_child", { parentPath: p.path, filePath: p.file, beforeChildName: p.before, reconnect: p.reconnect, importAsName: p.newName }));
      case "export":
        need(p, ["path", "name", "file"], p.action);
        return textResult(await bridgeCall("twincat_export_child", { parentPath: p.path, childName: p.name, filePath: p.file }));
      case "focus": need(p, ["path"], p.action); return textResult(await bridgeCall("xae_focus_tree_item", t));
    }
  },
);

server.registerTool(
  "tc_ethercat",
  toolSchemas.tc_ethercat,
  async ({ racks, save }) => {
    need({ racks }, ["racks"], "tc_ethercat");
    return textResult(await bridgeCall("twincat_create_io", { racks, save: save === true }));
  },
);

server.registerTool(
  "tc_link",
  toolSchemas.tc_link,
  async ({ action, a, b, autoResolve, links, save, verbose, details }) => {
    if (action === "link") {
      need({ b }, ["b"], action);
      return textResult(await bridgeCall("twincat_link_variables", { producer: a, consumer: b, autoResolve, verbose: verbose === true }));
    }
    if (action === "unlink") return textResult(await bridgeCall("twincat_unlink_variables", { variableA: a, variableB: b }));
    if (action === "link_batch") {
      need({ links }, ["links"], action);
      return textResult(await bridgeCall("twincat_link_variables_batch", { links, autoResolve, save: save === true, details: details === true }));
    }
    if (action === "unlink_batch") {
      need({ links }, ["links"], action);
      return textResult(await bridgeCall("twincat_unlink_variables_batch", { links, save: save === true, details: details === true }));
    }
    if (action === "links") {
      need({ a }, ["a"], action);
      return textResult(await bridgeCall("twincat_get_variable_links", { path: a }));
    }
    return textResult(await bridgeCall("twincat_resolve_variable_path", { variablePath: a, verbose: verbose === true }));
  },
);

server.registerTool(
  "tc_system",
  toolSchemas.tc_system,
  async ({ action, netId, path: treePath }) => {
    switch (action) {
      case "get_netid": return textResult(await bridgeCall("twincat_get_target_netid", {}));
      case "set_netid":
        need({ netId }, ["netId"], action);
        return textResult(await bridgeCall("twincat_set_target_netid", { targetNetId: netId }));
      case "errors": return textResult(await bridgeCall("twincat_get_system_manager_errors", {}));
      case "rescan_plc": return textResult(await bridgeCall("twincat_rescan_plc_project", { treePath: treePath || "TIPC" }));
      case "scan_io_boxes":
        need({ path: treePath }, ["path"], action);
        return textResult(await bridgeCall("twincat_scan_io_boxes", { treePath }));
    }
  },
);

server.registerTool(
  "tc_mapping",
  toolSchemas.tc_mapping,
  async (p) => {
    switch (p.action) {
      case "produce":
        return textResult(await bridgeCall("twincat_produce_mapping_info", {}));
      case "consume":
        need(p, ["xml"], p.action);
        return textResult(await bridgeCall("twincat_consume_mapping_info", { xml: p.xml, save: p.save === true }));
      case "clear":
        if (p.confirm !== DELETE_CONFIRMATION) {
          throw new Error('Blocked. clear deletes ALL variable links project-wide. Re-run with confirm="' + DELETE_CONFIRMATION + '" to proceed.');
        }
        return textResult(await bridgeCall("twincat_clear_mapping_info", { save: p.save === true }));
    }
  },
);

server.registerTool(
  "nc",
  toolSchemas.nc,
  async ({ action, path: p }) => {
    if (action === "tasks") return textResult(await bridgeCall("nc_list_tasks", {}));
    if (action === "axes") return textResult(await bridgeCall("nc_list_axes", { taskPath: p }));
    need({ path: p }, ["path"], action);
    return textResult(await bridgeCall("nc_get_axis_info", { axisPath: p }));
  },
);

server.registerTool(
  "tc_task",
  toolSchemas.tc_task,
  async (p) => {
    switch (p.action) {
      case "list":
        return textResult(await bridgeCall("tc_task_list", {}));
      case "get":
        need(p, ["path"], p.action);
        return textResult(await bridgeCall("tc_task_get", { path: p.path, summary: p.summary === true }));
      case "create":
        need(p, ["name"], p.action);
        return textResult(await bridgeCall("tc_task_create", { name: p.name, withImage: p.withImage, before: p.before, cycleTimeUs: p.cycleTimeUs, priority: p.priority, save: p.save === true }));
      case "set_params":
        need(p, ["path"], p.action);
        if (p.xml !== undefined && (p.cycleTimeUs !== undefined || p.priority !== undefined || p.autoStart !== undefined)) {
          throw new Error("set_params: xml is mutually exclusive with cycleTimeUs/priority/autoStart.");
        }
        return textResult(await bridgeCall("tc_task_set_params", { path: p.path, cycleTimeUs: p.cycleTimeUs, priority: p.priority, autoStart: p.autoStart, xml: p.xml, returnXml: p.returnXml === true, save: p.save === true }));
      case "add_image_var":
        need(p, ["path", "varName", "dataType"], p.action);
        return textResult(await bridgeCall("tc_task_add_image_var", { path: p.path, varName: p.varName, dataType: p.dataType, startAddress: p.startAddress, save: p.save === true }));
      case "get_rt_settings":
        return textResult(await bridgeCall("tc_task_get_rt_settings", { summary: p.summary === true }));
      case "set_rt_settings":
        if (p.xml !== undefined && (p.maxCPUs !== undefined || p.affinity !== undefined || p.cpus !== undefined)) {
          throw new Error("set_rt_settings: xml is mutually exclusive with maxCPUs/affinity/cpus.");
        }
        return textResult(await bridgeCall("tc_task_set_rt_settings", { maxCPUs: p.maxCPUs, affinity: p.affinity, cpus: p.cpus, xml: p.xml, returnXml: p.returnXml === true, save: p.save === true }));
      case "bind_cpu":
        need(p, ["path", "affinity"], p.action);
        return textResult(await bridgeCall("tc_task_bind_cpu", { path: p.path, affinity: p.affinity, returnXml: p.returnXml === true, save: p.save === true }));
      case "get_linked_task":
        return textResult(await bridgeCall("tc_task_get_linked_task", { path: p.path }));
      case "set_linked_task":
        need(p, ["linkedTask"], p.action);
        return textResult(await bridgeCall("tc_task_set_linked_task", { path: p.path, linkedTask: p.linkedTask, save: p.save === true }));
    }
  },
);

server.registerTool(
  "plc_download",
  toolSchemas.plc_download,
  async (params) => {
    if (params.confirm !== PLC_DOWNLOAD_CONFIRMATION) {
      throw new Error('Blocked. plc_download deploys a boot project to the live target. Re-run with confirm="' + PLC_DOWNLOAD_CONFIRMATION + '" to proceed.');
    }
    let logoutNote = null;
    if (params.autoLogout !== false) {
      const st = await sessionCall("status");
      if (st && st.loggedIn) {
        const lo = await sessionCall("logout");
        logoutNote = lo && lo.loggedIn === false
          ? "auto-logout: IDE was logged in; logged out before deploy so deferred source edits are applied (not logged back in)."
          : "auto-logout requested but the IDE still appears logged in — deploy may not include deferred source edits.";
      }
    }
    const data = await bridgeCall("plc_download", params);
    if (logoutNote && data && typeof data === "object") data.autoLogout = logoutNote;
    return textResult(data);
  },
);

server.registerTool(
  "plc_session",
  toolSchemas.plc_session,
  async ({ action, confirm }) => {
    if (action === "logout" && confirm !== PLC_LOGOUT_CONFIRMATION) {
      throw new Error(`Blocked. Re-run with confirm="${PLC_LOGOUT_CONFIRMATION}" to log the PLC out (the IDE Login button is never invoked — no auto-login).`);
    }
    const data = await sessionCall(action);
    if (!data) throw new Error("plc-session helper failed, or XAE is not reachable via UI Automation.");
    return textResult(data);
  },
);

server.registerTool(
  "plc_project",
  toolSchemas.plc_project,
  async (p) => {
    switch (p.action) {
      case "create_from_template":
        need(p, ["name"], p.action);
        return textResult(await bridgeCall("plc_project_create", { name: p.name, template: p.template, before: p.before, save: p.save === true }));
      case "open":
        need(p, ["name", "file"], p.action);
        return textResult(await bridgeCall("plc_project_open", { name: p.name, file: p.file, subType: p.subType, before: p.before, save: p.save === true }));
      case "info":
        return textResult(await bridgeCall("plc_project_info", { treePath: p.treePath }));
      case "set_boot_flags":
        return textResult(await bridgeCall("plc_project_boot_flags", { treePath: p.treePath, autostart: p.autostart, tmcFileCopy: p.tmcFileCopy }));
      case "generate_boot_project":
        if (p.confirm !== PLC_DOWNLOAD_CONFIRMATION) {
          throw new Error('Blocked. generate_boot_project writes the boot project to the live target. Re-run with confirm="' + PLC_DOWNLOAD_CONFIRMATION + '" to proceed.');
        }
        return textResult(await bridgeCall("plc_project_generate_boot", { treePath: p.treePath, autostart: p.autostart }));
      case "online":
        need(p, ["command"], p.action);
        if (p.confirm !== PLC_DOWNLOAD_CONFIRMATION) {
          throw new Error('Blocked. online command "' + p.command + '" changes the live runtime/IDE online state. Re-run with confirm="' + PLC_DOWNLOAD_CONFIRMATION + '" to proceed.');
        }
        return textResult(await bridgeCall("plc_project_online", { command: p.command, treePath: p.treePath }));
      case "plcopen_export":
        need(p, ["file"], p.action);
        return textResult(await bridgeCall("plc_project_plcopen_export", { treePath: p.treePath, file: p.file, selection: p.selection }));
      case "plcopen_import":
        need(p, ["file"], p.action);
        return textResult(await bridgeCall("plc_project_plcopen_import", { treePath: p.treePath, file: p.file, options: p.options, selection: p.selection, folderStructure: p.folderStructure, save: p.save === true }));
      case "save_as_library":
        need(p, ["file"], p.action);
        return textResult(await bridgeCall("plc_project_save_as_library", { treePath: p.treePath, file: p.file, install: p.install === true }));
    }
  },
);

server.registerTool(
  "plc_pou",
  toolSchemas.plc_pou,
  async (p) => {
    switch (p.action) {
      case "create":
        need(p, ["parent", "name", "subType"], p.action);
        return textResult(await bridgeCall("plc_pou_create", {
          parent: p.parent, name: p.name, subType: p.subType, language: p.language,
          returnType: p.returnType, extends: p.extends, implements: p.implements,
          declText: p.declText, before: p.before,
        }));
      case "create_batch":
        need(p, ["creates"], p.action);
        return textResult(await bridgeCall("plc_pou_create_batch", { creates: p.creates, save: p.save === true, details: p.details === true }));
      case "create_folder":
        need(p, ["parent", "name"], p.action);
        return textResult(await bridgeCall("plc_pou_create_folder", { parent: p.parent, name: p.name, before: p.before }));
      case "create_folder_batch":
        need(p, ["creates"], p.action);
        return textResult(await bridgeCall("plc_pou_create_folder_batch", { creates: p.creates, save: p.save === true, details: p.details === true }));
      case "import_template":
        need(p, ["parent", "paths"], p.action);
        return textResult(await bridgeCall("plc_pou_import_template", { parent: p.parent, paths: p.paths, save: p.save === true }));
      case "get_decl":
        need(p, ["path"], p.action);
        if (p.range && p.grep) throw new Error("get_decl: range and grep are mutually exclusive.");
        return textResult(await bridgeCall("plc_pou_get_decl", { path: p.path, range: p.range, grep: p.grep }));
      case "get_impl":
        need(p, ["path"], p.action);
        if (p.range && p.grep) throw new Error("get_impl: range and grep are mutually exclusive.");
        return textResult(await bridgeCall("plc_pou_get_impl", { path: p.path, range: p.range, grep: p.grep }));
      case "outline":
        need(p, ["path"], p.action);
        return textResult(await bridgeCall("plc_pou_outline", { path: p.path }));
      case "get_document":
        need(p, ["path"], p.action);
        return textResult(await bridgeCall("plc_pou_get_document", { path: p.path }));
      case "get_graphical":
        need(p, ["path"], p.action);
        return textResult(await bridgeCall("plc_pou_get_graphical", { path: p.path }));
      case "set_decl":
        need(p, ["path", "declText"], p.action);
        return textResult(await bridgeCall("plc_pou_set_decl", { path: p.path, declText: p.declText }));
      case "set_decl_batch":
        need(p, ["items"], p.action);
        return textResult(await bridgeCall("plc_pou_set_decl_batch", { items: p.items, save: p.save === true, details: p.details === true }));
      case "set_impl": {
        need(p, ["path"], p.action);
        const hasText = p.implText !== undefined;
        const hasXml = p.implXml !== undefined;
        if (hasText === hasXml) throw new Error("set_impl requires exactly one of implText / implXml.");
        return textResult(await bridgeCall("plc_pou_set_impl", { path: p.path, implText: p.implText, implXml: p.implXml }));
      }
      case "set_impl_batch":
        need(p, ["items"], p.action);
        return textResult(await bridgeCall("plc_pou_set_impl_batch", { items: p.items, save: p.save === true, details: p.details === true }));
      case "set_document":
        need(p, ["path", "documentXml"], p.action);
        return textResult(await bridgeCall("plc_pou_set_document", { path: p.path, documentXml: p.documentXml }));
      case "check_objects":
        return textResult(await bridgeCall("plc_pou_check_objects", { plcPath: p.plcPath }));
      case "replace":
        need(p, ["path", "find", "replaceWith"], p.action);
        return textResult(await bridgeCall("plc_pou_replace", {
          path: p.path, target: p.target, find: p.find, replaceWith: p.replaceWith,
          expectCount: p.expectCount, validate: p.validate === true, save: p.save === true,
        }));
      case "replace_lines":
        need(p, ["path", "start", "end", "text"], p.action);
        return textResult(await bridgeCall("plc_pou_replace_lines", {
          path: p.path, target: p.target, start: p.start, end: p.end, text: p.text,
          validate: p.validate === true, save: p.save === true,
        }));
      case "insert": {
        need(p, ["path", "text"], p.action);
        const supplied = [p.at, p.after, p.before].filter((x) => x !== undefined && x !== null).length;
        if (supplied !== 1) throw new Error("insert requires exactly one of at / after / before.");
        return textResult(await bridgeCall("plc_pou_insert", {
          path: p.path, target: p.target, at: p.at, after: p.after, before: p.before, text: p.text,
          validate: p.validate === true, save: p.save === true,
        }));
      }
      case "insert_in_var_block":
        need(p, ["path", "block", "text"], p.action);
        return textResult(await bridgeCall("plc_pou_insert_in_var_block", {
          path: p.path, target: p.target, block: p.block, text: p.text, occurrence: p.occurrence,
          validate: p.validate === true, save: p.save === true,
        }));
      case "append":
        need(p, ["path", "text"], p.action);
        return textResult(await bridgeCall("plc_pou_append", {
          path: p.path, target: p.target, text: p.text,
          validate: p.validate === true, save: p.save === true,
        }));
      case "tree":
        return textResult(await bridgeCall("plc_pou_tree", {
          plcPath: p.plcPath, path: p.path, depth: p.depth, typeFilter: p.typeFilter,
        }));
      case "find":
        if ((p.name === undefined || p.name === "") && (p.typeFilter === undefined || p.typeFilter === "")) {
          throw new Error("find: pass at least one of name / typeFilter. e.g. {action:'find', name:'MyFB'} or {action:'find', typeFilter:'FB,Method'}");
        }
        return textResult(await bridgeCall("plc_pou_find", {
          plcPath: p.plcPath, path: p.path, name: p.name, typeFilter: p.typeFilter,
        }));
      case "search": {
        need(p, ["pattern"], p.action);
        if (p.declOnly === true && p.implOnly === true) {
          throw new Error("declOnly and implOnly are mutually exclusive.");
        }
        return textResult(await bridgeCall("plc_pou_search", {
          pattern: p.pattern, ignoreCase: p.ignoreCase === true,
          declOnly: p.declOnly === true, implOnly: p.implOnly === true,
          plcPath: p.plcPath, path: p.path, maxResults: p.maxResults,
          refresh: p.refresh === true,
        }));
      }
      case "delete": {
        const hasPath = p.path !== undefined && p.path !== "";
        const hasPair = (p.parent !== undefined && p.parent !== "") && (p.name !== undefined && p.name !== "");
        if (!hasPath && !hasPair) throw new Error("delete requires either path, or parent and name.");
        if (p.dryRun !== true && p.confirm !== DELETE_CONFIRMATION) {
          throw new Error('Blocked. delete removes a PLC object. Re-run with dryRun:true to preview, or confirm="' + DELETE_CONFIRMATION + '" to actually delete.');
        }
        return textResult(await bridgeCall("plc_pou_delete", {
          path: p.path, parent: p.parent, name: p.name, dryRun: p.dryRun === true,
        }));
      }
      case "rename":
        need(p, ["path", "newName"], p.action);
        return textResult(await bridgeCall("plc_pou_rename", { path: p.path, newName: p.newName }));
      case "move":
        need(p, ["path", "newParent"], p.action);
        return textResult(await bridgeCall("plc_pou_move", {
          path: p.path, newParent: p.newParent, before: p.before,
        }));
    }
  },
);

server.registerTool(
  "plc_library",
  toolSchemas.plc_library,
  async (p) => {
    const repoGuard = () => {
      if (p.confirm !== PLC_LIBRARY_REPO_CONFIRMATION) {
        throw new Error('Blocked. ' + p.action + ' mutates the machine-wide TwinCAT library store. Re-run with confirm="' + PLC_LIBRARY_REPO_CONFIRMATION + '" to proceed.');
      }
    };
    const base = { referencesPath: p.referencesPath, mode: p.mode };
    switch (p.action) {
      case "list":
        return textResult(await bridgeCall("plc_library_list_references", base));
      case "scan":
        return textResult(await bridgeCall("plc_library_scan", base));
      case "repos":
        return textResult(await bridgeCall("plc_library_list_repositories", base));
      case "add_library":
        need(p, ["name"], p.action);
        return textResult(await bridgeCall("plc_library_add_library", { ...base, name: p.name, version: p.version, company: p.company, save: p.save === true }));
      case "add_placeholder":
        need(p, ["name"], p.action);
        return textResult(await bridgeCall("plc_library_add_placeholder", { ...base, name: p.name, defLib: p.defLib, defVer: p.defVer, defDist: p.defDist, save: p.save === true }));
      case "set_resolution":
        need(p, ["placeholder", "lib"], p.action);
        return textResult(await bridgeCall("plc_library_set_resolution", { ...base, placeholder: p.placeholder, lib: p.lib, version: p.version, dist: p.dist, save: p.save === true }));
      case "freeze":
        return textResult(await bridgeCall("plc_library_freeze_placeholder", { ...base, name: p.name, save: p.save === true }));
      case "remove_reference":
        need(p, ["name"], p.action);
        return textResult(await bridgeCall("plc_library_remove_reference", { ...base, name: p.name, save: p.save === true }));
      case "install_library":
        repoGuard();
        need(p, ["repo", "libPath"], p.action);
        return textResult(await bridgeCall("plc_library_install_library", { ...base, confirm: p.confirm, repo: p.repo, libPath: p.libPath, overwrite: p.overwrite === true }));
      case "uninstall_library":
        repoGuard();
        need(p, ["repo", "lib"], p.action);
        return textResult(await bridgeCall("plc_library_uninstall_library", { ...base, confirm: p.confirm, repo: p.repo, lib: p.lib, version: p.version, dist: p.dist }));
      case "insert_repository":
        repoGuard();
        need(p, ["name", "folder"], p.action);
        return textResult(await bridgeCall("plc_library_insert_repository", { ...base, confirm: p.confirm, name: p.name, folder: p.folder, index: p.index }));
      case "remove_repository":
        repoGuard();
        need(p, ["name"], p.action);
        return textResult(await bridgeCall("plc_library_remove_repository", { ...base, confirm: p.confirm, name: p.name }));
      case "move_repository":
        repoGuard();
        need(p, ["name", "index"], p.action);
        return textResult(await bridgeCall("plc_library_move_repository", { ...base, confirm: p.confirm, name: p.name, index: p.index }));
    }
  },
);

server.registerTool(
  "tc_route",
  toolSchemas.tc_route,
  async (p) => {
    const routeGuard = (label) => {
      if (p.confirm !== ROUTE_WRITE_CONFIRMATION) {
        throw new Error('Blocked. ' + label + ' writes an ADS route. Re-run with confirm="' + ROUTE_WRITE_CONFIRMATION + '" to proceed.');
      }
    };
    switch (p.action) {
      case "list":
        return textResult(await bridgeCall("twincat_list_routes", {}));
      case "broadcast_search":
        return textResult(await bridgeCall("twincat_route_broadcast_search", { timeoutMs: p.timeoutMs }));
      case "search_host":
        need(p, ["host"], p.action);
        return textResult(await bridgeCall("twincat_route_search_host", { host: p.host, timeoutMs: p.timeoutMs }));
      case "add_route":
        routeGuard("add_route");
        need(p, ["remoteName", "remoteNetId"], p.action);
        if (!p.remoteIpAddr && !p.remoteHostName) {
          throw new Error("add_route requires one of remoteIpAddr / remoteHostName.");
        }
        return textResult(await bridgeCall("twincat_add_route", {
          confirm: p.confirm, remoteName: p.remoteName, remoteNetId: p.remoteNetId,
          remoteIpAddr: p.remoteIpAddr, remoteHostName: p.remoteHostName,
          userName: p.userName, password: p.password, noEncryption: p.noEncryption === true, localName: p.localName,
        }));
      case "add_project_route":
        routeGuard("add_project_route");
        need(p, ["name", "netId"], p.action);
        if (!p.ipAddr && !p.hostName) {
          throw new Error("add_project_route requires one of ipAddr / hostName.");
        }
        return textResult(await bridgeCall("twincat_add_project_route", {
          confirm: p.confirm, name: p.name, netId: p.netId, ipAddr: p.ipAddr, hostName: p.hostName,
        }));
    }
  },
);

server.registerTool(
  "tc_settings",
  toolSchemas.tc_settings,
  async (p) => {
    switch (p.action) {
      case "get_silent_mode":
        return textResult(await bridgeCall("twincat_get_silent_mode", {}));
      case "set_silent_mode":
        need(p, ["enabled"], p.action);
        return textResult(await bridgeCall("twincat_set_silent_mode", { enabled: p.enabled }));
      case "get_target_platform":
        return textResult(await bridgeCall("twincat_get_target_platform", {}));
      case "set_target_platform":
        need(p, ["platform"], p.action);
        return textResult(await bridgeCall("twincat_set_target_platform", { platform: p.platform }));
      case "save_solution_archive":
        need(p, ["file"], p.action);
        return textResult(await bridgeCall("twincat_save_solution_archive", { file: p.file }));
      case "save_plc_archive":
        need(p, ["file"], p.action);
        return textResult(await bridgeCall("twincat_save_plc_archive", { file: p.file, name: p.name }));
      case "get_independent_file":
        need(p, ["path"], p.action);
        return textResult(await bridgeCall("twincat_get_independent_file", { path: p.path }));
      case "set_independent_file":
        need(p, ["path", "enabled"], p.action);
        return textResult(await bridgeCall("twincat_set_independent_file", { path: p.path, enabled: p.enabled }));
      case "get_disabled":
        need(p, ["path"], p.action);
        return textResult(await bridgeCall("twincat_get_node_disabled", { path: p.path }));
      case "set_disabled":
        need(p, ["path", "disabled"], p.action);
        return textResult(await bridgeCall("twincat_set_node_disabled", { path: p.path, disabled: p.disabled }));
    }
  },
);

server.registerTool(
  "tc_fieldbus",
  toolSchemas.tc_fieldbus,
  async (p) => {
    const base = { mode: p.mode };
    switch (p.action) {
      case "create_device":
        need(p, ["name", "subType"], p.action);
        return textResult(await bridgeCall("fieldbus_create_device", { ...base, parent: p.parent, name: p.name, subType: p.subType, before: p.before, vInfo: p.vInfo, claimIndex: p.claimIndex, save: p.save === true }));
      case "create_batch":
        need(p, ["creates"], p.action);
        return textResult(await bridgeCall("fieldbus_create_devices", { ...base, creates: p.creates, save: p.save === true }));
      case "list_resources":
        need(p, ["path"], p.action);
        return textResult(await bridgeCall("fieldbus_list_resources", { ...base, path: p.path }));
      case "claim_resources":
        need(p, ["path", "index"], p.action);
        return textResult(await bridgeCall("fieldbus_claim_resources", { ...base, path: p.path, index: p.index, save: p.save === true }));
      case "create_gsd_box":
        need(p, ["controllerPath", "name", "gsdPath", "moduleIdentNumber", "subType"], p.action);
        return textResult(await bridgeCall("fieldbus_create_gsd_box", { ...base, controllerPath: p.controllerPath, name: p.name, gsdPath: p.gsdPath, moduleIdentNumber: p.moduleIdentNumber, subType: p.subType, boxFlags: p.boxFlags, dapNumber: p.dapNumber, before: p.before, save: p.save === true }));
      case "add_netvar":
        need(p, ["boxPath", "name", "dataType"], p.action);
        return textResult(await bridgeCall("fieldbus_add_netvar", { ...base, boxPath: p.boxPath, name: p.name, dataType: p.dataType, before: p.before, save: p.save === true }));
      case "set_station_address":
        need(p, ["path", "address"], p.action);
        return textResult(await bridgeCall("fieldbus_set_station_address", { ...base, path: p.path, address: p.address, save: p.save === true }));
      case "import_dbc":
        need(p, ["masterPath", "fileName"], p.action);
        return textResult(await bridgeCall("fieldbus_import_dbc", { ...base, masterPath: p.masterPath, fileName: p.fileName, importExtendedMessages: p.importExtendedMessages, importMultiplexedDataMessages: p.importMultiplexedDataMessages, keepUnchangedMessages: p.keepUnchangedMessages, communicateWithSlavesFromDbcFile: p.communicateWithSlavesFromDbcFile, save: p.save === true }));
      case "get_xml":
        need(p, ["path"], p.action);
        return textResult(await bridgeCall("fieldbus_get_xml", { ...base, path: p.path }));
      case "set_xml":
        need(p, ["path", "xml"], p.action);
        return textResult(await bridgeCall("fieldbus_set_xml", { ...base, path: p.path, xml: p.xml, returnXml: p.returnXml === true, save: p.save === true }));
    }
  },
);

server.registerTool(
  "tc_module",
  toolSchemas.tc_module,
  async (p) => {
    switch (p.action) {
      case "list":
        return textResult(await bridgeCall("twincat_module_list", {}));
      case "create":
        need(p, ["name", "by", "id"], p.action);
        return textResult(await bridgeCall("twincat_module_create", { name: p.name, by: p.by, id: p.id, before: p.before }));
      case "get_xml":
        need(p, ["path"], p.action);
        return textResult(await bridgeCall("twincat_module_get_xml", { path: p.path }));
      case "set_xml":
        need(p, ["path", "xml"], p.action);
        return textResult(await bridgeCall("twincat_module_set_xml", { path: p.path, xml: p.xml, returnXml: p.returnXml === true }));
      case "enable_symbols":
        need(p, ["path"], p.action);
        if (p.parameters !== true && p.dataAreas !== true) {
          throw new Error("enable_symbols: set parameters:true and/or dataAreas:true (nothing to do otherwise).");
        }
        return textResult(await bridgeCall("twincat_module_enable_symbols", { path: p.path, parameters: p.parameters === true, dataAreas: p.dataAreas === true, returnXml: p.returnXml === true }));
      case "set_context":
        if (p.confirm !== MODULE_CONTEXT_CONFIRMATION) {
          throw new Error('Blocked. set_context assigns the module to a task execution context, changing the activated mapping/runtime context. Re-run with confirm="' + MODULE_CONTEXT_CONFIRMATION + '" to proceed.');
        }
        need(p, ["path", "taskObjectId"], p.action);
        return textResult(await bridgeCall("twincat_module_set_context", { path: p.path, taskObjectId: p.taskObjectId, contextId: p.contextId }));
    }
  },
);

server.registerTool(
  "tc_cpp",
  toolSchemas.tc_cpp,
  async (p) => {
    switch (p.action) {
      case "create_project":
        need(p, ["name", "template"], p.action);
        return textResult(await bridgeCall("twincat_cpp_create_project", { name: p.name, template: p.template, before: p.before }));
      case "create_module":
        need(p, ["projectPath", "name"], p.action);
        return textResult(await bridgeCall("twincat_cpp_create_module", { projectPath: p.projectPath, name: p.name, template: p.template, before: p.before }));
      case "open":
        need(p, ["file"], p.action);
        return textResult(await bridgeCall("twincat_cpp_open", { file: p.file, subType: p.subType, before: p.before }));
      case "tmc_codegen":
        need(p, ["projectPath"], p.action);
        return textResult(await bridgeCall("twincat_cpp_consume_xml", { projectPath: p.projectPath }));
      case "set_props":
        need(p, ["projectPath"], p.action);
        if (p.bootProjectEncryption === undefined && p.saveProjectSources === undefined) {
          throw new Error("set_props needs at least one of bootProjectEncryption / saveProjectSources.");
        }
        return textResult(await bridgeCall("twincat_cpp_set_props", { projectPath: p.projectPath, bootProjectEncryption: p.bootProjectEncryption, saveProjectSources: p.saveProjectSources }));
      case "build":
        need(p, ["projectName"], p.action);
        return textResult(await bridgeCall("twincat_cpp_build_project", { projectName: p.projectName, config: p.config, waitForFinish: p.waitForFinish, timeoutMs: p.timeoutMs }));
      case "publish":
        need(p, ["projectPath"], p.action);
        if (p.confirm !== CPP_PUBLISH_CONFIRMATION) {
          throw new Error('Blocked. publish builds the C++ module for ALL platforms and exports deployable driver artifacts. Re-run with confirm="' + CPP_PUBLISH_CONFIRMATION + '" to proceed.');
        }
        return textResult(await bridgeCall("twincat_cpp_publish", { projectPath: p.projectPath, confirm: p.confirm }));
    }
  },
);

server.registerTool(
  "tc_measurement",
  toolSchemas.tc_measurement,
  async (p) => {
    const base = { mode: p.mode };
    switch (p.action) {
      case "scope_create":
        need(p, ["name"], p.action);
        return textResult(await bridgeCall("measurement_scope_create", { ...base, name: p.name, template: p.template, destination: p.destination }));
      case "scope_add_child":
        need(p, ["project"], p.action);
        return textResult(await bridgeCall("measurement_scope_add_child", { ...base, project: p.project, parentPath: p.parentPath, name: p.name, elementType: p.elementType === undefined ? 0 : p.elementType }));
      case "scope_rename":
        need(p, ["project", "path", "newName"], p.action);
        return textResult(await bridgeCall("measurement_scope_rename", { ...base, project: p.project, path: p.path, newName: p.newName }));
      case "scope_record":
        need(p, ["project", "state"], p.action);
        if (p.state === "start" && p.confirm !== MEASUREMENT_RECORD_CONFIRMATION) {
          throw new Error('Blocked. scope_record state="start" performs live data acquisition against the running target. Re-run with confirm="' + MEASUREMENT_RECORD_CONFIRMATION + '" to proceed.');
        }
        return textResult(await bridgeCall("measurement_scope_record", { ...base, project: p.project, state: p.state }));
      case "analytics_create":
        need(p, ["name"], p.action);
        return textResult(await bridgeCall("measurement_analytics_create", { ...base, name: p.name, template: p.template, destination: p.destination }));
      case "logger_create":
        need(p, ["name"], p.action);
        return textResult(await bridgeCall("analytics_logger_create", { ...base, name: p.name, before: p.before }));
      case "logger_delete":
        need(p, ["name"], p.action);
        if (p.dryRun !== true && p.confirm !== DELETE_CONFIRMATION) {
          throw new Error('Blocked. logger_delete removes a TIAN DataLogger node. Re-run with dryRun:true to preview, or confirm="' + DELETE_CONFIRMATION + '" to delete.');
        }
        return textResult(await bridgeCall("analytics_logger_delete", { ...base, name: p.name, dryRun: p.dryRun === true }));
      case "stream_create":
        need(p, ["name"], p.action);
        return textResult(await bridgeCall("analytics_stream_create", { ...base, name: p.name, before: p.before }));
      case "stream_delete":
        need(p, ["name"], p.action);
        if (p.dryRun !== true && p.confirm !== DELETE_CONFIRMATION) {
          throw new Error('Blocked. stream_delete removes a TIAN StreamHelper node. Re-run with dryRun:true to preview, or confirm="' + DELETE_CONFIRMATION + '" to delete.');
        }
        return textResult(await bridgeCall("analytics_stream_delete", { ...base, name: p.name, dryRun: p.dryRun === true }));
      case "node_get_xml":
        need(p, ["path"], p.action);
        return textResult(await bridgeCall("twincat_get_tree_item_xml", { ...base, treePath: p.path, summary: p.summary === true }));
      case "node_set_xml":
        need(p, ["path", "xml"], p.action);
        return textResult(await bridgeCall("twincat_set_tree_item_xml", { ...base, treePath: p.path, xml: p.xml, returnXml: p.returnXml === true }));
    }
  },
);

server.registerTool(
  "tc_license",
  toolSchemas.tc_license,
  async (p) => {
    switch (p.action) {
      case "list":
        return textResult(await bridgeCall("twincat_license_list_devices", { raw: p.raw === true }));
      case "add":
        need(p, ["name", "device"], p.action);
        return textResult(await bridgeCall("twincat_license_add_device", { name: p.name, device: p.device }));
      case "activate_response":
        if (p.confirm !== LICENSE_ACTIVATE_CONFIRMATION) {
          throw new Error('Blocked. activate_response activates an OEM license response file (a license-activation state change). Re-run with confirm="' + LICENSE_ACTIVATE_CONFIRMATION + '" to proceed.');
        }
        need(p, ["path"], p.action);
        return textResult(await bridgeCall("twincat_license_activate_response", { confirm: p.confirm, path: p.path, oemGuid: p.oemGuid }));
    }
  },
);

server.registerTool(
  "tc_variant",
  toolSchemas.tc_variant,
  async (p) => {
    switch (p.action) {
      case "get_config":
        return textResult(await bridgeCall("twincat_get_variant_config", {}));
      case "get_current":
        return textResult(await bridgeCall("twincat_get_current_variant", {}));
      case "set_config":
        need(p, ["xml"], p.action);
        return textResult(await bridgeCall("twincat_set_variant_config", { xml: p.xml, save: p.save === true }));
      case "select":
        need(p, ["variant"], p.action);
        return textResult(await bridgeCall("twincat_set_current_variant", { variant: p.variant, save: p.save === true }));
      case "disable":
        need(p, ["path"], p.action);
        return textResult(await bridgeCall("twincat_set_item_variant_disable", { treePath: p.path, disable: true, save: p.save === true }));
      case "enable":
        need(p, ["path"], p.action);
        return textResult(await bridgeCall("twincat_set_item_variant_disable", { treePath: p.path, disable: false, save: p.save === true }));
    }
  },
);

server.registerTool(
  "twincat_activate_configuration",
  toolSchemas.twincat_activate_configuration,
  async ({ confirm }) => {
    if (confirm !== ACTIVATE_CONFIRMATION) {
      throw new Error(`Blocked. Re-run with confirm="${ACTIVATE_CONFIRMATION}" to activate the current TwinCAT configuration.`);
    }
    return textResult(await bridgeCall("twincat_activate_configuration", { confirm }));
  },
);

server.registerTool(
  "twincat_restart_runtime",
  toolSchemas.twincat_restart_runtime,
  async ({ confirm }) => {
    if (confirm !== RESTART_CONFIRMATION) {
      throw new Error(`Blocked. Re-run with confirm="${RESTART_CONFIRMATION}" to restart TwinCAT.`);
    }
    return textResult(await bridgeCall("twincat_restart_runtime", { confirm }));
  },
);

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error("te1000-mcp server running on stdio (native daemon mode)");
}

main().catch((error) => {
  console.error("Server error:", error);
  process.exit(1);
});
