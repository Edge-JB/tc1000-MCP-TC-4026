# Security Policy

`te1000-mcp` (TwinCAT-XAE-MCP) is an MCP server that drives a **real engineering tool** and can
**activate or download to a TwinCAT runtime**. Because of that, security here is not only about the
Node front end and C# daemon code — it is also about the **safety guards** that keep an AI agent
from touching a target runtime without an explicit, human-supplied confirmation. We take reports
about either seriously.

## Supported versions

Security fixes are applied to the latest released line. Older lines are not back-patched — please
update to the current version before reporting.

| Version | Supported          |
| ------- | ------------------ |
| 1.x     | :white_check_mark: |
| < 1.0   | :x:                |

## Reporting a vulnerability

**Please do not open a public issue for a security vulnerability**, and do not disclose it publicly
until it has been fixed.

Preferred channel — **GitHub private vulnerability reporting**:

1. Go to the repository's **Security** tab.
2. Click **Report a vulnerability** (under *Reporting → Private vulnerability reporting*).
3. Fill in the advisory form with the details below.

If you cannot use that channel, email **jbrock@edgeautomation.ca** with the subject line
`SECURITY: te1000-mcp` instead.

Please include:

- A description of the issue and the impact you believe it has.
- The version (or commit) you tested against.
- Step-by-step reproduction, ideally with the MCP tool call(s) / input involved.
- Any proof-of-concept, logs, or stack traces.

### What counts as a security issue here

In addition to ordinary code vulnerabilities (input handling, injection, dependency CVEs), the
following are in scope because they undermine the project's safety model:

- A way to perform a **runtime-affecting, destructive, or licensing action** (activate, restart,
  download, deletes, license writes) **without the required `confirm` token**, or to bypass the
  guard enforcement in either `index.js` **or** the native daemon (`daemon/`).
- A path that lets a tool **write toward the safety project** (any `TISC`-rooted path) despite
  `PathUtil.AssertNotSafetyPath`.
- A way to make the **dialog watchdog auto-answer** a prompt it must never auto-answer (Activate
  Configuration, Run-mode, restart, download, or any safety prompt).

Out of scope: the inherent fact that *confirmed* guarded actions reach the target runtime — that is
the intended, documented behavior (see [`docs/operations.md`](docs/operations.md) and
[`CONTRIBUTING.md`](CONTRIBUTING.md)).

## What to expect

- We aim to **acknowledge** a report within a few business days.
- We will work with you on a fix and a coordinated disclosure timeline, and credit you in the
  release notes if you would like.

Thank you for helping keep `te1000-mcp` — and the runtimes it can reach — safe.
