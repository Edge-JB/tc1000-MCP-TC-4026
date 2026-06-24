using System;
using System.Collections.Generic;
using TCatSysManagerLib;

namespace Te1000Daemon
{
    // plc_library actions ported from te1000-bridge.ps1 (L7159-7484).
    //
    // The References-node tree path is TIPC^<plc>^<plc> Project^References. The PS
    // bridge resolves it with Resolve-PlcReferencesPath (L1534) and wraps it in
    // Get-PlcLibraryReferencesItem (L1552). Both are ported INLINE here as
    // ResolveReferencesPath / GetReferencesItem.
    //
    // The library manager is the References tree item QI'd to ITcPlcLibraryManager.
    // dynamic (IDispatch) cannot QI to that vtable-only IUnknown interface, so —
    // exactly as PlcProjectHelper does for ITcPlcProject — every QI + member call
    // is funnelled through the typed PlcLibraryHelper class at the bottom of this
    // file (a faithful port of the PS bridge's compiled Te1000PlcLibraryHelper,
    // L1375-1487). We pass a FRESH (non-cached) RCW from ComHelpers.GetTreeItem
    // because the typed-cast QI can E_NOINTERFACE on a cached/reused RCW.
    //
    // Mutating actions (add/remove/set/freeze) edit the project-local .plcproj
    // References; repo-admin actions (install/uninstall/insert/remove/move) mutate
    // the machine-wide library store. Repo-admin actions re-check the
    // ALLOW_PLC_LIBRARY_REPO confirm token because the PS HANDLER itself checks it
    // (Assert-PlcLibraryRepoConfirm, L1569).
    //
    // C#5-clean (no interpolation, no out var, no expression-bodied members).
    internal static class PlcLibraryActions
    {
        // PS $script:PlcLibraryRefNote (L1567).
        private const string RefNote =
            ".plcproj reference change requires a solution close+reopen in XAE to take effect " +
            "(adding/removing/repinning a library or placeholder, set resolution); adding source " +
            "files alone does not.";

        public static void Register(Dictionary<string, ActionHandler> h)
        {
            h["plc_library_list_references"] = ListReferences;
            h["plc_library_scan"] = Scan;
            h["plc_library_list_repositories"] = ListRepositories;
            h["plc_library_add_library"] = AddLibrary;
            h["plc_library_add_placeholder"] = AddPlaceholder;
            h["plc_library_set_resolution"] = SetResolution;
            h["plc_library_freeze_placeholder"] = FreezePlaceholder;
            h["plc_library_remove_reference"] = RemoveReference;
            h["plc_library_install_library"] = InstallLibrary;
            h["plc_library_uninstall_library"] = UninstallLibrary;
            h["plc_library_insert_repository"] = InsertRepository;
            h["plc_library_remove_repository"] = RemoveRepository;
            h["plc_library_move_repository"] = MoveRepository;
        }

        // =====================================================================
        // READ actions
        // =====================================================================

        // --- plc_library_list_references (L7159-7183) ------------------------
        private static Json.JObj ListReferences(ActionContext ctx)
        {
            dynamic sm = ctx.SysManager();
            string path = ResolveReferencesPath(ctx, sm, ctx.Payload.Str("referencesPath"));
            object item = GetReferencesItem(sm, path);

            object[] rows = PlcLibraryHelper.ListReferences(item);
            var refs = new Json.JArr();
            for (int i = 0; i < rows.Length; i++)
            {
                object[] r = (object[])rows[i];
                var o = new Json.JObj();
                o["name"] = r[0];
                o["kind"] = r[1];
                o["displayName"] = r[2];
                o["distributor"] = r[3];
                o["version"] = r[4];
                refs.Add(o);
            }

            var data = new Json.JObj();
            data["referencesPath"] = path;
            data["count"] = refs.Count;
            data["references"] = refs;
            return data;
        }

        // --- plc_library_scan (L7185-7207) -----------------------------------
        private static Json.JObj Scan(ActionContext ctx)
        {
            dynamic sm = ctx.SysManager();
            string path = ResolveReferencesPath(ctx, sm, ctx.Payload.Str("referencesPath"));
            object item = GetReferencesItem(sm, path);

            object[] rows = PlcLibraryHelper.ScanLibraries(item);
            var libs = new Json.JArr();
            for (int i = 0; i < rows.Length; i++)
            {
                object[] r = (object[])rows[i];
                var o = new Json.JObj();
                o["name"] = r[0];
                o["version"] = r[1];
                o["distributor"] = r[2];
                o["displayName"] = r[3];
                libs.Add(o);
            }

            var data = new Json.JObj();
            data["count"] = libs.Count;
            data["libraries"] = libs;
            return data;
        }

        // --- plc_library_list_repositories (L7209-7226) ----------------------
        private static Json.JObj ListRepositories(ActionContext ctx)
        {
            dynamic sm = ctx.SysManager();
            string path = ResolveReferencesPath(ctx, sm, ctx.Payload.Str("referencesPath"));
            object item = GetReferencesItem(sm, path);

            object[] rows = PlcLibraryHelper.ListRepositories(item);
            var repos = new Json.JArr();
            for (int i = 0; i < rows.Length; i++)
            {
                object[] r = (object[])rows[i];
                var o = new Json.JObj();
                o["name"] = r[0];
                o["folder"] = r[1];
                repos.Add(o);
            }

            var data = new Json.JObj();
            data["count"] = repos.Count;
            data["repositories"] = repos;
            return data;
        }

        // =====================================================================
        // MUTATING actions (project-local .plcproj reference edits)
        // =====================================================================

        // --- plc_library_add_library (L7228-7254) ----------------------------
        private static Json.JObj AddLibrary(ActionContext ctx)
        {
            string name = ctx.Payload.Str("name");
            if (string.IsNullOrWhiteSpace(name)) throw new BridgeException("name is required");
            string version = ctx.Payload.Has("version") ? ctx.Payload.Str("version") : "";
            string company = ctx.Payload.Has("company") ? ctx.Payload.Str("company") : "";

            dynamic sm = ctx.SysManager();
            string path = ResolveReferencesPath(ctx, sm, ctx.Payload.Str("referencesPath"));
            object item = GetReferencesItem(sm, path);

            PlcLibraryHelper.AddLibrary(item, name, version, company);
            bool saved = SaveIfRequested(ctx);
            ctx.Cache.Invalidate(path);

            var data = new Json.JObj();
            data["action"] = "add_library";
            data["name"] = name;
            data["version"] = version;
            data["company"] = company;
            data["referencesPath"] = path;
            data["saved"] = saved;
            data["note"] = RefNote;
            return data;
        }

        // --- plc_library_add_placeholder (L7256-7288) ------------------------
        private static Json.JObj AddPlaceholder(ActionContext ctx)
        {
            string name = ctx.Payload.Str("name");
            if (string.IsNullOrWhiteSpace(name)) throw new BridgeException("name is required");
            string defLib = ctx.Payload.Has("defLib") ? ctx.Payload.Str("defLib") : "";
            string defVer = ctx.Payload.Has("defVer") ? ctx.Payload.Str("defVer") : "";
            string defDist = ctx.Payload.Has("defDist") ? ctx.Payload.Str("defDist") : "";

            dynamic sm = ctx.SysManager();
            string path = ResolveReferencesPath(ctx, sm, ctx.Payload.Str("referencesPath"));
            object item = GetReferencesItem(sm, path);

            if (!string.IsNullOrWhiteSpace(defLib))
            {
                PlcLibraryHelper.AddPlaceholder(item, name, defLib, defVer, defDist);
            }
            else
            {
                PlcLibraryHelper.AddPlaceholderNameOnly(item, name);
            }
            bool saved = SaveIfRequested(ctx);
            ctx.Cache.Invalidate(path);

            var data = new Json.JObj();
            data["action"] = "add_placeholder";
            data["name"] = name;
            data["defLib"] = defLib;
            data["defVer"] = defVer;
            data["defDist"] = defDist;
            data["referencesPath"] = path;
            data["saved"] = saved;
            data["note"] = RefNote;
            return data;
        }

        // --- plc_library_set_resolution (L7290-7319) -------------------------
        private static Json.JObj SetResolution(ActionContext ctx)
        {
            string placeholder = ctx.Payload.Str("placeholder");
            string lib = ctx.Payload.Str("lib");
            if (string.IsNullOrWhiteSpace(placeholder)) throw new BridgeException("placeholder is required");
            if (string.IsNullOrWhiteSpace(lib)) throw new BridgeException("lib is required");
            string version = ctx.Payload.Has("version") ? ctx.Payload.Str("version") : "";
            string dist = ctx.Payload.Has("dist") ? ctx.Payload.Str("dist") : "";

            dynamic sm = ctx.SysManager();
            string path = ResolveReferencesPath(ctx, sm, ctx.Payload.Str("referencesPath"));
            object item = GetReferencesItem(sm, path);

            PlcLibraryHelper.SetEffectiveResolution(item, placeholder, lib, version, dist);
            bool saved = SaveIfRequested(ctx);
            ctx.Cache.Invalidate(path);

            var data = new Json.JObj();
            data["action"] = "set_resolution";
            data["placeholder"] = placeholder;
            data["lib"] = lib;
            data["version"] = version;
            data["dist"] = dist;
            data["referencesPath"] = path;
            data["saved"] = saved;
            data["note"] = RefNote;
            return data;
        }

        // --- plc_library_freeze_placeholder (L7321-7346) ---------------------
        private static Json.JObj FreezePlaceholder(ActionContext ctx)
        {
            string name = ctx.Payload.Has("name") ? ctx.Payload.Str("name") : "";

            dynamic sm = ctx.SysManager();
            string path = ResolveReferencesPath(ctx, sm, ctx.Payload.Str("referencesPath"));
            object item = GetReferencesItem(sm, path);

            if (!string.IsNullOrWhiteSpace(name))
            {
                PlcLibraryHelper.FreezePlaceholder(item, name);
            }
            else
            {
                PlcLibraryHelper.FreezePlaceholderAll(item);
            }
            bool saved = SaveIfRequested(ctx);
            ctx.Cache.Invalidate(path);

            var data = new Json.JObj();
            data["action"] = "freeze";
            data["name"] = string.IsNullOrWhiteSpace(name) ? "(all)" : name;
            data["referencesPath"] = path;
            data["saved"] = saved;
            data["note"] = RefNote;
            return data;
        }

        // --- plc_library_remove_reference (L7348-7370) -----------------------
        private static Json.JObj RemoveReference(ActionContext ctx)
        {
            string name = ctx.Payload.Str("name");
            if (string.IsNullOrWhiteSpace(name)) throw new BridgeException("name is required");

            dynamic sm = ctx.SysManager();
            string path = ResolveReferencesPath(ctx, sm, ctx.Payload.Str("referencesPath"));
            object item = GetReferencesItem(sm, path);

            PlcLibraryHelper.RemoveReference(item, name);
            bool saved = SaveIfRequested(ctx);
            ctx.Cache.Invalidate(path);

            var data = new Json.JObj();
            data["action"] = "remove_reference";
            data["name"] = name;
            data["referencesPath"] = path;
            data["saved"] = saved;
            data["note"] = RefNote + " (Project-local edit only; does NOT uninstall from the repository.)";
            return data;
        }

        // =====================================================================
        // REPOSITORY ADMIN actions (machine-wide library store mutations)
        // Each re-checks ALLOW_PLC_LIBRARY_REPO because the PS handler does.
        // =====================================================================

        // --- plc_library_install_library (L7372-7393) ------------------------
        private static Json.JObj InstallLibrary(ActionContext ctx)
        {
            AssertRepoConfirm(ctx.Payload.Str("confirm"));
            string repo = ctx.Payload.Str("repo");
            string libPath = ctx.Payload.Str("libPath");
            if (string.IsNullOrWhiteSpace(repo)) throw new BridgeException("repo is required");
            if (string.IsNullOrWhiteSpace(libPath)) throw new BridgeException("libPath is required");
            bool overwrite = false;
            if (ctx.Payload.Has("overwrite")) overwrite = ctx.Payload.Bool("overwrite");

            dynamic sm = ctx.SysManager();
            string path = ResolveReferencesPath(ctx, sm, ctx.Payload.Str("referencesPath"));
            object item = GetReferencesItem(sm, path);

            PlcLibraryHelper.InstallLibrary(item, repo, libPath, overwrite);
            ctx.Cache.Invalidate(null);

            var data = new Json.JObj();
            data["action"] = "install_library";
            data["repo"] = repo;
            data["libPath"] = libPath;
            data["overwrite"] = overwrite;
            return data;
        }

        // --- plc_library_uninstall_library (L7396-7418) ----------------------
        private static Json.JObj UninstallLibrary(ActionContext ctx)
        {
            AssertRepoConfirm(ctx.Payload.Str("confirm"));
            string repo = ctx.Payload.Str("repo");
            string lib = ctx.Payload.Str("lib");
            if (string.IsNullOrWhiteSpace(repo)) throw new BridgeException("repo is required");
            if (string.IsNullOrWhiteSpace(lib)) throw new BridgeException("lib is required");
            string version = ctx.Payload.Has("version") ? ctx.Payload.Str("version") : "";
            string dist = ctx.Payload.Has("dist") ? ctx.Payload.Str("dist") : "";

            dynamic sm = ctx.SysManager();
            string path = ResolveReferencesPath(ctx, sm, ctx.Payload.Str("referencesPath"));
            object item = GetReferencesItem(sm, path);

            PlcLibraryHelper.UninstallLibrary(item, repo, lib, version, dist);
            ctx.Cache.Invalidate(null);

            var data = new Json.JObj();
            data["action"] = "uninstall_library";
            data["repo"] = repo;
            data["lib"] = lib;
            data["version"] = version;
            data["dist"] = dist;
            return data;
        }

        // --- plc_library_insert_repository (L7421-7442) ----------------------
        private static Json.JObj InsertRepository(ActionContext ctx)
        {
            AssertRepoConfirm(ctx.Payload.Str("confirm"));
            string name = ctx.Payload.Str("name");
            string folder = ctx.Payload.Str("folder");
            if (string.IsNullOrWhiteSpace(name)) throw new BridgeException("name is required");
            if (string.IsNullOrWhiteSpace(folder)) throw new BridgeException("folder is required");
            int index = 0;
            if (ctx.Payload.Has("index")) index = ctx.Payload.Int("index", 0);

            dynamic sm = ctx.SysManager();
            string path = ResolveReferencesPath(ctx, sm, ctx.Payload.Str("referencesPath"));
            object item = GetReferencesItem(sm, path);

            PlcLibraryHelper.InsertRepository(item, name, folder, index);
            ctx.Cache.Invalidate(null);

            var data = new Json.JObj();
            data["action"] = "insert_repository";
            data["name"] = name;
            data["folder"] = folder;
            data["index"] = index;
            return data;
        }

        // --- plc_library_remove_repository (L7445-7461) ----------------------
        private static Json.JObj RemoveRepository(ActionContext ctx)
        {
            AssertRepoConfirm(ctx.Payload.Str("confirm"));
            string name = ctx.Payload.Str("name");
            if (string.IsNullOrWhiteSpace(name)) throw new BridgeException("name is required");

            dynamic sm = ctx.SysManager();
            string path = ResolveReferencesPath(ctx, sm, ctx.Payload.Str("referencesPath"));
            object item = GetReferencesItem(sm, path);

            PlcLibraryHelper.RemoveRepository(item, name);
            ctx.Cache.Invalidate(null);

            var data = new Json.JObj();
            data["action"] = "remove_repository";
            data["name"] = name;
            return data;
        }

        // --- plc_library_move_repository (L7463-7482) ------------------------
        private static Json.JObj MoveRepository(ActionContext ctx)
        {
            AssertRepoConfirm(ctx.Payload.Str("confirm"));
            string name = ctx.Payload.Str("name");
            if (string.IsNullOrWhiteSpace(name)) throw new BridgeException("name is required");
            if (!ctx.Payload.Has("index")) throw new BridgeException("index is required");
            int index = ctx.Payload.Int("index", 0);

            dynamic sm = ctx.SysManager();
            string path = ResolveReferencesPath(ctx, sm, ctx.Payload.Str("referencesPath"));
            object item = GetReferencesItem(sm, path);

            PlcLibraryHelper.MoveRepository(item, name, index);
            ctx.Cache.Invalidate(null);

            var data = new Json.JObj();
            data["action"] = "move_repository";
            data["name"] = name;
            data["index"] = index;
            return data;
        }

        // =====================================================================
        // private helpers (ported inline from the PS bridge)
        // =====================================================================

        // Save-Solution-on-`save` opt-in, swallowing failures like the PS does
        // (try { Save-Solution } catch { $saved = $false }). PS Save-Solution maps
        // to File.SaveAll on the DTE.
        private static bool SaveIfRequested(ActionContext ctx)
        {
            if (ctx.Payload.Has("save") && ctx.Payload.Bool("save"))
            {
                try { ctx.Dte().ExecuteCommand("File.SaveAll"); return true; }
                catch { return false; }
            }
            return false;
        }

        // Assert-PlcLibraryRepoConfirm (L1569-1574). The PS handler itself checks
        // this token for every repo-admin verb, so it is replicated verbatim.
        private static void AssertRepoConfirm(string confirm)
        {
            if (confirm != "ALLOW_PLC_LIBRARY_REPO")
            {
                throw new BridgeException("Blocked: confirm=ALLOW_PLC_LIBRARY_REPO required for repository administration.");
            }
        }

        // Resolve-PlcReferencesPath (L1534-1550): use the supplied path as-is, else
        // default to the first PLC under TIPC: TIPC^<plc>^<plc> Project^References.
        private static string ResolveReferencesPath(ActionContext ctx, dynamic sm, string referencesPath)
        {
            if (!string.IsNullOrWhiteSpace(referencesPath)) return referencesPath;

            dynamic tipc = ComHelpers.GetTreeItem(sm, "TIPC");
            if (ComHelpers.ChildCount(tipc) < 1) throw new BridgeException("No PLC project found under TIPC");
            dynamic first = ComHelpers.Child(tipc, 1);
            string plcName = ComHelpers.SafeStr(delegate { return first.Name; });
            return "TIPC^" + plcName + "^" + plcName + " Project^References";
        }

        // Get-PlcLibraryReferencesItem (L1552-1565): resolve the References node to a
        // FRESH tree-item RCW. The typed ITcPlcLibraryManager helper is statically
        // linked (TCatSysManagerLib, EmbedInteropTypes) so no runtime load gate is
        // needed; PlcLibraryHelper's cast surfaces the equivalent failure if the QI
        // is unavailable on this shell.
        private static object GetReferencesItem(dynamic sm, string path)
        {
            return ComHelpers.GetTreeItem(sm, path);
        }
    }

    // Faithful port of the bridge's compiled Te1000PlcLibraryHelper (L1375-1487).
    //
    // ITcPlcLibraryManager / ITcPlcReferences / ITcPlcLibRef / ITcPlcLibrary /
    // ITcPlcPlaceholderRef / ITcPlcLibRepositories / ITcPlcLibRepository are
    // vtable (IUnknown) interfaces; late-bound `dynamic` (IDispatch) cannot QI to
    // them, so — exactly as PlcProjectHelper does — every QI + member call lives
    // in this typed helper. Lives in this file (not a new compile unit) because the
    // porting task may only touch PlcLibraryActions.cs.
    internal static class PlcLibraryHelper
    {
        // --- readers ---------------------------------------------------------
        public static object[] ListReferences(object refsItem)
        {
            ITcPlcLibraryManager mgr = (ITcPlcLibraryManager)refsItem;
            ITcPlcReferences refs = mgr.References;
            List<object> list = new List<object>();
            int count = refs.Count;
            for (int i = 0; i < count; i++)
            {
                ITcPlcLibRef r = refs[i];
                string name = null, displayName = null, distributor = null, version = null, kind = "reference";
                try { name = r.Name; } catch { }
                ITcPlcPlaceholderRef ph = r as ITcPlcPlaceholderRef;
                ITcPlcLibrary lib = r as ITcPlcLibrary;
                if (ph != null)
                {
                    kind = "placeholder";
                    try { if (name == null) name = ph.Name; } catch { }
                    ITcPlcLibrary res = null;
                    try { res = ph.EffectiveResolution; } catch { }
                    if (res == null) { try { res = ph.CurrentLibrary; } catch { } }
                    if (res != null)
                    {
                        try { displayName = res.DisplayName; } catch { }
                        try { distributor = res.Distributor; } catch { }
                        try { version = res.Version; } catch { }
                    }
                }
                else if (lib != null)
                {
                    kind = "library";
                    try { displayName = lib.DisplayName; } catch { }
                    try { distributor = lib.Distributor; } catch { }
                    try { if (name == null) name = lib.Name; } catch { }
                    try { version = lib.Version; } catch { }
                }
                list.Add(new object[] { name, kind, displayName, distributor, version });
            }
            return list.ToArray();
        }

        public static object[] ScanLibraries(object refsItem)
        {
            ITcPlcLibraryManager mgr = (ITcPlcLibraryManager)refsItem;
            ITcPlcReferences libs = mgr.ScanLibraries();
            List<object> list = new List<object>();
            int count = libs.Count;
            for (int i = 0; i < count; i++)
            {
                ITcPlcLibRef r = libs[i];
                string name = null, version = null, distributor = null, displayName = null;
                ITcPlcLibrary lib = r as ITcPlcLibrary;
                if (lib != null)
                {
                    try { name = lib.Name; } catch { }
                    try { version = lib.Version; } catch { }
                    try { distributor = lib.Distributor; } catch { }
                    try { displayName = lib.DisplayName; } catch { }
                }
                else
                {
                    try { name = r.Name; } catch { }
                }
                list.Add(new object[] { name, version, distributor, displayName });
            }
            return list.ToArray();
        }

        public static object[] ListRepositories(object refsItem)
        {
            ITcPlcLibraryManager mgr = (ITcPlcLibraryManager)refsItem;
            ITcPlcLibRepositories repos = mgr.Repositories;
            List<object> list = new List<object>();
            int count = repos.Count;
            for (int i = 0; i < count; i++)
            {
                ITcPlcLibRepository repo = repos[i];
                string name = null, folder = null;
                try { name = repo.Name; } catch { }
                try { folder = repo.Folder; } catch { }
                list.Add(new object[] { name, folder });
            }
            return list.ToArray();
        }

        // --- writers (project-local .plcproj edits) --------------------------
        public static void AddLibrary(object refsItem, string name, string ver, string co)
        {
            ((ITcPlcLibraryManager)refsItem).AddLibrary(name, ver, co);
        }
        public static void AddPlaceholder(object refsItem, string name, string defLib, string defVer, string defDist)
        {
            ((ITcPlcLibraryManager)refsItem).AddPlaceholder(name, defLib, defVer, defDist);
        }
        public static void AddPlaceholderNameOnly(object refsItem, string name)
        {
            ((ITcPlcLibraryManager)refsItem).AddPlaceholder(name);
        }
        public static void SetEffectiveResolution(object refsItem, string ph, string lib, string ver, string dist)
        {
            ((ITcPlcLibraryManager)refsItem).SetEffectiveResolution(ph, lib, ver, dist);
        }
        public static void FreezePlaceholder(object refsItem, string name)
        {
            ((ITcPlcLibraryManager)refsItem).FreezePlaceholder(name);
        }
        public static void FreezePlaceholderAll(object refsItem)
        {
            ((ITcPlcLibraryManager)refsItem).FreezePlaceholder();
        }
        public static void RemoveReference(object refsItem, string name)
        {
            ((ITcPlcLibraryManager)refsItem).RemoveReference(name);
        }

        // --- repo admin (machine-wide library store mutations) ---------------
        public static void InstallLibrary(object refsItem, string repo, string path, bool overwrite)
        {
            ((ITcPlcLibraryManager)refsItem).InstallLibrary(repo, path, overwrite);
        }
        public static void UninstallLibrary(object refsItem, string repo, string lib, string ver, string dist)
        {
            ((ITcPlcLibraryManager)refsItem).UninstallLibrary(repo, lib, ver, dist);
        }
        public static void InsertRepository(object refsItem, string name, string folder, int idx)
        {
            ((ITcPlcLibraryManager)refsItem).InsertRepository(name, folder, idx);
        }
        public static void RemoveRepository(object refsItem, string name)
        {
            ((ITcPlcLibraryManager)refsItem).RemoveRepository(name);
        }
        public static void MoveRepository(object refsItem, string name, int idx)
        {
            ((ITcPlcLibraryManager)refsItem).MoveRepository(name, idx);
        }
    }
}
