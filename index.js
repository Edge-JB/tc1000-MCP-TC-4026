#!/usr/bin/env node
// te1000-mcp: MCP server for the Beckhoff TwinCAT XAE / TE1000 Automation
// Interface, via the PowerShell COM bridge (powershell/te1000-bridge.ps1).
// v2: tool surface grouped by noun with action enums, terse schemas, compact
// outputs — agent context is the scarce resource. The bridge is unchanged and
// still answers the original fine-grained action names; this file maps the
// merged tools onto them. plc_login/plc_logout were dropped from the surface
// (DTE on the 64-bit shell exposes no window automation, so they never worked
// here); reach them via xae_command if ever needed on another shell.
"use strict";

const { spawn } = require("child_process");
const path = require("path");
const os = require("os");
const fs = require("fs");
const { McpServer } = require("@modelcontextprotocol/sdk/server/mcp.js");
const { StdioServerTransport } = require("@modelcontextprotocol/sdk/server/stdio.js");
const z = require("zod/v4");

const ACTIVATE_CONFIRMATION = "ALLOW_TWINCAT_ACTIVATE";
const RESTART_CONFIRMATION = "ALLOW_TWINCAT_RESTART";
const XAE_COMMAND_CONFIRMATION = "ALLOW_XAE_COMMAND_EXEC";
const PLC_LOGOUT_CONFIRMATION = "ALLOW_PLC_LOGOUT";

// --- Modal-dialog watchdog -------------------------------------------------
// A bridge COM call into XAE blocks until any modal dialog it raises is
// dismissed by a human, hanging the MCP call forever. dialog-watch.ps1 runs
// alongside each call: it detects the modal dialog, auto-clicks allowlisted
// ones, and otherwise lets us fail the call with the dialog's details instead
// of hanging. Toggle/tune via env:
//   TE1000_DIALOG_WATCH=0        disable the watchdog entirely
//   TE1000_DIALOG_AUTODISMISS=0  detect+report only, never auto-click
//   TE1000_DIALOG_GRACE_MS=N     how long a blocking dialog must persist before
//                                we abandon the call (default 4000)
//   TE1000_BRIDGE_TIMEOUT_MS=N   optional wall-clock backstop (default 0 = off,
//                                so long builds are never killed)
const DIALOG_WATCH = process.env.TE1000_DIALOG_WATCH !== "0";
const AUTO_DISMISS = process.env.TE1000_DIALOG_AUTODISMISS !== "0";
const BLOCK_GRACE_MS = Number(process.env.TE1000_DIALOG_GRACE_MS) || 4000;
const HARD_TIMEOUT_MS = Number(process.env.TE1000_BRIDGE_TIMEOUT_MS) || 0;
let callSeq = 0;

function killTree(child) {
  if (!child || child.pid === undefined) return;
  try { child.kill(); } catch {}
  try { spawn("taskkill", ["/PID", String(child.pid), "/T", "/F"], { stdio: "ignore" }); } catch {}
}

// 64-bit TcXaeShell (DTE.17.0) needs 64-bit PowerShell; the legacy 32-bit shell (DTE.15.0) needs SysWOW64.
function resolveBridgePaths() {
  const winDir = process.env.WINDIR || "C:\\Windows";
  const ps64 = path.join(winDir, "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
  const psWow = path.join(winDir, "SysWOW64", "WindowsPowerShell", "v1.0", "powershell.exe");
  const use64 = fs.existsSync("C:\\Program Files\\Beckhoff\\TcXaeShell\\Common7\\IDE\\PublicAssemblies\\envdte.dll");
  return {
    psExe: use64 ? ps64 : psWow,
    scriptPath: path.join(__dirname, "powershell", "te1000-bridge.ps1"),
    watchPath: path.join(__dirname, "powershell", "dialog-watch.ps1"),
    allowlistPath: path.join(__dirname, "powershell", "dialog-allowlist.json"),
  };
}

// One-shot dialog probe (auto-dismisses allowlisted dialogs when AUTO_DISMISS).
// Returns the snapshot object, or null if the probe couldn't run.
function probeDialogOnce() {
  return new Promise((resolve) => {
    const { psExe, watchPath, allowlistPath } = resolveBridgePaths();
    const args = ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", watchPath, "-Mode", "probe", "-AllowlistPath", allowlistPath];
    if (AUTO_DISMISS) args.push("-AutoDismiss");
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
      setTimeout(() => { try { c.kill(); } catch {} finish(null); }, 15000); // don't let the gate itself hang
    } catch { finish(null); }
  });
}

// Pre-flight: a modal dialog already sitting in XAE (file changed outside the
// editor, lost target connection, an earlier un-cleared prompt) corrupts the
// next command's result ("No solution is open", etc.) and hangs the old code.
// So before running anything: probe, auto-dismiss if allowlisted, and refuse to
// run with the dialog's details if a blocking prompt remains.
async function preflightGate(action) {
  if (!DIALOG_WATCH) return;
  let snap = await probeDialogOnce();
  if (snap && snap.found && snap.dismissed) {
    await new Promise((r) => setTimeout(r, 400)); // let the dismissed dialog tear down
    snap = await probeDialogOnce();
  }
  if (snap && snap.found && snap.blocking) {
    const btns = Array.isArray(snap.buttons) && snap.buttons.length ? snap.buttons.map((b) => `[${b}]`).join(" ") : "(none detected)";
    throw new Error(
      `Pre-flight blocked '${action}': XAE already has a modal dialog open, so the command was NOT run ` +
      `(a lingering prompt corrupts command results and would otherwise hang).\n` +
      `  Title:   ${snap.title || "(untitled)"}\n` +
      `  Message: ${snap.text || "(no text)"}\n` +
      `  Buttons: ${btns}\n` +
      `Clear it on the machine, or add a rule to powershell/dialog-allowlist.json to auto-dismiss ` +
      `it (then this call proceeds automatically).`,
    );
  }
}

// PLC online-session control via UI Automation (powershell/plc-session.ps1).
// The 64-bit shell's DTE can't log the PLC out (Logout command never IsAvailable,
// no key binding), but the IDE's Login/Logout toolbar buttons are reachable via
// UIA. mode "status" reports { loggedIn, ... }; mode "logout" invokes the Logout
// button (never Login). Returns the parsed snapshot, or null if it couldn't run.
function sessionCall(mode) {
  return new Promise((resolve) => {
    const { psExe } = resolveBridgePaths();
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
  await preflightGate(action);
  return runBridge(action, payload);
}

function runBridge(action, payload = {}) {
  return new Promise((resolve, reject) => {
    const scriptPath = path.join(__dirname, "powershell", "te1000-bridge.ps1");
    const watchPath = path.join(__dirname, "powershell", "dialog-watch.ps1");
    const allowlistPath = path.join(__dirname, "powershell", "dialog-allowlist.json");
    const encodedPayload = Buffer.from(JSON.stringify(payload), "utf8").toString("base64");
    // 64-bit TcXaeShell (DTE.17.0) needs 64-bit PowerShell; the legacy 32-bit shell (DTE.15.0) needs SysWOW64.
    const winDir = process.env.WINDIR || "C:\\Windows";
    const ps64 = path.join(winDir, "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
    const psWow = path.join(winDir, "SysWOW64", "WindowsPowerShell", "v1.0", "powershell.exe");
    const use64 = fs.existsSync("C:\\Program Files\\Beckhoff\\TcXaeShell\\Common7\\IDE\\PublicAssemblies\\envdte.dll");
    const psExe = use64 ? ps64 : psWow;
    const child = spawn(
      psExe,
      ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", scriptPath, "-Action", action, "-PayloadBase64", encodedPayload],
      { stdio: ["ignore", "pipe", "pipe"] },
    );

    // --- dialog watchdog ---------------------------------------------------
    let settled = false;
    let watcher = null;
    let pollTimer = null;
    let hardTimer = null;
    let blockingSince = null;
    let lastDialog = null;
    const outFile = path.join(os.tmpdir(), `te1000-dlg-${process.pid}-${Date.now()}-${callSeq++}.json`);
    const stopFile = `${outFile}.stop`;

    const cleanup = () => {
      if (pollTimer) { clearInterval(pollTimer); pollTimer = null; }
      if (hardTimer) { clearTimeout(hardTimer); hardTimer = null; }
      try { fs.writeFileSync(stopFile, "1"); } catch {}
      if (watcher) { try { watcher.kill(); } catch {} watcher = null; }
      setTimeout(() => { for (const f of [outFile, stopFile]) { try { fs.unlinkSync(f); } catch {} } }, 2000);
    };

    if (DIALOG_WATCH) {
      const wargs = ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", watchPath, "-Mode", "guard",
        "-OutFile", outFile, "-StopFile", stopFile, "-AllowlistPath", allowlistPath];
      if (AUTO_DISMISS) wargs.push("-AutoDismiss");
      try {
        watcher = spawn(psExe, wargs, { stdio: "ignore" });
        watcher.on("error", () => {});
      } catch { watcher = null; }

      pollTimer = setInterval(() => {
        if (settled) return;
        let snap;
        try { snap = JSON.parse(fs.readFileSync(outFile, "utf8")); } catch { return; }
        if (snap && snap.found && snap.blocking) {
          lastDialog = snap;
          if (blockingSince === null) blockingSince = Date.now();
          else if (Date.now() - blockingSince >= BLOCK_GRACE_MS) {
            settled = true;
            const d = lastDialog || {};
            const btns = Array.isArray(d.buttons) && d.buttons.length ? d.buttons.map((b) => `[${b}]`).join(" ") : "(none detected)";
            killTree(child);
            cleanup();
            reject(new Error(
              `XAE is blocked on a modal dialog, so this '${action}' call cannot complete.\n` +
              `  Title:   ${d.title || "(untitled)"}\n` +
              `  Message: ${d.text || "(no text)"}\n` +
              `  Buttons: ${btns}\n` +
              `The dialog is still open on the machine — clear it there, or add a rule to ` +
              `powershell/dialog-allowlist.json to auto-dismiss this dialog next time. ` +
              `The operation's result is indeterminate.`,
            ));
          }
        } else {
          blockingSince = null;
        }
      }, 1000);
    }

    if (HARD_TIMEOUT_MS > 0) {
      hardTimer = setTimeout(() => {
        if (settled) return;
        settled = true;
        killTree(child);
        cleanup();
        reject(new Error(`Bridge call '${action}' exceeded TE1000_BRIDGE_TIMEOUT_MS (${HARD_TIMEOUT_MS} ms); no modal dialog was detected — XAE may be busy.`));
      }, HARD_TIMEOUT_MS);
    }

    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => { stdout += chunk.toString(); });
    child.stderr.on("data", (chunk) => { stderr += chunk.toString(); });
    child.on("error", (err) => {
      if (settled) return;
      settled = true;
      cleanup();
      reject(err);
    });
    child.on("close", (code) => {
      if (settled) return;
      settled = true;
      cleanup();
      if (code !== 0) {
        reject(new Error(`Bridge failed with exit code ${code}: ${stderr || stdout}`.trim()));
        return;
      }
      try {
        const parsed = JSON.parse(stdout);
        if (!parsed.ok) {
          reject(new Error(parsed.error || "Bridge returned failure"));
          return;
        }
        resolve(parsed.data);
      } catch (error) {
        reject(new Error(`Failed to parse bridge output: ${error.message}\n${stdout}`));
      }
    });
  });
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
    if (typeof data.xml === "string") return text(data.xml); // raw XML beats JSON-escaped XML
    if (Array.isArray(data.commands)) return text(`${data.count} commands\n${data.commands.join("\n")}`);
    if (Array.isArray(data.items) && "available" in data) {
      if (!data.available) return text("error list unavailable");
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

const server = new McpServer({ name: "te1000-mcp", version: "2.0.0" });

const XAE_ACTIONS = {
  status: "xae_status",
  open_solution: "xae_open_solution",
  save_all: "xae_save_all",
  active_document: "xae_get_active_document",
  selected_items: "xae_get_selected_items",
  error_list: "xae_get_error_list",
  clear_error_list: "xae_clear_error_list",
  list_commands: "xae_list_commands",
};

server.registerTool(
  "xae",
  {
    description: "XAE shell: status, open_solution (solutionPath), save_all, active_document, selected_items, error_list, clear_error_list, list_commands (filter regex, limit).",
    inputSchema: {
      action: z.enum(Object.keys(XAE_ACTIONS)),
      solutionPath: z.string().optional(),
      closeExisting: z.boolean().optional(),
      filter: z.string().optional(),
      limit: z.number().int().positive().max(5000).optional(),
      mode: z.enum(["active", "activeOrCreate", "create"]).optional().describe("DTE attach mode; default active (open_solution: activeOrCreate)"),
    },
  },
  async ({ action, solutionPath, closeExisting, filter, limit, mode }) => {
    const payload = { mode };
    if (action === "open_solution") {
      need({ solutionPath }, ["solutionPath"], action);
      Object.assign(payload, { solutionPath, visible: true, closeExisting: closeExisting || false, mode: mode || "activeOrCreate" });
    }
    if (action === "list_commands") Object.assign(payload, { filter, limit });
    if (action === "error_list") payload.limit = limit;
    return textResult(await bridgeCall(XAE_ACTIONS[action], payload));
  },
);

server.registerTool(
  "xae_build",
  {
    description: "Clean/Build/Rebuild the active solution configuration; waits for completion by default.",
    inputSchema: {
      action: z.enum(["clean", "build", "rebuild"]),
      waitForFinish: z.boolean().default(true),
      timeoutMs: z.number().int().positive().max(3600000).default(1800000),
    },
  },
  async (params) => textResult(await bridgeCall("xae_solution_build", params)),
);

server.registerTool(
  "xae_command",
  {
    description: `Execute a raw XAE/DTE command by name (e.g. View.SolutionExplorer). Guarded: confirm="${XAE_COMMAND_CONFIRMATION}".`,
    inputSchema: {
      confirm: z.string(),
      commandName: z.string(),
      args: z.string().optional(),
    },
  },
  async ({ confirm, commandName, args }) => {
    if (confirm !== XAE_COMMAND_CONFIRMATION) {
      throw new Error(`Blocked. Re-run with confirm="${XAE_COMMAND_CONFIRMATION}" to execute an arbitrary XAE/DTE command.`);
    }
    return textResult(await bridgeCall("xae_execute_command", { commandName, args }));
  },
);

server.registerTool(
  "tc_tree",
  {
    description: "TwinCAT System Manager tree items; paths use ^ separators (e.g. TIPC^MyPlc, TIID^Device 2 (EtherCAT)^Box 1). BATCH-FIRST: when acting on more than one item, use the matching *_batch action — it runs N operations in ONE DTE attach and returns a compact roll-up {count,succeeded,failed,results:[{...,ok,error?}]} (continue-on-error), instead of paying a process-spawn + attach per call. Actions, grouped single / batch: READ identity — get / get_batch (paths:[...]); TEST existence — exists / exists_batch (paths:[...]); READ xml — get_xml (ProduceXml, raw); WRITE params — set_xml / set_xml_batch (items:[{path,xml}]) (ConsumeXml; compact unless returnXml:true); RENAME — rename / rename_batch (renames:[{name|path,newName}]) (keeps IO links intact); CREATE — create / create_batch (creates:[{parent,name,subType,before?,createInfo?}]); DELETE — delete / delete_batch (deletes:[{parent,name}]). No batch form: children (lists child items, incl. CPX-AP/Festo sub-modules), import (.xti under path), export (name to file), focus (Solution Explorer).",
    inputSchema: {
      action: z.enum(["get", "children", "exists", "exists_batch", "get_batch", "get_xml", "set_xml", "set_xml_batch", "rename", "rename_batch", "create", "create_batch", "delete", "delete_batch", "import", "export", "focus"]),
      path: z.string(),
      paths: z.array(z.string()).optional(),
      xml: z.string().optional(),
      returnXml: z.boolean().optional(),
      name: z.string().optional(),
      renames: z.array(z.object({ name: z.string().optional(), path: z.string().optional(), newName: z.string() })).optional(),
      items: z.array(z.object({ path: z.string(), xml: z.string() })).optional(),
      creates: z.array(z.object({ parent: z.string(), name: z.string(), subType: z.number().int(), before: z.string().optional(), createInfo: z.string().optional() })).optional(),
      deletes: z.array(z.object({ parent: z.string(), name: z.string() })).optional(),
      subType: z.number().int().optional(),
      before: z.string().optional().describe("insert before this sibling"),
      createInfo: z.string().optional(),
      file: z.string().optional(),
      reconnect: z.boolean().default(true),
      newName: z.string().optional(),
    },
  },
  async (p) => {
    const t = { treePath: p.path };
    switch (p.action) {
      case "get": return textResult(await bridgeCall("twincat_lookup_tree_item", t));
      case "children": return textResult(await bridgeCall("twincat_list_children", t));
      case "exists": return textResult(await bridgeCall("twincat_test_item_path", t));
      case "exists_batch":
        need(p, ["paths"], p.action);
        return textResult(await bridgeCall("twincat_test_item_paths", { paths: p.paths }));
      case "get_batch":
        need(p, ["paths"], p.action);
        return textResult(await bridgeCall("twincat_lookup_tree_items", { paths: p.paths }));
      case "get_xml": return textResult(await bridgeCall("twincat_get_tree_item_xml", t));
      case "set_xml":
        need(p, ["xml"], p.action);
        return textResult(await bridgeCall("twincat_set_tree_item_xml", { ...t, xml: p.xml, returnXml: p.returnXml === true }));
      case "set_xml_batch":
        need(p, ["items"], p.action);
        return textResult(await bridgeCall("twincat_set_tree_item_xml_batch", { items: p.items, returnXml: p.returnXml === true }));
      case "rename":
        need(p, ["newName"], p.action);
        return textResult(await bridgeCall("twincat_rename_tree_item", { treePath: p.path, newName: p.newName }));
      case "rename_batch":
        need(p, ["renames"], p.action);
        return textResult(await bridgeCall("twincat_rename_tree_items", { basePath: p.path, renames: p.renames }));
      case "create":
        need(p, ["name", "subType"], p.action);
        return textResult(await bridgeCall("twincat_create_child", { parentPath: p.path, childName: p.name, subType: p.subType, beforeChildName: p.before, createInfo: p.createInfo }));
      case "create_batch":
        need(p, ["creates"], p.action);
        return textResult(await bridgeCall("twincat_create_children", { creates: p.creates }));
      case "delete":
        need(p, ["name"], p.action);
        return textResult(await bridgeCall("twincat_delete_child", { parentPath: p.path, childName: p.name }));
      case "delete_batch":
        need(p, ["deletes"], p.action);
        return textResult(await bridgeCall("twincat_delete_children", { deletes: p.deletes }));
      case "import":
        need(p, ["file"], p.action);
        return textResult(await bridgeCall("twincat_import_child", { parentPath: p.path, filePath: p.file, beforeChildName: p.before, reconnect: p.reconnect, importAsName: p.newName }));
      case "export":
        need(p, ["name", "file"], p.action);
        return textResult(await bridgeCall("twincat_export_child", { parentPath: p.path, childName: p.name, filePath: p.file }));
      case "focus": return textResult(await bridgeCall("xae_focus_tree_item", t));
    }
  },
);

server.registerTool(
  "tc_link",
  {
    description: "Variable links (producer↔consumer); dot-form PLC subfields auto-resolve to XAE ^ subitem form. BATCH-FIRST: for more than one link use link_batch/unlink_batch — N ops in ONE DTE attach with a verbose per-entry roll-up (incl. resolved paths), instead of an attach per link. Actions, grouped single / batch: LINK — link (a=source, b=destination) / link_batch (links:[{a,b}]); UNLINK — unlink (a, optional b; a alone removes all its links) / unlink_batch (links:[{a,b?}]); resolve (report valid path forms for a).",
    inputSchema: {
      action: z.enum(["link", "unlink", "resolve", "link_batch", "unlink_batch"]),
      a: z.string(),
      b: z.string().optional(),
      autoResolve: z.boolean().default(true),
      links: z.array(z.object({ a: z.string(), b: z.string().optional() })).optional(),
    },
  },
  async ({ action, a, b, autoResolve, links }) => {
    if (action === "link") {
      need({ b }, ["b"], action);
      return textResult(await bridgeCall("twincat_link_variables", { producer: a, consumer: b, autoResolve }));
    }
    if (action === "unlink") return textResult(await bridgeCall("twincat_unlink_variables", { variableA: a, variableB: b }));
    if (action === "link_batch") {
      need({ links }, ["links"], action);
      return textResult(await bridgeCall("twincat_link_variables_batch", { links, autoResolve }));
    }
    if (action === "unlink_batch") {
      need({ links }, ["links"], action);
      return textResult(await bridgeCall("twincat_unlink_variables_batch", { links }));
    }
    return textResult(await bridgeCall("twincat_resolve_variable_path", { variablePath: a }));
  },
);

server.registerTool(
  "tc_system",
  {
    description: "System Manager: get_netid, set_netid (netId), errors (latest messages), rescan_plc (path, default TIPC), scan_io_boxes (path = IO device node).",
    inputSchema: {
      action: z.enum(["get_netid", "set_netid", "errors", "rescan_plc", "scan_io_boxes"]),
      netId: z.string().optional(),
      path: z.string().optional(),
    },
  },
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
  "nc",
  {
    description: "NC motion tree: tasks (list under TINC), axes (path = task, default first task), axis (path = full axis path, returns info + children).",
    inputSchema: {
      action: z.enum(["tasks", "axes", "axis"]),
      path: z.string().optional(),
    },
  },
  async ({ action, path: p }) => {
    if (action === "tasks") return textResult(await bridgeCall("nc_list_tasks", {}));
    if (action === "axes") return textResult(await bridgeCall("nc_list_axes", { taskPath: p }));
    need({ path: p }, ["path"], action);
    return textResult(await bridgeCall("nc_get_axis_info", { axisPath: p }));
  },
);

server.registerTool(
  "plc_download",
  {
    description: 'Deploy the active PLC project. method "bootproject" (default): headless via ITcPlcProject — writes the boot project to the target boot dir; twincat_restart_runtime loads and runs it. method "command": legacy DTE command route (needs a shell with window automation). autoLogout (default true): if the IDE is logged into the PLC, log out first via UI Automation so any source edits deferred by the online lock are applied before deploy. Never logs back in.',
    inputSchema: {
      method: z.enum(["bootproject", "command"]).default("bootproject"),
      treePath: z.string().optional().describe("PLC root node, default first project under TIPC"),
      autostart: z.boolean().default(true),
      commandName: z.string().optional(),
      autoLogout: z.boolean().default(true),
    },
  },
  async (params) => {
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
  {
    description: `PLC online-session control via UI Automation (the DTE Login/Logout commands are unavailable on the 64-bit shell). action "status" (read-only): reports { loggedIn }. action "logout": logs the IDE out of the PLC — this also applies any source edits the online lock deferred ("loaded after logout"). Never logs back in. Guarded: logout needs confirm="${PLC_LOGOUT_CONFIRMATION}".`,
    inputSchema: {
      action: z.enum(["status", "logout"]),
      confirm: z.string().optional(),
    },
  },
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
  "twincat_activate_configuration",
  {
    description: `Activate the TwinCAT configuration on the target. Guarded: confirm="${ACTIVATE_CONFIRMATION}".`,
    inputSchema: { confirm: z.string() },
  },
  async ({ confirm }) => {
    if (confirm !== ACTIVATE_CONFIRMATION) {
      throw new Error(`Blocked. Re-run with confirm="${ACTIVATE_CONFIRMATION}" to activate the current TwinCAT configuration.`);
    }
    return textResult(await bridgeCall("twincat_activate_configuration", { confirm }));
  },
);

server.registerTool(
  "twincat_restart_runtime",
  {
    description: `Start/restart the TwinCAT runtime on the target. Guarded: confirm="${RESTART_CONFIRMATION}".`,
    inputSchema: { confirm: z.string() },
  },
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
  console.error("te1000-mcp server running on stdio");
}

main().catch((error) => {
  console.error("Server error:", error);
  process.exit(1);
});
