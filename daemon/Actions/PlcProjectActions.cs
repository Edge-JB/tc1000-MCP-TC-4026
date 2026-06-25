using System;
using System.Collections.Generic;
using System.Globalization;

namespace Te1000Daemon
{
    // plc_project actions.
    //
    // The PLC ROOT node is TIPC^<name>; the project INSTANCE node is its first
    // child. Each handler resolves a fresh tree-item RCW via ComHelpers.GetTreeItem
    // (matching the PS Get-TreeItem -> .Value) and passes the dynamic COM object to
    // the typed vtable helper PlcProjectHelper (PS Te1000PlcProjectHelper). We pass
    // a FRESH (non-cached) RCW because the typed-cast QI can E_NOINTERFACE on a
    // cached/reused RCW. Mutating actions invalidate the affected subtree.
    //
    // C#5-clean (no interpolation, no out var, no expression-bodied members).
    internal static class PlcProjectActions
    {
        public static void Register(Dictionary<string, ActionHandler> h)
        {
            h["plc_project_create"] = Create;
            h["plc_project_open"] = Open;
            h["plc_project_info"] = Info;
            h["plc_project_boot_flags"] = BootFlags;
            h["plc_project_generate_boot"] = GenerateBoot;
            h["plc_project_online"] = Online;
            h["plc_project_plcopen_export"] = PlcOpenExport;
            h["plc_project_plcopen_import"] = PlcOpenImport;
            h["plc_project_save_as_library"] = SaveAsLibrary;
        }

        // --- plc_project_create (L5629-5657) ---------------------------------
        private static Json.JObj Create(ActionContext ctx)
        {
            string name = ctx.Payload.Str("name");
            if (string.IsNullOrWhiteSpace(name)) throw new BridgeException("name is required");

            string template = ctx.Payload.Truthy("template") ? ctx.Payload.Str("template") : "Standard PLC Template";
            string before = ctx.Payload.Truthy("before") ? ctx.Payload.Str("before") : "";

            dynamic sm = ctx.SysManager();
            dynamic tipc = ComHelpers.GetTreeItem(sm, "TIPC");
            // subType 0 = copy-to-solution; vInfo carries the stock template NAME.
            dynamic child = tipc.CreateChild(name, 0, before, template);
            AssertWellFormedChild(tipc, child, name, 0, "TIPC");

            if (ctx.Payload.Has("save") && ctx.Payload.Bool("save"))
            {
                ctx.Dte().ExecuteCommand("File.SaveAll");
            }
            ctx.Cache.Invalidate("TIPC");

            var data = new Json.JObj();
            data["parentPath"] = "TIPC";
            data["pathName"] = "TIPC^" + name;
            data["child"] = ComHelpers.ConvertTreeItem(child);
            return data;
        }

        // --- plc_project_open (L5659-5699) -----------------------------------
        private static Json.JObj Open(ActionContext ctx)
        {
            string name = ctx.Payload.Str("name");
            string file = ctx.Payload.Str("file");
            if (string.IsNullOrWhiteSpace(name)) throw new BridgeException("name is required");
            if (string.IsNullOrWhiteSpace(file)) throw new BridgeException("file is required");
            if (!System.IO.File.Exists(file)) throw new BridgeException("PLC project file not found: " + file);

            int subType = 0;
            if (ctx.Payload.Has("subType")) subType = ctx.Payload.Int("subType", 0);
            string before = ctx.Payload.Truthy("before") ? ctx.Payload.Str("before") : "";

            dynamic sm = ctx.SysManager();
            dynamic tipc = ComHelpers.GetTreeItem(sm, "TIPC");
            // Same CreateChild route as create; vInfo = file path, subType selects
            // copy(0)/move(1)/use-in-place(2).
            dynamic child = tipc.CreateChild(name, subType, before, file);
            AssertWellFormedChild(tipc, child, name, subType, "TIPC");

            if (ctx.Payload.Has("save") && ctx.Payload.Bool("save"))
            {
                ctx.Dte().ExecuteCommand("File.SaveAll");
            }
            ctx.Cache.Invalidate("TIPC");

            var data = new Json.JObj();
            data["parentPath"] = "TIPC";
            data["pathName"] = "TIPC^" + name;
            data["subType"] = subType;
            data["child"] = ComHelpers.ConvertTreeItem(child);
            return data;
        }

        // --- plc_project_info (L5701-5730) -----------------------------------
        private static Json.JObj Info(ActionContext ctx)
        {
            dynamic sm = ctx.SysManager();
            string treePath = ResolvePlcRootPath(ctx, sm, ctx.Payload.Str("treePath"));
            dynamic plc = ComHelpers.GetTreeItem(sm, treePath);

            string nestedName = PlcProjectHelper.GetNestedProjectName((object)plc);
            string instanceName = PlcProjectHelper.GetInstanceName((object)plc);

            var data = new Json.JObj();
            data["treePath"] = treePath;
            data["name"] = ComHelpers.SafeStr(delegate { return plc.Name; });
            data["nestedProjectName"] = nestedName;
            data["instanceName"] = instanceName;
            data["childCount"] = ComHelpers.ChildCount(plc);
            return data;
        }

        // --- plc_project_boot_flags (L5732-5767) -----------------------------
        // Maps to SetBootFlags (config-only). ITcPlcProject lives on the PLC ROOT.
        private static Json.JObj BootFlags(ActionContext ctx)
        {
            dynamic sm = ctx.SysManager();
            string treePath = ResolvePlcRootPath(ctx, sm, ctx.Payload.Str("treePath"));
            dynamic item = ComHelpers.GetTreeItem(sm, treePath);

            bool hasAutostart = ctx.Payload.Has("autostart");
            bool autostart = hasAutostart ? ctx.Payload.Bool("autostart") : false;
            bool hasTmc = ctx.Payload.Has("tmcFileCopy");
            bool tmc = hasTmc ? ctx.Payload.Bool("tmcFileCopy") : false;

            object[] current;
            try
            {
                current = PlcProjectHelper.SetBootFlags((object)item, hasAutostart, autostart, hasTmc, tmc);
            }
            catch (Exception ex)
            {
                throw new BridgeException("node '" + treePath +
                    "' does not implement ITcPlcProject (use the PLC root node TIPC^<name>): " + ex.Message);
            }
            ctx.Cache.Invalidate(treePath);

            var data = new Json.JObj();
            data["treePath"] = treePath;
            data["bootProjectAutostart"] = Convert.ToBoolean(current[0]);
            data["tmcFileCopy"] = Convert.ToBoolean(current[1]);
            return data;
        }

        // --- plc_project_generate_boot (L5769-5803) --------------------------
        // Maps to Deploy. GUARD enforced in index.js (ALLOW_PLC_DOWNLOAD). The only
        // verb in this tool that writes toward the live target.
        private static Json.JObj GenerateBoot(ActionContext ctx)
        {
            dynamic sm = ctx.SysManager();
            string treePath = ResolvePlcRootPath(ctx, sm, ctx.Payload.Str("treePath"));
            dynamic plcProject = ComHelpers.GetTreeItem(sm, treePath);

            bool autostart = true;
            if (ctx.Payload.Has("autostart")) autostart = ctx.Payload.Bool("autostart");

            PlcProjectHelper.Deploy((object)plcProject, autostart, true);
            ctx.Cache.Invalidate(treePath);

            var data = new Json.JObj();
            data["treePath"] = treePath;
            data["bootProjectGenerated"] = true;
            data["bootProjectAutostart"] = autostart;
            data["targetNetId"] = ComHelpers.SafeStr(delegate { return sm.GetTargetNetId(); });
            data["note"] = "Boot project generated to the target boot directory. Restart the TwinCAT runtime (twincat_restart_runtime) to load and run it.";
            return data;
        }

        // --- plc_project_online (L5805-5861) ---------------------------------
        // GUARD enforced in index.js (ALLOW_PLC_DOWNLOAD for every command).
        private static Json.JObj Online(ActionContext ctx)
        {
            string command = ctx.Payload.Str("command");
            if (string.IsNullOrWhiteSpace(command)) throw new BridgeException("command is required");

            var elementMap = new Dictionary<string, string>(StringComparer.Ordinal);
            elementMap["login"] = "LoginCmd";
            elementMap["logout"] = "LogoutCmd";
            elementMap["start"] = "StartCmd";
            elementMap["stop"] = "StopCmd";
            elementMap["reset_cold"] = "ResetColdCmd";
            elementMap["reset_origin"] = "ResetOriginCmd";

            if (!elementMap.ContainsKey(command))
                throw new BridgeException("Unsupported online command: " + command);
            string el = elementMap[command];

            dynamic sm = ctx.SysManager();
            string treePath = ResolvePlcRootPath(ctx, sm, ctx.Payload.Str("treePath"));
            dynamic item = ComHelpers.GetTreeItem(sm, treePath);

            string xml = "<TreeItem><PlcProjectDef><" + el + "></" + el + "></PlcProjectDef></TreeItem>";
            try
            {
                item.ConsumeXml(xml);
            }
            catch (Exception)
            {
                string xmlError = null;
                try { xmlError = (string)item.GetLastXmlError(); }
                catch { xmlError = null; }
                if (!string.IsNullOrEmpty(xmlError))
                    throw new BridgeException("ConsumeXml failed for online command '" + command + "': " + xmlError);
                throw;
            }
            ctx.Cache.Invalidate(treePath);

            var data = new Json.JObj();
            data["treePath"] = treePath;
            data["command"] = command;
            data["executed"] = true;
            return data;
        }

        // --- plc_project_plcopen_export (L5863-5899) -------------------------
        // Maps to PlcOpenExport. ITcPlcIECProject on the project INSTANCE node.
        private static Json.JObj PlcOpenExport(ActionContext ctx)
        {
            string file = ctx.Payload.Str("file");
            if (string.IsNullOrWhiteSpace(file)) throw new BridgeException("file is required");
            string selection = ctx.Payload.Truthy("selection") ? ctx.Payload.Str("selection") : "";

            dynamic sm = ctx.SysManager();
            string treePath = ResolvePlcRootPath(ctx, sm, ctx.Payload.Str("treePath"));
            dynamic item = ComHelpers.GetTreeItem(sm, treePath);

            try
            {
                PlcProjectHelper.PlcOpenExport((object)item, file, selection);
            }
            catch (Exception ex)
            {
                throw new BridgeException("node '" + treePath +
                    "' does not implement ITcPlcIECProject (use the nested project instance node): " + ex.Message);
            }

            var data = new Json.JObj();
            data["treePath"] = treePath;
            data["file"] = file;
            data["selection"] = selection;
            data["exported"] = true;
            return data;
        }

        // --- plc_project_plcopen_import (L5901-5951) -------------------------
        // Maps to PlcOpenImport. options is a plain int (PLCIMPORTOPTIONS:
        // 0 NONE / 1 REPLACE / 2 RENAME / 3 SKIP), default 0. folderStructure
        // defaults true.
        private static Json.JObj PlcOpenImport(ActionContext ctx)
        {
            string file = ctx.Payload.Str("file");
            if (string.IsNullOrWhiteSpace(file)) throw new BridgeException("file is required");
            if (!System.IO.File.Exists(file)) throw new BridgeException("PLCopen XML file not found: " + file);

            int options = 0;
            if (ctx.Payload.Has("options")) options = ctx.Payload.Int("options", 0);
            string selection = ctx.Payload.Truthy("selection") ? ctx.Payload.Str("selection") : "";
            bool folderStructure = true;
            if (ctx.Payload.Has("folderStructure")) folderStructure = ctx.Payload.Bool("folderStructure");

            dynamic sm = ctx.SysManager();
            string treePath = ResolvePlcRootPath(ctx, sm, ctx.Payload.Str("treePath"));
            dynamic item = ComHelpers.GetTreeItem(sm, treePath);

            try
            {
                PlcProjectHelper.PlcOpenImport((object)item, file, options, selection, folderStructure);
            }
            catch (Exception ex)
            {
                throw new BridgeException("node '" + treePath +
                    "' does not implement ITcPlcIECProject (use the nested project instance node): " + ex.Message);
            }

            if (ctx.Payload.Has("save") && ctx.Payload.Bool("save"))
            {
                ctx.Dte().ExecuteCommand("File.SaveAll");
            }
            ctx.Cache.Invalidate(treePath);

            var data = new Json.JObj();
            data["treePath"] = treePath;
            data["file"] = file;
            data["options"] = options;
            data["imported"] = true;
            return data;
        }

        // --- plc_project_save_as_library (L5953-5991) ------------------------
        // Maps to SaveAsLibrary. ITcPlcIECProject on the project INSTANCE node.
        private static Json.JObj SaveAsLibrary(ActionContext ctx)
        {
            string file = ctx.Payload.Str("file");
            if (string.IsNullOrWhiteSpace(file)) throw new BridgeException("file is required");
            bool install = false;
            if (ctx.Payload.Has("install")) install = ctx.Payload.Bool("install");

            dynamic sm = ctx.SysManager();
            string treePath = ResolvePlcRootPath(ctx, sm, ctx.Payload.Str("treePath"));
            dynamic item = ComHelpers.GetTreeItem(sm, treePath);

            try
            {
                PlcProjectHelper.SaveAsLibrary((object)item, file, install);
            }
            catch (Exception ex)
            {
                throw new BridgeException("node '" + treePath +
                    "' does not implement ITcPlcIECProject (use the nested project instance node): " + ex.Message);
            }

            var data = new Json.JObj();
            data["treePath"] = treePath;
            data["file"] = file;
            data["installed"] = install;
            return data;
        }

        // ===================================================================
        // private helpers
        // ===================================================================

        // Resolve-PlcRootPath (L1164-1177): if a path is supplied use it as-is;
        // otherwise default to TIPC^<firstChildName>, throwing if no PLC project
        // exists under TIPC.
        private static string ResolvePlcRootPath(ActionContext ctx, dynamic sm, string path)
        {
            if (!string.IsNullOrWhiteSpace(path)) return path;

            dynamic tipc = ComHelpers.GetTreeItem(sm, "TIPC");
            if (ComHelpers.ChildCount(tipc) < 1) throw new BridgeException("No PLC project found under TIPC");
            dynamic first = ComHelpers.Child(tipc, 1);
            string firstName = ComHelpers.SafeStr(delegate { return first.Name; });
            return "TIPC^" + firstName;
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
