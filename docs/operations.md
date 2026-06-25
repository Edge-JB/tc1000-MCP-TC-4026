# Operations: reliability, dialogs & session control

How `te1000-mcp` stays robust while driving a GUI engineering tool, and the safety model
behind every guarded action. For the tool list see [tools.md](tools.md).

> **Daemon-only.** All of the mechanisms below run **inside** the native daemon
> `Te1000Daemon.exe` — the dialog watcher is an internal thread (`DialogWatcher.cs`) reading
> `dialog-allowlist.json` (repo root), and a persistent modal recycles the daemon's COM worker
> rather than killing a process. (These were ported from an earlier per-call PowerShell
> dialog-watcher + pre-flight gate, which has been removed.) See
> [architecture.md](architecture.md). The dialog grace and the "XAE is blocked on a modal
> dialog…" report are controlled by the daemon's CLI flags / its allowlist; the front translates
> the dialog-watch env vars into those flags at spawn time (see [Watcher configuration](#watcher-configuration)).

## Why this matters

Every daemon action drives XAE through a **synchronous DTE/COM call**. If that call causes XAE to
raise a *modal* dialog (save-changes, "file changed externally", activate confirm, license
prompt), the COM call blocks inside XAE's modal message loop until a human clicks the dialog —
so the MCP call, and the calling agent, would otherwise hang indefinitely with no clue why.

## Modal-dialog watchdog

The daemon's `DialogWatcher.cs` thread polls (~750 ms) for an **application-modal** dialog owned
by the XAE process — the precise signal is a visible, enabled window whose *owner* window is
disabled (docked tool windows and non-modal popups don't qualify; it also matches the abnormal
owner-less / self-disabled `#32770` case — see the CHANGELOG). On finding one it either:

- **auto-dismisses** it — if the dialog matches a rule in `dialog-allowlist.json`, the watcher
  clicks that rule's button, releasing the blocked COM call so the operation completes normally;
  or
- **reports** it — for any dialog with no matching rule, after a short grace window the daemon
  abandons the call, recycles its COM worker, and returns an error containing the dialog's
  **title, body text, and buttons**, so the agent knows exactly what is blocking it. The dialog
  is left open for a human to clear; the result is indeterminate.

Detection is **dialog-driven, not a wall-clock timeout**, so long legitimate operations (a
multi-minute build) are never killed just for taking a while.

### Pre-flight gate

A dialog that is **already open before** a command (you edited a file outside XAE, the target
connection dropped, an earlier prompt was never cleared) corrupts the next command's result —
e.g. a build returns a bogus *"No solution is open"*. The daemon's watcher catches such a
pre-existing dialog the same way: it auto-dismisses an allowlisted one, and otherwise the
in-flight call surfaces the dialog's details instead of firing into an XAE that is blocked on a
dialog. Use `xae dialog_probe` to inspect the current dialog without clicking anything.

### Allowlist (`dialog-allowlist.json`)

Ships **empty** — the `rules` array is empty, so a fresh clone is **report-only by default** and
auto-clicks nothing. You build the allowlist up yourself, either by hand or via
`xae dialog_resolve {button, remember:true}` (which appends a rule and hot-applies it to the
running watcher). Each rule has `match` (regex on the title, required), optional `textMatch` (regex
on the body), and `button` (exact label to click). First match wins; unmatched dialogs are
reported, never clicked.

> [!WARNING]
> Only allowlist dialogs that are safe to auto-answer unattended. **Never** allowlist Activate
> Configuration, Run-mode, restart, download, or safety prompts — those must stay human-confirmed.
> Prefer the non-destructive button.

Run the `xae dialog_probe` action at any time to print the current dialog (if any) as JSON —
useful for discovering the exact `title`/`button` strings for a new rule.

### Watcher configuration

The watcher is configured by daemon CLI flags (`--no-watch`, `--no-autodismiss`, `--grace-ms`,
`--allowlist`) parsed in `Program.cs`. The Node front reads the `TE1000_DIALOG_WATCH` /
`TE1000_DIALOG_AUTODISMISS` / `TE1000_DIALOG_GRACE_MS` environment variables and translates them
into those flags **when it spawns the daemon**, so the env knobs still work — applied at spawn
time. Because the daemon is single-instance per pipe, changing one of these env vars has **no
effect on an already-running daemon**: kill that daemon process and let the front re-spawn it for
the new value to take hold. The grace window defaults to 4000 ms.

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
the target runtime, deletes a node, or alters licensing requires the matching `confirm` token (see
[README → Safety & guards](../README.md#safety--guards)). Tokens are enforced in `index.js` and
re-checked defensively in the daemon.

**Safety project.** Nothing in this toolchain writes toward the TwinSAFE safety project. Every
authoring tool refuses safety-rooted (`TISC`) paths via the daemon's `PathUtil.AssertNotSafetyPath`
guard. Safety remains import-only / read-only / diagnostic by policy.
