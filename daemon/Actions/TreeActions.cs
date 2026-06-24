using System;
using System.Collections.Generic;
using System.Xml;

namespace Te1000Daemon
{
    // tc_tree tree-item operations ported from te1000-bridge.ps1 (L3973-5306).
    // Read lookups go through ctx.Cache.LookupItem; mutating actions invalidate
    // the affected subtree after success. C#5-clean (no interpolation, no out var,
    // no expression-bodied members).
    internal static class TreeActions
    {
        public static void Register(Dictionary<string, ActionHandler> h)
        {
            h["twincat_lookup_tree_item"] = LookupTreeItem;
            h["twincat_test_item_path"] = TestItemPath;
            h["twincat_test_item_paths"] = TestItemPaths;
            h["twincat_lookup_tree_items"] = LookupTreeItems;
            h["twincat_resolve_variable_path"] = ResolveVariablePath;
            h["twincat_list_children"] = ListChildren;
            h["twincat_get_tree_item_xml"] = GetTreeItemXml;
            h["twincat_set_tree_item_xml"] = SetTreeItemXml;
            h["twincat_rename_tree_item"] = RenameTreeItem;
            h["twincat_rename_tree_items"] = RenameTreeItems;
            h["twincat_set_tree_item_xml_batch"] = SetTreeItemXmlBatch;
            h["twincat_create_child"] = CreateChild;
            h["twincat_delete_child"] = DeleteChild;
            h["twincat_create_children"] = CreateChildren;
            h["twincat_delete_children"] = DeleteChildren;
            h["twincat_import_child"] = ImportChild;
            h["twincat_export_child"] = ExportChild;
            h["twincat_create_io"] = CreateIo;
            h["twincat_get_target_netid"] = GetTargetNetId;
            h["twincat_set_target_netid"] = SetTargetNetId;
            h["twincat_get_system_manager_errors"] = GetSystemManagerErrors;
            h["twincat_rescan_plc_project"] = RescanPlcProject;
            h["twincat_scan_io_boxes"] = ScanIoBoxes;
        }

        // --- twincat_lookup_tree_item (L3973-3984) ---------------------------
        private static Json.JObj LookupTreeItem(ActionContext ctx)
        {
            string treePath = ctx.Payload.Str("treePath");
            dynamic sm = ctx.SysManager();
            dynamic item = ctx.Cache.LookupItem(sm, treePath);
            return ComHelpers.ConvertTreeItem(item);
        }

        // --- twincat_test_item_path (L3986-4010) -----------------------------
        private static Json.JObj TestItemPath(ActionContext ctx)
        {
            string treePath = ctx.Payload.Str("treePath");
            if (string.IsNullOrWhiteSpace(treePath)) throw new BridgeException("treePath is required");

            dynamic sm = ctx.SysManager();
            bool exists = false;
            try
            {
                dynamic item = ctx.Cache.LookupItem(sm, treePath);
                exists = (item != null);
            }
            catch { exists = false; }

            var data = new Json.JObj();
            data["treePath"] = treePath;
            data["exists"] = exists;
            return data;
        }

        // --- twincat_test_item_paths (L4012-4061) ----------------------------
        private static Json.JObj TestItemPaths(ActionContext ctx)
        {
            Json.JArr paths = ctx.Payload.Arr("paths");
            if (paths == null || paths.Count == 0) throw new BridgeException("paths is required");

            dynamic sm = ctx.SysManager();
            var results = new Json.JArr();
            int found = 0;
            int missing = 0;

            foreach (object entry in paths)
            {
                string entryPath = ScalarStr(entry);
                try
                {
                    bool exists = false;
                    try
                    {
                        dynamic item = ctx.Cache.LookupItem(sm, entryPath);
                        exists = (item != null);
                    }
                    catch { exists = false; }

                    if (exists) found++; else missing++;
                    var r = new Json.JObj();
                    r["path"] = entryPath;
                    r["exists"] = exists;
                    results.Add(r);
                }
                catch (Exception ex)
                {
                    missing++;
                    var r = new Json.JObj();
                    r["path"] = entryPath;
                    r["exists"] = false;
                    r["error"] = ex.Message;
                    results.Add(r);
                }
            }

            var data = new Json.JObj();
            data["count"] = paths.Count;
            data["found"] = found;
            data["missing"] = missing;
            data["results"] = results;
            return data;
        }

        // --- twincat_lookup_tree_items (L4063-4105) --------------------------
        private static Json.JObj LookupTreeItems(ActionContext ctx)
        {
            Json.JArr paths = ctx.Payload.Arr("paths");
            if (paths == null || paths.Count == 0) throw new BridgeException("paths is required");

            dynamic sm = ctx.SysManager();
            var results = new Json.JArr();
            int succeeded = 0;
            int failed = 0;

            foreach (object entry in paths)
            {
                string entryPath = ScalarStr(entry);
                try
                {
                    dynamic item = ctx.Cache.LookupItem(sm, entryPath);
                    Json.JObj converted = ComHelpers.ConvertTreeItem(item);
                    converted["path"] = entryPath;
                    converted["ok"] = true;
                    succeeded++;
                    results.Add(converted);
                }
                catch (Exception ex)
                {
                    failed++;
                    var r = new Json.JObj();
                    r["path"] = entryPath;
                    r["ok"] = false;
                    r["error"] = ex.Message;
                    results.Add(r);
                }
            }

            var data = new Json.JObj();
            data["count"] = paths.Count;
            data["succeeded"] = succeeded;
            data["failed"] = failed;
            data["results"] = results;
            return data;
        }

        // --- twincat_resolve_variable_path (L4107-4122) ----------------------
        // Ports Resolve-TwinCatVariablePath (L3408-3448): try each dot->^ candidate
        // and return {originalPath, resolvedPath, resolved, attempts[]}.
        private static Json.JObj ResolveVariablePath(ActionContext ctx)
        {
            string variablePath = ctx.Payload.Str("variablePath");
            if (string.IsNullOrWhiteSpace(variablePath)) throw new BridgeException("variablePath is required");

            dynamic sm = ctx.SysManager();
            return ResolveVariablePathData(ctx, sm, variablePath);
        }

        private static Json.JObj ResolveVariablePathData(ActionContext ctx, dynamic sm, string variablePath)
        {
            var attempts = new Json.JArr();
            foreach (string candidate in ComHelpers.VariablePathCandidates(variablePath))
            {
                try
                {
                    dynamic item = ctx.Cache.LookupItem(sm, candidate);
                    var att = new Json.JObj();
                    att["path"] = candidate;
                    att["exists"] = true;
                    att["item"] = ComHelpers.ConvertTreeItem(item);
                    attempts.Add(att);

                    var ok = new Json.JObj();
                    ok["originalPath"] = variablePath;
                    ok["resolvedPath"] = candidate;
                    ok["resolved"] = true;
                    ok["attempts"] = attempts;
                    return ok;
                }
                catch (Exception ex)
                {
                    var att = new Json.JObj();
                    att["path"] = candidate;
                    att["exists"] = false;
                    att["error"] = ex.Message;
                    attempts.Add(att);
                }
            }

            var data = new Json.JObj();
            data["originalPath"] = variablePath;
            data["resolvedPath"] = variablePath;
            data["resolved"] = false;
            data["attempts"] = attempts;
            return data;
        }

        // --- twincat_list_children (L4124-4212) ------------------------------
        // Bounded one-level walk: the parent is read via the cache, then its direct
        // children are enumerated (1-based). For nodes with ZERO standard children
        // the box ProduceXml is parsed for <Slot><Module><Name> entries and each is
        // resolved by its full "<treePath>^<moduleName>" path (kind=module). The
        // walk never descends past the requested node + its modules.
        private static Json.JObj ListChildren(ActionContext ctx)
        {
            string treePath = ctx.Payload.Str("treePath");
            dynamic sm = ctx.SysManager();
            dynamic item = ctx.Cache.LookupItem(sm, treePath);

            var children = new Json.JArr();
            int count = ComHelpers.ChildCount(item);
            var listedNames = new HashSet<string>(StringComparer.Ordinal);

            for (int i = 1; i <= count; i++)
            {
                dynamic childItem = ComHelpers.Child(item, i);
                Json.JObj childEntry = ComHelpers.ConvertTreeItem(childItem);
                childEntry["kind"] = "child";
                children.Add(childEntry);
                string childName = childEntry.Str("name");
                if (!string.IsNullOrEmpty(childName)) listedNames.Add(childName);
            }

            // Augmentation: only on nodes with ZERO standard children, surface
            // addressable slot-modules (e.g. Festo CPX-AP-A-EC-M12 carriers) that
            // are not in the Child/ChildCount collection but live in ProduceXml as
            // <Slot><Module> entries and resolve by "<treePath>^<moduleName>".
            // Every step is defensively guarded so a normal call never breaks.
            if (count == 0)
            {
                string boxXml = null;
                try { boxXml = (string)item.ProduceXml(); }
                catch { boxXml = null; }

                if (!string.IsNullOrEmpty(boxXml))
                {
                    var moduleNames = new List<string>();
                    try
                    {
                        var doc = new XmlDocument();
                        doc.LoadXml(boxXml);
                        XmlNodeList nodes = doc.SelectNodes("//Slot/Module/Name");
                        if (nodes != null)
                        {
                            foreach (XmlNode nameNode in nodes)
                            {
                                string moduleName = nameNode.InnerText;
                                if (!string.IsNullOrEmpty(moduleName)) moduleNames.Add(moduleName);
                            }
                        }
                    }
                    catch { moduleNames = new List<string>(); }

                    foreach (string moduleName in moduleNames)
                    {
                        if (listedNames.Contains(moduleName)) continue;
                        dynamic moduleItem = null;
                        try { moduleItem = ctx.Cache.LookupItem(sm, treePath + "^" + moduleName); }
                        catch { moduleItem = null; }
                        if (moduleItem == null) continue;
                        Json.JObj moduleEntry = ComHelpers.ConvertTreeItem(moduleItem);
                        moduleEntry["kind"] = "module";
                        children.Add(moduleEntry);
                        listedNames.Add(moduleName);
                    }
                }
            }

            var data = new Json.JObj();
            data["treePath"] = treePath;
            data["childCount"] = children.Count;
            data["children"] = children;
            return data;
        }

        // --- twincat_get_tree_item_xml (L4214-4272) --------------------------
        private static Json.JObj GetTreeItemXml(ActionContext ctx)
        {
            string treePath = ctx.Payload.Str("treePath");
            bool summary = false;
            if (ctx.Payload.Has("summary")) summary = ctx.Payload.Bool("summary");

            dynamic sm = ctx.SysManager();
            dynamic item = ctx.Cache.LookupItem(sm, treePath);

            if (!summary)
            {
                string xml = ComHelpers.StripTreeImage(ComHelpers.ProduceXml(item));
                var d = new Json.JObj();
                d["treePath"] = treePath;
                d["xml"] = xml;
                return d;
            }

            // Compact summary: identity + slot/module list, without the big XML blob.
            Json.JObj summaryData = ComHelpers.ConvertTreeItem(item);

            var moduleNames = new Json.JArr();
            string boxXml = null;
            try { boxXml = (string)item.ProduceXml(); }
            catch { boxXml = null; }
            if (!string.IsNullOrEmpty(boxXml))
            {
                try
                {
                    var doc = new XmlDocument();
                    doc.LoadXml(boxXml);
                    XmlNodeList nodes = doc.SelectNodes("//Slot/Module/Name");
                    if (nodes != null)
                    {
                        foreach (XmlNode nameNode in nodes)
                        {
                            string moduleName = nameNode.InnerText;
                            if (!string.IsNullOrEmpty(moduleName)) moduleNames.Add(moduleName);
                        }
                    }
                }
                catch { moduleNames = new Json.JArr(); }
            }

            summaryData["modules"] = moduleNames;

            var data = new Json.JObj();
            data["treePath"] = treePath;
            data["summary"] = summaryData;
            return data;
        }

        // --- twincat_set_tree_item_xml (L4274-4303) --------------------------
        private static Json.JObj SetTreeItemXml(ActionContext ctx)
        {
            string treePath = ctx.Payload.Str("treePath");
            string xml = ctx.Payload.Str("xml");
            if (string.IsNullOrWhiteSpace(xml)) throw new BridgeException("xml is required");

            bool returnXml = false;
            if (ctx.Payload.Has("returnXml")) returnXml = ctx.Payload.Bool("returnXml");

            dynamic sm = ctx.SysManager();
            dynamic item = SetTreeItemXmlInternal(ctx, sm, treePath, xml);

            var data = new Json.JObj();
            data["treePath"] = treePath;
            if (returnXml) data["xml"] = ComHelpers.StripTreeImage(ComHelpers.ProduceXml(item));
            return data;
        }

        // --- twincat_rename_tree_item (L4305-4326) ---------------------------
        private static Json.JObj RenameTreeItem(ActionContext ctx)
        {
            string treePath = ctx.Payload.Str("treePath");
            string newName = ctx.Payload.Str("newName");
            if (string.IsNullOrWhiteSpace(newName)) throw new BridgeException("newName is required");

            dynamic sm = ctx.SysManager();
            string newPath = RenameTreeItemInternal(ctx, sm, treePath, newName);

            var data = new Json.JObj();
            data["treePath"] = treePath;
            data["newName"] = newName;
            data["newPath"] = newPath;
            return data;
        }

        // --- twincat_rename_tree_items (L4328-4417) --------------------------
        private static Json.JObj RenameTreeItems(ActionContext ctx)
        {
            string basePath = ctx.Payload.Str("basePath");
            Json.JArr renames = ctx.Payload.Arr("renames");
            if (renames == null || renames.Count == 0) throw new BridgeException("renames is required");
            bool save = false;
            if (ctx.Payload.Has("save")) save = ctx.Payload.Bool("save");

            dynamic sm = ctx.SysManager();
            var results = new Json.JArr();
            int succeeded = 0;
            int failed = 0;

            foreach (object entryObj in renames)
            {
                Json.JObj entry = entryObj as Json.JObj;
                string entryName = (entry != null && entry.Has("name")) ? entry.Str("name") : null;
                string entryPath = (entry != null && entry.Has("path")) ? entry.Str("path") : null;
                string entryNewName = (entry != null && entry.Has("newName")) ? entry.Str("newName") : null;

                if (string.IsNullOrWhiteSpace(entryName)) entryName = null;

                string targetPath = null;
                if (!string.IsNullOrWhiteSpace(entryPath)) targetPath = entryPath;
                else if (entryName != null) targetPath = basePath + "^" + entryName;

                if (targetPath == null)
                {
                    failed++;
                    var r = new Json.JObj();
                    r["name"] = entryName;
                    r["newName"] = entryNewName;
                    r["ok"] = false;
                    r["error"] = "entry needs name or path";
                    results.Add(r);
                    continue;
                }

                try
                {
                    RenameTreeItemInternal(ctx, sm, targetPath, entryNewName);
                    succeeded++;
                    var r = new Json.JObj();
                    r["name"] = entryName;
                    r["newName"] = entryNewName;
                    r["ok"] = true;
                    results.Add(r);
                }
                catch (Exception ex)
                {
                    failed++;
                    var r = new Json.JObj();
                    r["name"] = entryName;
                    r["newName"] = entryNewName;
                    r["ok"] = false;
                    r["error"] = ex.Message;
                    results.Add(r);
                }
            }

            var data = new Json.JObj();
            data["parent"] = basePath;
            data["count"] = renames.Count;
            data["succeeded"] = succeeded;
            data["failed"] = failed;
            data["results"] = results;
            if (save)
            {
                bool saved = false;
                try { ctx.Dte().ExecuteCommand("File.SaveAll"); saved = true; }
                catch { saved = false; }
                data["saved"] = saved;
            }
            return data;
        }

        // --- twincat_set_tree_item_xml_batch (L4419-4499) --------------------
        private static Json.JObj SetTreeItemXmlBatch(ActionContext ctx)
        {
            Json.JArr items = ctx.Payload.Arr("items");
            if (items == null || items.Count == 0) throw new BridgeException("items is required");

            bool returnXml = false;
            if (ctx.Payload.Has("returnXml")) returnXml = ctx.Payload.Bool("returnXml");
            bool save = false;
            if (ctx.Payload.Has("save")) save = ctx.Payload.Bool("save");

            dynamic sm = ctx.SysManager();
            var results = new Json.JArr();
            int succeeded = 0;
            int failed = 0;

            foreach (object entryObj in items)
            {
                Json.JObj entry = entryObj as Json.JObj;
                string entryPath = (entry != null && entry.Has("path")) ? entry.Str("path") : null;
                string entryXml = (entry != null && entry.Has("xml")) ? entry.Str("xml") : null;

                if (string.IsNullOrWhiteSpace(entryPath) || string.IsNullOrWhiteSpace(entryXml))
                {
                    failed++;
                    var r = new Json.JObj();
                    r["path"] = entryPath;
                    r["ok"] = false;
                    r["error"] = "entry needs path and xml";
                    results.Add(r);
                    continue;
                }

                try
                {
                    dynamic item = SetTreeItemXmlInternal(ctx, sm, entryPath, entryXml);
                    succeeded++;
                    var r = new Json.JObj();
                    r["path"] = entryPath;
                    r["ok"] = true;
                    if (returnXml) r["xml"] = ComHelpers.StripTreeImage(ComHelpers.ProduceXml(item));
                    results.Add(r);
                }
                catch (Exception ex)
                {
                    failed++;
                    var r = new Json.JObj();
                    r["path"] = entryPath;
                    r["ok"] = false;
                    r["error"] = ex.Message;
                    results.Add(r);
                }
            }

            var data = new Json.JObj();
            data["count"] = items.Count;
            data["succeeded"] = succeeded;
            data["failed"] = failed;
            data["results"] = results;
            if (save)
            {
                bool saved = false;
                try { ctx.Dte().ExecuteCommand("File.SaveAll"); saved = true; }
                catch { saved = false; }
                data["saved"] = saved;
            }
            return data;
        }

        // --- twincat_create_child (L4755-4783) -------------------------------
        private static Json.JObj CreateChild(ActionContext ctx)
        {
            string parentPath = ctx.Payload.Str("parentPath");
            string childName = ctx.Payload.Str("childName");
            int subType = ctx.Payload.Int("subType", 0);
            string beforeChildName = ctx.Payload.Truthy("beforeChildName") ? ctx.Payload.Str("beforeChildName") : "";
            string createInfo = (ctx.Payload.Has("createInfo") && !string.IsNullOrWhiteSpace(ctx.Payload.Str("createInfo")))
                ? ctx.Payload.Str("createInfo") : null;

            if (string.IsNullOrWhiteSpace(parentPath) || string.IsNullOrWhiteSpace(childName))
                throw new BridgeException("parentPath and childName are required");

            dynamic sm = ctx.SysManager();
            dynamic parent = ComHelpers.GetTreeItem(sm, parentPath);
            dynamic child = parent.CreateChild(childName, subType, beforeChildName, createInfo);

            AssertWellFormedChild(parent, child, childName, subType, parentPath);
            ctx.Cache.Invalidate(parentPath);
            ctx.Cache.InvalidateEnum(); // structural: tree membership changed

            var data = new Json.JObj();
            data["parentPath"] = parentPath;
            data["child"] = ComHelpers.ConvertTreeItem(child);
            return data;
        }

        // --- twincat_delete_child (L4785-4805) -------------------------------
        private static Json.JObj DeleteChild(ActionContext ctx)
        {
            string parentPath = ctx.Payload.Str("parentPath");
            string childName = ctx.Payload.Str("childName");
            if (string.IsNullOrWhiteSpace(parentPath) || string.IsNullOrWhiteSpace(childName))
                throw new BridgeException("parentPath and childName are required");

            dynamic sm = ctx.SysManager();
            dynamic parent = ComHelpers.GetTreeItem(sm, parentPath);
            parent.DeleteChild(childName);
            ctx.Cache.Invalidate(parentPath);
            ctx.Cache.InvalidateEnum(); // structural: tree membership changed

            var data = new Json.JObj();
            data["parentPath"] = parentPath;
            data["childName"] = childName;
            data["deleted"] = true;
            return data;
        }

        // --- twincat_create_children (L4808-4892) ----------------------------
        private static Json.JObj CreateChildren(ActionContext ctx)
        {
            Json.JArr creates = ctx.Payload.Arr("creates");
            if (creates == null || creates.Count == 0) throw new BridgeException("creates is required");
            bool save = false;
            if (ctx.Payload.Has("save")) save = ctx.Payload.Bool("save");

            dynamic sm = ctx.SysManager();
            var results = new Json.JArr();
            int succeeded = 0;
            int failed = 0;

            foreach (object entryObj in creates)
            {
                Json.JObj entry = entryObj as Json.JObj;
                string entryParent = (entry != null && entry.Has("parent")) ? entry.Str("parent") : null;
                string entryName = (entry != null && entry.Has("name")) ? entry.Str("name") : null;
                bool hasSubType = (entry != null && entry.Has("subType"));
                string entryBefore = (entry != null && entry.Has("before") && entry.Truthy("before")) ? entry.Str("before") : "";
                string entryCreateInfo = (entry != null && entry.Has("createInfo") && !string.IsNullOrWhiteSpace(entry.Str("createInfo")))
                    ? entry.Str("createInfo") : null;

                if (string.IsNullOrWhiteSpace(entryParent) || string.IsNullOrWhiteSpace(entryName) || !hasSubType)
                {
                    failed++;
                    var r = new Json.JObj();
                    r["parent"] = entryParent;
                    r["name"] = entryName;
                    r["ok"] = false;
                    r["error"] = "entry needs parent, name, subType";
                    results.Add(r);
                    continue;
                }

                int entrySubType = entry.Int("subType", 0);

                try
                {
                    dynamic parent = ComHelpers.GetTreeItem(sm, entryParent);
                    dynamic child = parent.CreateChild(entryName, entrySubType, entryBefore, entryCreateInfo);
                    AssertWellFormedChild(parent, child, entryName, entrySubType, entryParent);
                    ctx.Cache.Invalidate(entryParent);
                    ctx.Cache.InvalidateEnum(); // structural: tree membership changed
                    succeeded++;
                    var r = new Json.JObj();
                    r["parent"] = entryParent;
                    r["ok"] = true;
                    r["child"] = ComHelpers.ConvertTreeItem(child);
                    results.Add(r);
                }
                catch (Exception ex)
                {
                    failed++;
                    var r = new Json.JObj();
                    r["parent"] = entryParent;
                    r["name"] = entryName;
                    r["ok"] = false;
                    r["error"] = ex.Message;
                    results.Add(r);
                }
            }

            var data = new Json.JObj();
            data["count"] = creates.Count;
            data["succeeded"] = succeeded;
            data["failed"] = failed;
            data["results"] = results;
            if (save)
            {
                bool saved = false;
                try { ctx.Dte().ExecuteCommand("File.SaveAll"); saved = true; }
                catch { saved = false; }
                data["saved"] = saved;
            }
            return data;
        }

        // --- twincat_delete_children (L4895-5026) ----------------------------
        private static Json.JObj DeleteChildren(ActionContext ctx)
        {
            Json.JArr deletes = ctx.Payload.Arr("deletes");
            if (deletes == null || deletes.Count == 0) throw new BridgeException("deletes is required");
            bool dryRun = false;
            if (ctx.Payload.Has("dryRun")) dryRun = ctx.Payload.Bool("dryRun");
            bool save = false;
            if (ctx.Payload.Has("save")) save = ctx.Payload.Bool("save");

            dynamic sm = ctx.SysManager();

            if (dryRun)
            {
                // Preview only — never deletes. Resolve the parent and report
                // whether the named child currently exists.
                var dResults = new Json.JArr();
                int present = 0;
                int dMissing = 0;
                foreach (object entryObj in deletes)
                {
                    Json.JObj entry = entryObj as Json.JObj;
                    string entryParent = (entry != null && entry.Has("parent")) ? entry.Str("parent") : null;
                    string entryName = (entry != null && entry.Has("name")) ? entry.Str("name") : null;

                    bool exists = false;
                    if (!string.IsNullOrWhiteSpace(entryParent) && !string.IsNullOrWhiteSpace(entryName))
                    {
                        try
                        {
                            dynamic parent = ctx.Cache.LookupItem(sm, entryParent);
                            try { exists = ChildExistsByName(parent, entryName); }
                            catch { exists = false; }
                        }
                        catch { exists = false; }
                    }

                    if (exists) present++; else dMissing++;
                    var r = new Json.JObj();
                    r["parent"] = entryParent;
                    r["name"] = entryName;
                    r["exists"] = exists;
                    dResults.Add(r);
                }

                var dd = new Json.JObj();
                dd["mode"] = "dryRun";
                dd["count"] = deletes.Count;
                dd["present"] = present;
                dd["missing"] = dMissing;
                dd["results"] = dResults;
                return dd;
            }

            var results = new Json.JArr();
            int succeeded = 0;
            int failed = 0;

            foreach (object entryObj in deletes)
            {
                Json.JObj entry = entryObj as Json.JObj;
                string entryParent = (entry != null && entry.Has("parent")) ? entry.Str("parent") : null;
                string entryName = (entry != null && entry.Has("name")) ? entry.Str("name") : null;

                if (string.IsNullOrWhiteSpace(entryParent) || string.IsNullOrWhiteSpace(entryName))
                {
                    failed++;
                    var r = new Json.JObj();
                    r["parent"] = entryParent;
                    r["name"] = entryName;
                    r["ok"] = false;
                    r["error"] = "entry needs parent, name";
                    results.Add(r);
                    continue;
                }

                try
                {
                    dynamic parent = ComHelpers.GetTreeItem(sm, entryParent);
                    parent.DeleteChild(entryName);
                    ctx.Cache.Invalidate(entryParent);
                    ctx.Cache.InvalidateEnum(); // structural: tree membership changed
                    succeeded++;
                    var r = new Json.JObj();
                    r["parent"] = entryParent;
                    r["name"] = entryName;
                    r["ok"] = true;
                    results.Add(r);
                }
                catch (Exception ex)
                {
                    failed++;
                    var r = new Json.JObj();
                    r["parent"] = entryParent;
                    r["name"] = entryName;
                    r["ok"] = false;
                    r["error"] = ex.Message;
                    results.Add(r);
                }
            }

            var data = new Json.JObj();
            data["count"] = deletes.Count;
            data["succeeded"] = succeeded;
            data["failed"] = failed;
            data["results"] = results;
            if (save)
            {
                bool saved = false;
                try { ctx.Dte().ExecuteCommand("File.SaveAll"); saved = true; }
                catch { saved = false; }
                data["saved"] = saved;
            }
            return data;
        }

        // --- twincat_import_child (L5028-5058) -------------------------------
        private static Json.JObj ImportChild(ActionContext ctx)
        {
            string parentPath = ctx.Payload.Str("parentPath");
            string filePath = ctx.Payload.Str("filePath");
            if (string.IsNullOrWhiteSpace(parentPath) || string.IsNullOrWhiteSpace(filePath))
                throw new BridgeException("parentPath and filePath are required");
            if (!System.IO.File.Exists(filePath))
                throw new BridgeException("Import file not found: " + filePath);

            string beforeChildName = ctx.Payload.Truthy("beforeChildName") ? ctx.Payload.Str("beforeChildName") : "";
            bool reconnect = true;
            if (ctx.Payload.Has("reconnect")) reconnect = ctx.Payload.Bool("reconnect");
            string importAsName = ctx.Payload.Truthy("importAsName") ? ctx.Payload.Str("importAsName") : "";

            dynamic sm = ctx.SysManager();
            dynamic parent = ComHelpers.GetTreeItem(sm, parentPath);
            dynamic child = parent.ImportChild(filePath, beforeChildName, reconnect, importAsName);
            ctx.Cache.Invalidate(parentPath);
            ctx.Cache.InvalidateEnum(); // structural: imported objects changed membership

            var data = new Json.JObj();
            data["parentPath"] = parentPath;
            data["filePath"] = filePath;
            data["child"] = ComHelpers.ConvertTreeItem(child);
            return data;
        }

        // --- twincat_export_child (L5061-5084) -------------------------------
        private static Json.JObj ExportChild(ActionContext ctx)
        {
            string parentPath = ctx.Payload.Str("parentPath");
            string childName = ctx.Payload.Str("childName");
            string filePath = ctx.Payload.Str("filePath");
            if (string.IsNullOrWhiteSpace(parentPath) || string.IsNullOrWhiteSpace(childName) || string.IsNullOrWhiteSpace(filePath))
                throw new BridgeException("parentPath, childName, and filePath are required");

            dynamic sm = ctx.SysManager();
            dynamic parent = ComHelpers.GetTreeItem(sm, parentPath);
            parent.ExportChild(childName, filePath);

            var data = new Json.JObj();
            data["parentPath"] = parentPath;
            data["childName"] = childName;
            data["filePath"] = filePath;
            data["exported"] = true;
            return data;
        }

        // --- twincat_create_io (L5086-5217) ----------------------------------
        // Native EtherCAT IO creator: for each module, CreateChild(name, 9099,
        // before, "<productString>") then Assert-WellFormedChild. Sequential,
        // continue-on-error, flat roll-up across all racks. One optional global save.
        private static Json.JObj CreateIo(ActionContext ctx)
        {
            Json.JArr racks = ctx.Payload.Arr("racks");
            if (racks == null || racks.Count == 0)
                throw new BridgeException("racks (non-empty array of {parent, modules:[...]}) is required");
            bool save = ctx.Payload.Has("save") && ctx.Payload.Bool("save");

            dynamic sm = ctx.SysManager();
            var results = new Json.JArr();
            int succeeded = 0;
            int failed = 0;

            foreach (object rackObj in racks)
            {
                Json.JObj rack = rackObj as Json.JObj;
                string parentPath = (rack != null) ? rack.Str("parent") : null;
                Json.JArr modules = (rack != null) ? rack.Arr("modules") : null;

                // Resolve the parent once per rack; a bad parent turns every module
                // under it into a clean per-entry failure (loop never throws).
                dynamic parent = null;
                string parentError = null;
                if (string.IsNullOrWhiteSpace(parentPath))
                {
                    parentError = "rack.parent is required";
                }
                else
                {
                    try { parent = ComHelpers.GetTreeItem(sm, parentPath); }
                    catch (Exception ex) { parentError = "parent lookup failed: " + ex.Message; }
                }

                if (modules == null) modules = new Json.JArr();

                foreach (object mObj in modules)
                {
                    Json.JObj m = mObj as Json.JObj;
                    string type = (m != null) ? m.Str("type") : null;
                    string revision = (m != null && m.Has("revision") && !string.IsNullOrWhiteSpace(m.Str("revision")))
                        ? m.Str("revision") : null;
                    string wantName = (m != null && m.Has("name") && !string.IsNullOrWhiteSpace(m.Str("name")))
                        ? m.Str("name") : null;
                    string before = (m != null && m.Has("before") && !string.IsNullOrWhiteSpace(m.Str("before")))
                        ? m.Str("before") : "";
                    string boxName = !string.IsNullOrEmpty(wantName) ? wantName : type;

                    var entry = new Json.JObj();
                    entry["parent"] = parentPath;
                    entry["type"] = type;
                    entry["name"] = boxName;
                    entry["ok"] = false;

                    if (parentError != null)
                    {
                        entry["error"] = parentError;
                        failed++;
                        results.Add(entry);
                        continue;
                    }
                    if (string.IsNullOrWhiteSpace(type))
                    {
                        entry["error"] = "module.type is required";
                        failed++;
                        results.Add(entry);
                        continue;
                    }

                    // createInfo = the plain product string. Bare type => latest
                    // revision; a revision suffix yields the full pinned string
                    // (appended verbatim if the caller passed only the suffix).
                    string createInfo;
                    if (revision != null)
                        createInfo = revision.StartsWith(type, StringComparison.Ordinal) ? revision : (type + "-" + revision);
                    else
                        createInfo = type;

                    try
                    {
                        dynamic child = parent.CreateChild(boxName, 9099, before, createInfo);
                        AssertWellFormedChild(parent, child, boxName, 9099, parentPath);
                        entry["name"] = ComHelpers.SafeStr(delegate { return child.Name; });
                        entry["path"] = ComHelpers.SafeStr(delegate { return child.PathName; });
                        entry["createInfo"] = createInfo;
                        entry["ok"] = true;
                        ctx.Cache.Invalidate(parentPath);
                        succeeded++;
                    }
                    catch (Exception ex)
                    {
                        entry["createInfo"] = createInfo;
                        entry["error"] = ex.Message;
                        failed++;
                    }
                    results.Add(entry);
                }
            }

            object saved = null;
            if (save)
            {
                try { ctx.Dte().ExecuteCommand("File.SaveAll"); saved = true; }
                catch { saved = false; }
            }

            var data = new Json.JObj();
            data["count"] = results.Count;
            data["succeeded"] = succeeded;
            data["failed"] = failed;
            data["saved"] = saved;
            data["results"] = results;
            return data;
        }

        // --- twincat_get_target_netid (L5219-5230) ---------------------------
        private static Json.JObj GetTargetNetId(ActionContext ctx)
        {
            dynamic sm = ctx.SysManager();
            var data = new Json.JObj();
            data["targetNetId"] = (string)sm.GetTargetNetId();
            return data;
        }

        // --- twincat_set_target_netid (L5232-5249) ---------------------------
        private static Json.JObj SetTargetNetId(ActionContext ctx)
        {
            string targetNetId = ctx.Payload.Str("targetNetId");
            if (string.IsNullOrWhiteSpace(targetNetId)) throw new BridgeException("targetNetId is required");

            dynamic sm = ctx.SysManager();
            sm.SetTargetNetId(targetNetId);

            var data = new Json.JObj();
            data["targetNetId"] = (string)sm.GetTargetNetId();
            return data;
        }

        // --- twincat_get_system_manager_errors (L5251-5263) ------------------
        private static Json.JObj GetSystemManagerErrors(ActionContext ctx)
        {
            dynamic sm = ctx.SysManager();
            string messages = ComHelpers.SafeStr(delegate { return sm.GetLastErrorMessages(); });

            var data = new Json.JObj();
            data["messages"] = messages;
            return data;
        }

        // --- twincat_rescan_plc_project (L5265-5282) -------------------------
        private static Json.JObj RescanPlcProject(ActionContext ctx)
        {
            string treePath = ctx.Payload.Truthy("treePath") ? ctx.Payload.Str("treePath") : "TIPC";
            string xml = "<TreeItem><PlcDef><ReScan>1</ReScan></PlcDef></TreeItem>";

            dynamic sm = ctx.SysManager();
            dynamic item = ComHelpers.GetTreeItem(sm, treePath);
            item.ConsumeXml(xml);
            ctx.Cache.Invalidate(treePath);
            ctx.Cache.InvalidateEnum(); // structural: rescan regenerates PLC project membership

            var data = new Json.JObj();
            data["treePath"] = treePath;
            data["rescanned"] = true;
            return data;
        }

        // --- twincat_scan_io_boxes (L5284-5304) ------------------------------
        private static Json.JObj ScanIoBoxes(ActionContext ctx)
        {
            string treePath = ctx.Payload.Str("treePath");
            if (string.IsNullOrWhiteSpace(treePath)) throw new BridgeException("treePath is required");
            string xml = "<TreeItem><DeviceDef><ScanBoxes>1</ScanBoxes></DeviceDef></TreeItem>";

            dynamic sm = ctx.SysManager();
            dynamic item = ComHelpers.GetTreeItem(sm, treePath);
            item.ConsumeXml(xml);
            ctx.Cache.Invalidate(treePath);

            var data = new Json.JObj();
            data["treePath"] = treePath;
            data["scanTriggered"] = true;
            return data;
        }

        // ===================================================================
        // private helpers
        // ===================================================================

        // Set-TreeItemXml (L3243-3262): ConsumeXml with GetLastXmlError surfacing,
        // then invalidate the affected subtree. Returns the live item.
        private static dynamic SetTreeItemXmlInternal(ActionContext ctx, dynamic sm, string targetPath, string xml)
        {
            dynamic item = ComHelpers.GetTreeItem(sm, targetPath);
            ComHelpers.ConsumeXml(item, xml);
            ctx.Cache.Invalidate(targetPath);
            ctx.Cache.InvalidateEnum(); // structural: a ConsumeXml set can rename/move tree members
            return item;
        }

        // Rename-TreeItem (L3049-3074): ConsumeXml('<TreeItem><ItemName>..') with
        // XML-escaped name + GetLastXmlError fallback. Returns post-rename PathName.
        // Invalidates the target's subtree on success.
        private static string RenameTreeItemInternal(ActionContext ctx, dynamic sm, string targetPath, string newName)
        {
            if (string.IsNullOrWhiteSpace(newName)) throw new BridgeException("newName is required");
            dynamic item = ComHelpers.GetTreeItem(sm, targetPath);

            string escapedName = PathUtil.XmlEscape(newName);
            string xml = "<TreeItem><ItemName>" + escapedName + "</ItemName></TreeItem>";
            ComHelpers.ConsumeXml(item, xml);

            ctx.Cache.Invalidate(targetPath);
            ctx.Cache.InvalidateEnum(); // structural: rename changes path/leaf membership
            return ComHelpers.SafeStr(delegate { return item.PathName; });
        }

        // Get-ChildTreeItemByName (L3469-3489): returns true if a direct child of
        // ParentItem has the given name (1-based scan).
        private static bool ChildExistsByName(dynamic parentItem, string childName)
        {
            int count = ComHelpers.ChildCount(parentItem);
            for (int i = 1; i <= count; i++)
            {
                dynamic child = ComHelpers.Child(parentItem, i);
                string name = ComHelpers.SafeStr(delegate { return child.Name; });
                if (name == childName) return true;
            }
            return false;
        }

        // Assert-WellFormedChild (L3192-3241): validate a child returned by
        // CreateChild; on a malformed "ghost" do best-effort cleanup (DeleteChild by
        // the actual non-blank name) and THROW a descriptive error. Returns on success.
        private static void AssertWellFormedChild(dynamic parent, dynamic child, string requestedName, int subType, string parentPath)
        {
            // Read back identity defensively — a ghost can throw on property access.
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
                // The child must live directly under the requested parent.
                string expectedPath = parentPath + "^" + requestedName;
                if (!string.IsNullOrWhiteSpace(childPath) && childPath != expectedPath)
                {
                    reason = "returned child path '" + childPath + "' is not under requested parent (expected '" + expectedPath + "')";
                }
            }

            if (reason == null) return;

            // Best-effort cleanup: only delete by name when we have a non-blank name.
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

        // PS treats array entries as scalars via [string]$entry. Mirror that: a
        // JObj/JArr would stringify oddly, but paths arrays are strings/numbers.
        private static string ScalarStr(object v)
        {
            if (v == null) return null;
            string s = v as string;
            if (s != null) return s;
            return Convert.ToString(v, System.Globalization.CultureInfo.InvariantCulture);
        }
    }
}
