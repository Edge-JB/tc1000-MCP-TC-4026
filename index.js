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
const DELETE_CONFIRMATION = "ALLOW_TWINCAT_DELETE";
const PLC_DOWNLOAD_CONFIRMATION = "ALLOW_PLC_DOWNLOAD";
const PLC_LIBRARY_REPO_CONFIRMATION = "ALLOW_PLC_LIBRARY_REPO";
const ROUTE_WRITE_CONFIRMATION = "ALLOW_TWINCAT_ROUTE_WRITE";
const MODULE_CONTEXT_CONFIRMATION = "ALLOW_TWINCAT_MODULE_CONTEXT";
const CPP_PUBLISH_CONFIRMATION = "ALLOW_CPP_PUBLISH";
const MEASUREMENT_RECORD_CONFIRMATION = "ALLOW_MEASUREMENT_RECORD";
const LICENSE_ACTIVATE_CONFIRMATION = "ALLOW_LICENSE_ACTIVATE";

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
    description: "XAE shell: status, open_solution (solutionPath; closeExisting:true reopens, discardChanges:true closes the current solution WITHOUT saving before reopening), save_all, active_document, selected_items, error_list, clear_error_list, list_commands (filter regex, limit).",
    inputSchema: {
      action: z.enum(Object.keys(XAE_ACTIONS)),
      solutionPath: z.string().optional(),
      closeExisting: z.boolean().optional(),
      discardChanges: z.boolean().optional(),
      filter: z.string().optional(),
      limit: z.number().int().positive().max(5000).optional(),
      mode: z.enum(["active", "activeOrCreate", "create"]).optional().describe("DTE attach mode; default active (open_solution: activeOrCreate)"),
    },
  },
  async ({ action, solutionPath, closeExisting, discardChanges, filter, limit, mode }) => {
    const payload = { mode };
    if (action === "open_solution") {
      need({ solutionPath }, ["solutionPath"], action);
      Object.assign(payload, { solutionPath, visible: true, closeExisting: closeExisting || false, discardChanges: discardChanges === true, mode: mode || "activeOrCreate" });
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
    description: "TwinCAT System Manager tree items; paths use ^ separators (e.g. TIPC^MyPlc, TIID^Device 2 (EtherCAT)^Box 1). BATCH-FIRST: when acting on more than one item, use the matching *_batch action — it runs N operations in ONE DTE attach and returns a compact roll-up {count,succeeded,failed,results:[{...,ok,error?}]} (continue-on-error), instead of paying a process-spawn + attach per call. Actions, grouped single / batch: READ identity — get / get_batch (paths:[...]); TEST existence — exists / exists_batch (paths:[...]); READ xml — get_xml (ProduceXml raw XML; summary:true for a compact identity + slot-module list instead of the full blob); WRITE params — set_xml / set_xml_batch (items:[{path,xml}]) (ConsumeXml; compact unless returnXml:true); RENAME — rename / rename_batch (renames:[{name|path,newName}]) (keeps IO links intact); CREATE — create / create_batch (creates:[{parent,name,subType,before?,createInfo?}]); create now VALIDATES the created child and errors clearly on a malformed/ghost result (blank name, name mismatch, or wrong parent) instead of silently succeeding — adding an EtherCAT box typically requires a proper ESI-based createInfo (a bare subType such as 9099 with no createInfo produces a blank-named ghost), and create_batch records such failures per-entry as ok:false (to ADD whole EtherCAT terminals/boxes from the ESI, prefer the dedicated createIO tool, which expands them natively); DELETE — delete / delete_batch (deletes:[{parent,name}], GUARDED: pass dryRun:true to preview which children exist without deleting, or confirm=\"ALLOW_TWINCAT_DELETE\" to actually delete). Mutating *_batch verbs (set_xml_batch, rename_batch, create_batch, delete_batch) accept optional save:true to save the solution once after the batch. No batch form: children (lists child items, incl. CPX-AP/Festo sub-modules), import (.xti under path), export (name to file), focus (Solution Explorer).",
    inputSchema: {
      action: z.enum(["get", "children", "exists", "exists_batch", "get_batch", "get_xml", "set_xml", "set_xml_batch", "rename", "rename_batch", "create", "create_batch", "delete", "delete_batch", "import", "export", "focus"]),
      path: z.string().optional(),
      paths: z.array(z.string()).optional(),
      xml: z.string().optional(),
      returnXml: z.boolean().optional(),
      summary: z.boolean().optional(),
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
      confirm: z.string().optional(),
      dryRun: z.boolean().optional(),
      save: z.boolean().optional(),
    },
  },
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
  "createIO",
  {
    description:
      "Create EtherCAT IO boxes (terminals/couplers) NATIVELY. Each module is added via the GUI's own \"Add Box\" route — ITcSmTreeItem.CreateChild(name, 9099, before, \"<productString>\") — so TwinCAT expands the box FROM ITS OWN ESI: a fully populated, non-hollow box (correct identity, SyncManagers, FMMUs, full <EtherCAT> mailbox/CoE/FoE element, complete PDOs+entries) for ANY class — digital, analog (in AND out), IO-Link, mailbox, DC, couplers. createInfo is the PLAIN PRODUCT STRING (the bare type = latest revision, or a revision-pinned form), NOT identity XML/numbers. " +
      "ONE unified shape — a single box and a whole multi-coupler design are the SAME operation: racks:[{ parent:\"<EtherCAT coupler/master tree path>\", modules:[{ type:\"EL1008\", name?:\"Term 7 (EL1008)\", revision?, before?:\"<sibling name>\" }] }]. A single box is just racks:[{parent, modules:[{type}]}]. Modules are created in array order (left-to-right terminal order); `before` inserts ahead of a named sibling; name omitted defaults to type. " +
      "Revision pinning: pass `revision` as the full Beckhoff product string suffix \"<pppp>-<rrrr>\" (decimal), e.g. type:\"EL1008\" revision:\"0000-0017\" → RevisionNo #x00110000; you may also pass the whole pinned string in `revision` (e.g. \"EL1008-0000-0017\"). Bare type = latest revision. " +
      "NO fallback — if CreateChild produces a ghost/unknown type, that ONE module is a clean ok:false (any stray child is cleaned up) and the rest continue. Optional save:true saves the solution once after everything. Returns a flat roll-up {count, succeeded, failed, results:[{parent, type, name, ok, error?}]}.",
    inputSchema: {
      racks: z.array(z.object({
        parent: z.string(),
        modules: z.array(z.object({
          type: z.string(),
          name: z.string().optional(),
          revision: z.string().optional(),
          before: z.string().optional().describe("insert before this sibling"),
        })),
      })),
      save: z.boolean().optional(),
    },
  },
  async ({ racks, save }) => {
    need({ racks }, ["racks"], "createIO");
    return textResult(await bridgeCall("twincat_create_io", { racks, save: save === true }));
  },
);

server.registerTool(
  "tc_link",
  {
    description: "Variable links (producer↔consumer); dot-form PLC subfields auto-resolve to XAE ^ subitem form. BATCH-FIRST: for more than one link use link_batch/unlink_batch — N ops in ONE DTE attach with a verbose per-entry roll-up (incl. resolved paths), instead of an attach per link. Actions, grouped single / batch: LINK — link (a=source, b=destination) / link_batch (links:[{a,b}]); UNLINK — unlink (a, optional b; a alone removes all its links) / unlink_batch (links:[{a,b?}]); resolve (report valid path forms for a); links (a=item path; reports that item's current variable links — closes the discover→act→verify loop). The mutating batch verbs (link_batch, unlink_batch) accept optional save:true to save the solution once after the batch.",
    inputSchema: {
      action: z.enum(["link", "unlink", "resolve", "link_batch", "unlink_batch", "links"]),
      a: z.string(),
      b: z.string().optional(),
      autoResolve: z.boolean().default(true),
      links: z.array(z.object({ a: z.string(), b: z.string().optional() })).optional(),
      save: z.boolean().optional(),
    },
  },
  async ({ action, a, b, autoResolve, links, save }) => {
    if (action === "link") {
      need({ b }, ["b"], action);
      return textResult(await bridgeCall("twincat_link_variables", { producer: a, consumer: b, autoResolve }));
    }
    if (action === "unlink") return textResult(await bridgeCall("twincat_unlink_variables", { variableA: a, variableB: b }));
    if (action === "link_batch") {
      need({ links }, ["links"], action);
      return textResult(await bridgeCall("twincat_link_variables_batch", { links, autoResolve, save: save === true }));
    }
    if (action === "unlink_batch") {
      need({ links }, ["links"], action);
      return textResult(await bridgeCall("twincat_unlink_variables_batch", { links, save: save === true }));
    }
    if (action === "links") {
      need({ a }, ["a"], action);
      return textResult(await bridgeCall("twincat_get_variable_links", { path: a }));
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
  "tc_mapping",
  {
    description:
      'Bulk variable-mapping (ALL links) ops on the loaded TwinCAT project via ITcSysManager2/3, whole-project (no tree path): ' +
      'produce (read-only) — ProduceMappingInfo serializes every current variable link/mapping to ONE XML blob (the IDE\'s "Export Mapping Information"); the blob is returned as raw XML. ' +
      'consume (xml) — ConsumeMappingInfo re-applies/merges a previously produced blob, ADDING links; MUTATES the offline config only (no live-cell impact until a later twincat_activate_configuration); optional save:true saves the solution after. ' +
      'clear — ClearMappingInfo deletes ALL variable links project-wide; destructive, GUARDED: requires confirm="' + DELETE_CONFIRMATION + '" (reuses the existing delete token); optional save:true. ' +
      'These are PROJECT-WIDE config-tree ops, NOT runtime/cell writes. SAFETY: the mapping blob spans the whole project and CAN include TwinSAFE I/O image links — produce/consume/clear may touch safety-related links; per project policy nothing should write toward safety, so run produce FIRST as a backup and treat the blob as opaque (export -> store -> consume round-trip). The exact XML schema is undocumented; test-import hand-edited blobs in the IDE before relying on them.',
    inputSchema: {
      action: z.enum(["produce", "consume", "clear"]),
      xml: z.string().optional(),
      confirm: z.string().optional(),
      save: z.boolean().optional(),
    },
  },
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
  "tc_task",
  {
    description:
      "RT tasks under TIRT (+ RT-core settings under TIRS, + a PLC project's LinkedTask under TIPC). CONFIG-ONLY: every action edits project config; nothing here touches the live runtime or the safety system, so no confirm token is needed (the guarded step is a later twincat_activate_configuration / twincat_restart_runtime). " +
      "Tree paths use ^ separators (e.g. TIRT^PlcTask). Actions: " +
      "list (tasks under TIRT); get (path; summary:true -> identity + parsed TaskDef tags instead of full XML); " +
      "create (name; withImage default true = SubType 0 / false = SubType 1 no image; before?; cycleTimeUs?/priority? applied after create via ConsumeXml; save?); " +
      "set_params (path; cycleTimeUs [us, converted to 100ns ticks = us*10] / priority [0-255] / autoStart; OR xml = raw <TreeItem>..</TreeItem> escape hatch [mutually exclusive with the typed fields]; returnXml?; save?). CAVEAT: the TaskDef tag names for cycle/priority/autostart are UNCONFIRMED against the AI docs — prefer the xml escape hatch and verify with get(summary) before trusting the typed fields; " +
      "add_image_var (path = a with-image task's Inputs/Outputs node; varName; dataType e.g. BOOL/INT/DINT; startAddress? default -1 = append; save?); " +
      "get_rt_settings (TIRS; summary:true -> parsed MaxCPUs/Affinity/per-CPU LoadLimit/BaseTime/LatencyWarning); " +
      "set_rt_settings (maxCPUs / affinity [TwinCAT hex token e.g. #x0000000000000007] / cpus [{id,loadLimit?,baseTimeNs?,latencyWarningUs?}]; OR xml escape hatch; returnXml?; save?); " +
      "bind_cpu (path; affinity = a name [CPU1..CPU8, MaskSingle/Dual/Quad/Hexa/Oct/All, None] OR a raw #x.. token; returnXml?; save?); " +
      "get_linked_task (path? = PLC root under TIPC, default first child of TIPC); " +
      "set_linked_task (path? = PLC root; linkedTask = XAE tree path of the RT task, e.g. TIRT^PlcTask; save?).",
    inputSchema: {
      action: z.enum([
        "list", "get", "create", "set_params", "add_image_var",
        "get_rt_settings", "set_rt_settings", "bind_cpu",
        "get_linked_task", "set_linked_task",
      ]),
      path: z.string().optional(),
      name: z.string().optional(),
      withImage: z.boolean().optional(),
      before: z.string().optional().describe("insert before this sibling task"),
      cycleTimeUs: z.number().optional(),
      priority: z.number().int().min(0).max(255).optional(),
      autoStart: z.boolean().optional(),
      summary: z.boolean().optional(),
      xml: z.string().optional(),
      returnXml: z.boolean().optional(),
      varName: z.string().optional(),
      dataType: z.string().optional(),
      startAddress: z.number().int().optional(),
      maxCPUs: z.number().int().optional(),
      affinity: z.string().optional(),
      cpus: z.array(z.object({
        id: z.number().int(),
        loadLimit: z.number().int().optional(),
        baseTimeNs: z.number().int().optional(),
        latencyWarningUs: z.number().int().optional(),
      })).optional(),
      linkedTask: z.string().optional(),
      save: z.boolean().optional(),
    },
  },
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
  {
    description: 'Deploy the active PLC project. Guarded: confirm="ALLOW_PLC_DOWNLOAD" (deploys a boot project to the live target). method "bootproject" (default): headless via ITcPlcProject — writes the boot project to the target boot dir; twincat_restart_runtime loads and runs it. method "command": legacy DTE command route (needs a shell with window automation). autoLogout (default true): if the IDE is logged into the PLC, log out first via UI Automation so any source edits deferred by the online lock are applied before deploy. Never logs back in.',
    inputSchema: {
      confirm: z.string().optional(),
      method: z.enum(["bootproject", "command"]).default("bootproject"),
      treePath: z.string().optional().describe("PLC root node, default first project under TIPC"),
      autostart: z.boolean().default(true),
      commandName: z.string().optional(),
      autoLogout: z.boolean().default(true),
    },
  },
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
  "plc_project",
  {
    description:
      'PLC (IEC) project lifecycle on the open solution. Tree paths use ^ separators; the PLC ROOT node is TIPC^<name>, the nested project INSTANCE node is TIPC^<name>^<name> Project. NODE MATTERS: ITcPlcProject (boot flags / generate_boot) is on the ROOT; ITcPlcIECProject* (check / plcopen_export/import / save_as_library) is on the INSTANCE node; ITcPlcTaskReference (link_task) is on the PlcTask node. ' +
      'Actions: create_from_template (name, template, before?, save?) — new PLC project from a stock template; open (name, file=.plcproj/.tpzip, subType 0 copy/1 move/2 use-in-place, before?, save?) — import an existing project; info (treePath? default first under TIPC) — read identity (nestedProjectName/instanceName/childCount); check (treePath? = INSTANCE node) — CheckAllObjects build-validate, returns allObjectsValid; set_boot_flags (treePath? = ROOT, autostart?, tmcFileCopy?) — config-only boot flags; ' +
      'plcopen_export (file, treePath? = INSTANCE, selection?) — write PLCopen XML; plcopen_import (file, treePath? = INSTANCE, options 0 NONE/1 RENAME/2 REPLACE/3 SKIP, selection?, folderStructure? default true, save?) — import PLCopen XML; save_as_library (file, treePath? = INSTANCE, install? default false — install:true mutates the local library repository) — save project as .library; link_task (treePath = PlcTask node, taskPath = ^-path of TIRT/TINC task) — set LinkedTask. ' +
      'GUARDED (live runtime/target writes), require confirm="' + PLC_DOWNLOAD_CONFIRMATION + '" and default to no-op: generate_boot_project (treePath? = ROOT, autostart? default true) — generates the boot project to the target boot dir (restart runtime to load); online (command login/logout/start/stop/reset_cold/reset_origin, treePath? — changes live online/runtime state; the ConsumeXml envelope is UNVERIFIED on this build and surfaces GetLastXmlError verbatim, reset_* need a prior login, build>=4010). Safety projects are deliberately out of scope.',
    inputSchema: {
      action: z.enum([
        "create_from_template", "open", "info", "check", "set_boot_flags",
        "generate_boot_project", "online", "link_task",
        "plcopen_export", "plcopen_import", "save_as_library",
      ]),
      name: z.string().optional(),
      template: z.enum(["Standard PLC Template", "Empty PLC Template"]).optional(),
      file: z.string().optional(),
      treePath: z.string().optional(),
      taskPath: z.string().optional(),
      subType: z.number().int().min(0).max(2).optional(),
      before: z.string().optional().describe("insert before this sibling PLC project"),
      autostart: z.boolean().optional(),
      tmcFileCopy: z.boolean().optional(),
      command: z.enum(["login", "logout", "start", "stop", "reset_cold", "reset_origin"]).optional(),
      options: z.number().int().min(0).max(3).optional(),
      selection: z.string().optional(),
      folderStructure: z.boolean().optional(),
      install: z.boolean().optional(),
      save: z.boolean().optional(),
      confirm: z.string().optional(),
    },
  },
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
      case "check":
        return textResult(await bridgeCall("plc_project_check", { treePath: p.treePath }));
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
      case "link_task":
        need(p, ["treePath", "taskPath"], p.action);
        return textResult(await bridgeCall("plc_project_link_task", { treePath: p.treePath, taskPath: p.taskPath }));
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
  {
    description:
      "PLC object authoring + code edit on the open solution (OFFLINE engineering only — no activate/download/online; edits land in-memory and reach the cell only via a later guarded plc_download + twincat_restart_runtime). Tree paths use ^ separators; safety (TISC-rooted) paths are rejected by policy. " +
      "CREATE — create / create_batch (parent, name, subType, language?, returnType?, extends?, implements?, declText?, before?): CreateChild sub-types 602 Program, 603 Function (returnType required), 604 FunctionBlock, 605 Enum, 606 Struct, 607 Union, 608 Action, 609 Method, 611 Property (returnType required), 615 GVL, 616 Transition, 618 Interface, 619 Visualization, 623 Alias, 629 ParameterList, 631 UML. language IECLANGUAGETYPES 0 NONE/1 ST/2 IL/3 SFC/4 FBD/5 CFC/6 LD (default 1). extends/implements for FB 604 / Program 602 derivation (618 uses extends as its base); declText seeds DUT/GVL decl. For code POUs prefer set_decl after create. " +
      "TEMPLATE — import_template (parent, paths[]) imports POU template file(s) (CreateChild sub-type 58). " +
      "READ — get_decl / get_impl / get_document (path). WRITE — set_decl / set_decl_batch (path, declText); set_impl / set_impl_batch (path, exactly one of implText|implXml — implXml is TwinCAT object XML, round-trip only, for graphical languages); set_document (path, documentXml). " +
      "BUILD-CHECK — check_objects (plcPath?, default first PLC under TIPC) runs CheckAllObjects on the nested IEC project (no download). Mutating batch verbs (create_batch, set_decl_batch, set_impl_batch) accept save:true to save the solution once after the batch.",
    inputSchema: {
      action: z.enum([
        "create", "create_batch", "import_template",
        "get_decl", "get_impl", "get_document",
        "set_decl", "set_decl_batch", "set_impl", "set_impl_batch", "set_document",
        "check_objects",
      ]),
      parent: z.string().optional(),
      name: z.string().optional(),
      subType: z.number().int().optional(),
      language: z.number().int().min(0).max(6).optional(),
      returnType: z.string().optional(),
      extends: z.string().optional(),
      implements: z.string().optional(),
      declText: z.string().optional(),
      before: z.string().optional().describe("insert before this sibling"),
      paths: z.array(z.string()).optional(),
      path: z.string().optional(),
      implText: z.string().optional(),
      implXml: z.string().optional(),
      documentXml: z.string().optional(),
      plcPath: z.string().optional(),
      creates: z.array(z.object({
        parent: z.string(),
        name: z.string(),
        subType: z.number().int(),
        language: z.number().int().min(0).max(6).optional(),
        returnType: z.string().optional(),
        extends: z.string().optional(),
        implements: z.string().optional(),
        declText: z.string().optional(),
        before: z.string().optional(),
      })).optional(),
      items: z.array(z.object({
        path: z.string(),
        declText: z.string().optional(),
        implText: z.string().optional(),
        implXml: z.string().optional(),
      })).optional(),
      save: z.boolean().optional(),
    },
  },
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
        return textResult(await bridgeCall("plc_pou_create_batch", { creates: p.creates, save: p.save === true }));
      case "import_template":
        need(p, ["parent", "paths"], p.action);
        return textResult(await bridgeCall("plc_pou_import_template", { parent: p.parent, paths: p.paths, save: p.save === true }));
      case "get_decl":
        need(p, ["path"], p.action);
        return textResult(await bridgeCall("plc_pou_get_decl", { path: p.path }));
      case "get_impl":
        need(p, ["path"], p.action);
        return textResult(await bridgeCall("plc_pou_get_impl", { path: p.path }));
      case "get_document":
        need(p, ["path"], p.action);
        return textResult(await bridgeCall("plc_pou_get_document", { path: p.path }));
      case "set_decl":
        need(p, ["path", "declText"], p.action);
        return textResult(await bridgeCall("plc_pou_set_decl", { path: p.path, declText: p.declText }));
      case "set_decl_batch":
        need(p, ["items"], p.action);
        return textResult(await bridgeCall("plc_pou_set_decl_batch", { items: p.items, save: p.save === true }));
      case "set_impl": {
        need(p, ["path"], p.action);
        const hasText = p.implText !== undefined;
        const hasXml = p.implXml !== undefined;
        if (hasText === hasXml) throw new Error("set_impl requires exactly one of implText / implXml.");
        return textResult(await bridgeCall("plc_pou_set_impl", { path: p.path, implText: p.implText, implXml: p.implXml }));
      }
      case "set_impl_batch":
        need(p, ["items"], p.action);
        return textResult(await bridgeCall("plc_pou_set_impl_batch", { items: p.items, save: p.save === true }));
      case "set_document":
        need(p, ["path", "documentXml"], p.action);
        return textResult(await bridgeCall("plc_pou_set_document", { path: p.path, documentXml: p.documentXml }));
      case "check_objects":
        return textResult(await bridgeCall("plc_pou_check_objects", { plcPath: p.plcPath }));
    }
  },
);

server.registerTool(
  "plc_library",
  {
    description:
      'PLC library references / placeholders / repositories via ITcPlcLibraryManager on the References node (TIPC^<plc>^<plc> Project^References). referencesPath defaults to the first PLC under TIPC. ' +
      'READ (no side effects): list (References → name/kind library|placeholder/displayName/distributor/version), scan (ScanLibraries → installed libs name/version/distributor/displayName), repos (Repositories → name/folder). ' +
      'WRITE — OFFLINE .plcproj edits, NO live-cell impact (not confirm-gated): add_library (name, version?, company?), add_placeholder (name, defLib?/defVer?/defDist? — omit defLib for the name-only form), set_resolution (placeholder, lib, version?, dist?), freeze (name? — omit to freeze ALL), remove_reference (name = library or placeholder). Each accepts save:true to File.SaveAll after the edit. ' +
      'LANDMINE: a .plcproj library-reference edit (add/remove/repin a library or placeholder, set resolution) requires a full solution close+reopen in XAE before it takes effect; adding source files alone does not — the response surfaces this note. ' +
      'REPO ADMIN — GUARDED, mutates the machine-wide TwinCAT library store (no runtime/cell change, but shared-machine state): install_library (repo, libPath, overwrite?), uninstall_library (repo, lib, version?, dist?), insert_repository (name, folder, index?), remove_repository (name), move_repository (name, index). These require confirm="' + PLC_LIBRARY_REPO_CONFIRMATION + '". Nothing here targets the safety system (References live only under TIPC).',
    inputSchema: {
      action: z.enum([
        "list", "scan", "repos",
        "add_library", "add_placeholder", "set_resolution", "freeze", "remove_reference",
        "install_library", "uninstall_library", "insert_repository", "remove_repository", "move_repository",
      ]),
      referencesPath: z.string().optional().describe("References node path; default = first PLC under TIPC"),
      name: z.string().optional(),
      version: z.string().optional(),
      company: z.string().optional(),
      defLib: z.string().optional(),
      defVer: z.string().optional(),
      defDist: z.string().optional(),
      placeholder: z.string().optional(),
      lib: z.string().optional(),
      dist: z.string().optional(),
      repo: z.string().optional(),
      libPath: z.string().optional(),
      overwrite: z.boolean().optional(),
      folder: z.string().optional(),
      index: z.number().int().optional(),
      save: z.boolean().optional(),
      confirm: z.string().optional(),
      mode: z.enum(["active", "activeOrCreate", "create"]).optional().describe("DTE attach mode; default active"),
    },
  },
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
  {
    description:
      'ADS routes via the System Manager TIRR (Routes) node, ConsumeXml/ProduceXml. READ (unguarded — a transient search trigger, never persists a route): ' +
      'list — existing static routes under RemoteConnections (best-effort name/netId/address); ' +
      'broadcast_search — LAN-wide UDP discovery (timeoutMs settle wait, default ~4000ms) → targets [{name,netId,ipAddr}]; ' +
      'search_host — direct by host (hostname or IP; needs TwinCAT 3.1 build>=4020.10, older builds return found:false) → {found, target:{name,netId,ipAddr,version,os}}. ' +
      'WRITE (GUARDED, require confirm="' + ROUTE_WRITE_CONFIRMATION + '", default NO-OP): ' +
      'add_route — credentialed route to a remote target (remoteName, remoteNetId, one of remoteIpAddr|remoteHostName; optional userName/password/noEncryption/localName); ' +
      'add_project_route — lighter project-local entry (name, netId, one of ipAddr|hostName). ' +
      'NOTE: route changes via TIRR ConsumeXml take effect in the engineering project; whether they propagate to the live target depends on the current target connection — this does NOT auto-activate. Nothing here targets the safety system (config/engineering-side only).',
    inputSchema: {
      action: z.enum(["list", "broadcast_search", "search_host", "add_route", "add_project_route"]),
      confirm: z.string().optional(),
      timeoutMs: z.number().int().positive().max(60000).optional(),
      host: z.string().optional(),
      remoteName: z.string().optional(),
      remoteNetId: z.string().optional(),
      remoteIpAddr: z.string().optional(),
      remoteHostName: z.string().optional(),
      userName: z.string().optional(),
      password: z.string().optional(),
      noEncryption: z.boolean().optional(),
      localName: z.string().optional(),
      name: z.string().optional(),
      netId: z.string().optional(),
      ipAddr: z.string().optional(),
      hostName: z.string().optional(),
    },
  },
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
  {
    description:
      'XAE engineering settings & packaging. OFFLINE/engineering-only: NONE of these write toward the live cell or change runtime state (their cell effect, if any, lands only on a SEPARATE later activate/download), so none are confirm-gated. Tree paths use ^ separators; safety (TISC-rooted) paths are rejected by policy in set_disabled/set_independent_file/save_plc_archive. Actions: ' +
      'get_silent_mode / set_silent_mode (enabled) — TcAutomationSettings.SilentMode; suppresses AI message-box dialogs (TC3.1>=4020.0; older builds throw). A good companion to the dialog watchdog. ' +
      'get_target_platform / set_target_platform (platform = "TwinCAT RT (x86)" | "TwinCAT RT (x64)") — ITcSysManager7.ConfigurationManager.ActiveTargetPlatform; switching platform invalidates prior build output, so rebuild (xae_build) before activate/download. ' +
      'save_solution_archive (file = absolute .tszip) — ITcSysManager9.SaveAsArchive, whole solution; parent dir must exist (not created). ' +
      'save_plc_archive (file = absolute .tpzip, name? = PLC child under TIPC, default first child) — ExportChild of the PLC project. ' +
      'get_independent_file / set_independent_file (path, enabled) — ITcSmTreeItem6.SaveInOwnFile (store node settings in its own file vs inline in .tsproj). ' +
      'get_disabled (path) — reads ITcSmTreeItem.Disabled, returns {disabled:0|1|2, state:SMDS_NOT_DISABLED|SMDS_DISABLED|SMDS_PARENT_DISABLED}; SMDS_PARENT_DISABLED(2) is a derived read-only state. set_disabled (path, disabled) — sets 0/1 only (2 is never settable).',
    inputSchema: {
      action: z.enum([
        "get_silent_mode", "set_silent_mode",
        "get_target_platform", "set_target_platform",
        "save_solution_archive", "save_plc_archive",
        "get_independent_file", "set_independent_file",
        "get_disabled", "set_disabled",
      ]),
      enabled: z.boolean().optional(),
      disabled: z.boolean().optional(),
      platform: z.string().optional(),
      path: z.string().optional(),
      file: z.string().optional(),
      name: z.string().optional(),
    },
  },
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
  {
    description:
      "Create + configure NON-EtherCAT fieldbus masters/slaves/boxes (PROFINET / PROFIBUS / CANopen / DeviceNet / EAP net-vars) via ITcSmTreeItem CreateChild + ClaimResources + ConsumeXml. OFFLINE CONFIG ONLY — every action edits the in-memory project; NOTHING here pushes to the live cell or runtime (activate/download/restart stay the existing guarded tools), so no confirm token is needed. Safety (TISC) paths are rejected by policy. For EtherCAT terminals/boxes use createIO instead. " +
      "BATCH-FIRST: to create more than one device use create_batch (N ops in ONE DTE attach, continue-on-error roll-up {count,succeeded,failed,results:[{parent,name,ok,child?,claimed?,error?}]}). " +
      "SubType cheat-sheet — PROFINET ctrl 113/119/126/140, dev 115/118/142/143; PROFIBUS master 86 slave 97; CANopen master 87 slave 98; DeviceNet master 41/73/88 slave 62/74/99 monitor 59 box 5203; EAP device 112 publisher 9051 subscriber 9052. " +
      "Actions: " +
      "create_device (parent? default TIID / EAP device path, name, subType, before?, vInfo?, claimIndex?, save?) — CreateChild a master/slave/box; claimIndex immediately ClaimResources to bind underlying hardware; a wrong subType/vInfo ghost is cleaned up and reported as failure; " +
      "create_batch (creates:[{parent?,name,subType,before?,vInfo?,claimIndex?}], save?); " +
      "list_resources (path) — read-only; probes ITcSmTreeItem5.ResourcesCount then ResourceCount (Beckhoff pages disagree on the name) and reports which answered; " +
      "claim_resources (path, index [1-based per Beckhoff examples], save?) — bind the node to underlying FC/EL hardware (offline config edit, NOT a cell write); " +
      "create_gsd_box (controllerPath, name, gsdPath, moduleIdentNumber, subType [REQUIRED — PN device subType, depends on controller variant], boxFlags? [GENERATE_NAME_FROM_PAB 0x0004 / GET_STATIONNAME 0x0400 / SET_NOT_IP_TO_OS 0x4000], dapNumber?, before?, save?) — PROFINET GSD/GSDML box; vInfo = gsdPath#moduleIdentNumber#boxFlags#dapNumber. CAVEAT: GSD box subType + vInfo format from a doc summary, confirm against infosys 1041677067 before relying on it; " +
      "add_netvar (boxPath = EAP publisher/subscriber box, name, dataType [IEC type as vInfo, e.g. BOOL/INT], before?, save?) — EAP pub/sub variable (SubType 0; resulting ItemType 35 publisher / 36 subscriber); " +
      "set_station_address (path = PROFIBUS slave/box, address, save?) — discovers the address element via ProduceXml then ConsumeXml a minimal envelope (the bare-number form is unverified and NOT shipped); if discovery fails, use get_xml + set_xml; " +
      "import_dbc (masterPath = CANopen master, fileName [.dbc], importExtendedMessages?, importMultiplexedDataMessages?, keepUnchangedMessages?, communicateWithSlavesFromDbcFile?, save?) — CanOpenMaster/ImportDbcFile config import (requires TC3.1 build >= 4018); " +
      "get_xml (path) — raw ProduceXml passthrough for discovering real param elements; " +
      "set_xml (path, xml = partial <TreeItem> XML, returnXml?, save?) — generic ConsumeXml escape hatch for any fieldbus param not covered above.",
    inputSchema: {
      action: z.enum([
        "create_device", "create_batch", "list_resources", "claim_resources",
        "create_gsd_box", "add_netvar", "set_station_address", "import_dbc",
        "get_xml", "set_xml",
      ]),
      parent: z.string().optional(),
      name: z.string().optional(),
      subType: z.number().int().optional(),
      before: z.string().optional().describe("insert before this sibling"),
      vInfo: z.string().optional(),
      claimIndex: z.number().int().optional(),
      creates: z.array(z.object({
        parent: z.string().optional(),
        name: z.string(),
        subType: z.number().int(),
        before: z.string().optional(),
        vInfo: z.string().optional(),
        claimIndex: z.number().int().optional(),
      })).optional(),
      path: z.string().optional(),
      index: z.number().int().optional(),
      controllerPath: z.string().optional(),
      gsdPath: z.string().optional(),
      moduleIdentNumber: z.string().optional(),
      boxFlags: z.number().int().optional(),
      dapNumber: z.string().optional(),
      boxPath: z.string().optional(),
      dataType: z.string().optional(),
      address: z.number().int().optional(),
      masterPath: z.string().optional(),
      fileName: z.string().optional(),
      importExtendedMessages: z.boolean().optional(),
      importMultiplexedDataMessages: z.boolean().optional(),
      keepUnchangedMessages: z.boolean().optional(),
      communicateWithSlavesFromDbcFile: z.boolean().optional(),
      xml: z.string().optional(),
      returnXml: z.boolean().optional(),
      mode: z.enum(["active", "activeOrCreate", "create"]).optional().describe("DTE attach mode; default active"),
      save: z.boolean().optional(),
    },
  },
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
  {
    description:
      "TcCOM module objects under TIRC^TcCOM Objects (paths use ^ separators). CONFIG-TIME ONLY — no INIT/PREOP/SAFEOP/OP transitions (not an Automation Interface feature); nothing here activates config, downloads, or touches the runtime/safety system. Actions: " +
      "list (read-only) — enumerate module instances via ITcModuleManager3, returns {count,modules:[{moduleTypeName,moduleInstanceName,classId,oid,objectId,parentOid}]} (oids are DECIMAL; XAE shows hex). " +
      "create (name, by=\"classid\"|\"name\", id, before?) — CreateChild under TcCOM Objects: by=classid -> subType 0, id = module GUID/ClassID e.g. {8f5fdcff-...}; by=name -> subType 1, id = registered module type name e.g. \"NewModule\"; a malformed/ghost child is cleaned up and reported as an error. " +
      "get_xml (path) — ProduceXml of the instance (Parameters / DataAreas / Symbols, with current CreateSymbol/CreateSymbols flags). set_xml (path, xml, returnXml?) — ConsumeXml escape hatch for parameters not exposed as typed properties. " +
      "enable_symbols (path, parameters?, dataAreas?, returnXml?) — convenience toggle: sets CreateSymbol=true on Parameter nodes and/or CreateSymbols=true on DataArea AreaNo nodes via ProduceXml/ConsumeXml. CAVEAT: the XPath/attribute names are from a how-to summary, NOT verified against a literal ProduceXml dump — call get_xml on a real module first and fall back to set_xml if the toggle reports changed:false. " +
      "link (a, b, autoResolve?) / unlink (a, b?; a alone removes all of a's links) — wire module DataArea symbols to PLC/IO/other-module variables (symbols must already exist via enable_symbols); offline edit, not guarded. " +
      "set_context (path, taskObjectId, contextId?) — assign the instance to a task's execution context; taskObjectId/contextId are DECIMAL oids (XAE shows hex). GUARDED: changes the activated mapping/runtime context, requires confirm=\"" + MODULE_CONTEXT_CONFIRMATION + "\" and defaults to no-op.",
    inputSchema: {
      action: z.enum(["list", "create", "get_xml", "set_xml", "enable_symbols", "set_context", "link", "unlink"]),
      path: z.string().optional(),
      name: z.string().optional(),
      by: z.enum(["classid", "name"]).optional(),
      id: z.string().optional(),
      before: z.string().optional().describe("insert before this sibling under TcCOM Objects"),
      xml: z.string().optional(),
      returnXml: z.boolean().optional(),
      parameters: z.boolean().optional(),
      dataAreas: z.boolean().optional(),
      taskObjectId: z.number().int().optional().describe("decimal ObjectId of the target task (XAE shows it in hex)"),
      contextId: z.number().int().optional(),
      a: z.string().optional(),
      b: z.string().optional(),
      autoResolve: z.boolean().optional(),
      confirm: z.string().optional(),
    },
  },
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
      case "link":
        need(p, ["a", "b"], p.action);
        return textResult(await bridgeCall("twincat_module_link_variables", { a: p.a, b: p.b, autoResolve: p.autoResolve !== false }));
      case "unlink":
        need(p, ["a"], p.action);
        return textResult(await bridgeCall("twincat_module_unlink_variables", { a: p.a, b: p.b }));
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
  {
    description:
      "TwinCAT C++ projects/modules under TIXC (paths use ^ separators). C++ ONLY — nothing here targets TISC/safety, and nothing activates/downloads/touches the runtime (those stay the existing guarded tools). VS-hosted-safe: create/open go purely through ITcSmTreeItem.CreateChild on TIXC (no New/Open/SaveConfiguration). Actions: " +
      "create_project (name, template, before?) — CreateChild a new C++ project node under TIXC from a wizard; template = \"TwinCAT C++ Project Wizard\" | \"TcVersionedDriverWizard\" | \"TcModuleCyclicCallerWizard\" (or a full template .vcxproj/.tczip path — if a wizard NAME is rejected, fall back to the file path). " +
      "create_module (projectPath = TIXC^<proj>, name, template? default \"TwinCAT Class Wizard\", before?) — CreateChild a module/class on an existing C++ project. " +
      "open (file = existing .vcxproj/.tczip, subType? 0 copy into solution dir (default) /1 move/2 use-in-place, before?) — import an existing C++ project; the project is NOT renamed (CreateChild name is empty). " +
      "tmc_codegen (projectPath) — offline StartTmcCodeGenerator (regenerates C++ from the .tmc; no runtime impact). " +
      "set_props (projectPath, bootProjectEncryption? None|Target, saveProjectSources?) — offline config edit via ConsumeXml (at least one prop required). " +
      "build (projectName = the .vcxproj DTE project Name/UniqueName, config? default \"Release|TwinCAT RT (x64)\", waitForFinish? default true, timeoutMs? default 1800000) — compile a single C++ project via SolutionBuild2.BuildProject; compiles only, does NOT deploy. " +
      "publish (projectPath, confirm) — GUARDED, requires confirm=\"" + CPP_PUBLISH_CONFIRMATION + "\" and defaults to no-op: builds the module for ALL platforms and exports the deployable/shippable driver artifacts (long-running); does NOT itself activate/restart the runtime. " +
      "CAVEAT: the ConsumeXml wrapper element for C++ project params is from a doc summary (Set-TreeItemXml surfaces GetLastXmlError, so a wrong element fails loudly); ProduceXml the project node once to confirm element names before relying on tmc_codegen/set_props/publish.",
    inputSchema: {
      action: z.enum(["create_project", "create_module", "open", "tmc_codegen", "set_props", "build", "publish"]),
      name: z.string().optional(),
      template: z.string().optional(),
      projectPath: z.string().optional(),
      file: z.string().optional(),
      subType: z.number().int().min(0).max(2).optional(),
      before: z.string().optional().describe("insert before this sibling"),
      bootProjectEncryption: z.enum(["None", "Target"]).optional(),
      saveProjectSources: z.boolean().optional(),
      projectName: z.string().optional(),
      config: z.string().optional(),
      waitForFinish: z.boolean().optional(),
      timeoutMs: z.number().int().positive().max(3600000).optional(),
      confirm: z.string().optional(),
    },
  },
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
  {
    description:
      "Measurement (TE130X Scope View) projects + TwinCAT Analytics (TIAN) logger/stream config. Scope/Analytics PROJECTS are separate EnvDTE.Project nodes (AddFromTemplate), NOT System Manager tree nodes; TIAN logger/stream nodes ARE System Manager children (CreateChild/DeleteChild under TIAN). Requires the respective products installed (TwinCAT.Measurement.AutomationInterface.dll + templates for scope, Analytics templates for analytics) — if absent the action fails with a clear 'tooling not installed' message rather than a raw COM HRESULT. " +
      "IMeasurementScope is a vtable interface reached via a compiled C# QI shim (a PowerShell cast cannot QI it). Actions: " +
      "scope_create (name, template? = full .tcmproj path [default: first installed under TE130X-Scope-View\\Templates\\Projects], destination? = folder [default: solution dir]) — AddFromTemplate a new Scope project; " +
      "scope_add_child (project, parentPath? = ^-path of names from scope root, name?, elementType? default 0) — CreateChild(out item,name,elementType); only elementType 0 is VERIFIED, non-zero values are EXPERIMENTAL; deep parentPath resolves by enumerating existing children by name; " +
      "scope_rename (project, path, newName) — ChangeName on the element at path; " +
      "scope_record (project, state 'start'|'stop') — StartRecord/StopRecord; GUARDED: state='start' performs LIVE data acquisition and requires confirm=\"" + MEASUREMENT_RECORD_CONFIRMATION + "\" (state='stop' needs no confirm); " +
      "analytics_create (name, template? = full Analytics project template path [must resolve or pass explicitly], destination? = folder) — AddFromTemplate a new Analytics project (project creation ONLY; network/function wiring is UNVERIFIED and not implemented); " +
      "logger_create (name, before?) — CreateChild a DataLogger (subType 1) under TIAN (config edit, no confirm); " +
      "logger_delete (name, dryRun?, confirm) — DeleteChild under TIAN, GUARDED confirm=\"" + DELETE_CONFIRMATION + "\" (dryRun:true previews existence without deleting); " +
      "stream_create (name, before?) — CreateChild a StreamHelper (subType 0) under TIAN (config edit, no confirm); " +
      "stream_delete (name, dryRun?, confirm) — DeleteChild under TIAN, GUARDED confirm=\"" + DELETE_CONFIRMATION + "\"; the actual node name is '<name>_Obj1 (StreamHelper)' (the suffix is appended for you). " +
      "For raw ProduceXml/ConsumeXml on a TIAN logger/stream node (e.g. 'TIAN^<loggerName>') use tc_tree get_xml/set_xml. " +
      "OMITTED as UNVERIFIED: Scope data-export (SaveSVD/ExportCSV/ExportTDMS/ExportBinary/ExportDAT), Scope-Server (ShowControl/CloseControl/Disconnect), LookUpChild, and all Scope/Analytics enums. Nothing here targets the safety system.",
    inputSchema: {
      action: z.enum([
        "scope_create", "scope_add_child", "scope_rename", "scope_record",
        "analytics_create",
        "logger_create", "logger_delete", "stream_create", "stream_delete",
      ]),
      name: z.string().optional(),
      template: z.string().optional(),
      destination: z.string().optional(),
      project: z.string().optional(),
      parentPath: z.string().optional().describe("^-path of names from the scope project root to the parent element"),
      path: z.string().optional(),
      newName: z.string().optional(),
      elementType: z.number().int().optional().describe("CreateChild elementType; only 0 is verified"),
      state: z.enum(["start", "stop"]).optional(),
      before: z.string().optional().describe("insert before this sibling under TIAN"),
      xml: z.string().optional(),
      returnXml: z.boolean().optional(),
      summary: z.boolean().optional(),
      dryRun: z.boolean().optional(),
      confirm: z.string().optional(),
      mode: z.enum(["active", "activeOrCreate", "create"]).optional().describe("DTE attach mode; default active"),
    },
  },
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
  {
    description:
      'TwinCAT licensing on the TIRC^License node (requires TC3.1 >= 4022.4; older targets have no AvailableLicenseDevices/ActivateResponseFile support and ProduceXml/ConsumeXml return empty or error — the HRESULT is surfaced, not masked). Nothing here touches the safety system (TIRC^License is real-time/licensing config). Actions: ' +
      'list (read-only) — discover available dongle license devices via ProduceXml; returns {treePath, devices:[{name,pathName,typeName,objectId}]} (pass raw:true to also include the full License-node ProduceXml blob). ' +
      'add (name, device) — OFFLINE config edit: CreateChild a license-device child under License bound to a dongle that MUST already exist in the I/O tree (device = its display-name e.g. "Term 2 (EL6070)" OR its ObjectID e.g. "50462722" from list). This only links the License node to existing hardware; it does NOT create the dongle terminal — add the EL6070 (etc.) first via createIO/tc_tree. Not confirm-gated (config-only). ' +
      'activate_response (confirm, path, oemGuid?) — GUARDED, requires confirm="' + LICENSE_ACTIVATE_CONFIRMATION + '" and defaults to no-op: ConsumeXml the ActivateResponseFile command to activate an OEM license response file (path = absolute path to the .tmc/.reresponse file). oemGuid is "only required in special cases" and accepts any value; defaults to 0 when omitted. This is a license-activation state change.',
    inputSchema: {
      action: z.enum(["list", "add", "activate_response"]),
      raw: z.boolean().optional(),
      name: z.string().optional(),
      device: z.string().optional().describe('dongle display-name (e.g. "Term 2 (EL6070)") or ObjectID string from list'),
      path: z.string().optional().describe("absolute path to the OEM license response (.tmc/.reresponse) file"),
      oemGuid: z.string().optional(),
      confirm: z.string().optional(),
    },
  },
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
  {
    description:
      "Project VARIANT management on the open solution (needs iTcSysManager14 / ITcSmTreeItem9 — TCatSysManagerLib >= 3.3.0.0; on older installs get_* return empty and set_*/disable surface a clear COM error). OFFLINE CONFIG ONLY — every action mutates only the variant definition / active variant / per-item variant-disable flag inside XAE; NOTHING activates config, downloads a boot project, or touches the runtime/safety system, so no confirm token (same project-config class as tc_tree set_xml/rename/create). Per-item disable/enable refuses TISC (safety) paths by policy. Optional save:true does File.SaveAll once after a write. Actions: " +
      "get_config (read-only) — sysManager.ProjectVariantConfig, returns the raw <ProjectVariants> XML (round-trip this FIRST to capture the live shape before editing). " +
      "get_current (read-only) — sysManager.CurrentProjectVariant; empty string => no variant active / variant management not configured. " +
      "set_config (xml, save?) — replaces the WHOLE variant definition: a <ProjectVariants> document with <Group><Name>..</Name><Member>VariantName</Member>..</Group> and/or standalone <Variant><Name>..</Name></Variant> children (raw XML taken verbatim, string readback returned — schema is not validated). " +
      "select (variant, save?) — sets the active variant by name (e.g. \"Variant3\") or a group in bracket form (e.g. \"[Group1]\"); the variant/group must already exist in the config (errors if the readback does not match). " +
      "disable / enable (path, save?) — sets ITcSmTreeItem9.PvDisable + Disabled (SMDS_DISABLED=1 / SMDS_NOT_DISABLED=0) on a tree item FOR THE ACTIVE VARIANT; path uses ^ separators (e.g. TIID^Device 2 (EtherCAT)^Box 1, TIPC^MyPlc) and MUST NOT be under TISC. The readback `disabled` int may report SMDS_PARENT_DISABLED=2 (read-only state: disabled because an ancestor is) — that value is never written, only echoed.",
    inputSchema: {
      action: z.enum(["get_config", "get_current", "set_config", "select", "disable", "enable"]),
      xml: z.string().optional(),
      variant: z.string().optional(),
      path: z.string().optional(),
      save: z.boolean().optional(),
    },
  },
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
