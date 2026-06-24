using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;

namespace Te1000Daemon
{
    // Measurement (TE130X Scope-View) + TwinCAT Analytics action group, ported
    // from te1000-bridge.ps1 (L9330-9559).
    //
    // Scope actions drive the TE130X Scope-View Automation Interface. The scope
    // automation object exposes IMeasurementScope, which is a vtable/IUnknown
    // interface that cannot be late-bound through `dynamic` (PowerShell hit the
    // same wall — see bridge L913-922), so the PS bridge invoked it through a
    // compiled reflection shim (Te1000MeasurementHelper). That shim is pure
    // System.Reflection, so it ports 1:1 to C# here (see ScopeHelper below). If
    // the TE130X automation assembly cannot be located/loaded, EnsureScopeHelper
    // returns false and the handlers throw the SAME 'tooling not installed'
    // BridgeException the PS bridge raised.
    //
    // Analytics actions use the TIAN tree node and CreateChild/DeleteChild, the
    // same pattern as twincat_create_child/delete_child.
    //
    // C#5-clean (no interpolation, no out var, no expression-bodied members).
    internal static class MeasurementActions
    {
        public static void Register(Dictionary<string, ActionHandler> h)
        {
            h["measurement_scope_create"] = ScopeCreate;
            h["measurement_scope_add_child"] = ScopeAddChild;
            h["measurement_scope_rename"] = ScopeRename;
            h["measurement_scope_record"] = ScopeRecord;
            h["measurement_analytics_create"] = AnalyticsCreate;
            h["analytics_logger_create"] = AnalyticsLoggerCreate;
            h["analytics_stream_create"] = AnalyticsStreamCreate;
            h["analytics_logger_delete"] = AnalyticsLoggerDelete;
            h["analytics_stream_delete"] = AnalyticsStreamDelete;
        }

        // --- measurement_scope_create (L9330-9356) ---------------------------
        private static Json.JObj ScopeCreate(ActionContext ctx)
        {
            string name = ctx.Payload.Str("name");
            if (string.IsNullOrWhiteSpace(name)) throw new BridgeException("name is required");

            dynamic dte = ctx.Dte(true);
            dynamic solution = dte.Solution;
            if (solution == null || !((bool)solution.IsOpen)) throw new BridgeException("No solution is open");

            string solutionFullName = (string)solution.FullName;
            string destination = ctx.Payload.Truthy("destination")
                ? ctx.Payload.Str("destination")
                : Path.GetDirectoryName(solutionFullName);

            string template = ctx.Payload.Truthy("template")
                ? ctx.Payload.Str("template")
                : GetScopeTemplatePath();
            if (string.IsNullOrWhiteSpace(template))
            {
                throw new BridgeException("Scope project template not found — TE130X Scope View tooling may not be installed. Pass template explicitly (a full .tcmproj path).");
            }
            if (!File.Exists(template)) throw new BridgeException("Scope template not found: " + template);

            dynamic proj = solution.AddFromTemplate(template, destination, name);

            ctx.Cache.Invalidate(null);

            var data = new Json.JObj();
            data["created"] = true;
            data["name"] = name;
            data["kind"] = "scope";
            data["projectFullName"] = ComHelpers.SafeStr(delegate { return proj.FullName; });
            return data;
        }

        // --- measurement_scope_add_child (L9358-9389) ------------------------
        private static Json.JObj ScopeAddChild(ActionContext ctx)
        {
            string project = ctx.Payload.Str("project");
            if (string.IsNullOrWhiteSpace(project)) throw new BridgeException("project is required");
            string name = (ctx.Payload.Has("name") && ctx.Payload.Str("name") != null) ? ctx.Payload.Str("name") : "";
            int elementType = ctx.Payload.Has("elementType") ? ctx.Payload.Int("elementType", 0) : 0;
            string parentPath = ctx.Payload.Truthy("parentPath") ? ctx.Payload.Str("parentPath") : "";

            dynamic dte = ctx.Dte(true);
            if (!EnsureScopeHelper())
            {
                throw new BridgeException("TE130X Scope automation assembly not found (TwinCAT.Measurement.AutomationInterface.dll). Scope tooling is not installed.");
            }
            object obj = GetScopeProjectObject(dte, project);
            if (!ScopeHelper.Is(obj))
            {
                throw new BridgeException("Project '" + project + "' is not a Measurement/Scope project (object is not IMeasurementScope).");
            }
            object parent = ResolveScopeElement(obj, parentPath);
            object child;
            int rc = ScopeHelper.CreateChild(parent, out child, name, elementType);

            ctx.Cache.Invalidate(null);

            var data = new Json.JObj();
            data["project"] = project;
            data["parentPath"] = parentPath;
            data["created"] = true;
            data["name"] = name;
            data["elementType"] = elementType;
            data["rc"] = rc;
            return data;
        }

        // --- measurement_scope_rename (L9391-9415) ---------------------------
        private static Json.JObj ScopeRename(ActionContext ctx)
        {
            string project = ctx.Payload.Str("project");
            string path = ctx.Payload.Str("path");
            string newName = ctx.Payload.Str("newName");
            if (string.IsNullOrWhiteSpace(project)) throw new BridgeException("project is required");
            if (string.IsNullOrWhiteSpace(path)) throw new BridgeException("path is required");
            if (string.IsNullOrWhiteSpace(newName)) throw new BridgeException("newName is required");

            dynamic dte = ctx.Dte(true);
            if (!EnsureScopeHelper())
            {
                throw new BridgeException("TE130X Scope automation assembly not found (TwinCAT.Measurement.AutomationInterface.dll). Scope tooling is not installed.");
            }
            object obj = GetScopeProjectObject(dte, project);
            if (!ScopeHelper.Is(obj))
            {
                throw new BridgeException("Project '" + project + "' is not a Measurement/Scope project (object is not IMeasurementScope).");
            }
            object element = ResolveScopeElement(obj, path);
            int rc = ScopeHelper.ChangeName(element, newName);

            ctx.Cache.Invalidate(null);

            var data = new Json.JObj();
            data["project"] = project;
            data["path"] = path;
            data["newName"] = newName;
            data["rc"] = rc;
            return data;
        }

        // --- measurement_scope_record (L9417-9438) ---------------------------
        // NOTE: index.js guards this with ALLOW_MEASUREMENT_RECORD upstream; the
        // PS handler itself does NOT re-check a token, so neither do we.
        private static Json.JObj ScopeRecord(ActionContext ctx)
        {
            string project = ctx.Payload.Str("project");
            string state = ctx.Payload.Str("state");
            if (string.IsNullOrWhiteSpace(project)) throw new BridgeException("project is required");
            if (state != "start" && state != "stop") throw new BridgeException("state must be 'start' or 'stop'");

            dynamic dte = ctx.Dte(true);
            if (!EnsureScopeHelper())
            {
                throw new BridgeException("TE130X Scope automation assembly not found (TwinCAT.Measurement.AutomationInterface.dll). Scope tooling is not installed.");
            }
            object obj = GetScopeProjectObject(dte, project);
            if (!ScopeHelper.Is(obj))
            {
                throw new BridgeException("Project '" + project + "' is not a Measurement/Scope project (object is not IMeasurementScope).");
            }
            int rc = (state == "start") ? ScopeHelper.StartRecord(obj) : ScopeHelper.StopRecord(obj);

            var data = new Json.JObj();
            data["project"] = project;
            data["state"] = state;
            data["rc"] = rc;
            return data;
        }

        // --- measurement_analytics_create (L9440-9466) -----------------------
        private static Json.JObj AnalyticsCreate(ActionContext ctx)
        {
            string name = ctx.Payload.Str("name");
            if (string.IsNullOrWhiteSpace(name)) throw new BridgeException("name is required");

            dynamic dte = ctx.Dte(true);
            dynamic solution = dte.Solution;
            if (solution == null || !((bool)solution.IsOpen)) throw new BridgeException("No solution is open");

            string solutionFullName = (string)solution.FullName;
            string destination = ctx.Payload.Truthy("destination")
                ? ctx.Payload.Str("destination")
                : Path.GetDirectoryName(solutionFullName);

            string template = ctx.Payload.Truthy("template")
                ? ctx.Payload.Str("template")
                : GetAnalyticsTemplatePath();
            if (string.IsNullOrWhiteSpace(template))
            {
                throw new BridgeException("Analytics project template not found — pass template explicitly (TwinCAT Analytics tooling may not be installed).");
            }
            if (!File.Exists(template)) throw new BridgeException("Analytics template not found: " + template);

            dynamic proj = solution.AddFromTemplate(template, destination, name);

            ctx.Cache.Invalidate(null);

            var data = new Json.JObj();
            data["created"] = true;
            data["name"] = name;
            data["kind"] = "analytics";
            data["projectFullName"] = ComHelpers.SafeStr(delegate { return proj.FullName; });
            return data;
        }

        // --- analytics_logger_create (L9468-9485) ----------------------------
        private static Json.JObj AnalyticsLoggerCreate(ActionContext ctx)
        {
            string name = ctx.Payload.Str("name");
            if (string.IsNullOrWhiteSpace(name)) throw new BridgeException("name is required");
            string before = ctx.Payload.Truthy("before") ? ctx.Payload.Str("before") : "";

            dynamic sm = ctx.SysManager();
            dynamic tian = ComHelpers.GetTreeItem(sm, "TIAN");
            // subType 1 = DataLogger (infosys 12562942987).
            dynamic child = tian.CreateChild(name, 1, before, null);
            AssertWellFormedChild(tian, child, name, 1, "TIAN");

            ctx.Cache.Invalidate("TIAN");

            var data = new Json.JObj();
            data["parentPath"] = "TIAN";
            data["child"] = ComHelpers.ConvertTreeItem(child);
            return data;
        }

        // --- analytics_stream_create (L9487-9504) ----------------------------
        private static Json.JObj AnalyticsStreamCreate(ActionContext ctx)
        {
            string name = ctx.Payload.Str("name");
            if (string.IsNullOrWhiteSpace(name)) throw new BridgeException("name is required");
            string before = ctx.Payload.Truthy("before") ? ctx.Payload.Str("before") : "";

            dynamic sm = ctx.SysManager();
            dynamic tian = ComHelpers.GetTreeItem(sm, "TIAN");
            // subType 0 = StreamHelper (infosys 12563004555).
            dynamic child = tian.CreateChild(name, 0, before, null);
            AssertWellFormedChild(tian, child, name, 0, "TIAN");

            ctx.Cache.Invalidate("TIAN");

            var data = new Json.JObj();
            data["parentPath"] = "TIAN";
            data["child"] = ComHelpers.ConvertTreeItem(child);
            return data;
        }

        // --- analytics_logger_delete (L9506-9531) ----------------------------
        private static Json.JObj AnalyticsLoggerDelete(ActionContext ctx)
        {
            string name = ctx.Payload.Str("name");
            if (string.IsNullOrWhiteSpace(name)) throw new BridgeException("name is required");
            bool dryRun = ctx.Payload.Bool("dryRun", false);

            dynamic sm = ctx.SysManager();

            if (dryRun)
            {
                dynamic tianRead = ctx.Cache.LookupItem(sm, "TIAN");
                bool exists = ChildExistsByName(tianRead, name);
                var dd = new Json.JObj();
                dd["parentPath"] = "TIAN";
                dd["name"] = name;
                dd["exists"] = exists;
                dd["deleted"] = false;
                return dd;
            }

            dynamic tian = ComHelpers.GetTreeItem(sm, "TIAN");
            tian.DeleteChild(name);
            ctx.Cache.Invalidate("TIAN");

            var data = new Json.JObj();
            data["parentPath"] = "TIAN";
            data["name"] = name;
            data["deleted"] = true;
            return data;
        }

        // --- analytics_stream_delete (L9533-9559) ----------------------------
        private static Json.JObj AnalyticsStreamDelete(ActionContext ctx)
        {
            string name = ctx.Payload.Str("name");
            if (string.IsNullOrWhiteSpace(name)) throw new BridgeException("name is required");
            string deleteName = name + "_Obj1 (StreamHelper)";
            bool dryRun = ctx.Payload.Bool("dryRun", false);

            dynamic sm = ctx.SysManager();

            if (dryRun)
            {
                dynamic tianRead = ctx.Cache.LookupItem(sm, "TIAN");
                bool exists = ChildExistsByName(tianRead, deleteName);
                var dd = new Json.JObj();
                dd["parentPath"] = "TIAN";
                dd["name"] = name;
                dd["deleteName"] = deleteName;
                dd["exists"] = exists;
                dd["deleted"] = false;
                return dd;
            }

            dynamic tian = ComHelpers.GetTreeItem(sm, "TIAN");
            tian.DeleteChild(deleteName);
            ctx.Cache.Invalidate("TIAN");

            var data = new Json.JObj();
            data["parentPath"] = "TIAN";
            data["name"] = name;
            data["deleteName"] = deleteName;
            data["deleted"] = true;
            return data;
        }

        // ===================================================================
        // private helpers
        // ===================================================================

        // Get-XaePublicAssembliesPath (bridge L64-75): the XAE PublicAssemblies
        // dir, used as a last-ditch probe location for the measurement assembly.
        private static string GetXaePublicAssembliesPath()
        {
            string[] candidates = new string[] {
                "C:\\Program Files (x86)\\Beckhoff\\TcXaeShell\\Common7\\IDE\\PublicAssemblies",
                "C:\\Program Files\\Beckhoff\\TcXaeShell\\Common7\\IDE\\PublicAssemblies"
            };
            foreach (string candidate in candidates)
            {
                if (File.Exists(Path.Combine(candidate, "envdte.dll"))) return candidate;
            }
            return candidates[0];
        }

        // Get-MeasurementLibPath (bridge L859-875): resolve the TE130X Scope View
        // Automation Interface assembly across known install dirs; null if absent.
        private static string GetMeasurementLibPath()
        {
            string name = "TwinCAT.Measurement.AutomationInterface.dll";
            string[] dirs = new string[] {
                "C:\\TwinCAT\\Functions\\TE130X-Scope-View",
                "C:\\Program Files (x86)\\Beckhoff\\TwinCAT\\Functions\\TE130X-Scope-View",
                "C:\\Program Files\\Beckhoff\\TwinCAT\\Functions\\TE130X-Scope-View",
                GetXaePublicAssembliesPath()
            };
            foreach (string dir in dirs)
            {
                if (string.IsNullOrWhiteSpace(dir) || !Directory.Exists(dir)) continue;
                string direct = Path.Combine(dir, name);
                if (File.Exists(direct)) return direct;
                try
                {
                    string[] hits = Directory.GetFiles(dir, name, SearchOption.AllDirectories);
                    if (hits != null && hits.Length > 0) return hits[0];
                }
                catch { }
            }
            return null;
        }

        // Get-ScopeTemplatePath (bridge L879-891): probe Templates\Projects for a
        // *.tcmproj; null if the tooling is not installed.
        private static string GetScopeTemplatePath()
        {
            string[] dirs = new string[] {
                "C:\\TwinCAT\\Functions\\TE130X-Scope-View\\Templates\\Projects",
                "C:\\Program Files (x86)\\Beckhoff\\TwinCAT\\Functions\\TE130X-Scope-View\\Templates\\Projects",
                "C:\\Program Files\\Beckhoff\\TwinCAT\\Functions\\TE130X-Scope-View\\Templates\\Projects"
            };
            foreach (string dir in dirs)
            {
                if (!Directory.Exists(dir)) continue;
                try
                {
                    string[] hits = Directory.GetFiles(dir, "*.tcmproj", SearchOption.TopDirectoryOnly);
                    if (hits != null && hits.Length > 0) return hits[0];
                }
                catch { }
            }
            return null;
        }

        // Get-AnalyticsTemplatePath (bridge L895-911): probe the Analytics product
        // template dirs for *.tcaproj/*.tcanalyticsproj/*.tsproj under a Templates
        // path segment; null if none found.
        private static string GetAnalyticsTemplatePath()
        {
            string[] roots = new string[] {
                "C:\\TwinCAT\\Functions\\TE3500-Analytics-Workbench",
                "C:\\TwinCAT\\Functions\\TE3520-Analytics-Service-Tool",
                "C:\\Program Files (x86)\\Beckhoff\\TwinCAT\\Functions\\TE3500-Analytics-Workbench",
                "C:\\Program Files (x86)\\Beckhoff\\TwinCAT\\Functions\\TE3520-Analytics-Service-Tool"
            };
            string[] patterns = new string[] { "*.tcaproj", "*.tcanalyticsproj", "*.tsproj" };
            foreach (string root in roots)
            {
                if (!Directory.Exists(root)) continue;
                foreach (string pat in patterns)
                {
                    string[] hits;
                    try { hits = Directory.GetFiles(root, pat, SearchOption.AllDirectories); }
                    catch { hits = null; }
                    if (hits == null) continue;
                    foreach (string hit in hits)
                    {
                        if (hit.IndexOf("\\Templates\\", StringComparison.OrdinalIgnoreCase) >= 0 ||
                            hit.IndexOf("/Templates/", StringComparison.OrdinalIgnoreCase) >= 0)
                        {
                            return hit;
                        }
                    }
                }
            }
            return null;
        }

        // Ensure-MeasurementScopeHelper (bridge L923-1018): load the TE130X
        // automation assembly so ScopeHelper can resolve IMeasurementScope by
        // reflection. Returns false (and callers throw 'tooling not installed') if
        // the assembly cannot be located/loaded.
        private static bool EnsureScopeHelper()
        {
            if (ScopeHelper.Available()) return true;
            string libPath = GetMeasurementLibPath();
            if (libPath == null) return false;
            try { Assembly.LoadFrom(libPath); }
            catch { return false; }
            return ScopeHelper.Available();
        }

        // Get-ScopeProjectObject (bridge L1023-1045): find the EnvDTE.Project by
        // Name in the open solution and return its .Object (the IMeasurementScope
        // automation object). These are SEPARATE EnvDTE.Project nodes, not System
        // Manager tree items.
        private static object GetScopeProjectObject(dynamic dte, string projectName)
        {
            if (string.IsNullOrWhiteSpace(projectName)) throw new BridgeException("project is required");
            dynamic solution = dte.Solution;
            if (solution == null || !((bool)solution.IsOpen)) throw new BridgeException("No solution is open");

            dynamic projects = solution.Projects;
            if (projects != null)
            {
                int count = (int)projects.Count;
                for (int i = 1; i <= count; i++)
                {
                    dynamic proj = null;
                    try { proj = projects.Item(i); }
                    catch { continue; }
                    if (proj == null) continue;
                    string pname = ComHelpers.SafeStr(delegate { return proj.Name; });
                    if (pname == projectName)
                    {
                        object obj = null;
                        try { obj = proj.Object; }
                        catch { }
                        if (obj == null) throw new BridgeException("Scope project '" + projectName + "' has no automation object (.Object is null)");
                        return obj;
                    }
                }
            }
            throw new BridgeException("Scope project not found in the open solution: " + projectName);
        }

        // Resolve-ScopeElement (bridge L1051-1069): walk a '^'-separated parentPath
        // of element names from the scope root, resolving each segment by name via
        // child enumeration. Empty path returns the root. LookUpChild is UNVERIFIED
        // and deliberately unused; enumeration is the only resolution.
        private static object ResolveScopeElement(object root, string elementPath)
        {
            object current = root;
            if (string.IsNullOrWhiteSpace(elementPath)) return current;
            string[] segments = elementPath.Split('^');
            foreach (string seg in segments)
            {
                if (string.IsNullOrWhiteSpace(seg)) continue;
                object[] children = ScopeHelper.Children(current);
                object match = null;
                foreach (object c in children)
                {
                    string cn = ScopeHelper.NameOf(c);
                    if (cn == seg) { match = c; break; }
                }
                if (match == null)
                {
                    throw new BridgeException("Scope element segment not found by name: '" + seg + "' (path '" + elementPath +
                        "'). Child enumeration is the only verified resolution; LookUpChild is unsupported. Restrict the path to existing named children.");
                }
                current = match;
            }
            return current;
        }

        // Get-ChildTreeItemByName equivalent: true if a direct child of the parent
        // tree item has the given name (1-based scan). Used by analytics dry-run.
        private static bool ChildExistsByName(dynamic parentItem, string childName)
        {
            int count = ComHelpers.ChildCount(parentItem);
            for (int i = 1; i <= count; i++)
            {
                dynamic child = ComHelpers.Child(parentItem, i);
                if (child == null) continue;
                string name = ComHelpers.SafeStr(delegate { return child.Name; });
                if (name == childName) return true;
            }
            return false;
        }

        // Assert-WellFormedChild (bridge L3192-3241): validate a child returned by
        // ITcSmTreeItem.CreateChild; on a malformed "ghost" do best-effort cleanup
        // (DeleteChild by the actual non-blank name) and THROW a descriptive error.
        // (Mirrors TreeActions.AssertWellFormedChild; duplicated to keep this group
        // self-contained.)
        private static void AssertWellFormedChild(dynamic parent, dynamic child, string requestedName, int subType, string parentPath)
        {
            string childActualName = ComHelpers.SafeStr(delegate { return child.Name; });
            string childPath = ComHelpers.SafeStr(delegate { return child.PathName; });

            string reason = null;
            if (child == null)
            {
                reason = "CreateChild returned null";
            }
            else if (string.IsNullOrWhiteSpace(childActualName))
            {
                reason = "returned child has a blank name";
            }
            else if (childActualName != requestedName)
            {
                reason = "returned child name '" + childActualName + "' does not match requested name '" + requestedName + "'";
            }
            else
            {
                string expectedPath = parentPath + "^" + requestedName;
                if (!string.IsNullOrWhiteSpace(childPath) && childPath != expectedPath)
                {
                    reason = "returned child path '" + childPath + "' is not under requested parent (expected '" + expectedPath + "')";
                }
            }

            if (reason == null) return;

            if (!string.IsNullOrWhiteSpace(childActualName))
            {
                try { parent.DeleteChild(childActualName); }
                catch { }
            }

            throw new BridgeException("CreateChild produced a malformed child (name='" + childActualName + "', path='" + childPath +
                "') for requested name='" + requestedName + "', subType=" + subType.ToString(System.Globalization.CultureInfo.InvariantCulture) +
                " under '" + parentPath + "' (" + reason + "). This usually means the subType/createInfo is not valid for this parent " +
                "(EtherCAT boxes typically require a proper createInfo). No usable child was created. If a stray blank-named child remains, " +
                "remove it in the XAE GUI or via close-without-save.");
        }

        // ===================================================================
        // ScopeHelper — C# port of the compiled Te1000MeasurementHelper shim
        // (bridge L936-1016). IMeasurementScope is a vtable/IUnknown interface
        // that cannot be late-bound via `dynamic`, so its members are invoked by
        // reflection against the interface type discovered (by name) in the loaded
        // TE130X automation assembly. Only the VERIFIED surface is exposed
        // (CreateChild/ChangeName/StartRecord/StopRecord); SaveSVD/ExportCSV/
        // LookUpChild are deliberately NOT exposed (UNVERIFIED).
        // ===================================================================
        private static class ScopeHelper
        {
            // Find the IMeasurementScope interface across all loaded assemblies.
            private static Type ScopeType()
            {
                foreach (Assembly a in AppDomain.CurrentDomain.GetAssemblies())
                {
                    Type t = null;
                    try
                    {
                        t = a.GetTypes().FirstOrDefault(delegate(Type x) { return x.IsInterface && x.Name == "IMeasurementScope"; });
                    }
                    catch { t = null; }
                    if (t != null) return t;
                }
                return null;
            }

            // True once the IMeasurementScope interface type is loadable.
            public static bool Available()
            {
                return ScopeType() != null;
            }

            public static bool Is(object o)
            {
                if (o == null) return false;
                Type t = ScopeType();
                return t != null && t.IsInstanceOfType(o);
            }

            // CreateChild(out object child, string name, int elementType) -> int rc.
            public static int CreateChild(object scope, out object child, string name, int elementType)
            {
                child = null;
                Type t = ScopeType();
                if (t == null) throw new InvalidOperationException("IMeasurementScope type not found");
                MethodInfo m = t.GetMethod("CreateChild");
                if (m == null) throw new MissingMethodException("IMeasurementScope.CreateChild");
                object[] args = new object[] { null, name == null ? "" : name, elementType };
                object rc = m.Invoke(scope, args);
                child = args[0];
                return rc == null ? 0 : Convert.ToInt32(rc);
            }

            public static int ChangeName(object el, string n)
            {
                Type t = ScopeType();
                MethodInfo m = t.GetMethod("ChangeName");
                if (m == null) throw new MissingMethodException("IMeasurementScope.ChangeName");
                object rc = m.Invoke(el, new object[] { n });
                return rc == null ? 0 : Convert.ToInt32(rc);
            }

            public static int StartRecord(object s)
            {
                Type t = ScopeType();
                MethodInfo m = t.GetMethod("StartRecord");
                if (m == null) throw new MissingMethodException("IMeasurementScope.StartRecord");
                object rc = m.Invoke(s, null);
                return rc == null ? 0 : Convert.ToInt32(rc);
            }

            public static int StopRecord(object s)
            {
                Type t = ScopeType();
                MethodInfo m = t.GetMethod("StopRecord");
                if (m == null) throw new MissingMethodException("IMeasurementScope.StopRecord");
                object rc = m.Invoke(s, null);
                return rc == null ? 0 : Convert.ToInt32(rc);
            }

            // Enumerate a parent scope element's children for name-walking. Tries
            // common collection members; returns an empty array if none resolve.
            public static object[] Children(object el)
            {
                if (el == null) return new object[0];
                Type t = el.GetType();
                string[] props = new string[] { "Children", "ChildCollection", "Items" };
                foreach (string p in props)
                {
                    try
                    {
                        PropertyInfo pi = t.GetProperty(p);
                        if (pi != null)
                        {
                            object col = pi.GetValue(el, null);
                            System.Collections.IEnumerable en = col as System.Collections.IEnumerable;
                            if (en != null)
                            {
                                return en.Cast<object>().ToArray();
                            }
                        }
                    }
                    catch { }
                }
                return new object[0];
            }

            public static string NameOf(object el)
            {
                if (el == null) return null;
                try
                {
                    PropertyInfo pi = el.GetType().GetProperty("Name");
                    if (pi != null)
                    {
                        object v = pi.GetValue(el, null);
                        return v == null ? null : v.ToString();
                    }
                }
                catch { }
                return null;
            }
        }
    }
}
