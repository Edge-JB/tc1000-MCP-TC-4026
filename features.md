# TE1000 Automation Interface — Feature Surface

A full sweep of what the **TwinCAT 3 Automation Interface (TE1000)** COM/.NET API
exposes, distilled from the Beckhoff infosys documentation
(`https://infosys.beckhoff.com/.../tc3_automationinterface/`, manual v1.6.2,
2026-04-01). It is the map of *what is automatable* — the menu from which this
MCP server's tools are (and could be) carved.

Every infosys topic is cited by its content-URL id; the full URL is
`https://infosys.beckhoff.com/content/1033/tc3_automationinterface/<id>.html`.

> **How to read this:** Sections 1–3 describe the architecture that everything
> else rests on. Sections 4–15 are the per-domain feature inventory. Section 16
> is the consolidated API reference (interfaces / methods / enums / sub-type
> constants / tree shortcuts / error codes). Section 17 maps the surface onto
> what this MCP already covers and what remains.

---

## 1. What the Automation Interface is

A **COM API** for automating TwinCAT XAE *engineering* (offline + activation),
not runtime data exchange (that is ADS — see `tcads`). It layers TwinCAT's
`TcatSysManagerLib` on top of the Visual Studio automation object model
(`EnvDTE.DTE`). It is reachable from any COM-capable language:

- **C#/.NET** (primary in the docs), **C++** (`#import` + `CoInitialize`),
- **Windows PowerShell** (`New-Object -ComObject …`) — the route this MCP uses,
- **IronPython**, and the obsolete **VBScript**.

Goal: generate/edit TwinCAT configurations programmatically — fewer manual
engineering steps, less human error, reproducible builds.

Two entry models, used together:

1. **VS DTE model** — owns *project/solution lifecycle* (create/open/save the
   `.sln`, build, error list, windows, source control).
2. **TwinCAT model** — `ITcSysManager` (the project cast to it) + `ITcSmTreeItem`
   (every node in the config tree). Owns *everything inside* the TwinCAT project.

---

## 2. The three pillars

### 2.1 `EnvDTE.DTE` — the IDE
Instantiated by ProgID (§16.4). Used to open/create solutions, add TwinCAT
projects from templates, build selected projects, read the Error List, manage
editor windows, drive source control, and reach `TcAutomationSettings`.

### 2.2 `ITcSysManager` — the configuration
The TwinCAT project object cast to `ITcSysManager` (+ versioned extensions
`ITcSysManager2/3/7/9/14`). Owns: activate config, start/restart runtime, set
target NetId, look up tree items, link/unlink variables, mapping
import/export/clear, target platform, archives, project variants. See §16.1.

> In VS-hosted (non-Compatibility) mode, `NewConfiguration` /
> `OpenConfiguration` / `SaveConfiguration` **error out** — VS owns project
> lifecycle; use DTE solution methods instead.

### 2.3 `ITcSmTreeItem` — every tree node
Each node in the XAE tree (devices, boxes, terminals, PLC objects, tasks, axes,
modules…) is an `ITcSmTreeItem` (+ extensions `2/5/6/9`). It is the universal
unit of navigation and editing. See §16.2.

### 2.4 The XML escape hatch — `ProduceXml` / `ConsumeXml`
The single most important mechanism. Any node parameter not exposed as a typed
property is reached by:

1. `ProduceXml()` → the node's full parameters as an XML string,
2. edit the XML (only the changed elements are needed on the way back),
3. `ConsumeXml(xml)` → applies it; unknown params are silently ignored.

This mirrors the IDE's **Export/Import XML Description…** menu. Some XML elements
**execute a function** rather than set a value (e.g. `<ReScan>1</ReScan>`, a
device scan, PLC online commands, license activation, library scan, TMC codegen,
publish modules). Recommended workflow: export → edit → test-import in the IDE →
then bake into code. Topic `242724875`; methods `242832779` / `242834315`.

---

## 3. Navigation model

- **Tree paths** use a circumflex `^` (or tab) separator, e.g.
  `TIID^Device 1 (EtherCAT)^Term 1 (EK1100)`.
- **Lookup:** `ITcSysManager.LookupTreeItem(path)` (absolute),
  `ITcSysManager3.LookupTreeItemById(type, id)`,
  `ITcSmTreeItem.LookupChild(relpath)`.
- **Iterate:** `_NewEnum` (all subnodes, `foreach`), `ChildCount` + `Child(n)`
  (direct children), `VarCount(x)` + `Var(x,n)` (process variables; `x`=0 inputs,
  `x`=1 outputs).
- **Language-neutral root shortcuts** (full set in §16.3): `TIID` (I/O devices),
  `TINC` (NC), `TIPC` (PLC), `TIRT` (tasks), `TIRR` (routes), `TIRC` (real-time),
  `TIXC` (C++), `TISC` (safety), `TIAN` (analytics).

---

## 4. Visual Studio / IDE automation

Chapter root `2753035787`.

| Capability | Topic | API |
|---|---|---|
| Pick IDE version by ProgID | `242746251` | `Type.GetTypeFromProgID` + `Activator.CreateInstance`; `New-Object -ComObject` |
| Attach to a running IDE (ROT) | `242747787` | `EnvDTE.DTE` via Running Object Table; `CreateBindCtx` (ole32) |
| **Silent mode** (suppress dialogs) | `2489025803` | `dte.GetObject("TcAutomationSettings").SilentMode = true` (TC3.1 ≥4020.0) |
| Open project from target device | `2488994571` | `dte.ExecuteCommand("File.OpenProjectFromTarget", "<route> <dir> <name>")` |
| Build selected projects only | `1520210443` | `SolutionBuild2.BuildProject("Release\|TwinCAT RT (x64)", proj, true)` |
| Set target **platform** (x86/x64) | `650882187` | `ITcSysManager7` → `ITcConfigManager.ActiveTargetPlatform`; `SolutionContexts.ShouldBuild` |
| Manage editor windows/tabs | `242744715` | `dte.ActiveWindow`, `Window.Close()`, `ItemOperations.OpenFile()` |
| Read the Error List | `242743179` | `dte.ToolWindows.ErrorList.ErrorItems` → `Description/FileName/Line/Column/Project` |
| TFS source control | `721118091` | `Microsoft.TeamFoundation.*`: workspaces, mappings, Get, PendEdit, CheckIn, Undo |
| COM message filter (retry rejected calls) | `242727947` | `IOleMessageFilter` (`HandleIncomingCall`/`MessagePending`/`RetryRejectedCall`); STA-only |
| Switch XAE engineering version | `2507904267` | `dte.GetObject(...)` → `ITcRemoteManager.Version = "3.1.4024.42"` |

---

## 5. System / configuration lifecycle

Chapter root `2753033867`. Core interface `ITcSysManager` (§16.1).

- **Create / open / save / activate** a configuration (`242721803`, `242929035`):
  `NewConfiguration`/`OpenConfiguration`/`SaveConfiguration` (Compatibility-mode
  only), `ActivateConfiguration` ("Save to Registry"), `StartRestartTwinCAT`,
  `IsTwinCATStarted`.
- **Target system** (`242741643`): `SetTargetNetId` / `GetTargetNetId`,
  `GetLastErrorMessages`.
- **Variable mappings** (`831837579`): `LinkVariables`, `UnlinkVariables`,
  `ProduceMappingInfo` (export all as XML), `ConsumeMappingInfo` (re-import),
  `ClearMappingInfo` (delete all).
- **Tasks** (`242740107`): `CreateChild` on `TIRT` — SubType `0` = task *with*
  image, `1` = *without*; add process-image vars via `CreateChild` with the data
  type as `vInfo` and start address as SubType (`-1` = append). Cycle time /
  priority are set via `ConsumeXml` on the task node (no typed property).
- **CPU cores** (`242938251`): enable RT cores, set `LoadLimit` / `BaseTime` /
  latency watchdog, bind tasks to cores via XML; enum `CpuAffinity`
  (`CPU1`…`CPU8`, `MaskQuad`, `MaskAll`). Uses `ITcSysManager3`.
- **Boot settings** (`2489005451`): XML `System/BootSettings` — `AutoRun`,
  `AutoLogon`, `LogonUserName`, `LogonPassword`, `BootFileEncryptionType`.
- **Independent project file** (`1520305803`): `ITcSmTreeItem6.SaveInOwnFile`
  (store a node's settings in its own file — cleaner source control).
- **Templates** (`717817483`): reuse at three levels — whole config
  (`.sln`/`.tszip` via DTE `AddFromTemplate`/`Open`), I/O & motion subtrees
  (`.xti` via `ImportChild`/`ExportChild`), PLC projects/POUs (via `CreateChild`,
  single or batched string arrays).
- **Enable / disable** any node (`242933643`): `ITcSmTreeItem.Disabled`
  (`SMDS_NOT_DISABLED` / `SMDS_DISABLED` / `SMDS_PARENT_DISABLED`).

---

## 6. ADS (route configuration)

Chapter root `2753090827`. Driven through `ConsumeXml`/`ProduceXml` on the
Routes node (`TIRR`), **not** raw ADS.

- **Create routes** (`242939787`): XML `<AddRoute>` (`RemoteName`,
  `RemoteNetId`, `RemoteIpAddr`/`RemoteHostName`, `UserName`, `Password`,
  `NoEncryption`, `LocalName`) and `<AddProjectRoute>` (`Name`, `NetId`,
  `IpAddr`/`HostName`).
- **Broadcast search** (`242941323`): general (`BroadcastSearch=true`, parse
  `AmsNetId`/`Name`) and direct-by-host/IP (TC3.1 ≥4020.10 — returns
  `Name`/`NetId`/`IpAddr`/`Version`/`OS`).

---

## 7. PLC (largest domain)

Chapter root `2753030027`. Three sections: projects (`242730891`), libraries &
placeholders (`242733963`), POUs (`242732427`).

### 7.1 Projects
- **Create** from template via `CreateChild` on `TIPC` (template *name* for stock
  templates: "Standard PLC Template", "Empty PLC Template").
- **Open** existing `.plcproj`/`.tpzip` with project SubType: `0` copy / `1` move
  / `2` use-in-place. PLC project = nested project (SubType `56`, source) +
  project instance (`get_Child(1)`, variables). Reach via `ITcProjectRoot.NestedProject`.
- **Build / validate**: `ITcPlcIECProject2.CheckAllObjects()` → bool.
- **Boot project** (`242855691`): `ITcPlcProject.GenerateBootProject(bool)`,
  `BootProjectAutostart`, `BootProjectEncryption`, `TmcFileCopy`.
- **Online control** (build ≥4010, via `ConsumeXml`): `LoginCmd`, `LogoutCmd`,
  `StartCmd`, `StopCmd`, `ResetOriginCmd`, `ResetColdCmd` (login before reset).
- **Archive**: solution `.tszip` via `ITcSysManager9.SaveAsArchive` (reload via
  DTE `AddFromTemplate`); PLC project `.tpzip` via `ExportChild` (reload via
  `CreateChild`).
- **Task assignment** (`242921611`): `ITcPlcTaskReference.LinkedTask` = task path.
- **PLCopen XML** (`242870539`): `PlcOpenExport(file, "sel1;sel2")`,
  `PlcOpenImport(file, options, selection, bFolderStructure)` (enum
  `PlcImportOptions`: NONE/RENAME/REPLACE/SKIP = 0/1/2/3),
  `SaveAsLibrary(path, bInstall)`.

### 7.2 Libraries & placeholders
Entry: lookup `…^References`, cast to `ITcPlcLibraryManager` (`242879627`).

- `AddLibrary(name, version="", company="")`, `AddPlaceholder(name, defLib,
  defVer="", defDist="")`, `RemoveReference(...)`.
- `SetEffectiveResolution(placeholder, lib, ver="", dist="")`,
  `FreezePlaceholder()` (no-arg = all, name = one).
- `ScanLibraries()` → `ITcPlcLibraries`.
- Repositories: `InsertRepository(name, folder, index)`,
  `InstallLibrary(repo, libPath, bOverwrite)`,
  `UninstallLibrary(repo, lib, ver="", dist="")`, `MoveRepository(name, index)`,
  `RemoveRepository(name)`.
- Object model: `References` (`ITcPlcReferences`) → `ITcPlcLibRef` (`Name`) →
  `ITcPlcLibrary` / `ITcPlcPlaceholderRef` (`DisplayName`/`Distributor`/`Name`/
  `Version`); `Repositories` (`ITcPlcLibRepositories`) → `ITcPlcLibRepository`
  (`Folder`/`Name`). `*` version = latest installed.

### 7.3 POUs / DUTs / GVLs
- **Create** via `CreateChild` with PLC sub-types (§16.5): Program 602, Function
  603, Function Block 604, Enum 605, Struct 606, Union 607, Action 608, Method
  609, Property 611, GVL 615, Transition 616, Interface 618, Visualization 619,
  Alias 623, Parameter List 629, UML 631, plus accessors; SubType `58` = import a
  POU template (`vInfo` = file path or array of paths). `vInfo` for 604/602 = IEC
  language int; for 603 = `[language, returnType]`.
- **Edit**: `ITcPlcPou.DocumentXml`; `ITcPlcDeclaration.DeclarationText`;
  `ITcPlcImplementation.ImplementationText`/`ImplementationXml`/`Language`
  (enum `IECLANGUAGETYPES`: NONE/ST/IL/SFC/FBD/CFC/LD = 0–6).
- **PLCopen XML** import/export for objects via the `ITcPlcIECProject` methods
  above.

---

## 8. I/O & fieldbus

Chapter root `2753031947`. Build topologies offline, then scan/activate.

- **Scan** (`242936715`): `SetTargetNetId` → `ProduceXml` on `TIID` (device
  scan) → parse → `CreateChild` with real address → `ConsumeXml`; box scan per
  device. Offline→online flow at `242741643`.
- **EtherCAT** (`242737035`): master SubType `111`, slave `130` (group also 94,
  106, 112, 144); boxes/couplers/terminals via generic `9099` with product
  revision in `vInfo` (e.g. `CreateChild("EK1100", 9099, "", "EK1100-0000-0017")`);
  serial terminals use `9101`/`9103`. HotConnect groups, SyncUnits, Previous-Port,
  DC/CoE/PDO/sync-managers — all via `ConsumeXml`/`ProduceXml` XML. AX5000 drives
  (`3297483147`) parameterized via SoE/PDO XML.
- **Linking** (`831837579`, `242764427`/`242765963`):
  `LinkVariables(v1, v2, offs1=0, offs2=0, size=0)` — offsets+size enable partial
  / multi-link; `UnlinkVariables(v1, v2)` — empty `v2` removes all of `v1`.
- **Other fieldbuses** (SubType-driven `CreateChild` + resource claiming +
  `ConsumeXml`):
  - Network variables / EAP (`242738571`): device 112, Publisher box 9051,
    Subscriber box 9052, vars 0/35/36.
  - PROFINET (`1041677067`): controllers 113/119/126/140, devices 115/118/142/143;
    GSD-driven boxes/modules; `BoxFlags`.
  - PROFIBUS (`1095398667`): master 86, slave 97; `ResourcesCount` +
    `ClaimResources`; station address via `ConsumeXml`.
  - CANopen (`1095735435`): master 87, slave 98; DBC import (≥4018) via XML flags.
  - DeviceNet (`1520292363`): masters 41/73/88, slaves 62/74/99, monitor 59.
- **Import/export `.xti`**: `ImportChild` / `ExportChild`.

---

## 9. TcCOM modules

Chapter root `2753096587`; how-to `718009739`.

- Locate `TIRC^TcCOM Objects`; add a module via `CreateChild` — SubType `0` by
  GUID/ClassID, SubType `1` by registered name.
- Iterate instances via `ITcSysManager3.GetModuleManager()` → `ITcModuleManager3`
  (read `ModuleTypeName`, `ModuleInstanceName`, `ClassID`, `oid`, `ObjectId`).
- Assign to a task: `ITcModuleInstance2.SetModuleContext(contextId, taskObjectId)`.
- Enable symbols: `ProduceXml`/`ConsumeXml` to set `CreateSymbol` (parameters) /
  `CreateSymbols` (data areas) via XPath on `Parameters`/`DataAreas`.
- Link module I/O via `LinkVariables`.
- Module registration: copy to `%TWINCAT3.XDIR%\CustomConfig\Modules\` or edit
  `TcModuleFolders.xml`; module def = `.TMC`. (Runtime INIT/PREOP/SAFEOP/OP
  transitions are **not** an AI feature — config-time only.)

---

## 10. TwinCAT C++

Chapter root `2753098507`; how-to `2135353611`.

- Create project: `CreateChild` on `TIXC` from a template (`TwinCAT C++ Project
  Wizard`, `TcVersionedDriverWizard`, `TcModuleCyclicCallerWizard`).
- Create module: `CreateChild` on the project from a class template
  (`TwinCAT Class Wizard`).
- Open existing: `CreateChild` with `.vcxproj`/`.tczip` path, SubType `0` copy /
  `1` move / `2` use-in-place (pass `""` as name — C++ projects can't be renamed).
- `ConsumeXml` commands: `<StartTmcCodeGenerator><Active>true` (regen code from
  `.tmc`), `<PublishModules><Active>true` (build all platforms + export).
- Project props via `ConsumeXml`: `BootProjectEncryption` (None/Target),
  `TargetArchiveSettings`/`FileArchiveSettings` → `SaveProjectSources`.
- Build a single project: VS `SolutionBuild2.BuildProject` (`1520210443`).

---

## 11. Measurement / Scope / Analytics

Chapter root `2753037707`.

### 11.1 Measurement / Scope (`498477707`, TC3.1 ≥4013)
- Create a Scope project via DTE `dte.Solution.AddFromTemplate(template, dest,
  name)`; get `EnvDTE.Project`/`ProjectItem.Object` cast to **`IMeasurementScope`**.
- Build the chart→axis→channel hierarchy with repeated `CreateChild(out …)`;
  rename via `ChangeName(string)`; record via `StartRecord()` / `StopRecord()`.

> ⚠️ **Unverified:** the data-export methods (`SaveSVD`, `ExportCSV`,
> `ExportBinary`, `ExportTDMS`, `ExportDAT`), Scope-Server methods (`ShowControl`,
> `CloseControl`, `Disconnect`, `LookUpChild`) and enums (`ChartType`,
> `AcquisitionType`, `AxisGroupMember`, `MarkerType`) surfaced from a page
> summary but did **not** survive a literal re-read of `498477707`. Confirm on
> infosys before relying on them.

### 11.2 Analytics project (`9267262731`)
Built on the Measurement project type. Interfaces
`IMeasurementAnalyticsProject` / `IMeasurementAnalyticsNetwork` /
`IMeasurementAnalyticsFunction` (create networks/functions, wire inputs,
start/stop analysis). Project creation via `AddFromTemplate` is verified; the
network/function method names are **unverified** (same caveat as 11.1).

### 11.3 Analytics Logger & Stream Helper (`12562699019`)
System-manager route on `TIAN`:
- Create/delete DataLogger (`12562942987`) and StreamHelper (`12563004555`) via
  `CreateChild`/`DeleteChild` (StreamHelper delete name gets `_Obj1 (StreamHelper)`
  appended).
- Parameterize logger (`12563013387`), stream (`12563036299`), and select logged
  symbols (`12563783307`) via `ProduceXml`/`ConsumeXml` `SetParameter` elements
  (e.g. `ANALYTICS_FORMAT_FILE`).

---

## 12. Motion (NC / PTP / CNC)

Chapter root `2753092747`; how-to `242735499`.

- Create NC task: `CreateChild("NC-Task", 1)` on `TINC`; create axes:
  `CreateChild("Axis 1", 1)` on `TINC^NC-Task^Axes`.
- Parameterize axis / encoder / drive / controller via `ProduceXml`/`ConsumeXml`
  (no dedicated typed methods; ItemTypes `NCAXIS 22`, `NCENCODER 23`,
  `NCDRIVE 24`, `NCCONTROLLER 25`, `NCGROUP 26` — §16.6).
- Import/export axis templates (`.xti`) via `ImportChild` / `ExportChild`.
- CNC present as ItemTypes (`CNCPRJ 10`, `ISGDEF 400`, `ISGCHANNEL 401`,
  `ISGAGROUP 402`, `ISGAXIS 403`) but has no dedicated how-to leaf — XML route.

---

## 13. Licensing

Chapter root `4554515339` (TC3.1 ≥4022.4).

- Configure license dongle hardware (`4554517771`): the hardware (e.g. EL6070)
  must exist in I/O first; `LookupTreeItem("TIRC^License")` → `ProduceXml` to
  discover devices → `CreateChild("Name", 0, null, "Term 2 (EL6070)")`.
- Activate a license response file (`4554565515`): `ConsumeXml` on the License
  node with `<ActivateResponseFile><Path>…</Path><OemGuid>…</OemGuid>`.

---

## 14. Variant management

Chapter root `14796589835`; how-to `8204600715` (needs `iTcSysManager14`,
`TCatSysManagerLib` ≥3.3.0.0).

- Define variants/groups: `sysManager.ProjectVariantConfig` = `<ProjectVariants>`
  XML (`<Group>`/`<Member>`/`<Variant>`).
- Select active: `sysManager.CurrentProjectVariant = "Variant3"` (or `"[Group1]"`).
- Per-item variant disabling: `ITcSmTreeItem9.PvDisable = true` then
  `Disabled = DISABLED_STATE.SMDS_DISABLED`.

---

## 15. Safety (import-only)

Chapter root `2753094667`; how-to `2633259147`.

- **Import an existing** safety project: `LookupTreeItem("TISC")` →
  `CreateChild("Name", subType, null, path)` from `.splcproj` or `.tfzip`;
  SubType `0` copy / `1` move / `2` use-in-place (name `""`).
- **Documented support is import/open only.** There is **no** AI for authoring
  safety logic, connections, aliases, group parameterization, export, download,
  or verification — consistent with this project's policy that nothing in the
  toolchain may write toward the safety system.

---

## 16. API reference

API-reference root `242750731`.

### 16.1 `ITcSysManager` family (`242753675`)
| Interface | Members |
|---|---|
| `ITcSysManager` | `NewConfiguration`, `OpenConfiguration`, `SaveConfiguration` *(Compat-mode only)*, `ActivateConfiguration`, `LookupTreeItem`, `StartRestartTwinCAT`, `IsTwinCATStarted`, `LinkVariables`, `UnlinkVariables` |
| `ITcSysManager2` | `SetTargetNetId`, `GetTargetNetId`, `GetLastErrorMessages`, `ConsumeMappingInfo` |
| `ITcSysManager3` | `LookupTreeItemById`, `ProduceMappingInfo`, `ClearMappingInfo`, `GetModuleManager` |
| `ITcSysManager7` | config manager → `ActiveTargetPlatform` |
| `ITcSysManager9` | `SaveAsArchive` |
| `ITcSysManager14` | `ProjectVariantConfig`, `CurrentProjectVariant` |

Key signatures: `LinkVariables(BSTR v1, BSTR v2, long offs1, long offs2, long
size)`; `UnlinkVariables(BSTR v1, BSTR v2)`; `LookupTreeItem(BSTR path,
ITcSmTreeItem** out)`; `SetTargetNetId(BSTR netId)`.

### 16.2 `ITcSmTreeItem` family (`242779659`)
**Properties:** `Name` (RW), `Comment` (RW), `Disabled` (RW), `PathName` (R),
`ItemType` (R enum), `ItemSubType` (RW), `Parent` (R), `ChildCount` (R),
`Child(n)` (R), `VarCount(x)` (R), `Var(x,n)` (R), `_NewEnum` (R).
**Methods (`ITcSmTreeItem`):** `CreateChild`, `DeleteChild`, `ImportChild`,
`ExportChild`, `ProduceXml`, `ConsumeXml`, `GetLastXmlError`, `LookupChild`.
**`ITcSmTreeItem2`:** `ChangeChildSubType`, `ResourcesCount`, `ClaimResources`.
**`ITcSmTreeItem5`:** `ClaimResources`, `ResourcesCount`/`ResourceCount` (fieldbus).
**`ITcSmTreeItem6`:** `SaveInOwnFile`.
**`ITcSmTreeItem9`:** `PvDisable`, `Disabled` (variant management).

Key signatures:
- `CreateChild(BSTR name, long nSubType, BSTR before, VARIANT vInfo,
  ITcSmTreeItem** out)`
- `ImportChild(BSTR file, BSTR before, VARIANT_BOOL bReconnect, BSTR name,
  ITcSmTreeItem** out)` — empty file = clipboard; `bReconnect` re-links by name
- `ExportChild(BSTR name, BSTR file)` — empty file = clipboard
- `ProduceXml(VARIANT_BOOL bRecursive, BSTR* out)`
- `ConsumeXml(BSTR xml)`
- `LookupChild(BSTR relpath, ITcSmTreeItem** out)`

### 16.3 Tree-path shortcuts (`242772107`)
`TIIC` I/O config · `TIID` I/O devices · `TIRC` real-time config · `TIRR` routes
· `TIRT` additional tasks · `TIRS` real-time settings · `TIPC` PLC · `TINC` NC ·
`TICC` CNC · `TIAC` CAM · `TIXC` C++ · `TISC` safety · `TIAN` analytics.

### 16.4 Visual Studio ProgIDs (`242746251`)
`VisualStudio.DTE.15.0` (VS2017) · `.16.0` (VS2019) · `.17.0` (VS2022) ·
`TcXaeShell.DTE.15.0` · `TcXaeShell.DTE.17.0` (64-bit) ·
`VisualStudio.DTE.10.0` (legacy). *(This MCP defaults to `TcXaeShell.DTE.17.0`,
overridable via `TE1000_PROGID`.)*

### 16.5 PLC object `CreateChild` sub-types (`242732427`)
602 Program · 603 Function · 604 Function Block · 605 Enum · 606 Struct ·
607 Union · 608 Action · 609 Method · 610 Interface Method · 611 Property ·
612 Interface Property · 613/614 Get/Set accessor · 615 GVL · 616 Transition ·
618 Interface · 619 Visualization · 623 Alias · 629 Parameter List ·
631 UML Class Diagram · 654/655 Interface Get/Set accessor · **58 POU template
import** (`vInfo` = path or path[]). PLC project copy/move/use-in-place = 0/1/2;
nested project = 56.

### 16.6 `ItemType` enum (`242781195`, selected)
General: 1 TASK · 2 DEVICE · 3 IMAGE · 4 MAPPING · 5 BOX · 6 TERM · 7 VAR ·
8 VARGRP · 9 IECPRJ. NC: 19 NCDEF · 20 NCAXISES · 21 NCCHANNEL · 22 NCAXIS ·
23 NCENCODER · 24 NCDRIVE · 25 NCCONTROLLER · 26 NCGROUP · 27 NCINTERPRETER ·
40–42 NCTABLE*. CNC: 10 CNCPRJ · 400–403 ISG*. CAM: 200–205 CAM*. PLC:
600 PLCAPP · 621 PLCTASK · 602–655 POU/DUT. RTS 500–505. (All `TREEITEMTYPE_*`.)

### 16.7 I/O `ItemSubType` (`242784139`)
Identifies the exact device/box/terminal in `<ItemSubType>`. Category tables:
Devices `242788619` · Boxes `242791563` · E-Bus EL/EP `242785675` (generic
**9099**; serial 9101/9103) · K-Bus KL1xxx–KL9xxx `242795531`–`242816011`.
EtherCAT identity (VendorId/ProductCode/RevisionNo) is passed via `vInfo` /
embedded in the box `.xti`.

### 16.8 Other enums
- `IECLANGUAGETYPES` (`242861707`): NONE 0 · ST 1 · IL 2 · SFC 3 · FBD 4 ·
  CFC 5 · LD 6.
- `PlcImportOptions` (`242872075`): NONE 0 · RENAME 1 · REPLACE 2 · SKIP 3.
- `Disabled`/`DISABLED_STATE`: `SMDS_NOT_DISABLED` · `SMDS_DISABLED` ·
  `SMDS_PARENT_DISABLED`.
- `CpuAffinity`: CPU1…CPU8 · MaskQuad · MaskAll.

### 16.9 Common HRESULTs
`S_OK` · `S_FALSE` · `E_POINTER` · `E_FAIL` · `E_INVALIDARG` ·
`TSM_E_ITEMNOTFOUND 0x98510001` · `TSM_E_INVALIDITEMTYPE 0x98510002` ·
`TSM_E_INVALIDITEMSUBTYPE 0x98510003` · `TSM_E_MISMATCHINGITEMS 0x98510004` ·
`TSM_E_CORRUPTEDLINK 0x98510005` · `NTE_NOT_FOUND 0x80090011` ·
`NTE_BAD_SIGNATURE 0x80090006`.

### 16.10 PLC helper interfaces (`242750731`, Level 2)
`ITcPlcProject` `242855691` · `ITcPlcIECProject` `242870539` ·
`ITcPlcIECProject2` (CheckAllObjects) · `ITcPlcLibraryManager` `242879627` ·
`ITcPlcPou` `242860171` · `ITcPlcDeclaration` `242864651` ·
`ITcPlcImplementation` `242867595` · `ITcPlcTaskReference` `242921611` ·
`ITcPlcLibrary` `242900875` · `ITcPlcLibraries` `242903819` ·
`ITcPlcReferences` `242897931` · `ITcPlcLibRef` `242908299` ·
`ITcPlcPlaceholderRef` `242911243` · `ITcPlcLibRepository` `242914187` ·
`ITcPlcLibRepositories` `242917131` · `ITcProjectRoot` (NestedProject).
Module side: `ITcModuleManager2/3`, `ITcModuleInstance2`, `ITcRemoteManager`.

---

## 17. Coverage map — this MCP vs. the surface

What the `te1000` MCP already exposes (see `README.md`) against the feature
surface above. Use this to spot gaps worth filling.

### Covered
- **Solution/DTE**: open/save/close, active doc, selected items, error list,
  list commands → `xae`; build/clean/rebuild → `xae_build`; raw DTE command →
  `xae_command`. (§4)
- **Tree**: get/children/exists/get_xml/set_xml/rename/create/create_rack/delete/
  import/export/focus (+ batch) → `tc_tree` — i.e. `LookupTreeItem`, `Child`,
  `ProduceXml`/`ConsumeXml`, `CreateChild`/`DeleteChild`/`ImportChild`/
  `ExportChild`, `Name`. (§2–§3, §16.2)
- **Linking**: link/unlink/resolve/links (+ batch) → `tc_link` —
  `LinkVariables`/`UnlinkVariables` + `<LinkedWith>` readback. (§8)
- **System**: get/set NetId, errors, rescan PLC, scan IO boxes → `tc_system`;
  activate config, restart runtime (guarded). (§5, §8)
- **PLC**: boot-project download → `plc_download`; login/logout via UI-automation
  → `plc_session`. (§7.1)
- **NC**: tasks/axes/axis → `nc`. (§12)
- **ESI-backed EtherCAT rack creation** (`create_rack`) — a higher-level
  capability beyond raw `CreateChild 9099`. (§8)

### Notable gaps (automatable but not yet wrapped)
- **PLC project authoring**: create PLC project / POUs / DUTs / GVLs
  (`CreateChild` 602–655), `DeclarationText`/`ImplementationText` edit, PLCopen
  XML import/export, `CheckAllObjects` build-check, boot-project generation
  flags, online command XML (Login/Start/Stop/Reset). (§7.1, §7.3)
- **Library management**: add/remove libraries & placeholders, set resolution,
  freeze, scan, repository install/uninstall (`ITcPlcLibraryManager`). The
  project notes `.plcproj` library edits need a solution reopen — relevant. (§7.2)
- **Mapping bulk ops**: `ProduceMappingInfo`/`ConsumeMappingInfo`/
  `ClearMappingInfo` (export/import/clear all links at once). (§5)
- **Tasks**: create RT tasks with/without image, cycle time/priority via XML,
  CPU-core assignment, `LinkedTask`. (§5)
- **Silent mode** toggle (`TcAutomationSettings.SilentMode`) — could harden the
  dialog watchdog. (§4)
- **Target platform** x86/x64 (`ActiveTargetPlatform`); **archives**
  (`SaveAsArchive` / `.tszip` / `.tpzip`). (§4, §7.1)
- **ADS routes**: add route / broadcast search via `TIRR` XML. (§6)
- **Other fieldbuses**: PROFINET/PROFIBUS/CANopen/DeviceNet/EAP create + claim
  resources (the `create_rack` pattern, generalized). (§8)
- **TcCOM**: add module by GUID/name, set context, enable symbols. (§9)
- **C++**: create project/module, TMC codegen, publish modules. (§10)
- **Measurement/Analytics**: Scope project + chart/axis/channel + record;
  Analytics Logger/Stream config. (§11)
- **Licensing**: dongle config + response-file activation. (§13)
- **Variant management**: define/select variants (`iTcSysManager14`). (§14)
- **Safety**: import existing `.splcproj`/`.tfzip` only — and by project policy
  the toolchain must **not** write toward safety, so leave this read-only. (§15)

---

*Sources: Beckhoff infosys, TwinCAT 3 Automation Interface manual (TE1000),
v1.6.2 / 2026-04-01. Each topic cited by content-URL id; full URL pattern is
`https://infosys.beckhoff.com/content/1033/tc3_automationinterface/<id>.html`.
Items in §11.1/§11.2 marked "unverified" should be confirmed against the live
page before use.*
