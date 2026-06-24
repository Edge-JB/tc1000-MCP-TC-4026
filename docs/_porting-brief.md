# Porting brief — te1000 PowerShell bridge action -> C# daemon handler

You are porting a group of action handlers from the PowerShell bridge
`C:\ProgramData\te1000-mcp\powershell\te1000-bridge.ps1` into a C# file under
`C:\ProgramData\te1000-mcp-daemon\daemon\Actions\`. The daemon is **already built
and working**; you are filling in one handler-group file. DO NOT touch any other
file. DO NOT run a live build/XAE.

## The contract (read carefully)

Each action in the PS bridge is a `switch ($Action)` case (in
`te1000-bridge.ps1`). It reads `$payload` fields, drives the cached DTE /
`$sysManager` via late-bound COM, and ends by calling
`Write-JsonResult @{ ok = $true; data = <hashtable> }` then `exit 0`. On error it
`throw`s (the harness turns that into `{ok:false, error:<msg>}`).

Your C# handler must produce the **same `data` object** (same keys, same value
types, same shapes). Return that `data` as a `Json.JObj` from the handler. The
dispatcher wraps it into `{ok:true, result:<data>}`. To signal an error, throw
`new BridgeException("message")` (mirrors PS `throw`).

## Mechanical porting rules

PowerShell construct -> C# (`dynamic` COM):
- `$sysManager.LookupTreeItem($p)` -> `ctx.SysManager().LookupTreeItem(p)` OR
  `ComHelpers.GetTreeItem(sm, p)` (throws "Tree item not found: <p>" if null) —
  use the cache: `ctx.Cache.LookupItem(sm, p)` for **read** lookups.
- `$item.Child($i)` -> `item.Child(i)` (1-based, like PS). `ComHelpers.Child(item,i)` swallows errors.
- `$item.ChildCount` -> `ComHelpers.ChildCount(item)`.
- `$item.ProduceXml()` / `$item.ConsumeXml($xml)` -> `ComHelpers.ProduceXml(item)` /
  `ComHelpers.ConsumeXml(item, xml)` (the latter surfaces GetLastXmlError exactly like PS).
- `Get-SafeValue { ... }` -> `ComHelpers.Safe(() => ...)` / `SafeStr` / `SafeInt`.
- `Normalize-ScalarValue (Get-SafeValue { [string]$x.Y })` -> `ComHelpers.SafeStr(() => x.Y)`.
- `Convert-TreeItem $item` -> `ComHelpers.ConvertTreeItem(item)` (returns a Json.JObj
  with name/pathName/itemType/subType/childCount).
- `Invoke-WithRetry { ... }` -> `ComHelpers.WithRetry(() => ...)`.
- `Assert-NotSafetyPath $p` -> `PathUtil.AssertNotSafetyPath(p)` (TISC rejection — KEEP IT).
- `Split-PlcObjectPath` -> `PathUtil.SplitObjectPath(p)` -> `.Parent` / `.Name`.
- `Assert-PlcMoveLegal` -> `PathUtil.AssertMoveLegal(path, newParent)`.
- typed vtable helpers (`Te1000PlcProjectHelper::X(...)`) -> `PlcProjectHelper.X(...)`.

Payload access (`$payload.foo`):
- string: `ctx.Payload.Str("foo")`  (null if absent)
- required string: `ctx.Require("foo")` (throws "foo is required")
- bool with default: `ctx.Payload.Bool("foo", false)`
- present-and-set bool (`if ($null -ne $payload.x)`): `if (ctx.Payload.Has("x")) { var b = ctx.Payload.Bool("x"); }`
- int: `ctx.Payload.Int("foo", dflt)`
- PS truthiness `if ($payload.foo)`: `ctx.Payload.Truthy("foo")`
- array: `ctx.Payload.Arr("foo")` (Json.JArr : List<object>); required: `ctx.RequireArray("foo")`
- nested object: `ctx.Payload.Obj("foo")` (Json.JObj)
- `$payload.PSObject.Properties.Name -contains 'x'` -> `ctx.Payload.Has("x")`

Building `data`:
```csharp
var data = new Json.JObj();
data["ok"] = true;            // only where the PS data block sets it
data["count"] = n;
data["results"] = arr;        // arr is a Json.JArr; add Json.JObj / strings / numbers
```
A `Json.JArr` is built with `new Json.JArr(); arr.Add(obj);`. Numbers: pass `int`/`long`/`double`.
Booleans: pass `bool`. Mirror the PS key order where practical (JObj preserves insert order).

### Batch roll-up shape (continue-on-error) — preserve EXACTLY
Many `*_batch` / `*_children` actions return:
```
{ count, succeeded, failed, results: [ {<per-item>, ok:true} | {<key>, ok:false, error:"..."} ] }
```
and frequently honor an opt-in `save: true` that calls `File.SaveAll` at the end
(`ctx.Dte().ExecuteCommand("File.SaveAll")`). Replicate the exact field names,
the per-item ok/error, and the save behavior from the PS source.

### Guard tokens — keep verbatim
Some actions require a confirm token (e.g. delete needs `ALLOW_TWINCAT_DELETE`).
NOTE: index.js already enforces most confirm tokens before calling the bridge, so
the BRIDGE handler usually does NOT re-check. **Only** replicate a token/guard
check if the PS handler itself checks it. Otherwise port the handler logic as-is.

### Perf fix (only relevant to plc_pou.find/search and tc_tree walks)
Where the PS code calls `Invoke-PlcTreeWalk -MaxDepth 0` from a root, scope the
walk to the requested subtree path and a bounded depth, resolving known paths via
`LookupTreeItem`. If your group does not include those actions, ignore this.

## Helpers available (already compiled — do not redefine)
- `ActionContext ctx`: `ctx.Payload` (Json.JObj), `ctx.Dte()`, `ctx.SysManager()`,
  `ctx.Cache` (TreeCache), `ctx.ProgId`, `ctx.Mode`, `ctx.Require(key)`, `ctx.RequireArray(key)`.
- `ComHelpers`: GetTreeItem, TryGetTreeItem, Child, ChildCount, ConsumeXml, ProduceXml,
  Safe/SafeStr/SafeInt, WithRetry, ConvertTreeItem, StripTreeImage, ToInt,
  VariablePathCandidates, ResolveVariablePath, ResolveVariableItem (out resolvedPath).
- `PathUtil`: AssertNotSafetyPath, SplitObjectPath(.Parent/.Name), AssertMoveLegal, XmlEscape.
- `PlcProjectHelper`: GetAutostart, Deploy, SetBootFlags, CheckAll, GetNestedProjectName,
  GetInstanceName, SetLinkedTask, PlcOpenExport, PlcOpenImport, SaveAsLibrary.
- `Json.JObj` (ordered map; `o["k"]=v`, `o.Str/Int/Bool/Arr/Obj/Has/Truthy`),
  `Json.JArr : List<object>`.
- Throw `new BridgeException("msg")` for handled errors.

## C# LANGUAGE LIMIT — CRITICAL
The in-box compiler is **C# 5 only**. DO NOT use: string interpolation (`$"..."`),
`out var`, expression-bodied members (`=>`), pattern matching (`is T x` / `case T x:`),
getter-only auto-props (`{ get; }`), `nameof`, tuples, null-conditional with index.
Use: explicit casts, `string.Format`/concatenation, classic `out` with a declared
variable, full method bodies, `??` (ok), named args (ok), `dynamic` (ok).
After editing, the integrator will compile; keep it C#5-clean.

## File skeleton (fill in the Register body + one private static method per action)
```csharp
using System;
using System.Collections.Generic;

namespace Te1000Daemon
{
    internal static class <GroupName>Actions
    {
        public static void Register(Dictionary<string, ActionHandler> h)
        {
            h["<bridge_action_name>"] = <MethodName>;
            // ... one per action ...
        }

        private static Json.JObj <MethodName>(ActionContext ctx)
        {
            // ... port of the PS handler body; return the `data` JObj ...
        }
    }
}
```

Use the EXACT bridge action string as the dictionary key (e.g. `"twincat_lookup_tree_item"`).
Read the PS source for each action at the given line range and port it faithfully.
