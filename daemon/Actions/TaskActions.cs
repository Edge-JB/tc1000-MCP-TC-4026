using System;
using System.Collections.Generic;
using System.Globalization;
using System.Xml;

namespace Te1000Daemon
{
    // tc_task actions.
    //
    // Real-time tasks live under the TIRT collection node; the project-wide
    // real-time/router settings live under TIRS. list/get read the tree; create
    // uses ITcSmTreeItem.CreateChild; set_params / set_rt_settings / bind_cpu push
    // a <TreeItem>...</TreeItem> ConsumeXml envelope (mirrors PS Set-TreeItemXml,
    // i.e. ComHelpers.ConsumeXml which surfaces GetLastXmlError exactly like PS).
    //
    // get/set_linked_task target ITcPlcTaskReference, a vtable interface that lives
    // on a task-reference sub-node (e.g. PlcTask) under the nested PLC project, NOT
    // the PLC root. dynamic cannot QI to it, so the typed read/write goes through
    // PlcProjectHelper.GetLinkedTask / .SetLinkedTask, and the candidate node path
    // is resolved with a FRESH RCW per attempt (cached RCWs QI-fail E_NOINTERFACE).
    //
    // Mutating actions invalidate the affected subtree in the tree cache.
    //
    // C#5-clean (no interpolation, no out var, no expression-bodied members).
    internal static class TaskActions
    {
        public static void Register(Dictionary<string, ActionHandler> h)
        {
            h["tc_task_list"] = List;
            h["tc_task_get"] = Get;
            h["tc_task_create"] = Create;
            h["tc_task_set_params"] = SetParams;
            h["tc_task_add_image_var"] = AddImageVar;
            h["tc_task_get_rt_settings"] = GetRtSettings;
            h["tc_task_set_rt_settings"] = SetRtSettings;
            h["tc_task_bind_cpu"] = BindCpu;
            h["tc_task_get_linked_task"] = GetLinkedTask;
            h["tc_task_set_linked_task"] = SetLinkedTask;
        }

        // --- tc_task_list (L7484-7503) ---------------------------------------
        private static Json.JObj List(ActionContext ctx)
        {
            dynamic sm = ctx.SysManager();
            dynamic tirt = ctx.Cache.LookupItem(sm, "TIRT");
            int count = ComHelpers.ChildCount(tirt);
            var tasks = new Json.JArr();
            for (int i = 1; i <= count; i++)
            {
                dynamic child = ComHelpers.Child(tirt, i);
                if (child == null) continue;
                tasks.Add(ComHelpers.ConvertTreeItem(child));
            }

            var data = new Json.JObj();
            data["count"] = count;
            data["tasks"] = tasks;
            return data;
        }

        // --- tc_task_get (L7505-7560) ----------------------------------------
        private static Json.JObj Get(ActionContext ctx)
        {
            string treePath = ctx.Payload.Str("path");
            if (string.IsNullOrWhiteSpace(treePath)) throw new BridgeException("path is required");

            bool summary = false;
            if (ctx.Payload.Has("summary")) summary = ctx.Payload.Bool("summary");

            dynamic sm = ctx.SysManager();
            dynamic item = ctx.Cache.LookupItem(sm, treePath);
            string xml = ComHelpers.StripTreeImage(ComHelpers.ProduceXml(item));

            if (!summary)
            {
                var d = new Json.JObj();
                d["treePath"] = treePath;
                d["xml"] = xml;
                return d;
            }

            // Compact summary: identity + parsed TaskDef child tags (best-effort
            // name->text map of leaf elements).
            Json.JObj identity = ComHelpers.ConvertTreeItem(item);
            var taskDef = new Json.JObj();
            if (!string.IsNullOrEmpty(xml))
            {
                try
                {
                    XmlDocument doc = new XmlDocument();
                    doc.LoadXml(xml);
                    XmlNode node = doc.SelectSingleNode("//TaskDef");
                    if (node != null)
                    {
                        foreach (XmlNode childNode in node.ChildNodes)
                        {
                            if (childNode.NodeType != XmlNodeType.Element) continue;
                            if (childNode.HasChildNodes && childNode.ChildNodes.Count > 1) continue;
                            taskDef[childNode.Name] = childNode.InnerText;
                        }
                    }
                }
                catch
                {
                    taskDef = new Json.JObj();
                }
            }

            var data = new Json.JObj();
            data["treePath"] = treePath;
            data["identity"] = identity;
            data["taskDef"] = taskDef;
            return data;
        }

        // --- tc_task_create (L7562-7615) -------------------------------------
        private static Json.JObj Create(ActionContext ctx)
        {
            string name = ctx.Payload.Str("name");
            if (string.IsNullOrWhiteSpace(name)) throw new BridgeException("name is required");

            // withImage defaults true (subType 0). withImage==false -> subType 1.
            int subType = 0;
            if (ctx.Payload.Has("withImage") && ctx.Payload.Bool("withImage") == false) subType = 1;
            string before = ctx.Payload.Truthy("before") ? ctx.Payload.Str("before") : "";

            dynamic sm = ctx.SysManager();
            dynamic tirt = ComHelpers.GetTreeItem(sm, "TIRT");
            dynamic child = tirt.CreateChild(name, subType, before, null);
            AssertWellFormedChild(tirt, child, name, subType, "TIRT");

            bool paramsApplied = false;
            bool hasCycle = ctx.Payload.Has("cycleTimeUs") && ctx.Payload["cycleTimeUs"] != null;
            bool hasPriority = ctx.Payload.Has("priority") && ctx.Payload["priority"] != null;
            if (hasCycle || hasPriority)
            {
                string frag = "";
                if (hasCycle)
                {
                    long ticks = (long)(Convert.ToDouble(ctx.Payload["cycleTimeUs"], CultureInfo.InvariantCulture) * 10);
                    frag += "<CycleTime>" + ticks.ToString(CultureInfo.InvariantCulture) + "</CycleTime>";
                }
                if (hasPriority)
                {
                    frag += "<Priority>" + ctx.Payload.Int("priority").ToString(CultureInfo.InvariantCulture) + "</Priority>";
                }
                string x = "<TreeItem><TaskDef>" + frag + "</TaskDef></TreeItem>";
                // ComHelpers.ConsumeXml surfaces GetLastXmlError; the PS here prefixes
                // "applying task params" -- replicate that wording on failure.
                try
                {
                    child.ConsumeXml(x);
                }
                catch (Exception)
                {
                    string xmlError = null;
                    try { xmlError = (string)child.GetLastXmlError(); }
                    catch { xmlError = null; }
                    if (!string.IsNullOrEmpty(xmlError))
                        throw new BridgeException("ConsumeXml failed applying task params: " + xmlError);
                    throw;
                }
                paramsApplied = true;
            }

            if (ctx.Payload.Has("save") && ctx.Payload.Bool("save"))
            {
                ctx.Dte().ExecuteCommand("File.SaveAll");
            }
            ctx.Cache.Invalidate("TIRT");

            var data = new Json.JObj();
            data["parentPath"] = "TIRT";
            data["child"] = ComHelpers.ConvertTreeItem(child);
            data["paramsApplied"] = paramsApplied;
            return data;
        }

        // --- tc_task_set_params (L7617-7661) ---------------------------------
        private static Json.JObj SetParams(ActionContext ctx)
        {
            string treePath = ctx.Payload.Str("path");
            if (string.IsNullOrWhiteSpace(treePath)) throw new BridgeException("path is required");

            bool hasXml = ctx.Payload.Has("xml") && !string.IsNullOrWhiteSpace(ctx.Payload.Str("xml"));
            string x;
            if (hasXml)
            {
                x = ctx.Payload.Str("xml");
            }
            else
            {
                string frag = "";
                if (ctx.Payload.Has("cycleTimeUs") && ctx.Payload["cycleTimeUs"] != null)
                {
                    long ticks = (long)(Convert.ToDouble(ctx.Payload["cycleTimeUs"], CultureInfo.InvariantCulture) * 10);
                    frag += "<CycleTime>" + ticks.ToString(CultureInfo.InvariantCulture) + "</CycleTime>";
                }
                if (ctx.Payload.Has("priority") && ctx.Payload["priority"] != null)
                {
                    frag += "<Priority>" + ctx.Payload.Int("priority").ToString(CultureInfo.InvariantCulture) + "</Priority>";
                }
                if (ctx.Payload.Has("autoStart") && ctx.Payload["autoStart"] != null)
                {
                    frag += "<AutoStart>" + (ctx.Payload.Bool("autoStart") ? "true" : "false") + "</AutoStart>";
                }
                if (string.IsNullOrEmpty(frag))
                    throw new BridgeException("set_params requires xml, or at least one of cycleTimeUs / priority / autoStart");
                x = "<TreeItem><TaskDef>" + frag + "</TaskDef></TreeItem>";
            }

            bool returnXml = false;
            if (ctx.Payload.Has("returnXml")) returnXml = ctx.Payload.Bool("returnXml");

            dynamic sm = ctx.SysManager();
            dynamic item = SetTreeItemXml(sm, treePath, x);

            var data = new Json.JObj();
            data["treePath"] = treePath;
            if (returnXml) data["xml"] = ComHelpers.StripTreeImage(ComHelpers.ProduceXml(item));

            if (ctx.Payload.Has("save") && ctx.Payload.Bool("save"))
            {
                ctx.Dte().ExecuteCommand("File.SaveAll");
            }
            ctx.Cache.Invalidate(treePath);
            return data;
        }

        // --- tc_task_add_image_var (L7663-7690) ------------------------------
        private static Json.JObj AddImageVar(ActionContext ctx)
        {
            string treePath = ctx.Payload.Str("path");
            string varName = ctx.Payload.Str("varName");
            string dataType = ctx.Payload.Str("dataType");
            if (string.IsNullOrWhiteSpace(treePath)) throw new BridgeException("path is required");
            if (string.IsNullOrWhiteSpace(varName)) throw new BridgeException("varName is required");
            if (string.IsNullOrWhiteSpace(dataType)) throw new BridgeException("dataType is required");

            int start = -1;
            if (ctx.Payload.Has("startAddress") && ctx.Payload["startAddress"] != null)
                start = ctx.Payload.Int("startAddress");

            dynamic sm = ctx.SysManager();
            dynamic node = ComHelpers.GetTreeItem(sm, treePath);
            dynamic child = node.CreateChild(varName, start, "", dataType);
            AssertWellFormedChild(node, child, varName, start, treePath);

            if (ctx.Payload.Has("save") && ctx.Payload.Bool("save"))
            {
                ctx.Dte().ExecuteCommand("File.SaveAll");
            }
            ctx.Cache.Invalidate(treePath);

            var data = new Json.JObj();
            data["parentPath"] = treePath;
            data["child"] = ComHelpers.ConvertTreeItem(child);
            return data;
        }

        // --- tc_task_get_rt_settings (L7692-7748) ----------------------------
        private static Json.JObj GetRtSettings(ActionContext ctx)
        {
            bool summary = false;
            if (ctx.Payload.Has("summary")) summary = ctx.Payload.Bool("summary");

            dynamic sm = ctx.SysManager();
            dynamic tirs = ctx.Cache.LookupItem(sm, "TIRS");
            string xml = ComHelpers.StripTreeImage(ComHelpers.ProduceXml(tirs));

            if (!summary)
            {
                var d = new Json.JObj();
                d["treePath"] = "TIRS";
                d["xml"] = xml;
                return d;
            }

            object maxCPUs = null;
            object affinity = null;
            var cpus = new Json.JArr();
            if (!string.IsNullOrEmpty(xml))
            {
                try
                {
                    XmlDocument doc = new XmlDocument();
                    doc.LoadXml(xml);
                    XmlNode def = doc.SelectSingleNode("//RTimeSetDef");
                    if (def != null)
                    {
                        XmlNode mc = def.SelectSingleNode("MaxCPUs");
                        if (mc != null) maxCPUs = mc.InnerText;
                        XmlNode af = def.SelectSingleNode("Affinity");
                        if (af != null) affinity = af.InnerText;
                        XmlNodeList cpuNodes = def.SelectNodes(".//CPU");
                        if (cpuNodes != null)
                        {
                            foreach (XmlNode cpuNode in cpuNodes)
                            {
                                var entry = new Json.JObj();
                                if (cpuNode.Attributes != null)
                                {
                                    XmlNode idAttr = cpuNode.Attributes.GetNamedItem("id");
                                    if (idAttr != null) entry["id"] = idAttr.Value;
                                }
                                foreach (XmlNode cn in cpuNode.ChildNodes)
                                {
                                    if (cn.NodeType != XmlNodeType.Element) continue;
                                    entry[cn.Name] = cn.InnerText;
                                }
                                cpus.Add(entry);
                            }
                        }
                    }
                }
                catch
                {
                    maxCPUs = null;
                    affinity = null;
                    cpus = new Json.JArr();
                }
            }

            var data = new Json.JObj();
            data["treePath"] = "TIRS";
            data["maxCPUs"] = maxCPUs;
            data["affinity"] = affinity;
            data["cpus"] = cpus;
            return data;
        }

        // --- tc_task_set_rt_settings (L7750-7802) ----------------------------
        // CONFIG-ONLY: edits the project RT settings, not the running target.
        private static Json.JObj SetRtSettings(ActionContext ctx)
        {
            bool hasXml = ctx.Payload.Has("xml") && !string.IsNullOrWhiteSpace(ctx.Payload.Str("xml"));
            string x;
            if (hasXml)
            {
                x = ctx.Payload.Str("xml");
            }
            else
            {
                string frag = "";
                if (ctx.Payload.Has("maxCPUs") && ctx.Payload["maxCPUs"] != null)
                {
                    frag += "<MaxCPUs>" + ctx.Payload.Int("maxCPUs").ToString(CultureInfo.InvariantCulture) + "</MaxCPUs>";
                }
                if (ctx.Payload.Has("affinity") && !string.IsNullOrWhiteSpace(ctx.Payload.Str("affinity")))
                {
                    frag += "<Affinity>" + XmlText(ctx.Payload.Str("affinity")) + "</Affinity>";
                }
                if (ctx.Payload.Has("cpus") && ctx.Payload["cpus"] != null)
                {
                    string cpuFrag = "";
                    Json.JArr cpuArr = ctx.Payload.Arr("cpus");
                    if (cpuArr != null)
                    {
                        foreach (object cpuObj in cpuArr)
                        {
                            if (cpuObj == null) continue;
                            Json.JObj cpu = cpuObj as Json.JObj;
                            if (cpu == null) continue;
                            if (!cpu.Has("id") || cpu["id"] == null) throw new BridgeException("each cpus entry requires id");
                            int idVal = cpu.Int("id");
                            string inner = "";
                            if (cpu.Has("loadLimit") && cpu["loadLimit"] != null)
                                inner += "<LoadLimit>" + cpu.Int("loadLimit").ToString(CultureInfo.InvariantCulture) + "</LoadLimit>";
                            if (cpu.Has("baseTimeNs") && cpu["baseTimeNs"] != null)
                                inner += "<BaseTime>" + cpu.Long("baseTimeNs").ToString(CultureInfo.InvariantCulture) + "</BaseTime>";
                            if (cpu.Has("latencyWarningUs") && cpu["latencyWarningUs"] != null)
                                inner += "<LatencyWarning>" + cpu.Int("latencyWarningUs").ToString(CultureInfo.InvariantCulture) + "</LatencyWarning>";
                            cpuFrag += "<CPU id=\"" + idVal.ToString(CultureInfo.InvariantCulture) + "\">" + inner + "</CPU>";
                        }
                    }
                    if (!string.IsNullOrEmpty(cpuFrag))
                    {
                        frag += "<CPUs>" + cpuFrag + "</CPUs>";
                    }
                }
                if (string.IsNullOrEmpty(frag))
                    throw new BridgeException("set_rt_settings requires xml, or at least one of maxCPUs / affinity / cpus");
                x = "<TreeItem><RTimeSetDef>" + frag + "</RTimeSetDef></TreeItem>";
            }

            bool returnXml = false;
            if (ctx.Payload.Has("returnXml")) returnXml = ctx.Payload.Bool("returnXml");

            dynamic sm = ctx.SysManager();
            dynamic item = SetTreeItemXml(sm, "TIRS", x);

            var data = new Json.JObj();
            data["treePath"] = "TIRS";
            if (returnXml) data["xml"] = ComHelpers.StripTreeImage(ComHelpers.ProduceXml(item));

            if (ctx.Payload.Has("save") && ctx.Payload.Bool("save"))
            {
                ctx.Dte().ExecuteCommand("File.SaveAll");
            }
            ctx.Cache.Invalidate("TIRS");
            return data;
        }

        // --- tc_task_bind_cpu (L7804-7832) -----------------------------------
        private static Json.JObj BindCpu(ActionContext ctx)
        {
            string treePath = ctx.Payload.Str("path");
            if (string.IsNullOrWhiteSpace(treePath)) throw new BridgeException("path is required");
            if (string.IsNullOrWhiteSpace(ctx.Payload.Str("affinity"))) throw new BridgeException("affinity is required");

            string token = ConvertCpuAffinity(ctx.Payload.Str("affinity"));
            string x = "<TreeItem><TaskDef><CpuAffinity>" + token + "</CpuAffinity></TaskDef></TreeItem>";

            bool returnXml = false;
            if (ctx.Payload.Has("returnXml")) returnXml = ctx.Payload.Bool("returnXml");

            dynamic sm = ctx.SysManager();
            dynamic item = SetTreeItemXml(sm, treePath, x);

            var data = new Json.JObj();
            data["treePath"] = treePath;
            data["affinity"] = token;
            if (returnXml) data["xml"] = ComHelpers.StripTreeImage(ComHelpers.ProduceXml(item));

            if (ctx.Payload.Has("save") && ctx.Payload.Bool("save"))
            {
                ctx.Dte().ExecuteCommand("File.SaveAll");
            }
            ctx.Cache.Invalidate(treePath);
            return data;
        }

        // --- tc_task_get_linked_task (L7834-7869) ----------------------------
        private static Json.JObj GetLinkedTask(ActionContext ctx)
        {
            dynamic sm = ctx.SysManager();
            // ITcPlcTaskReference is NOT on the PLC root -- resolve the task-reference
            // sub-node (e.g. PlcTask). Try each candidate PATH with a FRESH RCW per
            // attempt (cached RCWs QI-fail E_NOINTERFACE); first that reads wins.
            List<string> candidatePaths = ResolvePlcTaskRefCandidates(ctx, sm, ctx.Payload.Str("path"));
            string treePath = null;
            string lt = null;
            bool resolved = false;
            string lastErr = null;
            foreach (string candPath in candidatePaths)
            {
                try
                {
                    dynamic node = ComHelpers.GetTreeItem(sm, candPath);
                    lt = PlcProjectHelper.GetLinkedTask((object)node);
                    treePath = candPath;
                    resolved = true;
                    break;
                }
                catch (Exception ex)
                {
                    lastErr = ex.Message;
                }
            }
            if (!resolved)
                throw new BridgeException("could not find a node implementing ITcPlcTaskReference (GetLinkedTask) under the PLC project. Tried: " +
                    string.Join(", ", candidatePaths.ToArray()) + ". Last error: " + lastErr);

            var data = new Json.JObj();
            data["treePath"] = treePath;
            data["linkedTask"] = lt;
            return data;
        }

        // --- tc_task_set_linked_task (L7872-7922) ----------------------------
        private static Json.JObj SetLinkedTask(ActionContext ctx)
        {
            string linkedTask = ctx.Payload.Str("linkedTask");
            if (string.IsNullOrWhiteSpace(linkedTask)) throw new BridgeException("linkedTask is required");

            dynamic sm = ctx.SysManager();
            // Same resolution as get_linked_task: feature-detect the node with a
            // GetLinkedTask read (proves the QI), then write on a FRESH RCW for the
            // same path (cached RCWs QI-fail E_NOINTERFACE).
            List<string> candidatePaths = ResolvePlcTaskRefCandidates(ctx, sm, ctx.Payload.Str("path"));
            string treePath = null;
            bool resolved = false;
            string lastErr = null;
            foreach (string candPath in candidatePaths)
            {
                try
                {
                    dynamic probe = ComHelpers.GetTreeItem(sm, candPath);
                    PlcProjectHelper.GetLinkedTask((object)probe);
                    treePath = candPath;
                    resolved = true;
                    break;
                }
                catch (Exception ex)
                {
                    lastErr = ex.Message;
                }
            }
            if (!resolved)
                throw new BridgeException("could not find a node implementing ITcPlcTaskReference (SetLinkedTask) under the PLC project. Tried: " +
                    string.Join(", ", candidatePaths.ToArray()) + ". Last error: " + lastErr);

            dynamic node = ComHelpers.GetTreeItem(sm, treePath);
            try
            {
                PlcProjectHelper.SetLinkedTask((object)node, linkedTask);
            }
            catch (Exception ex)
            {
                throw new BridgeException("node '" + treePath + "' does not implement ITcPlcTaskReference: " + ex.Message);
            }

            if (ctx.Payload.Has("save") && ctx.Payload.Bool("save"))
            {
                ctx.Dte().ExecuteCommand("File.SaveAll");
            }
            ctx.Cache.Invalidate(treePath);

            var data = new Json.JObj();
            data["treePath"] = treePath;
            data["linkedTask"] = linkedTask;
            data["set"] = true;
            return data;
        }

        // ===================================================================
        // private helpers
        // ===================================================================

        // Set-TreeItemXml (L3243-3262): resolve a fresh RCW for the target path and
        // ConsumeXml, surfacing GetLastXmlError. Returns the (dynamic) tree item.
        private static dynamic SetTreeItemXml(dynamic sm, string targetPath, string xml)
        {
            dynamic item = ComHelpers.GetTreeItem(sm, targetPath);
            ComHelpers.ConsumeXml(item, xml);
            return item;
        }

        // Resolve-PlcRootPath (L1164-1177).
        private static string ResolvePlcRootPath(dynamic sm, string path)
        {
            if (!string.IsNullOrWhiteSpace(path)) return path;
            dynamic tipc = ComHelpers.GetTreeItem(sm, "TIPC");
            if (ComHelpers.ChildCount(tipc) < 1) throw new BridgeException("No PLC project found under TIPC");
            dynamic first = ComHelpers.Child(tipc, 1);
            string firstName = ComHelpers.SafeStr(delegate { return first.Name; });
            return "TIPC^" + firstName;
        }

        // Resolve-PlcTaskRefCandidates (L1186-1259): ordered list of candidate tree
        // PATHS that might implement ITcPlcTaskReference. When a path is supplied it
        // is the single candidate. Otherwise probe the '<name> Project' node and the
        // PLC root's children, preferring a 'PlcTask'-named child, plus the
        // well-known names PlcTask/VISU_TASK, then fall back to the project/root nodes.
        private static List<string> ResolvePlcTaskRefCandidates(ActionContext ctx, dynamic sm, string path)
        {
            if (!string.IsNullOrWhiteSpace(path))
            {
                var single = new List<string>();
                single.Add(path);
                return single;
            }

            string plcPath = ResolvePlcRootPath(sm, null);
            dynamic root = ComHelpers.GetTreeItem(sm, plcPath);
            string rootName = ComHelpers.SafeStr(delegate { return root.Name; });

            var candidatePaths = new List<string>();

            // Build the list of project-node paths to probe.
            var projectPaths = new List<string>();
            if (!string.IsNullOrWhiteSpace(rootName))
            {
                projectPaths.Add(plcPath + "^" + rootName + " Project");
            }
            int rootChildCount = ComHelpers.ChildCount(root);
            for (int ri = 1; ri <= rootChildCount; ri++)
            {
                dynamic rc = ComHelpers.Child(root, ri);
                if (rc == null) continue;
                string rcn = ComHelpers.SafeStr(delegate { return rc.Name; });
                if (string.IsNullOrWhiteSpace(rcn)) continue;
                string rcp = plcPath + "^" + rcn;
                if (!projectPaths.Contains(rcp)) projectPaths.Add(rcp);
            }

            foreach (string projPath in projectPaths)
            {
                dynamic projNode = null;
                try { projNode = ComHelpers.GetTreeItem(sm, projPath); }
                catch { projNode = null; }
                if (projNode == null) continue;

                var named = new List<string>();
                var other = new List<string>();

                int childCount = ComHelpers.ChildCount(projNode);
                for (int ci = 1; ci <= childCount; ci++)
                {
                    dynamic childNode = ComHelpers.Child(projNode, ci);
                    if (childNode == null) continue;
                    string cn = ComHelpers.SafeStr(delegate { return childNode.Name; });
                    if (string.IsNullOrWhiteSpace(cn)) continue;
                    string cp = projPath + "^" + cn;
                    if (cn == "PlcTask") named.Add(cp); else other.Add(cp);
                }

                // Always also probe well-known task-reference child names by path.
                string[] wellKnown = new string[] { "PlcTask", "VISU_TASK" };
                foreach (string wk in wellKnown)
                {
                    string wkp = projPath + "^" + wk;
                    if (!named.Contains(wkp) && !other.Contains(wkp))
                    {
                        if (wk == "PlcTask") named.Add(wkp); else other.Add(wkp);
                    }
                }

                foreach (string p in named) { if (!candidatePaths.Contains(p)) candidatePaths.Add(p); }
                foreach (string p in other) { if (!candidatePaths.Contains(p)) candidatePaths.Add(p); }
            }

            // Fall back to the project/root nodes themselves (older layouts).
            foreach (string p in projectPaths) { if (!candidatePaths.Contains(p)) candidatePaths.Add(p); }
            if (!candidatePaths.Contains(plcPath)) candidatePaths.Add(plcPath);

            if (candidatePaths.Count < 1)
                throw new BridgeException("No task-reference node found under PLC project '" + plcPath +
                    "' (nothing implementing ITcPlcTaskReference)");
            return candidatePaths;
        }

        // Convert-CpuAffinity (L1263-1293): map a CpuAffinity name (or pass through a
        // raw #x.. hex token) to a TwinCAT affinity token #x{16 hex}.
        private static string ConvertCpuAffinity(string affinity)
        {
            string a = (affinity ?? "").Trim();
            if (a.StartsWith("#x", StringComparison.Ordinal)) return a;

            ulong cpu1 = 0x1, cpu2 = 0x2, cpu3 = 0x4, cpu4 = 0x8;
            ulong cpu5 = 0x10, cpu6 = 0x20, cpu7 = 0x40, cpu8 = 0x80;
            ulong mask;
            switch (a.ToUpperInvariant())
            {
                case "NONE": mask = 0; break;
                case "CPU1": mask = cpu1; break;
                case "CPU2": mask = cpu2; break;
                case "CPU3": mask = cpu3; break;
                case "CPU4": mask = cpu4; break;
                case "CPU5": mask = cpu5; break;
                case "CPU6": mask = cpu6; break;
                case "CPU7": mask = cpu7; break;
                case "CPU8": mask = cpu8; break;
                case "MASKSINGLE": mask = cpu1; break;
                case "MASKDUAL": mask = cpu1 | cpu2; break;
                case "MASKQUAD": mask = cpu1 | cpu2 | cpu3 | cpu4; break;
                case "MASKHEXA": mask = cpu1 | cpu2 | cpu3 | cpu4 | cpu5 | cpu6; break;
                case "MASKOCT": mask = cpu1 | cpu2 | cpu3 | cpu4 | cpu5 | cpu6 | cpu7 | cpu8; break;
                case "MASKALL": mask = ulong.MaxValue; break;
                default:
                    throw new BridgeException("Unrecognized affinity '" + affinity +
                        "'. Use a name (CPU1..CPU8, MaskSingle/Dual/Quad/Hexa/Oct/All, None) or a raw #x.. hex token.");
            }
            return "#x" + mask.ToString("x16", CultureInfo.InvariantCulture);
        }

        // ConvertTo-XmlText (L1296-1299): XML-escape a scalar for a ConsumeXml envelope.
        private static string XmlText(object value)
        {
            if (value == null) return "";
            string s = Convert.ToString(value, CultureInfo.InvariantCulture);
            return s.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;");
        }

        // Assert-WellFormedChild (L3192-3241): validate a CreateChild result; on a
        // malformed "ghost" do best-effort cleanup and THROW.
        private static void AssertWellFormedChild(dynamic parent, dynamic child, string requestedName, int subType, string parentPath)
        {
            // Null-check FIRST, before dereferencing child.Name / child.PathName.
            // (Previously these were read first; SafeStr swallowed the NRE so it was
            // harmless, but reading then checking is backwards — order it properly.)
            string reason = null;
            string childActualName = null;
            string childPath = null;

            if (child == null)
            {
                reason = "CreateChild returned null";
            }
            else
            {
                childActualName = ComHelpers.SafeStr(delegate { return child.Name; });
                childPath = ComHelpers.SafeStr(delegate { return child.PathName; });

                if (string.IsNullOrWhiteSpace(childActualName))
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
