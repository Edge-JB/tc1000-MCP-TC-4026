using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace Te1000Daemon
{
    // XAE / DTE shell actions ported from te1000-bridge.ps1:
    //   xae_status (L3689), xae_open_solution (L3720), xae_list_commands (L3769),
    //   xae_execute_command (L3805), xae_get_active_document (L3845),
    //   xae_get_selected_items (L3862), xae_focus_tree_item (L3886),
    //   xae_get_error_list (L3914), xae_clear_error_list (L3957),
    //   xae_save_all (L5306), xae_solution_build (L5436).
    internal static class XaeActions
    {
        public static void Register(Dictionary<string, ActionHandler> h)
        {
            h["xae_status"] = XaeStatus;
            h["xae_open_solution"] = XaeOpenSolution;
            h["xae_list_commands"] = XaeListCommands;
            h["xae_execute_command"] = XaeExecuteCommand;
            h["xae_get_active_document"] = XaeGetActiveDocument;
            h["xae_get_selected_items"] = XaeGetSelectedItems;
            h["xae_focus_tree_item"] = XaeFocusTreeItem;
            h["xae_get_error_list"] = XaeGetErrorList;
            h["xae_clear_error_list"] = XaeClearErrorList;
            h["xae_save_all"] = XaeSaveAll;
            h["xae_solution_build"] = XaeSolutionBuild;
        }

        // ---- shared helpers (port of bridge helper functions) ----------------

        // Get-SolutionInfo (bridge L581-601): {isOpen, fullName}.
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

        // Get-AutomationSettings (bridge L695-703). Retries TcAutomationSettings.
        private static dynamic GetAutomationSettings(dynamic dte)
        {
            return ComHelpers.WithRetry<dynamic>(delegate()
            {
                dynamic settings = dte.GetObject("TcAutomationSettings");
                if (settings == null) throw new BridgeException("TcAutomationSettings is null");
                return settings;
            }, 20, 250);
        }

        // Wait-ForSolutionOpen (bridge L610-621).
        private static Json.JObj WaitForSolutionOpen(dynamic dte, string expectedPath)
        {
            return ComHelpers.WithRetry<Json.JObj>(delegate()
            {
                Json.JObj info = GetSolutionInfo(dte);
                bool isOpen = info.Bool("isOpen");
                if (!isOpen) throw new BridgeException("Solution is not open yet");
                string fullName = info.Str("fullName");
                if (!string.IsNullOrWhiteSpace(expectedPath) &&
                    !string.Equals(fullName, expectedPath, StringComparison.Ordinal))
                {
                    throw new BridgeException("Different solution is active: " + fullName);
                }
                return info;
            }, 60, 500);
        }

        // Wait-ForBuildFinish (bridge L678-693): poll until BuildState != 2.
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

        // Invoke-DteCommand (bridge L705-750): {commandName, isAvailable, executed}.
        private static Json.JObj InvokeDteCommand(dynamic dte, string commandName)
        {
            if (string.IsNullOrWhiteSpace(commandName)) throw new BridgeException("CommandName is required");

            GetAutomationSettings(dte);
            dynamic cmd;
            try { cmd = dte.Commands.Item(commandName, 0); }
            catch (Exception ex) { throw new BridgeException("Command lookup failed for '" + commandName + "': " + ex.Message); }

            if (cmd == null) throw new BridgeException("Command not found: " + commandName);

            bool isAvailable = true;
            try { isAvailable = (bool)cmd.IsAvailable; }
            catch { }

            if (!isAvailable) throw new BridgeException("Command is not available in the current XAE context: " + commandName);

            try { dte.ExecuteCommand(commandName); }
            catch (Exception ex) { throw new BridgeException("ExecuteCommand failed for '" + commandName + "': " + ex.Message); }

            var o = new Json.JObj();
            o["commandName"] = commandName;
            o["isAvailable"] = isAvailable;
            o["executed"] = true;
            return o;
        }

        // Convert-SelectedItem (bridge L3002-3021).
        private static Json.JObj ConvertSelectedItem(dynamic selectedItem)
        {
            dynamic projectItem = ComHelpers.Safe<dynamic>(delegate() { return selectedItem.ProjectItem; });
            dynamic projectItemObject = null;
            if (projectItem != null)
            {
                projectItemObject = ComHelpers.Safe<dynamic>(delegate() { return projectItem.Object; });
            }

            dynamic pi = projectItem;
            dynamic pio = projectItemObject;

            var o = new Json.JObj();
            o["name"] = ComHelpers.SafeStr(delegate() { return selectedItem.Name; });
            o["projectName"] = ComHelpers.SafeStr(delegate() { return selectedItem.Project.Name; });
            o["projectItemName"] = ComHelpers.SafeStr(delegate() { return pi.Name; });
            o["projectItemKind"] = ComHelpers.SafeStr(delegate() { return pi.Kind; });
            o["treePath"] = ComHelpers.SafeStr(delegate() { return pio.PathName; });
            return o;
        }

        // ---- actions ---------------------------------------------------------

        // xae_status (L3689-3718).
        private static Json.JObj XaeStatus(ActionContext ctx)
        {
            dynamic dte = ctx.Dte(true);
            Json.JObj solution = GetSolutionInfo(dte);

            bool automationAvailable = false;
            try { dynamic s = GetAutomationSettings(dte); automationAvailable = (s != null); }
            catch { automationAvailable = false; }

            bool sysManagerAvailable = false;
            try { ctx.SysManager(); sysManagerAvailable = true; }
            catch { sysManagerAvailable = false; }

            var data = new Json.JObj();
            data["progId"] = ctx.ProgId;
            data["mode"] = ctx.Mode;
            data["solution"] = solution;
            data["automationSettingsAvailable"] = automationAvailable;
            data["sysManagerAvailable"] = sysManagerAvailable;
            return data;
        }

        // xae_open_solution (L3720-3767).
        private static Json.JObj XaeOpenSolution(ActionContext ctx)
        {
            string solutionPath = ctx.Payload.Str("solutionPath");
            if (string.IsNullOrWhiteSpace(solutionPath)) throw new BridgeException("solutionPath is required");
            if (!System.IO.File.Exists(solutionPath)) throw new BridgeException("Solution file not found: " + solutionPath);

            bool visible = true;
            if (ctx.Payload.Has("visible")) visible = ctx.Payload.Bool("visible");

            bool closeExisting = false;
            if (ctx.Payload.Has("closeExisting")) closeExisting = ctx.Payload.Bool("closeExisting");

            bool discardChanges = false;
            if (ctx.Payload.Has("discardChanges")) discardChanges = ctx.Payload.Bool("discardChanges");

            // open_solution may pass its own mode (read by ActionContext into ctx.Mode).
            dynamic dte = ctx.Dte(visible);
            try { dte.MainWindow.Visible = visible; }
            catch { }

            Json.JObj current = GetSolutionInfo(dte);
            if (current.Bool("isOpen") && closeExisting)
            {
                dte.Solution.Close(!discardChanges);
            }

            dte.Solution.Open(solutionPath);
            Json.JObj solution = WaitForSolutionOpen(dte, solutionPath);
            GetAutomationSettings(dte);

            var data = new Json.JObj();
            data["progId"] = ctx.ProgId;
            data["solution"] = solution;
            return data;
        }

        // xae_list_commands (L3769-3803).
        private static Json.JObj XaeListCommands(ActionContext ctx)
        {
            string filter = ctx.Payload.Truthy("filter") ? ctx.Payload.Str("filter") : null;
            int limit = 250;
            if (ctx.Payload.Has("limit")) limit = ctx.Payload.Int("limit", 250);

            dynamic dte = ctx.Dte(true);
            var names = new List<string>();

            System.Text.RegularExpressions.Regex rx = null;
            if (!string.IsNullOrEmpty(filter))
            {
                rx = new System.Text.RegularExpressions.Regex(filter, System.Text.RegularExpressions.RegexOptions.IgnoreCase);
            }

            foreach (dynamic cmd in dte.Commands)
            {
                try
                {
                    string name = (string)cmd.Name;
                    if (string.IsNullOrWhiteSpace(name)) continue;
                    if (rx != null && !rx.IsMatch(name)) continue;
                    names.Add(name);
                }
                catch { }
            }

            // Sort -Unique then Select -First $limit.
            var seen = new HashSet<string>(StringComparer.Ordinal);
            names.Sort(StringComparer.Ordinal);
            var commands = new Json.JArr();
            foreach (string n in names)
            {
                if (commands.Count >= limit) break;
                if (seen.Add(n)) commands.Add(n);
            }

            var data = new Json.JObj();
            data["filter"] = filter;
            data["count"] = commands.Count;
            data["commands"] = commands;
            return data;
        }

        // xae_execute_command (L3805-3843).
        private static Json.JObj XaeExecuteCommand(ActionContext ctx)
        {
            string commandName = ctx.Payload.Str("commandName");
            if (string.IsNullOrWhiteSpace(commandName)) throw new BridgeException("commandName is required");

            string args = ctx.Payload.Has("args") ? ctx.Payload.Str("args") : "";
            if (args == null) args = "";

            dynamic dte = ctx.Dte(true);
            GetAutomationSettings(dte);
            dynamic cmd = dte.Commands.Item(commandName, 0);
            if (cmd == null) throw new BridgeException("Command not found: " + commandName);

            bool isAvailable = true;
            try { isAvailable = (bool)cmd.IsAvailable; }
            catch { }

            if (!isAvailable) throw new BridgeException("Command is not available in the current XAE context: " + commandName);

            if (string.IsNullOrWhiteSpace(args)) dte.ExecuteCommand(commandName);
            else dte.ExecuteCommand(commandName, args);

            var data = new Json.JObj();
            data["commandName"] = commandName;
            data["args"] = args;
            data["isAvailable"] = isAvailable;
            data["executed"] = true;
            return data;
        }

        // xae_get_active_document (L3845-3860).
        private static Json.JObj XaeGetActiveDocument(ActionContext ctx)
        {
            dynamic dte = ctx.Dte(true);
            dynamic doc = ComHelpers.Safe<dynamic>(delegate() { return dte.ActiveDocument; });
            dynamic d = doc;

            var data = new Json.JObj();
            data["hasActiveDocument"] = (doc != null);
            data["name"] = ComHelpers.SafeStr(delegate() { return d.Name; });
            data["fullName"] = ComHelpers.SafeStr(delegate() { return d.FullName; });
            data["kind"] = ComHelpers.SafeStr(delegate() { return d.Kind; });
            data["projectItemName"] = ComHelpers.SafeStr(delegate() { return d.ProjectItem.Name; });
            return data;
        }

        // xae_get_selected_items (L3862-3883).
        private static Json.JObj XaeGetSelectedItems(ActionContext ctx)
        {
            dynamic dte = ctx.Dte(true);
            var items = new Json.JArr();
            int count = 0;

            try { count = (int)dte.SelectedItems.Count; }
            catch { }

            for (int i = 1; i <= count; i++)
            {
                items.Add(ConvertSelectedItem(dte.SelectedItems.Item(i)));
            }

            var data = new Json.JObj();
            data["count"] = count;
            data["items"] = items;
            return data;
        }

        // xae_focus_tree_item (L3886-3911).
        private static Json.JObj XaeFocusTreeItem(ActionContext ctx)
        {
            string treePath = ctx.Payload.Str("treePath");
            if (string.IsNullOrWhiteSpace(treePath)) throw new BridgeException("treePath is required");

            dynamic dte = ctx.Dte(true);
            dynamic sysManager = ctx.SysManager();
            dynamic item = ComHelpers.GetTreeItem(sysManager, treePath);
            dynamic vsProjectItem = ComHelpers.Safe<dynamic>(delegate() { return item.VSProjectItem; });
            if (vsProjectItem == null) throw new BridgeException("No VSProjectItem is available for tree item: " + treePath);

            dynamic vp = vsProjectItem;
            ComHelpers.Safe<object>(delegate() { dte.ExecuteCommand("View.SolutionExplorer"); return null; });
            ComHelpers.Safe<object>(delegate() { vp.ExpandView(); return null; });

            var data = new Json.JObj();
            data["treePath"] = treePath;
            data["expanded"] = true;
            data["note"] = "Best effort only. XAE did not expose a reliable programmatic selection method in this environment.";
            return data;
        }

        // xae_get_error_list (L3914-3954) + XaeErrorListProbe (L205-260).
        private static Json.JObj XaeGetErrorList(ActionContext ctx)
        {
            int limit = 200;
            if (ctx.Payload.Has("limit")) limit = ctx.Payload.Int("limit", 200);

            string error;
            ErrorListResult result = ReadErrorList(ctx, limit, out error);
            if (result == null)
            {
                var unavailable = new Json.JObj();
                unavailable["available"] = false;
                unavailable["count"] = 0;
                unavailable["items"] = new Json.JArr();
                if (!string.IsNullOrEmpty(error)) unavailable["error"] = error;
                return unavailable;
            }

            var data = new Json.JObj();
            data["available"] = true;
            data["count"] = result.TotalCount;
            data["returned"] = result.Items.Count;
            data["items"] = result.Items;
            return data;
        }

        // xae_clear_error_list (L3957-3970).
        private static Json.JObj XaeClearErrorList(ActionContext ctx)
        {
            dynamic dte = ctx.Dte(true);
            Json.JObj showResult = InvokeDteCommand(dte, "View.ErrorList");
            Json.JObj clearResult = InvokeDteCommand(dte, "OtherContextMenus.ErrorList.Clear");

            var data = new Json.JObj();
            data["cleared"] = true;
            data["showCommand"] = showResult;
            data["clearCommand"] = clearResult;
            return data;
        }

        // xae_save_all (L5306-5317): Save-Solution (File.SaveAll) then SolutionInfo.
        private static Json.JObj XaeSaveAll(ActionContext ctx)
        {
            dynamic dte = ctx.Dte(true);
            dte.ExecuteCommand("File.SaveAll");

            var data = new Json.JObj();
            data["saved"] = true;
            data["solution"] = GetSolutionInfo(dte);
            return data;
        }

        // xae_solution_build (L5436-5502).
        private static Json.JObj XaeSolutionBuild(ActionContext ctx)
        {
            string actionName = ctx.Payload.Str("action");
            if (string.IsNullOrWhiteSpace(actionName)) throw new BridgeException("action is required");

            bool waitForFinish = true;
            if (ctx.Payload.Has("waitForFinish")) waitForFinish = ctx.Payload.Bool("waitForFinish");

            int timeoutMs = 1800000;
            if (ctx.Payload.Has("timeoutMs")) timeoutMs = ctx.Payload.Int("timeoutMs", 1800000);

            dynamic dte = ctx.Dte(true);
            Json.JObj solution = GetSolutionInfo(dte);
            if (!solution.Bool("isOpen")) throw new BridgeException("No solution is open in XAE");

            dynamic solutionBuild = dte.Solution.SolutionBuild;

            switch (actionName)
            {
                case "clean":
                    solutionBuild.Clean(waitForFinish);
                    break;
                case "build":
                    solutionBuild.Build(waitForFinish);
                    break;
                case "rebuild":
                    solutionBuild.Clean(waitForFinish);
                    if (waitForFinish)
                    {
                        WaitForBuildFinish(solutionBuild, timeoutMs);
                    }
                    solutionBuild.Build(waitForFinish);
                    break;
                default:
                    throw new BridgeException("Unsupported build action: " + actionName);
            }

            Json.JObj buildResult = new Json.JObj();
            buildResult["buildState"] = (int)solutionBuild.BuildState;
            buildResult["lastBuildInfo"] = null;

            if (waitForFinish)
            {
                buildResult = WaitForBuildFinish(solutionBuild, timeoutMs);
            }
            else
            {
                try { buildResult["lastBuildInfo"] = (int)solutionBuild.LastBuildInfo; }
                catch { }
            }

            var data = new Json.JObj();
            data["action"] = actionName;
            data["waited"] = waitForFinish;
            data["solution"] = solution;
            data["build"] = buildResult;
            return data;
        }

        // ---- error-list reading (port of XaeErrorListProbe, bridge L205-260) -
        // Reads the DTE ToolWindows ErrorList through the STRONGLY-TYPED DTE2 cast,
        // exactly like the PS bridge's XaeErrorListProbe. Raw IDispatch late
        // binding (`dynamic dte.ToolWindows.ErrorList`) returns NULL on TcXaeShell
        // — EnvDTE80.ToolWindows.get_ErrorList is not reachable that way — so the
        // earlier dynamic port always reported the list "unavailable". The typed
        // cast (GetTypedObjectForIUnknown → DTE2) returns a live ErrorList. The
        // EnvDTE PIAs are loaded at runtime by VsInterop. Returns null + an error
        // string on failure (matches the PS {available:false} path). Item key order
        // matches the PS handler at L3935-3942: description, fileName, line, column,
        // project, errorLevel.
        private sealed class ErrorListResult
        {
            public int TotalCount;
            public Json.JArr Items;
        }

        private static ErrorListResult ReadErrorList(ActionContext ctx, int limit, out string error)
        {
            error = null;
            IntPtr pUnk = IntPtr.Zero;
            try
            {
                // Acquire the DTE inside the try so a dead/absent XAE (ctx.Dte
                // throws) takes the graceful {available:false, error:...} path
                // instead of escaping as a hard com_error.
                object rawDte = ctx.Dte(true);
                pUnk = Marshal.GetIUnknownForObject(rawDte);
                EnvDTE80.DTE2 dte = (EnvDTE80.DTE2)Marshal.GetTypedObjectForIUnknown(pUnk, typeof(EnvDTE80.DTE2));

                try { dte.ExecuteCommand("View.ErrorList", " "); }
                catch { }
                System.Threading.Thread.Sleep(1000);

                EnvDTE80.ErrorList errorList = dte.ToolWindows.ErrorList;
                if (errorList == null) { error = "ToolWindows.ErrorList returned null"; return null; }

                try { errorList.ShowErrors = true; } catch { }
                try { errorList.ShowWarnings = true; } catch { }
                try { errorList.ShowMessages = true; } catch { }

                EnvDTE80.ErrorItems errorItems = errorList.ErrorItems;
                int totalCount = errorItems.Count;
                int returnedCount = totalCount < limit ? totalCount : limit;

                var items = new Json.JArr();
                for (int i = 1; i <= returnedCount; i++)
                {
                    EnvDTE80.ErrorItem item = errorItems.Item(i);
                    var o = new Json.JObj();
                    o["description"] = ComHelpers.SafeStr(delegate() { return item.Description; });
                    o["fileName"] = ComHelpers.SafeStr(delegate() { return item.FileName; });
                    o["line"] = NullableInt(delegate() { return item.Line; });
                    o["column"] = NullableInt(delegate() { return item.Column; });
                    o["project"] = ComHelpers.SafeStr(delegate() { return item.Project; });
                    o["errorLevel"] = ComHelpers.SafeStr(delegate() { return item.ErrorLevel; });
                    items.Add(o);
                }

                ErrorListResult result = new ErrorListResult();
                result.TotalCount = totalCount;
                result.Items = items;
                return result;
            }
            catch (Exception ex)
            {
                error = ex.GetType().Name + ": " + ex.Message;
                Log.Error("ReadErrorList failed", ex);
                return null;
            }
            finally
            {
                if (pUnk != IntPtr.Zero) Marshal.Release(pUnk);
            }
        }

        // Get-SafeValue { [int]$x } / Normalize-ScalarValue: a value that fails to
        // read becomes null (not 0), matching the PS shape.
        private static object NullableInt(Func<object> f)
        {
            try
            {
                object v = f();
                if (v == null) return null;
                return (object)ComHelpers.ToInt(v);
            }
            catch { return null; }
        }
    }
}
