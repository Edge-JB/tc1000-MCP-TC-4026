# te1000-mcp — Improvement List

Running list of papercuts and enhancement ideas discovered while using the server
on real TwinCAT projects. Newest first.

---

## 2026-06-22 — Renamed `createIO` → `tc_ethercat` for clarity — branch `feature/rename-tc-ethercat`

`createIO` is renamed to **`tc_ethercat`** so the EtherCAT-vs-other-buses split is
obvious and parallel: `tc_ethercat` (EtherCAT IO from ESI) sits beside
`tc_fieldbus` (PROFINET/PROFIBUS/CANopen/DeviceNet/EAP). "fieldbus" technically
includes EtherCAT, so the old `createIO`/`tc_fieldbus` pairing was ambiguous.
Decision: rename + keep them separate (not merged) — `tc_ethercat`'s zero-SubType,
product-string-only `racks[]` shape is deliberately simpler than the SubType-driven
`tc_fieldbus`, and merging would dilute it. The MCP **tool name** changed; the
internal bridge verb stays `twincat_create_io` (no functional change). All
cross-references in tool descriptions + README updated. Historical entries below
keep the old `createIO` name as the record of what it was called at the time.

---

## 2026-06-22 — AI-surface buildout: 13 new tools close almost all of `features.md §17` — branch `feature/ai-surface-buildout`

Added **13 noun-grouped MCP tools** (one commit each) that wrap the automatable
gaps catalogued in `features.md §17`, taking the registered surface from 12 to
**25 tools**. The PowerShell bridge gained matching dispatch verbs (143 distinct
action verbs are referenced from `index.js`, every one resolves to a bridge
case); no pre-existing tool (`xae` / `xae_build` / `xae_command` / `tc_tree` /
`tc_link` / `tc_system` / `createIO` / `plc_download` / `plc_session` / `nc` /
`twincat_activate_configuration` / `twincat_restart_runtime`) was removed or
altered (diff vs branch point: 5221 insertions, 9 deletions, none touching a
pre-existing tool registration).

**New tools:** `plc_project`, `plc_pou`, `plc_library`, `tc_task`, `tc_mapping`,
`tc_route`, `tc_settings`, `tc_fieldbus`, `tc_module`, `tc_cpp`,
`tc_measurement`, `tc_license`, `tc_variant`.

**§17 gaps now covered** (was "automatable but not yet wrapped"):

- PLC project authoring (§7.1) + POUs/DUTs/GVLs + decl/impl edit + PLCopen
  import/export + `CheckAllObjects` + boot-flags/online → `plc_project`,
  `plc_pou`.
- Library refs / placeholders / resolution / freeze / scan / repository admin
  (`ITcPlcLibraryManager`) (§7.2) → `plc_library`.
- Mapping bulk ops `Produce/Consume/ClearMappingInfo` (§5) → `tc_mapping`.
- RT tasks (with/without image, cycle/priority), CPU-core bind, LinkedTask (§5)
  → `tc_task`.
- Silent-mode toggle, target platform x86/x64, solution/PLC archives (§4, §7.1)
  → `tc_settings`.
- ADS routes — add route / broadcast search via `TIRR` (§6) → `tc_route`.
- Non-EtherCAT fieldbuses — PROFINET/PROFIBUS/CANopen/DeviceNet/EAP create +
  claim resources + GSD box + netvar + DBC import (§8) → `tc_fieldbus`.
- TcCOM — add module by GUID/name, get/set XML, enable symbols, set context,
  link/unlink (§9) → `tc_module`.
- TwinCAT C++ — create project/module, open, TMC codegen, set props, build,
  publish (§10) → `tc_cpp`.
- Measurement/Scope + Analytics Logger/Stream (TIAN) (§11) → `tc_measurement`.
- Licensing — dongle config + OEM response-file activation (§13) → `tc_license`.
- Variant management via `iTcSysManager14` (§14) → `tc_variant`.

**Safety (§15) was intentionally excluded by project policy.** Nothing in the
toolchain may write toward the safety system; every authoring/write verb refuses
any `TISC`-rooted path (`Assert-NotSafetyPath`), and `tc_variant` additionally
refuses variant ops on the safety project. This is the one §17 item left
uncovered, by design — not a gap.

**Guarding.** Every cell-impacting / runtime / remote-write / license action is
`confirm`-token gated in `index.js` (and re-checked in the bridge):
`ALLOW_PLC_DOWNLOAD` (boot/online), `ALLOW_PLC_LIBRARY_REPO`,
`ALLOW_TWINCAT_ROUTE_WRITE`, `ALLOW_TWINCAT_MODULE_CONTEXT`, `ALLOW_CPP_PUBLISH`,
`ALLOW_MEASUREMENT_RECORD`, `ALLOW_TWINCAT_DELETE`, `ALLOW_LICENSE_ACTIVATE`
(joining the pre-existing `ALLOW_TWINCAT_ACTIVATE` / `_RESTART` /
`ALLOW_XAE_COMMAND_EXEC` / `ALLOW_PLC_LOGOUT`).

**Integration fix (safety net).** During final verification, the PowerShell
`Parser::ParseFile` check on `te1000-bridge.ps1` failed where Windows
PowerShell 5.1 reads the BOM-less file as ANSI: two em-dashes (`—`, U+2014)
sat **inside double-quoted strings** (`twincat_cpp_open` ghost-error and
`twincat_set_current_variant` mismatch-error) and corrupted those string
literals under the ANSI read. Replaced both with ASCII hyphens; `node --check
index.js` and `ParseFile` both pass clean. (Em-dashes in *comments* parse fine
and were left alone.) `features.md` (the design source for this work) is now
tracked in git.

---

## 2026-06-22 — `createIO`: two polish items found during the full-rack (R03.CNC) test — TODO

Both surfaced while building an entire CNC rack (EK1100 coupler + EL1904/EL2904/EL1008/EL2008/EL9011)
in one `createIO` call. The call itself works end-to-end — coupler created first, terminals nested
under it in the same call (cross-rack parent dependency resolves sequentially). These are follow-ups,
not regressions.

**1. [TODO] Garbled error string on parent-lookup failure.** When a rack's `parent` can't be resolved
(e.g. because an earlier rack that should have created it failed), the per-entry error comes back as
mojibake: `parent lookup failed: Item '??????'???????????????????????????????!' not found`. The path
is being mangled — an encoding/quoting glitch in the bridge's error echo (likely the `(...)` / E-Bus
name passing through a PowerShell error-message interpolation or a non-UTF8 round-trip). Fix: emit the
actual requested parent path verbatim in the error. Cosmetic only — the `ok:false` and continue-on-error
behaviour are correct.

**2. [TODO] `Assert-WellFormedChild` is too strict for couplers that TwinCAT auto-places.** Appending a
coupler (`EK1100`) to the **EtherCAT master** (`TIID^Device 2 (EtherCAT)`) succeeds at the TwinCAT level
but TwinCAT **relocates** the box into the topology under the appropriate junction (observed: it landed
under the `EK1122` at `R01.Main.N14` instead of directly under the master). The guard then sees
"returned child path is not under requested parent", flags it malformed, and deletes the (validly
created) box. Decide on one of: (a) relax the guard to accept TwinCAT's auto-chosen slot for couplers —
detect by class/`9099` + actual path being a descendant rather than a direct child — and return the real
path; or (b) keep the guard but document the rule clearly: **couplers must target the junction
(`EK1122`) or their true parent, not the master or a sibling coupler**. Note the related TwinCAT
topology rule observed: an `EK1100` cannot be appended under an `EK1200` (`Cannot append box ... to
slave ...`) — couplers attach to a junction, not to a compact coupler. Whichever path is chosen, the
docs should state the coupler-parent rule so callers pick the right `parent` up front.

---

## 2026-06-21 — `createIO` replaces `create_rack`: native ESI expansion, generator deleted — branch `feature/createio-native`

`createIO` replaces `create_rack`: native `ITcSmTreeItem.CreateChild(name, 9099, '', '<type>')` makes
TwinCAT expand boxes from its ESI (the GUI's own "Add Box" path); works for **ALL** classes — digital,
analog input **and** output, IO-Link, mailbox, DC, couplers. The hand-rolled ESI generator + all of its
helpers are **DELETED** (no fallback). `vInfo` = the **product string**, not identity XML — the old
dead-end.

**Why.** The 4th `CreateChild` arg (`vInfo`/createInfo) is the plain product string (`"EL1417"` =
latest revision, or `"EL1008-0000-0017"` = pinned). TwinCAT's own ESI engine then populates the box:
correct identity, TwinCAT-computed SyncManagers, FMMUs, the full `<EtherCAT>` mailbox/CoE/FoE element,
and the complete `<Pdo>`/`<Entry>` set — for any device class. The previous dead-end was passing
identity XML / VendorId+ProductCode numbers as `vInfo`, which yields a blank-named ghost.

**Proven live** (via the hot-reloading `tc_tree create` route, subType 9099, createInfo=type) across
every class under `EK1200`, each exported and confirmed non-hollow then deleted:

| type   | class            | SyncMan | Pdos | entries |
|--------|------------------|---------|------|---------|
| EL2008 | digital-out      | 4 (1 `<SyncMan>` blob) | 8 | 8 |
| EL3064 | analog-in (CoE)  | 4 | 8 | 44 |
| EL4004 | analog-out (CoE) | 4 | 4 | 4 |
| EL6224 | IO-Link master   | 4 | 10 | 6 |
| EL1417 | mailbox-digital  | 4 | 1 | 32 |

EL4004 (analog-out) and EL6224 (IO-Link) are classes the **old generator could not produce at all** —
native expansion handles them for free.

**Revision pin format (confirmed live on EL1008).** The product-string suffix `"<pppp>-<rrrr>"` is
**decimal**: `pppp` = the product-code variant (the EtherCAT `"0000"` variant), `rrrr` = the decimal
revision number, which TwinCAT renders into the high 16 bits of `RevisionNo`:
`EL1008-0000-0016` → `RevisionNo #x00100000`, `EL1008-0000-0017` → `#x00110000`. Bare type = latest.

**ONE unified schema.** A single box and a full multi-coupler rack are the same operation:
`createIO({ racks:[{ parent, modules:[{ type, name?, revision?, before? }] }], save? })`. A single box
is just `racks:[{ parent, modules:[{ type }] }]` — there is no separate "batch" vs "rack" form.
Continue-on-error; flat roll-up `{ count, succeeded, failed, results:[{ parent, type, name, ok, error? }] }`.

**Deleted (entire hand-rolled generator + helpers, all confined to the old `create_rack` path, grep-confirmed unused):**
`Build-BoxXti`, `Build-SyncManFromEsi`, `Build-FmmuFromEsi`, `Get-AnalogEntryType`,
`Test-EsiDeviceHasRealPdos`, `ConvertFrom-EsiHex`, `Resolve-EsiDevice` (with its `SmList`/`FmmuList`/PDO
parsing), and the `$script:EsiFolder` constant — 497 lines removed from `te1000-bridge.ps1`. The
`twincat_create_rack` bridge action is replaced by `twincat_create_io`. **Kept:** `Assert-WellFormedChild`
(shared by `tc_tree create`/`create_batch` and now `createIO` for ghost detection + cleanup).

The `2026-06-21` entry below (ESI-computed SyncMan/Fmmu) and the moot `improve/esi-parser-robustness`
hex-parse fix both targeted the now-deleted generator and no longer apply.

---

## 2026-06-21 — SyncMan/Fmmu now fully ESI-computed; baked framing removed — branch `improve/esi-computed-syncman`

**Refactor.** The box-level `<SyncMan>`/`<Fmmu>` blobs in the `create_rack` ESI→`.xti` generator are
now computed **entirely from the ESI's own `<Sm>`/`<Fmmu>` declarations** by a single generic encoder
pair — `Build-SyncManFromEsi` / `Build-FmmuFromEsi` — used by **both** digital and analog. The four
old per-class functions (`Get-DigitalSyncManBlob` / `Get-DigitalFmmuBlob` / `Get-AnalogSyncManBlob` /
`Get-AnalogFmmuBlob`) with their hardcoded literal byte arrays (the `04 00 00 00…` tail, the fixed
3-record/24-byte SyncMan frame, the 16-byte FMMU layout) are **deleted**. `Resolve-EsiDevice` now
surfaces the **full ordered `<Sm>` set** (`SmList`: Label/StartAddress/ControlByte/DefaultSize/Enable)
and **full ordered `<Fmmu>` set** (`FmmuList`: Role/SmStart/Direction, each FMMU pre-resolved to its
target SM's start address) plus a `HasMailbox` flag, so the encoders iterate the device's real
topology instead of a baked recipe.

**The derived ESI→blob rule (reverse-engineered against the import→export oracle).** Validated
byte-for-byte against TwinCAT's import-normalised export of `EL1008` (digital-in, 1 SM), `EL2008`
(digital-out, 1 SM), `EL3064`/`EL3104`/`EL3162` (analog-in, 4 SMs w/ CoE mailbox) — three distinct
SM topologies. The `<SyncMan>` blob is a **24-byte, process-SM-centric** frame (NOT one record per
ESI SM — a 1-SM digital and a 4-SM analog both produce 24 bytes):

- **Block A `[0..7]` — process SM descriptor** (process SM = Inputs for `*In`, Outputs for `*Out`):
  `StartAddress`(LE16, **from ESI** `<Sm StartAddress>`), `Length`(LE16), `ControlByte`(**from ESI**
  `<Sm ControlByte>`), `Status=0`, `Enable`, `Type=0`.
- **Block B `[8..15]` — SM-type byte + 7×0:** `4` for an input process SM, `3` for output
  (TwinCAT's EtherCAT SM-type enum, keyed on the ESI process-SM direction).
- **Block C `[16..23]` — TwinCAT trailer, direction-keyed:** input → `01 00 <StartAddr LE16> 00 01 00 00`;
  output → `00 00 <StartAddr LE16> <ControlByte> 09 00 00`. Every non-constant byte here is the ESI
  `StartAddress`/`ControlByte`; the rest is a direction-determined pattern.

The `<Fmmu>` blob is **one 16-byte record per ESI `<Fmmu>`**, in order, each mapped to its target SM's
`StartAddress` (resolved from the ESI `<Sm>` set): `LogStart`(LE32), `Length=0`, `LogStartBit=0`,
`LogStopBit=0`, `PhysStart`(LE16, **= target SM start from ESI**), `PhysStartBit=0`,
`Direction`(1 input / 2 output, **from the FMMU role**), `Active`(1 if target SM exists). Role→SM:
`Inputs`→Inputs SM, `Outputs`→Outputs SM, `MBoxState`→MBoxIn SM. Digital terminals declare a single
`<Fmmu>`; TwinCAT additionally emits one **inactive `MBoxState`** FMMU placeholder, which the encoder
**synthesises** (PhysStart=0, Active=0) so the record count matches.

**Irreducible TwinCAT-owned bytes (cannot come from the ESI; emitted as 0/derived-minimum, never as a
hardcoded template — and documented inline).**

1. **SyncMan Block A `Length` (`[2..3]`) and `Enable` (`[6]`).** TwinCAT recomputes the process-image
   size at activation from the mapped PDO variables. On import it leaves both **0 for a mailboxed
   (analog) terminal** (size not yet known) and fixes both to **1 for a mailbox-less (digital)
   terminal**. This is **not** the ESI `DefaultSize` (EL2008 declares no `DefaultSize` yet Length=1;
   EL3064 declares `DefaultSize=16` yet Length=0), so we key it on the ESI fact *"has CoE mailbox"*
   (presence of an `MBoxIn`/`MBoxOut` `<Sm>`) and emit exactly the value TwinCAT itself writes on
   import. Source of truth = the round-trip, not a literal array.
2. **SyncMan Block B SM-type byte (`3`/`4`) and Block C trailer flag bytes (`[16]`,`[17]`,`[21]`, and
   `[20]` for input).** A TwinCAT-internal serialization not present in the ESI; fully determined by
   the ESI process-SM direction (so derived per-device, not a fixed opaque blob).
3. **FMMU `LogStart` on the synthesised inactive MBoxState placeholder (`2` input / `1` output).** A
   TwinCAT logical-address counter seed, not in the ESI; keyed on the process-SM direction.

These are the *only* bytes not taken straight from an ESI field, and each is reproduced as a function
of an ESI-derived value (direction / has-mailbox), not as a baked record. **Zero hardcoded record
byte-arrays remain.**

**Validation.** All five test devices round-trip **byte-for-byte identical** SyncMan/Fmmu (and full
box `.xti` modulo the volatile `Box Id`/`ImageId`) to the pre-refactor output and to TwinCAT's live
import→export, through the one generic encoder pair. Unsupported classes (`AnaOut`/EL4xxx,
`Communication`/EL6652, …) still error clearly. Scratch boxes were created/exported/deleted under
`EK1200` (left at exactly 13 children); the solution was **not** saved.

---

## 2026-06-21 — `tc_tree action:create_rack` v1.1 — ANALOG input terminals (EL3xxx) — branch `improve/create-rack-analog`

**Feature.** Extends the ESI→`.xti` generator from digital-only to **analog input** terminals
(ESI `GroupType` `AnaIn`, EL3xxx). Validated against `EL3064` (4-ch, the calibration target) and
sanity-checked against `EL3104` (4-ch) and `EL3162` (2-ch, legacy byte-status layout). The digital
path is unchanged.

**ESI → `.xti` mapping added for analog.**
- **PDOs.** Only the **SM-assigned** `<TxPdo Sm="…">` PDOs are emitted (e.g. EL3064's four
  *AI Standard Channel* PDOs on SM3). The unassigned *AI Compact* PDOs (Value-only alternative the
  user does not get by default) are **skipped**. Each `<Pdo>` carries `Flags="#x0001"` and
  `SyncMan="<the ESI PDO's own Sm index>"` (vs digital's fixed `Flags="#x0011" SyncMan="0"`).
- **Entry data types.** `INT`→`INT` (16-bit value), `BIT2`/2-bit→`BIT2`, 1-bit→`BIT`, and the
  byte/word status fields used by older terminals (`USINT`/`BYTE`/`SINT`/`WORD`/`DWORD`,
  `UINT`/`DINT`/`UDINT`). **Padding gaps** (ESI `<Entry>` with `Index #x0`/no name) are preserved
  **in order** as typeless `<Entry Index="#x0000" Sub="#x00"><BitLen>N</BitLen></Entry>` so the
  16-bit analog status-word bit layout stays intact. An unmapped data type errors per-entry.
- **`<SyncMan>` (the key calibration).** Despite the analog ESI declaring **four** SyncManagers
  (MBoxOut/MBoxIn/Outputs/Inputs), the box-level `<SyncMan>` blob is the **same fixed 3-record
  (24-byte)** structure as digital — only the process-SM start/control differ. Record 0 = the
  **Inputs** SM (start + ESI control byte; Length=0 and Enable=0 because TwinCAT recomputes those),
  record 1 = `04 00…`, record 2 = `01 00 <start LE> 00 01 00 00` (same direction-fixed tail as a
  digital **input**).
- **`<Fmmu>`.** Two 16-byte records: record 0 = process/**Inputs** SM (physAddr = Inputs start,
  dir = input, active), record 1 = **mailbox-state** (physAddr = **MBoxIn** SM start, dir = input,
  active) — vs digital's single process FMMU + zero tail.

**How the SM/Fmmu were calibrated (no native reference was obtainable).** `CreateChild` with
`subType:9099` + ESI `createInfo` is rejected ("Invalid item sub type"), so a *native* TwinCAT
EL3064 `.xti` could **not** be produced for diffing. Instead the reference was obtained by the
**import→export loop**: a hand-built box was imported under `EK1200`, then **exported**, and
TwinCAT's *import-normalised* serialization was read back. A first guess (one 8-byte SM record per
ESI SM = 32 bytes) was **blanked** by TwinCAT on import — proving that guess wrong and revealing the
correct length is the fixed 24-byte/3-record blob. The digital-input recipe generalised to the
analog Inputs SM was then **kept verbatim** by TwinCAT (it only zeroes Length/Enable, which we now
emit as 0). So the analog SM/Fmmu encoding is **calibrated against TwinCAT's own normalised export**,
which is the authoritative reference here.

**Catalog-stub revision fix.** Auto-selecting the highest ESI revision could pick a thin
**placeholder Device block** from a master ESI file (e.g. `Beckhoff EtherCAT Terminals.xml`,
revision `#x270b0000`) whose PDOs have empty `Index`/`Name` and no real entries — yielding "no usable
PDOs". `Resolve-EsiDevice` now prefers the **highest revision that has real process PDOs**
(`Test-EsiDeviceHasRealPdos`), falling back to plain-highest only if none qualify. This is what makes
`EL3162` resolve to a usable revision without an explicit `revision`.

**Import → export → compare results (live, with cleanup).**
- **EL3064** (built by the production `create_rack` verb): imported non-hollow, `pdoCount:4`; all four
  `AI Standard Channel N^Value` leaves **resolve/link**. Exported SyncMan
  `801100002000000004000000000000000100801100010000` and Fmmu
  `0000000000000000801100010100000000000000000000008010000101000000` match the generator output
  byte-for-byte (this is the calibration reference).
- **EL3104**: `pdoCount:4`, channels 1–4 `Value` resolve; export SM/Fmmu **identical** to input.
- **EL3162**: `pdoCount:2`, `Channel 1/2 Value` resolve; TwinCAT preserved the `USINT`+`INT` entry
  types; export SM **identical** to input.
- Every scratch box used a `ZZ_*` name, was deleted, and the `EK1200` tree was left at exactly **13
  children**. The solution was **never saved**.

**What generalises vs. what still needs care.**
- Generalises cleanly: any EL3xxx **AnaIn** with a CoE mailbox and an Inputs SM whose process PDOs
  are SM-assigned — the SM (start 0x1180) / MBoxIn (0x1080) addresses and the 24-byte SM / 2-record
  Fmmu structure held across EL3064/EL3104/EL3162.
- **Not** covered / needs separate calibration: **analog OUTPUT** (`AnaOut`, EL4xxx) — its process SM
  is an *Outputs* SM with a different control byte and FMMU direction, and was **not** reverse-engineered
  here; it errors per-entry. IO-Link and modular terminals remain unsupported.
- A device whose **only** real PDOs live in a non-default alternative assignment, or whose status word
  uses an entry data type outside the supported set, will error per-entry (by design — no wrong box).

**Verification.** `node --check index.js` → OK. PowerShell `Parser::ParseFile` on the bridge → 0
errors. Digital regression: regenerated `EL1008`/`EL2008` `.xti` still byte-for-byte match their real
exports.

---

## 2026-06-21 — `tc_tree action:create_rack` — ESI-backed EtherCAT rack creator — branch `improve/create-rack`

**Feature.** A new `tc_tree` action `create_rack` that, given a parent path and an ordered list of
EtherCAT module type names, creates **functional** boxes by resolving each type's descriptor from the
stock Beckhoff ESI library, **generating a full `.xti`** (identity + PDOs + SyncMan/Fmmu) and
**importing** it. This is the working follow-up to the create-ghost guard below: it answers "how do
you actually add an EtherCAT box" that the ghost guard left open.

**Why import, not create.** Option 3 — `CreateChild` with `subType:9099` + an ESI `createInfo`
descriptor — was confirmed a **dead end** in live testing (rejected / ghost). And a *minimal* `.xti`
(identity only, no PDOs) imports but yields a **hollow** box (0 PDOs, unusable). Only a **full** `.xti`
carrying the complete PDO set + box-level `<SyncMan>`/`<Fmmu>` imports as a functional box. So the tool
**generates the full PDO set** and uses `ImportChild`.

**v1 scope (digital terminals only).** Supported: **EL1xxx digital-input** (ESI `GroupType` `DigIn`)
and **EL2xxx digital-output** (`DigOut`), one 1-bit `BOOL` channel per PDO. Anything else — analog
(`AnaIn`/`AnaOut`), IO-Link, mailbox/CoE devices, multi-bit or non-`BOOL` entries — is detected and
**rejected with a clear per-entry error** rather than emitting a wrong box. Analog / IO-Link / complex
devices are deferred to a **v2**. Highest ESI revision is chosen by default (override via `revision`).

**ESI → `.xti` mapping (the translator).**
- Identity: ESI `<Type ProductCode RevisionNo>` + Vendor `Id=2` → box `<EtherCAT VendorId="#x00000002"
  ProductCode RevisionNo Type=<long name> Desc=<type>>`; `SlaveType="1" PdiType="#x0104"` etc. fixed.
- PDOs: ESI `<TxPdo>` (inputs) / `<RxPdo>` (outputs) `<Index>` → `<Pdo Index= Flags="#x0011"
  SyncMan="0">`; outputs get `InOut="1"`. `<Entry><Index>` → `Index=`, `<SubIndex>` → `Sub="#x0N"`,
  `<DataType>BOOL</DataType>` + `<BitLen>1` → `<Type>BIT</Type>`; `<Name>` carried through.
- `<SyncMan>`: 8-byte SM records — record 0 from the ESI process `<Sm StartAddress ControlByte>`
  (Length=1, Enable=1), records 1–2 are the direction-fixed TwinCAT tail (different for in vs out).
- `<Fmmu>`: two 16-byte FMMU records — record 0 maps the process SM (physAddr = SM start, dir = 1 in /
  2 out, active = 1); record 1 is the fixed mailbox-state tail.

**Validation by diff (the correctness gate).** Before wiring the live tool, the generator was anchored
to TwinCAT's own output: real `EL1008` (digital input) and `EL2008` (digital output) boxes were
**exported** to reference `.xti`, the matching ESI device blocks read, and the generated `.xti` diffed
against the exports — ignoring instance noise (box `Id`, `<Name>`, `ImageId`/`ImageDatas`, `<Mappings>`,
whitespace, attribute order) but requiring the EtherCAT identity + full `<Pdo>`/`<Entry>` + `<SyncMan>`/
`<Fmmu>` to match. Result: **byte-for-byte identical** functional content (incl. the SyncMan/Fmmu hex
blobs) for both EL1008 and EL2008.

**Live smoke test (with cleanup).** Created a 2-module scratch rack (`EL1008` + `EL2008`) under the
existing `EK1200` coupler with `ZZ_*` junk names, exported both back, confirmed **8 PDOs / 8 entries
each (not hollow)** and that TwinCAT round-tripped the generated SyncMan/Fmmu unchanged, then **deleted
both** — tree restored to exactly as found (13 children). The solution was **not saved** at any point.
Also confirmed the error path: `EL3064` (analog `AnaIn`) and a bogus type both fail per-entry with clear
errors, continue-on-error, no boxes emitted.

**Implementation.**
- Bridge (`te1000-bridge.ps1`): helpers `ConvertFrom-EsiHex`, `Resolve-EsiDevice(typeName, revision?)`
  (finds the device across the ESI files, highest revision by default, errors clearly on
  not-found/ambiguous/unsupported-class), `Get-DigitalSyncManBlob` / `Get-DigitalFmmuBlob`, and
  `Build-BoxXti(esiDevice, boxName)`; plus a new verb `twincat_create_rack` (sequential,
  continue-on-error, temp-file write → `ImportChild` → validate → cleanup, optional `save`).
- `index.js`: `create_rack` added to the `tc_tree` action enum; `modules:[{type,revision?,name?}]`
  input; `need(p,["path","modules"])`; bridges to `twincat_create_rack`; `tc_tree` description updated.

**v2 ideas (deferred).** Analog terminals (multi-byte PDOs, status/control words), IO-Link masters,
and mailbox/CoE devices (multiple SyncManagers, CoE init); per-device SyncMan/Fmmu derivation for
terminals whose process SM differs from the simple digital profile; optional auto-link of channels to
GVL variables after import.

---

## 2026-06-21 — `tc_tree` create ghost guard (validate the created child, fail loudly) — branch `improve/test-fixes`

**Bug (found in live testing).** `tc_tree action:create` on the EtherCAT device with
`subType:9099` returned **SUCCESS** but actually inserted a malformed, **blank-named "ghost"
child under the wrong parent** (under the EK1200 coupler, not the requested device), ignoring the
requested name. Root cause: `ITcSmTreeItem.CreateChild(name, subType, before, createInfo)` can
silently produce an unaddressable child when the `subType`/`createInfo` is not valid for the
parent (an EtherCAT box needs an ESI-based `createInfo`, not a bare `subType:9099`). The bridge
verb `twincat_create_child` (and the batch `twincat_create_children`) returned
`Convert-TreeItem $child` **without validating** the result, so the caller was told it succeeded
while a blank-named node was left in the tree.

**Fix (post-create validation + loud failure + best-effort cleanup).** Added a shared
`Assert-WellFormedChild` helper (factored alongside `Rename-TreeItem` / `Set-TreeItemXml`) that,
right after `CreateChild`, reads the child's `Name` / `PathName` defensively via `Get-SafeValue`
and treats the create as **failed** if: the child is null, the name is null/empty/whitespace, the
returned name ≠ the requested name, or the child's path ≠ `"<parent>^<name>"` (it landed
unexpectedly). On failure it attempts best-effort cleanup (`$parent.DeleteChild($actualName)`,
skipped when the name is blank since a blank name can't be addressed safely) and then **throws** a
descriptive error (actual vs. requested name, path, subType, parent, and the hint that EtherCAT
boxes typically require a proper `createInfo`).

- `twincat_create_child` calls the helper before returning — a ghost now fails the tool call.
- `twincat_create_children` calls it per entry inside the existing `try`; a malformed create
  becomes that entry's `{ parent, name, ok:false, error }` (best-effort cleanup applied) and the
  loop continues — a ghost is **never** rolled up as `ok:true`. Roll-up shape unchanged.

`index.js`: no schema change; updated the `tc_tree` description to note that create now validates
the result and errors clearly on a malformed/ghost result, and that EtherCAT boxes typically need
an ESI-based `createInfo` (bare `subType:9099` produces a ghost).

**Step-1 read-only finding.** Inspecting existing terminals (`get_xml` on `R01.Main.N07
(EL1008)`) shows a real box reports the generic `ItemSubType` **9099** with its true identity in
an `<EtherCAT><Slave><Info>` descriptor (VendorId / ProductCode / RevisionNo + `EsiFile`). So
`9099` alone is insufficient — the ESI descriptor must come through `createInfo`. The exact
correct `createInfo` payload for adding a box **could not be determined from read-only inspection
alone** and needs live confirmation (scaffold a box once in the GUI and capture the descriptor)
before it can be documented as a reusable recipe — not guessed here.

**Not yet live-verified.** Static checks only (`node --check`, PowerShell `ParseFile`). The MCP
server could not be reconnected during this change and creating anything live would spawn more
ghosts, so the validation/cleanup path is **implemented + reasoned but pending live verification**
after server reconnect.

---

## 2026-06-21 — Three test-driven fixes (download guard, optional `tc_tree` path, `open_solution` discard) — branch `improve/test-fixes`

Found during live testing of the v2 tool surface; all three are small and mechanical.

- **`plc_download` confirm guard.** It was the one cell-impacting deploy with **no** confirm
  token (activate / restart / xae_command / plc logout all already had one), so a bare call
  would push a boot project to the live target. Added `PLC_DOWNLOAD_CONFIRMATION =
  "ALLOW_PLC_DOWNLOAD"` and a guard at the very top of the handler (before the auto-logout
  status check and the bridge call): without `confirm="ALLOW_PLC_DOWNLOAD"` it throws and
  deploys nothing. All other behavior (method / autostart / autoLogout) is unchanged.

- **`tc_tree` top-level `path` made optional.** `path: z.string()` was *required*, so the
  batch actions (`exists_batch` / `get_batch` / `set_xml_batch` / `create_batch` /
  `delete_batch` / `rename_batch`) — which carry their targets in `paths` / `items` / `creates`
  / `deletes` / `renames` — rejected the call until a throwaway `path` was supplied. Changed to
  `z.string().optional()` and added an explicit `need(p, ["path"], action)` to each
  path-requiring case (`get`, `children`, `exists`, `get_xml`, `set_xml`, `rename`, `create`,
  `delete`, `import`, `export`, `focus`) so those still validate. The batch cases keep only
  their existing field checks; `rename_batch` tolerates an absent `path` (its `basePath` is just
  an optional base for relative names — entries with absolute `path` work without it).

- **`xae open_solution` discard-on-close option.** The bridge's `xae_open_solution` closed the
  current solution with the hardcoded `$dte.Solution.Close($true)` — **save-first** — which
  persists unwanted in-memory edits when you only meant to reopen/discard. Added an optional
  `discardChanges` (index.js schema + payload, read in the bridge via the
  `PSObject.Properties.Name -contains` idiom, default `$false`) and changed the close to
  `$dte.Solution.Close(-not $discardChanges)`: default stays save-first (current behavior),
  `discardChanges:true` → `Close($false)` = discard. Only meaningful with `closeExisting:true`.

Static checks only (`node --check`, PowerShell `ParseFile`) — the server could not be reloaded
to exercise the tools live during this change.

---

## 2026-06-20 — `delete_batch` guarded (dryRun/confirm) + opt-in `save:true` on mutating batch ops — branch `improve/batch-ops`

Two safety/convenience improvements to the batch surface:

- **`delete_batch` guard.** It was the only destructive op with no confirm gate (every
  other — activate, restart, xae_command, plc logout — already required a token). A bare
  `delete_batch` now throws and must be re-run with either `dryRun:true` (preview only —
  resolves each parent and reports whether the named child exists, returning
  `{ mode:"dryRun", count, present, missing, results:[{ parent, name, exists }] }`, never
  deleting) or `confirm:"ALLOW_TWINCAT_DELETE"` (performs the deletes). The single `delete`
  action is left unguarded (scope was the batch). Bridge verb `twincat_delete_children`
  honors `dryRun` (no-op preview path) ahead of the existing real-delete path.

- **Opt-in `save:true` on mutating batch ops.** After a bulk mutation the caller previously
  had to make a separate `xae save_all` round-trip. The mutating batch verbs —
  `rename_batch`, `set_xml_batch`, `create_batch`, `delete_batch` (real path), `link_batch`,
  `unlink_batch` — now take an optional `save:true` that saves the solution **once after the
  batch** via a small `Save-Solution($Dte)` helper (factored from the existing `xae_save_all`
  mechanism — `$dte.ExecuteCommand('File.SaveAll')` — so there's one save path, not a new one).
  The roll-up gains `saved:true|false` only when save was requested; a save failure is caught
  and reported as `saved:false` without failing the already-completed batch.

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
