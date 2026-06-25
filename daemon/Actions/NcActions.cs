using System;
using System.Collections.Generic;

namespace Te1000Daemon
{
    // nc tool group.
    // NC tasks/axes live under the TINC (NC configuration) tree node.
    // All three actions are READ-only — no cache invalidation needed.
    // Read lookups go through ctx.Cache.LookupItem. C#5-clean (no interpolation,
    // no out var, no expression-bodied members, no pattern matching).
    internal static class NcActions
    {
        public static void Register(Dictionary<string, ActionHandler> h)
        {
            h["nc_list_tasks"] = ListTasks;
            h["nc_list_axes"] = ListAxes;
            h["nc_get_axis_info"] = GetAxisInfo;
        }

        // Mirror PS Normalize-ScalarValue (Get-SafeValue { [int]$x }) which yields
        // null when the producer throws / is null. JObj stores object (boxed int or null).
        private static object SafeIntObj(Func<object> f)
        {
            try
            {
                object v = f();
                if (v == null) return null;
                return ComHelpers.ToInt(v);
            }
            catch { return null; }
        }

        // Resolve-NcTaskPath (bridge ~L3450) — ported inline.
        // If a path was requested, return it as-is. Otherwise default to the first
        // NC task under TINC ("TINC^<name>").
        private static string ResolveNcTaskPath(dynamic sysManager, string requestedTaskPath)
        {
            if (!string.IsNullOrWhiteSpace(requestedTaskPath))
            {
                return requestedTaskPath;
            }

            dynamic motionRoot = ComHelpers.GetTreeItem(sysManager, "TINC");
            if (ComHelpers.ChildCount(motionRoot) < 1)
            {
                throw new BridgeException("No NC tasks were found under TINC");
            }

            dynamic firstTask = ComHelpers.Child(motionRoot, 1);
            string name = ComHelpers.SafeStr(delegate { return firstTask.Name; });
            if (!string.IsNullOrWhiteSpace(name))
            {
                return "TINC^" + name;
            }

            throw new BridgeException("Unable to resolve an NC task path under TINC");
        }

        // --- nc_list_tasks (L5320-5348) --------------------------------------
        private static Json.JObj ListTasks(ActionContext ctx)
        {
            dynamic sm = ctx.SysManager();
            dynamic motionRoot = ctx.Cache.LookupItem(sm, "TINC");

            var tasks = new Json.JArr();
            int count = ComHelpers.ChildCount(motionRoot);
            for (int i = 1; i <= count; i++)
            {
                dynamic child = ComHelpers.Child(motionRoot, i);
                var t = new Json.JObj();
                t["name"] = ComHelpers.SafeStr(delegate { return child.Name; });
                t["pathName"] = ComHelpers.SafeStr(delegate { return child.PathName; });
                t["childCount"] = SafeIntObj(delegate { return child.ChildCount; });
                t["itemType"] = SafeIntObj(delegate { return child.ItemType; });
                tasks.Add(t);
            }

            var data = new Json.JObj();
            data["rootPath"] = "TINC";
            data["count"] = tasks.Count;
            data["tasks"] = tasks;
            return data;
        }

        // --- nc_list_axes (L5350-5391) ---------------------------------------
        private static Json.JObj ListAxes(ActionContext ctx)
        {
            dynamic sm = ctx.SysManager();

            string requestedTaskPath = null;
            if (ctx.Payload.Truthy("taskPath"))
            {
                requestedTaskPath = ctx.Payload.Str("taskPath");
            }

            string taskPath = ResolveNcTaskPath(sm, requestedTaskPath);
            dynamic task = ctx.Cache.LookupItem(sm, taskPath);
            dynamic axesRoot = task.LookupChild("Axes");
            if (axesRoot == null)
            {
                throw new BridgeException("Axes node was not found under task: " + taskPath);
            }

            string axesPath = ComHelpers.SafeStr(delegate { return axesRoot.PathName; });

            var axes = new Json.JArr();
            int count = ComHelpers.ChildCount(axesRoot);
            for (int i = 1; i <= count; i++)
            {
                dynamic child = ComHelpers.Child(axesRoot, i);
                var a = new Json.JObj();
                a["name"] = ComHelpers.SafeStr(delegate { return child.Name; });
                a["pathName"] = ComHelpers.SafeStr(delegate { return child.PathName; });
                a["childCount"] = SafeIntObj(delegate { return child.ChildCount; });
                a["itemType"] = SafeIntObj(delegate { return child.ItemType; });
                a["itemSubType"] = SafeIntObj(delegate { return child.ItemSubType; });
                a["itemSubTypeName"] = ComHelpers.SafeStr(delegate { return child.ItemSubTypeName; });
                axes.Add(a);
            }

            var data = new Json.JObj();
            data["taskPath"] = taskPath;
            data["axesPath"] = axesPath;
            data["count"] = axes.Count;
            data["axes"] = axes;
            return data;
        }

        // --- nc_get_axis_info (L5393-5434) -----------------------------------
        private static Json.JObj GetAxisInfo(ActionContext ctx)
        {
            string axisPath = ctx.Payload.Str("axisPath");
            if (string.IsNullOrWhiteSpace(axisPath))
            {
                throw new BridgeException("axisPath is required");
            }

            dynamic sm = ctx.SysManager();

            int axesSep = axisPath.LastIndexOf("^Axes^", StringComparison.Ordinal);
            if (axesSep < 0)
            {
                throw new BridgeException("axisPath must include ^Axes^ before the axis name");
            }
            string taskPath = axisPath.Substring(0, axesSep);
            string axisName = axisPath.Substring(axesSep + 6);

            dynamic task = ctx.Cache.LookupItem(sm, taskPath);
            dynamic axesRoot = task.LookupChild("Axes");
            if (axesRoot == null)
            {
                throw new BridgeException("Axes node was not found under task: " + taskPath);
            }

            dynamic axis = GetChildTreeItemByName(axesRoot, axisName);

            var children = new Json.JArr();
            int count = ComHelpers.ChildCount(axis);
            for (int i = 1; i <= count; i++)
            {
                children.Add(ComHelpers.ConvertTreeItem(ComHelpers.Child(axis, i)));
            }

            var data = new Json.JObj();
            data["axis"] = ComHelpers.ConvertTreeItem(axis);
            data["itemSubType"] = SafeIntObj(delegate { return axis.ItemSubType; });
            data["itemSubTypeName"] = ComHelpers.SafeStr(delegate { return axis.ItemSubTypeName; });
            data["moduleTypeName"] = ComHelpers.SafeStr(delegate { return axis.ModuleTypeName; });
            data["moduleInstanceName"] = ComHelpers.SafeStr(delegate { return axis.ModuleInstanceName; });
            data["children"] = children;
            return data;
        }

        // Get-ChildTreeItemByName (bridge L3469-3489) — find a direct child by Name,
        // throw if absent. Ported inline for nc_get_axis_info.
        private static dynamic GetChildTreeItemByName(dynamic parentItem, string childName)
        {
            int count = ComHelpers.ChildCount(parentItem);
            for (int i = 1; i <= count; i++)
            {
                dynamic child = ComHelpers.Child(parentItem, i);
                string name = ComHelpers.SafeStr(delegate { return child.Name; });
                if (name == childName)
                {
                    return child;
                }
            }

            string parentPath = ComHelpers.SafeStr(delegate { return parentItem.PathName; });
            throw new BridgeException("Child '" + childName + "' was not found under '" + parentPath + "'");
        }
    }
}
