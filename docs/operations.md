# Operations: reliability, dialogs & session control

How `te1000-mcp` stays robust while driving a GUI engineering tool, and the safety model
behind every guarded action. For the tool list see [tools.md](tools.md).

> **Daemon vs. legacy.** The mechanisms below are described as the **legacy PowerShell bridge**
> implements them (per-call `dialog-watch.ps1` + pre-flight gate). In the default **daemon**
> mode the same logic runs **inside** `Te1000Daemon.exe` — the dialog watcher is an internal
> thread (`DialogWatcher.cs`) reading the same `dialog-allowlist.json`, and a persistent modal
> recycles the daemon's COM worker instead of killing a per-call process. The
> agent-visible behavior (auto-dismiss, the "XAE is blocked on a modal dialog…" report, the
> grace window) is identical. See [architecture.md](architecture.md). The safety/guard model
> below applies to both paths.

## Why this matters

Every bridge call drives XAE through a **synchronous DTE/COM call**. If that call causes XAE to
raise a *modal* dialog (save-changes, "file changed externally", activate confirm, license
prompt), the COM call blocks inside XAE's modal message loop until a human clicks the dialog —
so the MCP call, and the calling agent, would otherwise hang indefinitely with no clue why.

## Modal-dialog watchdog

`powershell/dialog-watch.ps1` runs as a short-lived process alongside every bridge call. Each
poll it looks for an **application-modal** dialog owned by the XAE process — the precise signal
is a visible, enabled window whose *owner* window is disabled (docked tool windows and
non-modal popups don't qualify). On finding one it either:

- **auto-dismisses** it — if the dialog matches a rule in `powershell/dialog-allowlist.json`,
  the watcher clicks that rule's button, releasing the blocked COM call so the operation
  completes normally; or
- **reports** it — for any dialog with no matching rule, `index.js` waits a short grace period
  (`TE1000_DIALOG_GRACE_MS`, default 4000 ms), then abandons the bridge call and returns an
  error containing the dialog's **title, body text, and buttons**, so the agent knows exactly
  what is blocking it. The dialog is left open for a human to clear; the result is indeterminate.

Detection is **dialog-driven, not a wall-clock timeout**, so long legitimate operations (a
multi-minute build) are never killed just for taking a while.

### Pre-flight gate

A dialog that is **already open before** a command (you edited a file outside XAE, the target
connection dropped, an earlier prompt was never cleared) corrupts the next command's result —
e.g. a build returns a bogus *"No solution is open"*. So before every bridge call, `index.js`
runs a one-shot probe: it auto-dismisses an allowlisted dialog, and otherwise **refuses to run
the command**, returning the dialog's details instead of firing into a poisoned XAE.

### Allowlist (`powershell/dialog-allowlist.json`)

Ships with one rule — the *"file has been changed outside the environment → reload?"* prompt is
auto-answered **Yes**, so an agent's own source edits load into XAE. Each rule has `match` (regex
on the title, required), optional `textMatch` (regex on the body), and `button` (exact label to
click). First match wins; unmatched dialogs are reported, never clicked.

> [!WARNING]
> **Live cell.** Only allowlist dialogs that are safe to auto-answer unattended. **Never**
> allowlist Activate Configuration, Run-mode, restart, download, or safety prompts — those must
> stay human-confirmed. Prefer the non-destructive button.

Run `dialog-watch.ps1 -Mode probe` at any time to print the current dialog (if any) as JSON —
useful for discovering the exact `title`/`button` strings for a new rule.

### Environment toggles

| Variable | Default | Effect |
|---|---|---|
| `TE1000_DIALOG_WATCH` | on | `0` disables the watchdog entirely |
| `TE1000_DIALOG_AUTODISMISS` | on | `0` = detect + report only, never auto-click |
| `TE1000_DIALOG_GRACE_MS` | `4000` | how long a blocking dialog must persist before the call is abandoned |
| `TE1000_BRIDGE_TIMEOUT_MS` | `0` (off) | optional wall-clock backstop for non-dialog hangs |

## PLC session control (auto-logout)

While the IDE is **logged in** to the PLC, TwinCAT will not load source edited outside the
editor — it defers it (*"File will be loaded after logout"*). So an agent that edits a POU
mid-session can't get that change compiled or deployed until a logout happens. On the 64-bit
TcXaeShell the DTE Login/Logout commands are unreachable (they never report `IsAvailable=true`
and have no key binding), which is why they were dropped from the tool surface.

`powershell/plc-session.ps1` works around this with **UI Automation**: the IDE's Login/Logout
toolbar buttons are reachable even when the DTE commands are not, and their enabled state is a
reliable session detector (Logout enabled ⇒ logged in).

- **`plc_session` tool** — `status` (read-only `{ loggedIn }`) or `logout` (invokes the Logout
  button; guarded with `confirm: "ALLOW_PLC_LOGOUT"`). It **never** invokes Login — there is no
  auto-login by design.
- **`plc_download` auto-logout** — with `autoLogout` (default `true`), the deploy first checks
  the session and, if logged in, logs out so deferred source edits are applied before the boot
  project is generated. It never logs back in; pass `autoLogout: false` to skip.

## Safety model

The server **never auto-activates, auto-restarts, or auto-deploys**. Every action that changes
the live target, deletes a node, or alters licensing requires the matching `confirm` token (see
[README → Safety & guards](../README.md#safety--guards)). Tokens are enforced in `index.js` and
re-checked defensively in the bridge.

**Safety project.** Nothing in this toolchain writes toward the TwinSAFE safety project. Every
authoring tool refuses safety-rooted (`TISC`) paths via an internal `Assert-NotSafetyPath` guard.
Safety remains import-only / read-only / diagnostic by policy.
