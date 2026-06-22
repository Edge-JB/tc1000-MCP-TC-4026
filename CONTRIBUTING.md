# Contributing

Thanks for your interest in improving `te1000-mcp`. This document covers the architecture, the
contract between the Node server and the PowerShell bridge, and the rules every change must respect.

## Architecture

```
MCP client ──stdio──► index.js (Node 20) ──spawns──► 32-bit PowerShell
                                                       └─ powershell/te1000-bridge.ps1 ──COM/DTE──► XAE Shell
```

- **`index.js`** — registers MCP tools, validates input with [zod](https://zod.dev), enforces
  confirmation-token guards, and maps each tool `action` onto a bridge action name. It owns the
  modal-dialog watchdog and pre-flight gate.
- **`powershell/te1000-bridge.ps1`** — attaches to the running XAE Shell via its COM ProgID and
  calls the TE1000 Automation Interface. It re-checks guards defensively. 32-bit PowerShell is
  required to match Beckhoff's TE1000 COM model.
- **`powershell/dialog-watch.ps1`**, **`dialog-allowlist.json`**, **`plc-session.ps1`** — the
  reliability layer (see [docs/operations.md](docs/operations.md)).

## Development

```powershell
git clone https://github.com/Edge-JB/TwinCAT-XAE-MCP.git
cd TwinCAT-XAE-MCP
npm install
npm run check        # node --check index.js — syntax-validate the server
node index.js        # smoke test — prints "running on stdio" and waits
```

CI runs `npm run check` on every push and pull request. There is no automated test of the live
TwinCAT path — that requires a real XAE installation and is exercised manually against a project.
The PowerShell engine tests under `powershell/test-code-engine*.ps1` are run by hand on a machine
with XAE present.

## Adding or changing a tool

1. Keep the **noun-grouped, action-enum** shape. New capabilities are usually a new `action` on an
   existing tool, not a new top-level tool.
2. Prefer a **`*_batch`** form for anything that operates on more than one item — one DTE attach,
   continue-on-error roll-up.
3. Return **compact** output. Slice/grep large reads; echo full XML only on explicit request.
4. Update the [tool reference](docs/tools.md), the README table, and [CHANGELOG.md](CHANGELOG.md).

## Non-negotiable safety rules

- **Guard every live-target, destructive, or licensing action** with a `confirm` token, enforced
  in both `index.js` and the bridge. Off by default.
- **Never write toward the safety project.** Authoring tools must refuse safety-rooted (`TISC`)
  paths via `Assert-NotSafetyPath`.
- **Never auto-answer destructive dialogs.** The dialog allowlist must not contain Activate
  Configuration, Run-mode, restart, download, or safety prompts.

## Commits & pull requests

- Use clear, conventional commit subjects (`feat(plc_pou): …`, `fix(tc_tree): …`, `docs: …`).
- Describe what you verified and on what (build green? run against a live XAE? syntax check only?).
- Keep documentation in lockstep with behaviour changes.
