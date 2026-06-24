// No-XAE end-to-end test: start the daemon on a TEST pipe, round-trip `ping`.
// Usage: node test-ping.js
"use strict";
const { spawn } = require("child_process");
const net = require("net");
const path = require("path");

const PIPE = "te1000-test-" + process.pid;
const PIPE_PATH = "\\\\.\\pipe\\" + PIPE;
const EXE = path.join(__dirname, "bin", "Release", "Te1000Daemon.exe");

function connect(timeoutMs) {
  return new Promise((resolve, reject) => {
    const deadline = Date.now() + timeoutMs;
    const tryOnce = () => {
      const sock = net.connect(PIPE_PATH);
      sock.once("connect", () => resolve(sock));
      sock.once("error", () => {
        sock.destroy();
        if (Date.now() > deadline) reject(new Error("pipe connect timeout"));
        else setTimeout(tryOnce, 100);
      });
    };
    tryOnce();
  });
}

function rpc(sock, obj) {
  return new Promise((resolve, reject) => {
    let buf = "";
    const onData = (d) => {
      buf += d.toString("utf8");
      const nl = buf.indexOf("\n");
      if (nl >= 0) {
        sock.removeListener("data", onData);
        try { resolve(JSON.parse(buf.slice(0, nl))); } catch (e) { reject(e); }
      }
    };
    sock.on("data", onData);
    sock.write(JSON.stringify(obj) + "\n");
  });
}

(async () => {
  const child = spawn(EXE, ["--pipe", PIPE, "--no-watch"], { stdio: "ignore", detached: true });
  child.unref();
  let sock;
  try {
    sock = await connect(8000);
    const ping = await rpc(sock, { id: "1", action: "ping", payload: {} });
    console.log("PING:", JSON.stringify(ping));
    const la = await rpc(sock, { id: "2", action: "list_actions", payload: {} });
    console.log("ACTIONS_COUNT:", la.result ? la.result.count : "?");
    const bad = await rpc(sock, { id: "3", action: "nonexistent_action", payload: {} });
    console.log("BAD:", JSON.stringify(bad));
    let pass = ping.ok && ping.result && ping.result.pong === true && bad.ok === false && bad.errorKind === "com_error";
    console.log(pass ? "RESULT: PASS" : "RESULT: FAIL");
    process.exitCode = pass ? 0 : 1;
  } catch (e) {
    console.error("ERROR:", e.message);
    process.exitCode = 1;
  } finally {
    if (sock) sock.end();
    try { process.kill(child.pid); } catch {}
  }
})();
