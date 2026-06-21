# te1000-mcp — Improvement List

Running list of papercuts and enhancement ideas discovered while using the server
on real TwinCAT projects. Newest first.

---

## 2026-06-20 — Link read-back (`tc_link links`) added to close the verify loop for bulk linking — branch `improve/batch-ops`

`tc_link` could link/unlink/resolve but had no way to ask "what is X currently linked
to?", so bulk linking had no read-back to verify against (the gap `exists_batch`/
`get_batch` already close for tree edits). Added a `links` action (bridge verb
`twincat_get_variable_links`) that, given an item path, reports its current variable
links as `{ path, count, links:[{ varA, varB, offsA?, offsB?, size? }] }`.

XML source: variable links are NOT serialized in a box/device `ProduceXml()` — the
on-disk `.xti` `<Mappings><OwnerA><OwnerB><Link VarA VarB/>` shape is written only by
the project saver, and confirmed (read-only, via the live `tc_tree get_xml`) absent
from both the EtherCAT *device* and *box* level live ProduceXml. Live, each **linked
leaf variable** instead carries its links in its own ProduceXml under
`<VarDef><LinkedWith>` (InnerText = the other endpoint's `^`-path; PLC-side endpoints
also carry `offsA`/`offsB`/`size`/`removeLink` attributes), and it's bidirectional.
So the verb reads a leaf's `<LinkedWith>` directly; for a box/terminal/group (which
carries no `<LinkedWith>` of its own) it walks descendants — standard `Child()` plus
addressable PDO-channel / slot-module sub-items — collecting each leaf's links, with
bounded recursion and `Get-SafeValue`/guarded `[xml]` parsing (parse failure →
`count:0, links:[]`, never throws). Verified against `EL2008 Channel 1 Output` ↔
`GvSys.R01.N09.Ch1`.

---

## 2026-06-20 — Fixed `twincat_list_children` ProduceXml-on-every-call regression — branch `improve/batch-ops`

The CPX-AP/Festo sub-module augmentation added to `twincat_list_children` called
`$item.ProduceXml()` and `[xml]`-parsed it on EVERY children call — including when
listing the children of an EtherCAT *device* root, where ProduceXml serializes the
ENTIRE bus (all boxes + PDO maps + init commands → hundreds of KB to MB) and parses
it, every time, purely to look for sub-modules that only couplers have.

Fix: the children sub-module scan is now gated to `ChildCount == 0` and the XPath is
anchored to `//Slot/Module/Name`. The CPX-AP-A-EC-M12 carrier reports
`ChildCount == 0` (its modules are not standard children) while devices and normal
couplers report `ChildCount > 0` and carry no `<Slot><Module>` entries, so the gate
confines the expensive ProduceXml to the actual carriers. The anchored XPath stops
the old `//Module/Name` form from also matching `<Module><Name>` inside safety
terminals and other non-slot `<Module>` elements. This removes a
ProduceXml-on-every-call regression (was serializing the whole bus when listing a
device's children). Accepted trade-off: a hypothetical box with BOTH standard
children AND slot-modules would have its modules missed.

---

## 2026-06-20 — WON'T DO: persistent bridge (long-lived attached PowerShell + DTE) — rationale

Considered keeping the PowerShell process and the attached TcXaeShell DTE alive
across MCP calls (instead of spawn + `Get-Dte` attach per call) to cut per-call
latency. **Declined.** TcXaeShell's COM/DTE is flaky; a long-lived attached DTE
risks drifting out of sync with the live solution — stale tree-item handles, a lost
target/connection, lingering modal dialogs that wedge the next call. The per-call
spawn + attach latency is an acceptable trade because it carries NO token cost
(it's wall-clock only, not context), and every call starts from a known-clean
attach. Recorded here as a deliberate non-goal, not an open idea.

---

## 2026-06-20 — Added `tc_tree action:create_batch` / `delete_batch` (scaffold / teardown N child nodes in one attach) — branch `improve/batch-ops`

Building out (or tearing down) a set of tree children — e.g. several EtherCAT boxes
or CPX modules — done one at a time is N `tc_tree action:create` / `action:delete`
calls, each spawning its own PowerShell process and `Get-Dte` / `Get-SysManager`
DTE attach.

`create_batch` (`creates:[{parent,name,subType,before?,createInfo?}]`) and
`delete_batch` (`deletes:[{parent,name}]`) collapse that to **one** tool-call /
process / DTE attach: attach once, then process each entry sequentially in array
order with continue-on-error (one failure never aborts the rest). Each entry mirrors
the single `twincat_create_child` / `twincat_delete_child` semantics — `create_batch`
looks up the parent via `Get-TreeItem`, calls `parent.CreateChild(name, subType,
before, createInfo)` and returns the shared `Convert-TreeItem` shape; `delete_batch`
calls `parent.DeleteChild(name)`. Because every entry addresses items by **name**
under a freshly-looked-up parent, delete is order-independent even though deleting a
child shifts sibling indices — no index bookkeeping needed. Both return the same
compact `{ count, succeeded, failed, results }` roll-up used by the other batch
verbs (`succeeded`/`failed` counters; `ok` reserved for the envelope + per-entry
status).

---

## 2026-06-20 — Added `tc_tree action:exists_batch` / `get_batch` (one attach for N read/verify checks) — branch `improve/batch-ops`

After a bulk rename / link / create it's common to want to confirm that a whole set
of tree paths now resolve (or that the old ones are gone), or to pull back the
identity of many items at once. Done one path at a time that's N `tc_tree
action:exists` / `action:get` calls, each spawning its own PowerShell process and
doing its own `Get-Dte` / `Get-SysManager` DTE attach.

`exists_batch` (`paths:[...]`) and `get_batch` (`paths:[...]`) collapse that to **one**
tool-call / process / DTE attach: attach once, then check / look up each path
sequentially in the given order. Both are read-only — a bad path never aborts the
loop (continue-on-error). `exists_batch` replicates the single `exists` existence
test (resolve via `Get-TreeItem`, `exists = $null -ne $item`, swallow throws as
`exists:false`) and returns a compact `{ count, found, missing, results }` of
`{ path, exists }` entries. `get_batch` resolves via `Get-TreeItem` then reuses the
shared `Convert-TreeItem` helper, returning `{ count, succeeded, failed, results }`
where each found entry is the Convert-TreeItem shape (name / pathName / itemType /
subType / childCount) plus `path` + `ok:true`, and a miss is `{ path, ok:false, error }`.
Field naming matches the existing `rename_batch` / `set_xml_batch` / link-batch
roll-ups.

---

## 2026-06-20 — Added `tc_tree action:set_xml_batch` (one attach for N param-pushes) — branch `improve/batch-ops`

Pushing parameter (XML) changes into a group of tree items — e.g. setting the same
analog-input scaling block on every channel of a rack — previously meant one
`tc_tree action:set_xml` (ConsumeXml) call per item, each spawning its own PowerShell
process and doing its own `Get-Dte` / `Get-SysManager` DTE attach.

`set_xml_batch` (`items:[{path,xml}]`) collapses that to **one** tool-call / process /
DTE attach: attach once, then ConsumeXml each `path`/`xml` pair sequentially in the
given order. One failure (or a blank `path`/`xml`) never aborts the rest
(continue-on-error). The result is a compact roll-up `{ count, succeeded, failed,
results }` where each entry is `{ path, ok }` (plus `error` on failure); pass
`returnXml:true` to also echo each item's produced XML (TreeImage stripped). The single
`twincat_set_tree_item_xml` and the new `twincat_set_tree_item_xml_batch` bridge verbs
now share one `Set-TreeItemXml` helper (ConsumeXml + `GetLastXmlError()` reporting,
returns the item for optional ProduceXml), mirroring how `Rename-TreeItem` and
`Link-Variables` were factored.

---

## 2026-06-20 — Added `tc_link action:link_batch` / `unlink_batch` (one attach for N links) — branch `improve/batch-ops`

Wiring up IO (or tearing it down) one `tc_link action:link` call at a time has the
same papercut as single renames: every call spawns its own PowerShell process and
does its own `Get-Dte` / `Get-SysManager` DTE attach. Linking a rack of channels is
N tool-calls × N attaches.

`link_batch` (`links:[{a,b}]`) and `unlink_batch` (`links:[{a,b?}]`) collapse that to
**one** tool-call / process / DTE attach: attach once, then link/unlink each pair
sequentially in the given order. One failure never aborts the rest (continue-on-error).
The result is a verbose per-entry roll-up `{ count, succeeded, failed, results }`; each
`link_batch` entry reports the **resolved** `^`-path forms each side was linked through
(`resolvedA`/`resolvedB`) so you can confirm the dot→`^` subitem resolution that
actually happened. The single `twincat_link_variables` and the new
`twincat_link_variables_batch` bridge verbs now share one `Link-Variables` helper
(resolve-then-`LinkVariables`), mirroring how `Rename-TreeItem` was factored.

---

## 2026-06-20 — Added `tc_tree action:rename_batch` (one attach for N renames) — branch `improve/rename-batch`

Renaming a group of items (e.g. every CPX-AP sub-module under a coupler) previously
meant one `tc_tree action:rename` call per item — and each call spawns its own
PowerShell process and does its own `Get-Dte` / `Get-SysManager` DTE attach. For a
rack of modules that is N tool-calls × N process-spawns × N attaches, which is slow.

`rename_batch` collapses that to **one** tool-call / process / DTE attach: it takes a
parent `path` and a `renames:[{name|path,newName}]` array, attaches once, and renames
each item sequentially in order (reusing the proven ConsumeXml `<ItemName>` mechanism —
links stay intact). One failure never aborts the rest; it returns a compact roll-up
`{ parent, count, succeeded, failed, results }`. The single `twincat_rename_tree_item`
and the new `twincat_rename_tree_items` bridge verbs now share one `Rename-TreeItem`
helper so there is a single rename implementation.

---

## 2026-06-20 — `children` does not enumerate CPX-AP (Festo) sub-modules — they're undiscoverable by tree-walking

### What I was doing
Renaming a Festo CPX-AP sub-module — `Module 3 (CPX-AP-A-4IOL-M12 Variant 8)` —
that hangs off a `CPX-AP-A-EC-M12` bus head (itself an EtherCAT box,
`R06.LDR.N05`). The AP modules continue the rack node numbering
(`...N06`, `...N07`, ...).

### The pitfall
`tc_tree action:children` on the `CPX-AP-A-EC-M12` box returns
**`childCount: 0`** — yet the AP modules underneath it absolutely exist and are
fully addressable:
- `tc_tree action:exists path:"...^R06.LDR.N05 (CPX-AP-A-EC-M12)^Module 3 (CPX-AP-A-4IOL-M12 Variant 8)"` → `exists: true`
- `tc_tree action:rename` on that same path → succeeds, links intact.

So the modules are real tree items (`twincat_lookup_tree_item` / ConsumeXml find
them by path), but `twincat_list_children` does **not** walk into them. Net
effect: **you cannot discover these sub-modules through the MCP at all.** The only
way I found `Module 3` was by grepping the on-disk `.xti`
(`_Config/IO/Device 2 (EtherCAT)/R01.Main.N01 (EK1200).xti`) for the name. If a
caller relied on `children` to enumerate "what still needs renaming," every
CPX-AP / Festo AP module (IO-Link masters, valve terminals, DI/DO blocks) would be
silently skipped — exactly the kind of silent gap that looks like "all done" when
it isn't.

Likely cause: these AP modules live in the box's XML as `<Slot><Module>` entries
(a sub-object collection), not as standard child tree items, so whatever
collection `twincat_list_children` iterates (`ITcSmTreeItem.Child`/`ChildCount`)
doesn't include them — even though they ARE resolvable via `LookupTreeItem` by
their full `^`-path.

### Improvement ideas
1. **Make `children` enumerate sub-modules.** Where a box exposes a `<Slot>/<Module>`
   collection (CPX-AP-A-EC-M12 and similar Festo/3rd-party couplers), have
   `twincat_list_children` fall back to (or additionally include) those module
   entries so tree-walking discovery is complete. Tag them (e.g.
   `kind: "module"`) so callers can tell them from real child boxes.
2. **At minimum, signal the gap.** If `ChildCount` is 0 but the item is a coupler
   type known to carry AP/sub-modules, include a hint in the result
   (e.g. `hasUnlistedModules: true`) so a caller doesn't conclude the branch is empty.
3. **Document it** in README: "CPX-AP / Festo AP modules are addressable by path
   (`exists`/`get_xml`/`rename` work) but are not returned by `children`; discover
   them via the box's `get_xml` `<Slot><Module>` list or the on-disk `.xti`."
4. Consider a `get_xml summary:true` (see the entry below) that, for a coupler,
   returns just the slot/module name list cheaply — that would double as the
   discovery path for these modules without the full blob.

The rename mechanism itself is fine here; the problem is purely **discoverability**
via `children`.

### Resolved 2026-06-20 (branch `improve/children-enumerate-modules`)
`twincat_list_children` now augments the standard `ChildCount`/`Child()` result with
coupler sub-modules. After building the standard `$children` (each tagged
`kind:"child"`), it reads `$item.ProduceXml()` (try/catch), parses it (`[xml]`,
try/catch), selects every `//Module/Name`, and for each module name not already
listed it resolves `"<boxPath>^<moduleName>"` via `Get-TreeItem` (try/catch). Only
genuinely-resolvable modules are emitted — `Convert-TreeItem`'d to the same shape as a
normal child, tagged `kind:"module"`, and appended. Dedupe is a case-sensitive
(`Ordinal`) `HashSet[string]` of listed names. `childCount` in the response now equals
`$children.Count` (standard + modules). Every step is guarded so a malformed box or an
unresolvable module never breaks a normal `children` call. No `index.js` change needed
(the `children` case flows straight through `textResult`, so `kind` passes through).
Improvement idea #1 above is now implemented; #2 (`hasUnlistedModules` hint) is moot.

---

## 2026-06-20 — Renaming IO tree items is a token sink (no `rename`, `set_xml` echoes full XML)

### What I was doing
Bulk-renaming EtherCAT IO boxes/terminals in the CabSort project to the
`R{rack}.{area}.N{node} (partno)` convention — 15 items across three coupler chains
(EOAT boxes, OMAL terminals, LDR terminals). Conceptually this is 15 string
assignments. In practice it cost an estimated **~225k+ tokens** and forced me to
offload the bulk to a subagent just to keep the main context from being buried.

### The pitfalls

1. **There is no first-class rename.** The obvious affordance — the `newName`
   parameter on `tc_tree` — is silently inert for this purpose. It is wired only to
   the `import` action (`importAsName`); for an existing item it does nothing. See
   `index.js` `tc_tree` handler: `newName` only appears in `case "import"`.
   - `action:"rename"` fails Zod enum validation (the enum is
     `get|children|exists|get_xml|set_xml|create|delete|import|export|focus`).
   - `set_xml` with `newName` (no `xml`) errors with `'xml' is required`.
   - So the caller has to *discover by probing* that the only working path is
     `set_xml` (ConsumeXml) with a hand-built `<TreeItem><ItemName>...</ItemName></TreeItem>`.
     Each failed probe is a wasted round-trip.

2. **`set_xml` returns the entire `ProduceXml()` of the item.** See
   `te1000-bridge.ps1` `twincat_set_tree_item_xml`: after `ConsumeXml`, it returns
   `xml = $item.ProduceXml()`. For an EtherCAT slave that blob includes the full
   TxPdo/RxPdo map, the entire CoE/EEPROM/FMMU/SM init-command sequence, DC opmodes,
   **and an embedded bitmap (`TreeImageData16x14`)** — roughly **12–16k tokens per
   item**. A rename only needs to set one string, but you pay the full blob back on
   every single call.

3. **Inspecting the tree to plan the rename is also expensive.** `get_xml` is the
   same ~15k-token blob, so even *looking* at one item to confirm structure before
   renaming is costly. There's no cheap "identity only" view.

4. **Net effect.** 15 renames × ~15k token echo ≈ 225k tokens of pure return payload
   that is immediately discarded, plus the discovery probes and an exploratory
   `get_xml`. The operation is semantically trivial but blows a context budget and
   pushed me into spawning a subagent purely for damage control.

### Improvement ideas (roughly priority-ordered)

1. **Add a dedicated `rename` action** to `tc_tree`, wiring the already-present
   `newName` param to it. Implement a bridge verb `twincat_rename_tree_item` that
   sets the name and returns a **compact** result only:
   `{ ok, treePath, newName, newPath }` — no `ProduceXml`.
   - Implementation that is already proven to work and keeps IO links intact:
     ConsumeXml a minimal `<TreeItem><ItemName>$newName</ItemName></TreeItem>`
     (this updates *both* the tree `ItemName` and the internal EtherCAT
     `Info/Name` CDATA), then read back `$item.PathName` for `newPath`.
   - (`$item.Name = $newName` may also work via the Automation Interface, but the
     minimal-ConsumeXml route is the one verified on EtherCAT slaves here.)

2. **Stop echoing the full XML from `set_xml` by default.** Return a compact
   `{ ok, treePath }` (or `{ ok, treePath, newPath }`). Add an opt-in
   `returnXml: boolean` (default `false`) for callers who genuinely want the
   produced XML. This single change removes the per-call blow-up for *all*
   ConsumeXml uses, not just renames.

3. **Always strip `TreeImageData16x14`** (the embedded bitmap) from any XML the
   server returns. It's never useful to a model and is pure token cost in both
   `get_xml` and any `returnXml` path.

4. **Add a cheap identity view to `get_xml`** — e.g. `summary:true` (or a `fields`
   selector) that returns just `ItemName / PathName / ItemSubTypeName / ChildCount`
   without the PDO/CoE payload, so the tree can be inspected before edits without
   paying the full blob.

5. **Document the rename recipe** in `README.md` and the `tc_tree` tool description
   so future callers don't have to probe to find it.

6. **(Optional) Bulk rename helper** — racks are renamed in sequential runs
   (`Nxx` incrementing along a coupler chain), so a batch form that takes
   `[{path, newName}, ...]` and returns one compact array would fit the real usage
   pattern and cut round-trips.

The two highest-leverage, lowest-risk fixes are **#1 (dedicated `rename`)** and
**#2 (compact `set_xml` by default)**.

> **Resolved 2026-06-20 (branch `improve/batch-ops`)** — idea #4 implemented:
> `tc_tree action:get_xml summary:true` now returns the cheap identity view
> (`name / pathName / itemType / subType / childCount` from `Convert-TreeItem`,
> plus a `modules` array of the `//Slot/Module/Name` slot-module names) instead of
> the full `ProduceXml()` blob. Summary mode still calls `ProduceXml()` server-side
> to extract the module list (latency, not tokens) — the win is not returning the
> blob. The default (no `summary`) path is unchanged.
