using System;
using System.Globalization;
using System.Collections;
using System.Collections.Generic;
using TCatSysManagerLib;

namespace Te1000Daemon
{
    // twincat_module_* and twincat_cpp_* actions ported from te1000-bridge.ps1
    // (L8941-9328).
    //
    // module actions operate under TIRC^TcCOM Objects (create/get_xml/set_xml/
    // enable_symbols) or via the typed ITcModuleManager3 enumeration (list) and
    // ITcModuleInstance2.SetModuleContext (set_context). cpp actions create/open
    // C++ projects under TIXC, drive TMC codegen / publish via ConsumeXml, and
    // build a named C++ project via Solution.SolutionBuild.BuildProject.
    //
    // module_list / module_set_context need the vtable-only typed COM interfaces
    // (ITcSysManager4 / ITcModuleManager3 / ITcModuleInstance2) that late-bound
    // dynamic cannot QI — these mirror the PS bridge's compiled Te1000ModuleHelper
    // (L1121-1157). The TCatSysManagerLib reference is EmbedInteropTypes=true.
    //
    // index.js enforces the confirm tokens for module_set_context
    // (ALLOW_TWINCAT_MODULE_CONTEXT) and cpp_publish (ALLOW_CPP_PUBLISH) BEFORE
    // calling the bridge; the PS handlers do NOT re-check, so neither do we.
    //
    // C#5-clean (no interpolation, no out var, no expression-bodied members).
    internal static class ModuleCppActions
    {
        public static void Register(Dictionary<string, ActionHandler> h)
        {
            h["twincat_module_list"] = ModuleList;
            h["twincat_module_create"] = ModuleCreate;
            h["twincat_module_get_xml"] = ModuleGetXml;
            h["twincat_module_set_xml"] = ModuleSetXml;
            h["twincat_module_enable_symbols"] = ModuleEnableSymbols;
            h["twincat_module_set_context"] = ModuleSetContext;
            h["twincat_cpp_create_project"] = CppCreateProject;
            h["twincat_cpp_create_module"] = CppCreateModule;
            h["twincat_cpp_open"] = CppOpen;
            h["twincat_cpp_consume_xml"] = CppConsumeXml;
            h["twincat_cpp_set_props"] = CppSetProps;
            h["twincat_cpp_build_project"] = CppBuildProject;
            h["twincat_cpp_publish"] = CppPublish;
        }

        // ---- twincat_module_list (L8941-8969) --------------------------------
        // Port of Te1000ModuleHelper.List (L1130-1148): enumerate ITcModuleInstance2
        // under the module manager. There is no 'ObjectId' member -> objectId mirrors
        // oid. An empty cell yields an empty list (not an error).
        private static Json.JObj ModuleList(ActionContext ctx)
        {
            dynamic sm = ctx.SysManager();
            ITcSysManager4 typedSm = (ITcSysManager4)sm;
            ITcModuleManager3 mgr = (ITcModuleManager3)typedSm.GetModuleManager();

            var modules = new Json.JArr();
            IEnumerator en = ((IEnumerable)mgr).GetEnumerator();
            while (en.MoveNext())
            {
                ITcModuleInstance2 mi = en.Current as ITcModuleInstance2;
                if (mi == null) continue;

                uint oid = mi.oid;
                var m = new Json.JObj();
                m["moduleTypeName"] = mi.ModuleTypeName;
                m["moduleInstanceName"] = mi.ModuleInstanceName;
                m["classId"] = mi.ClassID.ToString();
                m["oid"] = (long)oid;
                m["objectId"] = (long)oid;
                m["parentOid"] = (long)mi.ParentOID;
                modules.Add(m);
            }

            var data = new Json.JObj();
            data["count"] = modules.Count;
            data["modules"] = modules;
            return data;
        }

        // ---- twincat_module_create (L8971-8996) ------------------------------
        private static Json.JObj ModuleCreate(ActionContext ctx)
        {
            string parentPath = "TIRC^TcCOM Objects";
            string name = ctx.Payload.Str("name");
            if (string.IsNullOrWhiteSpace(name)) throw new BridgeException("name is required");
            string by = ctx.Payload.Str("by");
            if (by != "classid" && by != "name") throw new BridgeException("by must be 'classid' or 'name'");
            string id = ctx.Payload.Str("id");
            if (string.IsNullOrWhiteSpace(id)) throw new BridgeException("id is required");
            int subType = (by == "classid") ? 0 : 1;
            string before = ctx.Payload.Truthy("before") ? ctx.Payload.Str("before") : "";

            dynamic sm = ctx.SysManager();
            dynamic parent = ComHelpers.GetTreeItem(sm, parentPath);
            dynamic child = parent.CreateChild(name, subType, before, id);
            AssertWellFormedChild(parent, child, name, subType, parentPath);

            ctx.Cache.Invalidate(parentPath);

            var data = new Json.JObj();
            data["parentPath"] = parentPath;
            data["child"] = ComHelpers.ConvertTreeItem(child);
            return data;
        }

        // ---- twincat_module_get_xml (L8998-9012) -----------------------------
        private static Json.JObj ModuleGetXml(ActionContext ctx)
        {
            string path = ctx.Payload.Str("path");
            if (string.IsNullOrWhiteSpace(path)) throw new BridgeException("path is required");

            dynamic sm = ctx.SysManager();
            dynamic item = ComHelpers.GetTreeItem(sm, path);
            string xml = ComHelpers.StripTreeImage(ComHelpers.ProduceXml(item));

            var data = new Json.JObj();
            data["treePath"] = path;
            data["xml"] = xml;
            return data;
        }

        // ---- twincat_module_set_xml (L9014-9035) -----------------------------
        private static Json.JObj ModuleSetXml(ActionContext ctx)
        {
            string path = ctx.Payload.Str("path");
            string xml = ctx.Payload.Str("xml");
            if (string.IsNullOrWhiteSpace(path)) throw new BridgeException("path is required");
            if (string.IsNullOrWhiteSpace(xml)) throw new BridgeException("xml is required");
            bool returnXml = ctx.Payload.Has("returnXml") && ctx.Payload.Bool("returnXml");

            dynamic sm = ctx.SysManager();
            dynamic item = SetTreeItemXmlInternal(ctx, sm, path, xml);

            var data = new Json.JObj();
            data["treePath"] = path;
            if (returnXml)
            {
                data["xml"] = ComHelpers.StripTreeImage(ComHelpers.ProduceXml(item));
            }
            return data;
        }

        // ---- twincat_module_enable_symbols (L9037-9088) ----------------------
        // Read ProduceXml, set CreateSymbol / CreateSymbols attributes on the
        // requested parameter / data-area nodes, ConsumeXml back if changed.
        private static Json.JObj ModuleEnableSymbols(ActionContext ctx)
        {
            string path = ctx.Payload.Str("path");
            if (string.IsNullOrWhiteSpace(path)) throw new BridgeException("path is required");
            bool doParams = ctx.Payload.Has("parameters") && ctx.Payload.Bool("parameters");
            bool doAreas = ctx.Payload.Has("dataAreas") && ctx.Payload.Bool("dataAreas");
            bool returnXml = ctx.Payload.Has("returnXml") && ctx.Payload.Bool("returnXml");

            dynamic sm = ctx.SysManager();
            dynamic item = ComHelpers.GetTreeItem(sm, path);

            System.Xml.XmlDocument doc = new System.Xml.XmlDocument();
            doc.LoadXml(ComHelpers.ProduceXml(item));
            bool changed = false;

            if (doParams)
            {
                System.Xml.XmlNodeList nodes = doc.SelectNodes("//Parameters//Parameter");
                if (nodes != null)
                {
                    foreach (System.Xml.XmlNode n in nodes)
                    {
                        System.Xml.XmlElement el = n as System.Xml.XmlElement;
                        if (el == null) continue;
                        el.SetAttribute("CreateSymbol", "true");
                        changed = true;
                    }
                }
            }
            if (doAreas)
            {
                System.Xml.XmlNodeList nodes = doc.SelectNodes("//DataAreas//DataArea/AreaNo");
                if (nodes != null)
                {
                    foreach (System.Xml.XmlNode n in nodes)
                    {
                        System.Xml.XmlElement el = n as System.Xml.XmlElement;
                        if (el == null) continue;
                        el.SetAttribute("CreateSymbols", "true");
                        changed = true;
                    }
                }
            }

            if (changed)
            {
                ComHelpers.ConsumeXml(item, doc.OuterXml);
                ctx.Cache.Invalidate(path);
            }

            var data = new Json.JObj();
            data["treePath"] = path;
            data["parameters"] = doParams;
            data["dataAreas"] = doAreas;
            data["changed"] = changed;
            if (returnXml)
            {
                data["xml"] = ComHelpers.StripTreeImage(ComHelpers.ProduceXml(item));
            }
            return data;
        }

        // ---- twincat_module_set_context (L9090-9116) -------------------------
        // Port of Te1000ModuleHelper.SetContext (L1153-1156): typed
        // ITcModuleInstance2.SetModuleContext(contextId, taskObjectId) — both are
        // DECIMAL oids. Confirm token enforced upstream in index.js.
        private static Json.JObj ModuleSetContext(ActionContext ctx)
        {
            string path = ctx.Payload.Str("path");
            if (string.IsNullOrWhiteSpace(path)) throw new BridgeException("path is required");
            if (!ctx.Payload.Has("taskObjectId")) throw new BridgeException("taskObjectId is required");
            int taskObjectId = ctx.Payload.Int("taskObjectId", 0);
            int contextId = (ctx.Payload.Has("contextId")) ? ctx.Payload.Int("contextId", 0) : 0;

            dynamic sm = ctx.SysManager();
            dynamic item = ComHelpers.GetTreeItem(sm, path);

            ((ITcModuleInstance2)item).SetModuleContext((uint)contextId, (uint)taskObjectId);

            ctx.Cache.Invalidate(path);

            var data = new Json.JObj();
            data["treePath"] = path;
            data["contextId"] = contextId;
            data["taskObjectId"] = taskObjectId;
            data["contextSet"] = true;
            return data;
        }

        // ---- twincat_cpp_create_project (L9118-9140) -------------------------
        private static Json.JObj CppCreateProject(ActionContext ctx)
        {
            string parentPath = "TIXC";
            string name = ctx.Payload.Str("name");
            string template = ctx.Payload.Str("template");
            if (string.IsNullOrWhiteSpace(name)) throw new BridgeException("name is required");
            if (string.IsNullOrWhiteSpace(template)) throw new BridgeException("template is required");
            string before = ctx.Payload.Truthy("before") ? ctx.Payload.Str("before") : "";

            dynamic sm = ctx.SysManager();
            dynamic cpp = ComHelpers.GetTreeItem(sm, parentPath);
            dynamic child = cpp.CreateChild(name, 0, before, template);
            AssertWellFormedChild(cpp, child, name, 0, parentPath);

            ctx.Cache.Invalidate(parentPath);

            var data = new Json.JObj();
            data["parentPath"] = parentPath;
            data["child"] = ComHelpers.ConvertTreeItem(child);
            return data;
        }

        // ---- twincat_cpp_create_module (L9142-9165) --------------------------
        private static Json.JObj CppCreateModule(ActionContext ctx)
        {
            string parentPath = ctx.Payload.Str("projectPath");
            string name = ctx.Payload.Str("name");
            if (string.IsNullOrWhiteSpace(parentPath)) throw new BridgeException("projectPath is required");
            if (string.IsNullOrWhiteSpace(name)) throw new BridgeException("name is required");
            PathUtil.AssertNotSafetyPath(parentPath);
            string template = (ctx.Payload.Has("template") && !string.IsNullOrWhiteSpace(ctx.Payload.Str("template")))
                ? ctx.Payload.Str("template") : "TwinCAT Class Wizard";
            string before = ctx.Payload.Truthy("before") ? ctx.Payload.Str("before") : "";

            dynamic sm = ctx.SysManager();
            dynamic proj = ComHelpers.GetTreeItem(sm, parentPath);
            dynamic child = proj.CreateChild(name, 0, before, template);
            AssertWellFormedChild(proj, child, name, 0, parentPath);

            ctx.Cache.Invalidate(parentPath);

            var data = new Json.JObj();
            data["parentPath"] = parentPath;
            data["child"] = ComHelpers.ConvertTreeItem(child);
            return data;
        }

        // ---- twincat_cpp_open (L9167-9198) -----------------------------------
        // name MUST be '' (C++ projects cannot be renamed on open), so
        // Assert-WellFormedChild is intentionally bypassed in favor of a manual
        // non-null / non-blank ghost check.
        private static Json.JObj CppOpen(ActionContext ctx)
        {
            string file = ctx.Payload.Str("file");
            if (string.IsNullOrWhiteSpace(file)) throw new BridgeException("file is required");
            if (!System.IO.File.Exists(file)) throw new BridgeException("C++ project file not found: " + file);
            int subType = (ctx.Payload.Has("subType")) ? ctx.Payload.Int("subType", 0) : 0;
            if (subType != 0 && subType != 1 && subType != 2) throw new BridgeException("subType must be 0, 1, or 2");
            string before = ctx.Payload.Truthy("before") ? ctx.Payload.Str("before") : "";

            dynamic sm = ctx.SysManager();
            dynamic cpp = ComHelpers.GetTreeItem(sm, "TIXC");
            dynamic child = cpp.CreateChild("", subType, before, file);
            if (child == null) throw new BridgeException("CreateChild returned null opening C++ project");
            string actualName = ComHelpers.SafeStr(delegate { return child.Name; });
            if (string.IsNullOrWhiteSpace(actualName))
            {
                throw new BridgeException("open produced a ghost (blank name) - check the .vcxproj/.tczip path and subType (" +
                    file + ", subType=" + subType.ToString(CultureInfo.InvariantCulture) + ")");
            }

            ctx.Cache.Invalidate("TIXC");

            var data = new Json.JObj();
            data["parentPath"] = "TIXC";
            data["file"] = file;
            data["subType"] = subType;
            data["child"] = ComHelpers.ConvertTreeItem(child);
            return data;
        }

        // ---- twincat_cpp_consume_xml (L9200-9218) ----------------------------
        // Trigger the TMC code generator on a C++ project via ConsumeXml.
        private static Json.JObj CppConsumeXml(ActionContext ctx)
        {
            string projectPath = ctx.Payload.Str("projectPath");
            if (string.IsNullOrWhiteSpace(projectPath)) throw new BridgeException("projectPath is required");
            PathUtil.AssertNotSafetyPath(projectPath);

            dynamic sm = ctx.SysManager();
            string xml = "<TreeItem><CppProjectDef><StartTmcCodeGenerator><Active>true</Active></StartTmcCodeGenerator></CppProjectDef></TreeItem>";
            SetTreeItemXmlInternal(ctx, sm, projectPath, xml);

            var data = new Json.JObj();
            data["projectPath"] = projectPath;
            data["tmcCodeGenerated"] = true;
            return data;
        }

        // ---- twincat_cpp_set_props (L9220-9252) ------------------------------
        private static Json.JObj CppSetProps(ActionContext ctx)
        {
            string projectPath = ctx.Payload.Str("projectPath");
            if (string.IsNullOrWhiteSpace(projectPath)) throw new BridgeException("projectPath is required");
            PathUtil.AssertNotSafetyPath(projectPath);

            string inner = "";
            if (ctx.Payload.Has("bootProjectEncryption") && !string.IsNullOrWhiteSpace(ctx.Payload.Str("bootProjectEncryption")))
            {
                string v = ctx.Payload.Str("bootProjectEncryption");
                if (v != "None" && v != "Target") throw new BridgeException("bootProjectEncryption must be None or Target");
                inner += "<BootProjectEncryption>" + v + "</BootProjectEncryption>";
            }
            if (ctx.Payload.Has("saveProjectSources"))
            {
                string b = ctx.Payload.Bool("saveProjectSources") ? "true" : "false";
                inner += "<TargetArchiveSettings><SaveProjectSources>" + b + "</SaveProjectSources></TargetArchiveSettings>" +
                         "<FileArchiveSettings><SaveProjectSources>" + b + "</SaveProjectSources></FileArchiveSettings>";
            }
            if (string.IsNullOrEmpty(inner))
            {
                throw new BridgeException("set_props needs at least one of bootProjectEncryption / saveProjectSources");
            }

            dynamic sm = ctx.SysManager();
            string xml = "<TreeItem><CppProjectDef>" + inner + "</CppProjectDef></TreeItem>";
            SetTreeItemXmlInternal(ctx, sm, projectPath, xml);

            var data = new Json.JObj();
            data["projectPath"] = projectPath;
            data["propsApplied"] = true;
            return data;
        }

        // ---- twincat_cpp_build_project (L9254-9304) --------------------------
        // BuildProject wants the project UniqueName, not the display name; resolve
        // it by scanning Solution.Projects. Polls via Wait-ForBuildFinish when
        // waitForFinish. Does not mutate the tree structure (no cache invalidate).
        private static Json.JObj CppBuildProject(ActionContext ctx)
        {
            string projectName = ctx.Payload.Str("projectName");
            if (string.IsNullOrWhiteSpace(projectName)) throw new BridgeException("projectName is required");
            string config = (ctx.Payload.Has("config") && !string.IsNullOrWhiteSpace(ctx.Payload.Str("config")))
                ? ctx.Payload.Str("config") : "Release|TwinCAT RT (x64)";
            bool wait = (ctx.Payload.Has("waitForFinish")) ? ctx.Payload.Bool("waitForFinish") : true;
            int timeoutMs = (ctx.Payload.Has("timeoutMs")) ? ctx.Payload.Int("timeoutMs", 1800000) : 1800000;

            dynamic dte = ctx.Dte(true);
            Json.JObj solution = GetSolutionInfo(dte);
            if (!solution.Bool("isOpen")) throw new BridgeException("No solution is open in XAE");

            string unique = null;
            dynamic projects = dte.Solution.Projects;
            int projCount = (int)projects.Count;
            for (int i = 1; i <= projCount; i++)
            {
                dynamic proj = projects.Item(i);
                if (proj == null) continue;
                dynamic p = proj;
                string pName = ComHelpers.SafeStr(delegate { return p.Name; });
                string pUnique = ComHelpers.SafeStr(delegate { return p.UniqueName; });
                if (pName == projectName || pUnique == projectName)
                {
                    unique = !string.IsNullOrWhiteSpace(pUnique) ? pUnique : pName;
                    break;
                }
            }
            if (string.IsNullOrWhiteSpace(unique)) throw new BridgeException("C++ project not found in solution: " + projectName);

            dynamic solutionBuild = dte.Solution.SolutionBuild;
            solutionBuild.BuildProject(config, unique, wait);

            Json.JObj build;
            if (wait)
            {
                build = WaitForBuildFinish(solutionBuild, timeoutMs);
            }
            else
            {
                build = new Json.JObj();
                build["buildState"] = (int)solutionBuild.BuildState;
                build["lastBuildInfo"] = (object)SafeNullableInt(delegate { return solutionBuild.LastBuildInfo; });
            }

            var data = new Json.JObj();
            data["projectName"] = projectName;
            data["uniqueName"] = unique;
            data["config"] = config;
            data["waited"] = wait;
            data["build"] = build;
            return data;
        }

        // ---- twincat_cpp_publish (L9306-9328) --------------------------------
        // Confirm token (ALLOW_CPP_PUBLISH) enforced upstream in index.js; the PS
        // handler does not re-verify, so neither do we.
        private static Json.JObj CppPublish(ActionContext ctx)
        {
            string projectPath = ctx.Payload.Str("projectPath");
            if (string.IsNullOrWhiteSpace(projectPath)) throw new BridgeException("projectPath is required");
            PathUtil.AssertNotSafetyPath(projectPath);

            dynamic sm = ctx.SysManager();
            string xml = "<TreeItem><CppProjectDef><PublishModules><Active>true</Active></PublishModules></CppProjectDef></TreeItem>";
            SetTreeItemXmlInternal(ctx, sm, projectPath, xml);

            var data = new Json.JObj();
            data["projectPath"] = projectPath;
            data["published"] = true;
            data["note"] = "Modules built for all platforms and exported. Does not activate/restart the runtime.";
            return data;
        }

        // ---- shared helpers --------------------------------------------------

        // Set-TreeItemXml (L3243-3262): ConsumeXml with GetLastXmlError surfacing,
        // then invalidate the target subtree. Returns the live item.
        private static dynamic SetTreeItemXmlInternal(ActionContext ctx, dynamic sm, string targetPath, string xml)
        {
            dynamic item = ComHelpers.GetTreeItem(sm, targetPath);
            ComHelpers.ConsumeXml(item, xml);
            ctx.Cache.Invalidate(targetPath);
            return item;
        }

        // Get-SolutionInfo (L581-601): {isOpen, fullName}.
        private static Json.JObj GetSolutionInfo(dynamic dte)
        {
            dynamic solution = dte.Solution;
            string fullName = null;
            bool isOpen = false;
            bool isOpenResolved = false;

            try { fullName = (string)solution.FullName; }
            catch { }

            try { isOpen = (bool)solution.IsOpen; isOpenResolved = true; }
            catch { isOpenResolved = false; }

            if (!isOpenResolved)
            {
                isOpen = !string.IsNullOrWhiteSpace(fullName);
            }

            var o = new Json.JObj();
            o["isOpen"] = isOpen;
            o["fullName"] = fullName;
            return o;
        }

        // Wait-ForBuildFinish (L678-693): poll until BuildState != 2.
        private static Json.JObj WaitForBuildFinish(dynamic solutionBuild, int timeoutMs)
        {
            DateTime deadline = DateTime.Now.AddMilliseconds(timeoutMs);
            while (DateTime.Now < deadline)
            {
                int state = (int)solutionBuild.BuildState;
                if (state != 2)
                {
                    var done = new Json.JObj();
                    done["buildState"] = state;
                    done["lastBuildInfo"] = (int)solutionBuild.LastBuildInfo;
                    return done;
                }
                System.Threading.Thread.Sleep(500);
            }
            throw new BridgeException("Timed out waiting for build completion after " + timeoutMs + " ms");
        }

        // Get-SafeValue { [int]$x }: returns null on failure (matches PS null shape).
        private static object SafeNullableInt(Func<object> f)
        {
            try
            {
                object v = f();
                if (v == null) return null;
                return (object)ComHelpers.ToInt(v);
            }
            catch { return null; }
        }

        // Assert-WellFormedChild (L3192-3241): validate a child returned by
        // CreateChild; on a malformed "ghost" do best-effort cleanup and THROW.
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
                "') for requested name='" + requestedName + "', subType=" + subType.ToString(CultureInfo.InvariantCulture) +
                " under '" + parentPath + "' (" + reason + "). This usually means the subType/createInfo is not valid for this parent " +
                "(EtherCAT boxes typically require a proper createInfo). No usable child was created. If a stray blank-named child remains, " +
                "remove it in the XAE GUI or via close-without-save.");
        }
    }
}
