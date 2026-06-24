"use strict";
// daemonClient.js — talks to the persistent native Te1000Daemon over a named
// pipe. Replaces the per-call powershell.exe spawn model for the hot path.
//
// Protocol: newline-delimited JSON over \\.\pipe\<name>.
//   request:  {id, action, payload}
//   response: {id, ok, result?|error?, errorKind?, dialog?}
//
// On connect failure the daemon exe is auto-spawned (detached) and the client
// waits for the pipe. Responses are correlated by id. Reconnects on pipe drop.
//
// The Node host (index.js) maps daemon errorKind -> the same user-facing error
// messages the legacy PS-bridge watchdog produced, so agent-visible behavior is
// unchanged.

const net = require("net");
const path = require("path");
const fs = require("fs");
const { spawn } = require("child_process");

const PIPE_NAME = process.env.TE1000_DAEMON_PIPE || "te1000-mcp";
const PIPE_PATH = "\\\\.\\pipe\\" + PIPE_NAME;
const EXE_PATH = path.join(__dirname, "daemon", "bin", "Release", "Te1000Daemon.exe");
const CONNECT_TIMEOUT_MS = Number(process.env.TE1000_DAEMON_CONNECT_MS) || 20000;
// Per-request ceiling: once a frame is written, the pending id waits for a
// matching response. Without this, a wedged daemon (or a dropped/malformed reply
// frame that never matches the id) would hang the request forever. The daemon's
// own per-call ceiling is ~180s and long actions carry their own larger
// timeoutMs; keep this Node-side wall comfortably above that so we don't pre-empt
// a daemon call that is legitimately still running. 0 disables (parity escape).
const REQUEST_TIMEOUT_MS = Number(process.env.TE1000_DAEMON_REQUEST_MS) || 1900000;

// Watcher/auto-dismiss knobs are honored by the daemon via CLI flags (it runs
// the watcher internally as a thread). Mirror the index.js env switches.
const DIALOG_WATCH = process.env.TE1000_DIALOG_WATCH !== "0";
const AUTO_DISMISS = process.env.TE1000_DIALOG_AUTODISMISS !== "0";
const GRACE_MS = Number(process.env.TE1000_DIALOG_GRACE_MS) || 4000;

let sock = null;
let connecting = null;
let nextId = 1;
const pending = new Map(); // id -> {resolve, reject}
let rxBuf = "";

function daemonExeExists() {
  try { return fs.existsSync(EXE_PATH); } catch { return false; }
}

function spawnDaemon() {
  const args = ["--pipe", PIPE_NAME];
  if (!DIALOG_WATCH) args.push("--no-watch");
  if (!AUTO_DISMISS) args.push("--no-autodismiss");
  args.push("--grace-ms", String(GRACE_MS));
  // Detached so the daemon outlives this MCP process restart; it self-guards as
  // a single instance per pipe name (named mutex), so duplicate spawns are safe.
  const child = spawn(EXE_PATH, args, { stdio: "ignore", detached: true, windowsHide: true });
  child.unref();
}

function attachSocket(s) {
  sock = s;
  rxBuf = "";
  s.setNoDelay(true);
  s.on("data", (chunk) => {
    rxBuf += chunk.toString("utf8");
    let nl;
    while ((nl = rxBuf.indexOf("\n")) >= 0) {
      const line = rxBuf.slice(0, nl);
      rxBuf = rxBuf.slice(nl + 1);
      if (!line) continue;
      let msg;
      try { msg = JSON.parse(line); } catch { continue; }
      const id = String(msg.id);
      const waiter = pending.get(id);
      if (waiter) { pending.delete(id); waiter.resolve(msg); }
    }
  });
  const drop = () => {
    if (sock === s) sock = null;
    // Fail all in-flight requests; callers may retry. Snapshot the waiters first
    // (each reject() mutates `pending` via settle()).
    const waiters = Array.from(pending.values());
    pending.clear();
    for (const w of waiters) {
      const e = new Error("Daemon pipe closed");
      e.pipeClosed = true;
      w.reject(e);
    }
  };
  s.on("close", drop);
  s.on("error", drop);
}

function connectOnce() {
  return new Promise((resolve, reject) => {
    const s = net.connect(PIPE_PATH);
    const onConnect = () => { s.removeListener("error", onErr); resolve(s); };
    const onErr = (e) => {
      // Remove BOTH transient listeners so the pending "connect" handler can't
      // leak/fire after we've destroyed the socket (L5).
      s.removeListener("connect", onConnect);
      s.removeListener("error", onErr);
      s.destroy();
      reject(e);
    };
    s.once("error", onErr);
    s.once("connect", onConnect);
  });
}

async function ensureConnected() {
  if (sock) return sock;
  if (connecting) return connecting;
  connecting = (async () => {
    const deadline = Date.now() + CONNECT_TIMEOUT_MS;
    let spawned = false;
    while (Date.now() < deadline) {
      try {
        const s = await connectOnce();
        attachSocket(s);
        return s;
      } catch {
        if (!spawned) {
          if (!daemonExeExists()) {
            throw new Error(
              "Te1000Daemon.exe not found at " + EXE_PATH +
              ". Build it (daemon/build.ps1) or set TE1000_NO_DAEMON=1 to use the legacy PowerShell bridge.",
            );
          }
          spawnDaemon();
          spawned = true;
        }
        await new Promise((r) => setTimeout(r, 200));
      }
    }
    throw new Error("Timed out connecting to Te1000Daemon on " + PIPE_PATH);
  })();
  try {
    return await connecting;
  } finally {
    connecting = null;
  }
}

function sendOnce(action, payload) {
  return new Promise(async (resolve, reject) => {
    let s;
    try { s = await ensureConnected(); } catch (e) { return reject(e); }
    const id = String(nextId++);

    // Per-request timer: if no matching-id response arrives within the ceiling,
    // drop the pending id and reject with a timeout-kind error. This also covers
    // the "malformed reply line silently dropped → request hangs" case (a dropped
    // frame never resolves the id, so it now times out instead).
    let timer = null;
    const settle = (fn, arg) => {
      if (timer) { clearTimeout(timer); timer = null; }
      pending.delete(id);
      fn(arg);
    };
    pending.set(id, {
      resolve: (msg) => settle(resolve, msg),
      reject: (err) => settle(reject, err),
    });
    if (REQUEST_TIMEOUT_MS > 0) {
      timer = setTimeout(() => {
        if (!pending.has(id)) return;
        pending.delete(id);
        const e = new Error(
          `Te1000Daemon request '${action}' timed out after ${REQUEST_TIMEOUT_MS} ms with no response (daemon may be wedged or the reply was dropped).`,
        );
        e.daemonUnavailable = true; // let runBridge fall back to the legacy bridge
        reject(e);
      }, REQUEST_TIMEOUT_MS);
    }

    try {
      s.write(JSON.stringify({ id, action, payload }) + "\n");
    } catch (e) {
      if (timer) { clearTimeout(timer); timer = null; }
      pending.delete(id);
      reject(e);
    }
  });
}

// Map daemon errorKind to the same user-facing errors index.js produced.
function toError(action, resp) {
  const kind = resp.errorKind;
  const d = resp.dialog || {};
  const btns = Array.isArray(d.buttons) && d.buttons.length
    ? d.buttons.map((b) => `[${b}]`).join(" ") : "(none detected)";
  if (kind === "dialog_blocked") {
    return new Error(
      `XAE is blocked on a modal dialog, so this '${action}' call cannot complete.\n` +
      `  Title:   ${d.title || "(untitled)"}\n` +
      `  Message: ${d.text || "(no text)"}\n` +
      `  Buttons: ${btns}\n` +
      `The dialog is still open on the machine — clear it there, or add a rule to ` +
      `powershell/dialog-allowlist.json to auto-dismiss this dialog next time. ` +
      `The operation's result is indeterminate.`,
    );
  }
  if (kind === "timeout") {
    return new Error(
      `Bridge call '${action}' timed out; no modal dialog was detected — XAE may be busy. ` +
      `(${resp.error || ""})`.trim(),
    );
  }
  // Parity: the legacy PS bridge path said "Bridge returned failure"; keep the
  // agent-visible text stable rather than introducing "Daemon returned failure".
  return new Error(resp.error || "Bridge returned failure");
}

// Public: run an action via the daemon. Resolves with the `result` (== the PS
// bridge's `data`), rejects with a mapped Error. One transparent reconnect retry
// on a dropped pipe.
function isRetryablePipeError(e) {
  return !!(e && (e.pipeClosed || /pipe closed|ECONNRESET|EPIPE/i.test(e.message || "")));
}

async function runViaDaemon(action, payload = {}) {
  let resp;
  try {
    resp = await sendOnce(action, payload);
  } catch (e) {
    if (isRetryablePipeError(e)) {
      try {
        resp = await sendOnce(action, payload); // reconnect + retry once
      } catch (e2) {
        // The pipe is still dropping after a reconnect attempt (a daemon that
        // connects but immediately closes every frame). Surface this as a
        // daemon-unavailable error so index.js can fall back to the legacy
        // bridge instead of treating it as a hard failure (H4a).
        if (isRetryablePipeError(e2)) e2.daemonUnavailable = true;
        throw e2;
      }
    } else {
      throw e;
    }
  }
  if (resp.ok) return resp.result;
  throw toError(action, resp);
}

module.exports = { runViaDaemon, PIPE_NAME, EXE_PATH };
