using System;
using System.Collections.Generic;

namespace Te1000Daemon
{
    // activate / restart / download / login / logout actions.
    //
    // These are config / live-cell verbs. index.js enforces the confirm tokens
    // upstream (ALLOW_TWINCAT_ACTIVATE / ALLOW_TWINCAT_RESTART / ALLOW_PLC_DOWNLOAD)
    // BEFORE the daemon is called, and none of the PS handlers re-check a token, so
    // none is re-checked here (per the porting brief). After a successful
    // activate / download / restart the cached COM session may be stale, so we
    // Cache.Invalidate(null) on success.
    //
    // plc_login / plc_logout (and plc_download method='command') are LEGACY: they
    // drive the IDE command surface via Invoke-PlcProjectCommand, which needs a DTE
    // that exposes window automation. The 64-bit TcXaeShell 17.0 DTE reports
    // Windows.Count = 0 and cannot select the PLC node, so these "never worked here"
    // and index.js does not wire login/logout. Ported faithfully for completeness.
    //
    // C#5-clean (no interpolation, no out var, no expression-bodied members).
    internal static class SessionDownloadActions
    {
        public static void Register(Dictionary<string, ActionHandler> h)
        {
            h["twincat_activate_configuration"] = ActivateConfiguration;
            h["plc_login"] = Login;
            h["plc_download"] = Download;
            h["plc_logout"] = Logout;
            h["twincat_restart_runtime"] = RestartRuntime;
        }

        // --- twincat_activate_configuration (L5505-5517) ---------------------
        // LIVE-cell action. index.js guards with ALLOW_TWINCAT_ACTIVATE.
        private static Json.JObj ActivateConfiguration(ActionContext ctx)
        {
            dynamic sm = ctx.SysManager();
            sm.ActivateConfiguration();
            ctx.Cache.Invalidate(null);

            var data = new Json.JObj();
            data["activated"] = true;
            return data;
        }

        // --- plc_login (L5519-5531) ------------------------------------------
        // LEGACY (IDE command surface). Not wired in index.js.
        private static Json.JObj Login(ActionContext ctx)
        {
            dynamic dte = ctx.Dte(true);
            var candidates = new List<string>();
            string commandName = ctx.Payload.Str("commandName");
            if (!string.IsNullOrEmpty(commandName)) candidates.Add(commandName);
            candidates.Add("OtherContextMenus.PlcProject.Login");

            return InvokePlcProjectCommand(ctx, dte, candidates, "^PLC\\.Loginto", ctx.Payload.Str("itemName"));
        }

        // --- plc_download (L5533-5592) ---------------------------------------
        // Default 'bootproject' route: GenerateBootProject via the typed
        // ITcPlcProject helper. 'command' route is the legacy IDE-command surface.
        // index.js guards with ALLOW_PLC_DOWNLOAD.
        private static Json.JObj Download(ActionContext ctx)
        {
            string method = ctx.Payload.Truthy("method") ? ctx.Payload.Str("method") : "bootproject";

            if (method == "command")
            {
                // Legacy route via the IDE command surface. Requires a shell whose
                // DTE exposes window automation so the PLC project node can be
                // selected (the 64-bit TcXaeShell 17.0 DTE reports Windows.Count = 0).
                dynamic dte = ctx.Dte(true);
                var candidates = new List<string>();
                string commandName = ctx.Payload.Str("commandName");
                if (!string.IsNullOrEmpty(commandName)) candidates.Add(commandName);
                candidates.Add("PLC.Downloadnone");

                return InvokePlcProjectCommand(ctx, dte, candidates, "^PLC\\.Download", ctx.Payload.Str("itemName"));
            }

            // Default: headless deployment via ITcPlcProject (Beckhoff CI path).
            // GenerateBootProject($true) writes the boot project to the target's
            // boot directory; the runtime loads it on the next TwinCAT restart.
            dynamic sm = ctx.SysManager();

            // ITcPlcProject is implemented by the PLC root node (TIPC^<name>), NOT the
            // nested "<name> Project" node (that one only carries ITcPlcIECProject*).
            string treePath = ctx.Payload.Str("treePath");
            if (string.IsNullOrWhiteSpace(treePath))
            {
                dynamic tipc = sm.LookupTreeItem("TIPC");
                if (ComHelpers.ChildCount(tipc) < 1) throw new BridgeException("No PLC project found under TIPC");
                string plcName = ComHelpers.SafeStr(delegate { return tipc.Child(1).Name; });
                treePath = "TIPC^" + plcName;
            }

            dynamic plcProject = sm.LookupTreeItem(treePath);
            bool autostart = true;
            if (ctx.Payload.Has("autostart")) autostart = ctx.Payload.Bool("autostart");

            // The typed ITcPlcProject cast (PlcProjectHelper) is always compiled in
            // this daemon; the PS Ensure-TcPlcProjectHelper precondition is moot.
            PlcProjectHelper.Deploy((object)plcProject, autostart, true);
            ctx.Cache.Invalidate(null);

            var data = new Json.JObj();
            data["method"] = "bootproject";
            data["treePath"] = treePath;
            data["bootProjectGenerated"] = true;
            data["bootProjectAutostart"] = autostart;
            data["targetNetId"] = ComHelpers.SafeStr(delegate { return sm.GetTargetNetId(); });
            data["note"] = "Boot project deployed to the target boot directory. Restart the TwinCAT runtime (twincat_restart_runtime) to load and run it.";
            return data;
        }

        // --- plc_logout (L5594-5606) -----------------------------------------
        // LEGACY (IDE command surface). Not wired in index.js.
        private static Json.JObj Logout(ActionContext ctx)
        {
            dynamic dte = ctx.Dte(true);
            var candidates = new List<string>();
            string commandName = ctx.Payload.Str("commandName");
            if (!string.IsNullOrEmpty(commandName)) candidates.Add(commandName);
            candidates.Add("OtherContextMenus.PlcProject.Logout");

            return InvokePlcProjectCommand(ctx, dte, candidates, "^PLC\\.Logout", ctx.Payload.Str("itemName"));
        }

        // --- twincat_restart_runtime (L5608-5627) ----------------------------
        // LIVE-cell action. index.js guards with ALLOW_TWINCAT_RESTART.
        private static Json.JObj RestartRuntime(ActionContext ctx)
        {
            dynamic sm = ctx.SysManager();
            object wasStarted = null;
            try { wasStarted = (bool)sm.IsTwinCATStarted(); }
            catch { }

            sm.StartRestartTwinCAT();
            ctx.Cache.Invalidate(null);

            var data = new Json.JObj();
            data["restarted"] = true;
            data["wasStarted"] = wasStarted;
            return data;
        }

        // ===================================================================
        // private helpers
        // ===================================================================

        // Invoke-PlcProjectCommand (L2914-3000): select the "<plc> Project" node in
        // Solution Explorer (selection-context establishes IsAvailable for the PLC
        // online commands), temporarily force automation SilentMode, then try the
        // candidate command names, then a fallback scan by name pattern. Throws if
        // nothing was available. Returns the executed command descriptor.
        private static Json.JObj InvokePlcProjectCommand(ActionContext ctx, dynamic dte, List<string> candidateCommands, string fallbackPattern, string plcItemName)
        {
            dynamic settings = ComHelpers.Safe<object>(delegate { return GetAutomationSettings(dte); });
            object prevSilent = null;
            if (settings != null)
            {
                prevSilent = ComHelpers.Safe<object>(delegate { return (bool)settings.SilentMode; });
                try { settings.SilentMode = true; }
                catch { }
            }

            try
            {
                string selectedItem = SelectPlcProjectInSolutionExplorer(ctx, dte, plcItemName);

                var tried = new List<string>();
                foreach (string name in candidateCommands)
                {
                    if (string.IsNullOrWhiteSpace(name)) continue;
                    dynamic cmd = null;
                    try { cmd = dte.Commands.Item(name, 0); }
                    catch { }
                    if (cmd == null) { tried.Add(name + " (not found)"); continue; }

                    bool isAvailable = true;
                    try { isAvailable = (bool)cmd.IsAvailable; }
                    catch { }
                    if (!isAvailable) { tried.Add(name + " (unavailable)"); continue; }

                    dte.ExecuteCommand(name);
                    var ok = new Json.JObj();
                    ok["commandName"] = name;
                    ok["executed"] = true;
                    ok["selectedItem"] = selectedItem;
                    return ok;
                }

                if (!string.IsNullOrWhiteSpace(fallbackPattern))
                {
                    var re = new System.Text.RegularExpressions.Regex(fallbackPattern);
                    foreach (dynamic cmd in dte.Commands)
                    {
                        string name = ComHelpers.SafeStr(delegate { return cmd.Name; });
                        if (string.IsNullOrWhiteSpace(name) || !re.IsMatch(name)) continue;

                        bool isAvailable = false;
                        try { isAvailable = (bool)cmd.IsAvailable; }
                        catch { }
                        if (isAvailable)
                        {
                            dte.ExecuteCommand(name);
                            var ok = new Json.JObj();
                            ok["commandName"] = name;
                            ok["executed"] = true;
                            ok["selectedItem"] = selectedItem;
                            ok["viaFallbackScan"] = true;
                            return ok;
                        }
                        tried.Add(name + " (unavailable)");
                    }
                }

                throw new BridgeException("No PLC command was available after selecting '" + selectedItem +
                    "' in Solution Explorer. Tried: " + string.Join(", ", tried.ToArray()));
            }
            finally
            {
                if (settings != null && prevSilent != null)
                {
                    try { settings.SilentMode = prevSilent; }
                    catch { }
                }
            }
        }

        // Get-AutomationSettings (L695-703): Dte.GetObject('TcAutomationSettings')
        // with retry; throws if null.
        private static object GetAutomationSettings(dynamic dte)
        {
            return ComHelpers.WithRetry<object>(delegate
            {
                dynamic settings = dte.GetObject("TcAutomationSettings");
                if (settings == null) throw new BridgeException("TcAutomationSettings is null");
                return settings;
            }, 20, 250);
        }

        // Select-PlcProjectInSolutionExplorer (L2822-2912): the PLC login/download/
        // logout DTE commands are selection-context-sensitive — they stay
        // IsAvailable=false until the "<plc> Project" node is selected in Solution
        // Explorer. Only UIHierarchyItem.Select() establishes that context.
        private static string SelectPlcProjectInSolutionExplorer(ActionContext ctx, dynamic dte, string plcItemName)
        {
            dynamic sm = ctx.SysManager();
            string plcName = null;
            try
            {
                dynamic tipc = sm.LookupTreeItem("TIPC");
                if (ComHelpers.ChildCount(tipc) >= 1) plcName = ComHelpers.SafeStr(delegate { return tipc.Child(1).Name; });
            }
            catch { }

            if (string.IsNullOrWhiteSpace(plcItemName))
            {
                if (string.IsNullOrWhiteSpace(plcName)) throw new BridgeException("Could not determine the PLC project name from TIPC");
                plcItemName = plcName + " Project";
            }

            ComHelpers.Safe<object>(delegate { dte.ExecuteCommand("View.SolutionExplorer"); return null; });
            dynamic solutionExplorer = dte.ToolWindows.SolutionExplorer;
            dynamic rootItems = ComHelpers.Safe<object>(delegate { return solutionExplorer.UIHierarchyItems; });
            if (rootItems == null || ComHelpers.SafeInt(delegate { return rootItems.Count; }) < 1)
                throw new BridgeException("Solution Explorer hierarchy is empty");

            dynamic target = null;
            dynamic solutionNode = rootItems.Item(1);
            dynamic projectNodes = ExpandUIHierarchyChildren(solutionNode);
            if (projectNodes != null)
            {
                foreach (dynamic projectNode in projectNodes)
                {
                    dynamic plcFolder = FindUIHierarchyChildByName(projectNode, "PLC");
                    if (plcFolder == null) continue;

                    var plcRoots = new List<object>();
                    if (!string.IsNullOrWhiteSpace(plcName))
                    {
                        dynamic named = FindUIHierarchyChildByName(plcFolder, plcName);
                        if (named != null) plcRoots.Add(named);
                    }
                    if (plcRoots.Count == 0)
                    {
                        dynamic allRoots = ExpandUIHierarchyChildren(plcFolder);
                        if (allRoots != null)
                        {
                            foreach (dynamic root in allRoots) plcRoots.Add(root);
                        }
                    }

                    foreach (dynamic plcRoot in plcRoots)
                    {
                        target = FindUIHierarchyChildByName(plcRoot, plcItemName);
                        if (target == null)
                        {
                            dynamic rootChildren = ExpandUIHierarchyChildren(plcRoot);
                            if (rootChildren != null)
                            {
                                foreach (dynamic child in rootChildren)
                                {
                                    string childName = ComHelpers.SafeStr(delegate { return child.Name; });
                                    if (childName != null && childName.EndsWith(" Project", StringComparison.Ordinal))
                                    {
                                        target = child;
                                        break;
                                    }
                                }
                            }
                        }
                        if (target != null) break;
                    }
                    if (target != null) break;
                }
            }

            if (target == null)
                throw new BridgeException("Could not locate '" + plcItemName + "' under a PLC node in Solution Explorer");

            target.Select(1); // vsUISelectionTypeSelect
            System.Threading.Thread.Sleep(400);
            return plcItemName;
        }

        // Expand-UIHierarchyChildren (L2790-2804): get .UIHierarchyItems and expand.
        private static dynamic ExpandUIHierarchyChildren(dynamic item)
        {
            dynamic children = ComHelpers.Safe<object>(delegate { return item.UIHierarchyItems; });
            if (children == null) return null;
            try
            {
                if (!(bool)children.Expanded) children.Expanded = true;
            }
            catch { }
            return children;
        }

        // Find-UIHierarchyChildByName (L2806-2820): expand then match by Name.
        private static dynamic FindUIHierarchyChildByName(dynamic item, string name)
        {
            dynamic children = ExpandUIHierarchyChildren(item);
            if (children == null) return null;
            foreach (dynamic child in children)
            {
                string childName = ComHelpers.SafeStr(delegate { return child.Name; });
                if (childName == name) return child;
            }
            return null;
        }
    }
}
