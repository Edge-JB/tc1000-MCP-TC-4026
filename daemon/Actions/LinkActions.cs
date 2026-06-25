using System;
using System.Collections.Generic;
using System.Xml;

namespace Te1000Daemon
{
    // Variable-LINK actions plus the shared helpers Link-Variables,
    // Resolve-TwinCatVariablePath, Get-VariableLinksFromXml,
    // Get-VariableSubItemNames and Get-VariableLinksRecursive.
    //
    // Linking uses the late-bound sysManager.LinkVariables / UnlinkVariables. The
    // PS never calls Assert-NotSafetyPath in any of these handlers, so neither do
    // we. Linking mutates links that can span multiple subtrees, so after a
    // successful (un)link the whole tree cache is cleared (ctx.Cache.Invalidate(null)).
    // C#5-clean (no interpolation, no out var, no expression-bodied members).
    internal static class LinkActions
    {
        public static void Register(Dictionary<string, ActionHandler> h)
        {
            h["twincat_link_variables"] = LinkVariables;
            h["twincat_link_variables_batch"] = LinkVariablesBatch;
            h["twincat_unlink_variables"] = UnlinkVariables;
            h["twincat_unlink_variables_batch"] = UnlinkVariablesBatch;
            h["twincat_get_variable_links"] = GetVariableLinks;
        }

        // --- twincat_link_variables (L4501-4522) -----------------------------
        private static Json.JObj LinkVariables(ActionContext ctx)
        {
            string producer = ctx.Payload.Str("producer");
            string consumer = ctx.Payload.Str("consumer");
            bool autoResolve = true;
            if (ctx.Payload.Has("autoResolve")) autoResolve = ctx.Payload.Bool("autoResolve");

            if (string.IsNullOrWhiteSpace(producer) || string.IsNullOrWhiteSpace(consumer))
                throw new BridgeException("producer and consumer are required");

            dynamic sm = ctx.SysManager();
            Json.JObj result = LinkVariablesCore(ctx, sm, producer, consumer, autoResolve);
            return result;
        }

        // --- twincat_link_variables_batch (L4524-4604) -----------------------
        private static Json.JObj LinkVariablesBatch(ActionContext ctx)
        {
            Json.JArr links = ctx.Payload.Arr("links");
            if (links == null || links.Count == 0) throw new BridgeException("links is required");

            bool autoResolve = true;
            if (ctx.Payload.Has("autoResolve")) autoResolve = ctx.Payload.Bool("autoResolve");
            bool save = false;
            if (ctx.Payload.Has("save")) save = ctx.Payload.Bool("save");

            dynamic sm = ctx.SysManager();
            var results = new Json.JArr();
            int succeeded = 0;
            int failed = 0;

            foreach (object entryObj in links)
            {
                Json.JObj entry = entryObj as Json.JObj;
                string entryA = (entry != null && entry.Has("a")) ? entry.Str("a") : null;
                string entryB = (entry != null && entry.Has("b")) ? entry.Str("b") : null;

                if (string.IsNullOrWhiteSpace(entryA) || string.IsNullOrWhiteSpace(entryB))
                {
                    failed++;
                    var r = new Json.JObj();
                    r["a"] = entryA;
                    r["b"] = entryB;
                    r["ok"] = false;
                    r["error"] = "entry needs a and b";
                    results.Add(r);
                    continue;
                }

                try
                {
                    Json.JObj linkResult = LinkVariablesCore(ctx, sm, entryA, entryB, autoResolve);
                    succeeded++;
                    var r = new Json.JObj();
                    r["a"] = entryA;
                    r["b"] = entryB;
                    r["resolvedA"] = ResolutionResolvedPath(linkResult, "producerResolution");
                    r["resolvedB"] = ResolutionResolvedPath(linkResult, "consumerResolution");
                    r["ok"] = true;
                    results.Add(r);
                }
                catch (Exception ex)
                {
                    failed++;
                    var r = new Json.JObj();
                    r["a"] = entryA;
                    r["b"] = entryB;
                    r["ok"] = false;
                    r["error"] = ex.Message;
                    results.Add(r);
                }
            }

            var data = new Json.JObj();
            data["count"] = links.Count;
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

        // --- twincat_unlink_variables (L4606-4631) ---------------------------
        private static Json.JObj UnlinkVariables(ActionContext ctx)
        {
            string variableA = ctx.Payload.Str("variableA");
            string variableB = ctx.Payload.Has("variableB") ? ctx.Payload.Str("variableB") : null;
            if (string.IsNullOrWhiteSpace(variableA)) throw new BridgeException("variableA is required");

            dynamic sm = ctx.SysManager();

            if (string.IsNullOrWhiteSpace(variableB))
                sm.UnlinkVariables(variableA);
            else
                sm.UnlinkVariables(variableA, variableB);

            // Unlinking can affect either endpoint's subtree — clear the cache.
            ctx.Cache.Invalidate(null);

            var data = new Json.JObj();
            data["variableA"] = variableA;
            data["variableB"] = variableB;
            data["unlinked"] = true;
            return data;
        }

        // --- twincat_unlink_variables_batch (L4633-4711) ---------------------
        private static Json.JObj UnlinkVariablesBatch(ActionContext ctx)
        {
            Json.JArr links = ctx.Payload.Arr("links");
            if (links == null || links.Count == 0) throw new BridgeException("links is required");

            bool save = false;
            if (ctx.Payload.Has("save")) save = ctx.Payload.Bool("save");

            dynamic sm = ctx.SysManager();
            var results = new Json.JArr();
            int succeeded = 0;
            int failed = 0;

            foreach (object entryObj in links)
            {
                Json.JObj entry = entryObj as Json.JObj;
                string entryA = (entry != null && entry.Has("a")) ? entry.Str("a") : null;
                string entryB = (entry != null && entry.Has("b")) ? entry.Str("b") : null;

                if (string.IsNullOrWhiteSpace(entryA))
                {
                    failed++;
                    var r = new Json.JObj();
                    r["a"] = entryA;
                    r["b"] = entryB;
                    r["ok"] = false;
                    r["error"] = "entry needs a";
                    results.Add(r);
                    continue;
                }

                try
                {
                    if (string.IsNullOrWhiteSpace(entryB))
                        sm.UnlinkVariables(entryA);
                    else
                        sm.UnlinkVariables(entryA, entryB);
                    succeeded++;
                    var r = new Json.JObj();
                    r["a"] = entryA;
                    r["b"] = entryB;
                    r["ok"] = true;
                    results.Add(r);
                }
                catch (Exception ex)
                {
                    failed++;
                    var r = new Json.JObj();
                    r["a"] = entryA;
                    r["b"] = entryB;
                    r["ok"] = false;
                    r["error"] = ex.Message;
                    results.Add(r);
                }
            }

            // Any successful unlink may have touched multiple subtrees — full clear.
            if (succeeded > 0) ctx.Cache.Invalidate(null);

            var data = new Json.JObj();
            data["count"] = links.Count;
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

        // --- twincat_get_variable_links (L4713-4753) -------------------------
        // A linked leaf variable lists its links in its own ProduceXml under
        // <VarDef><LinkedWith>. If the queried path is itself such a leaf, that is
        // all we need. Otherwise (box/terminal/group) its own XML carries no
        // <LinkedWith>, so walk descendants (bounded recursion) and collect each
        // leaf's links.
        private static Json.JObj GetVariableLinks(ActionContext ctx)
        {
            string path = ctx.Payload.Str("path");
            if (string.IsNullOrWhiteSpace(path)) throw new BridgeException("path is required");

            dynamic sm = ctx.SysManager();
            dynamic item = ComHelpers.GetTreeItem(sm, path);

            Json.JArr links = new Json.JArr();
            try { links = GetVariableLinksFromXml(item); }
            catch { links = new Json.JArr(); }

            if (links.Count == 0)
            {
                try
                {
                    int[] budget = new int[] { 2000 };
                    var seen = new HashSet<string>(StringComparer.Ordinal);
                    links = GetVariableLinksRecursive(sm, item, 0, 8, seen, budget);
                }
                catch { links = new Json.JArr(); }
            }

            var data = new Json.JObj();
            data["path"] = path;
            data["count"] = links.Count;
            data["links"] = links;
            return data;
        }

        // ===================================================================
        // private helpers
        // ===================================================================

        // Link-Variables (L3264-3298): optionally dot->^ resolve both endpoints,
        // then sysManager.LinkVariables(producer, consumer). Returns the full
        // {producer, consumer, producerResolution, consumerResolution, linked}
        // shape (resolution objects mirror Resolve-TwinCatVariablePath). On
        // success the cache is fully cleared (link can affect multiple subtrees).
        private static Json.JObj LinkVariablesCore(ActionContext ctx, dynamic sm, string producer, string consumer, bool autoResolve)
        {
            if (string.IsNullOrWhiteSpace(producer) || string.IsNullOrWhiteSpace(consumer))
                throw new BridgeException("producer and consumer are required");

            Json.JObj producerResolution = DefaultResolution(producer);
            Json.JObj consumerResolution = DefaultResolution(consumer);

            if (autoResolve)
            {
                producerResolution = ResolveVariablePathData(sm, producer);
                consumerResolution = ResolveVariablePathData(sm, consumer);
                producer = producerResolution.Str("resolvedPath");
                consumer = consumerResolution.Str("resolvedPath");
            }

            sm.LinkVariables(producer, consumer);
            ctx.Cache.Invalidate(null);

            var data = new Json.JObj();
            data["producer"] = producer;
            data["consumer"] = consumer;
            data["producerResolution"] = producerResolution;
            data["consumerResolution"] = consumerResolution;
            data["linked"] = true;
            return data;
        }

        // Identity resolution used when AutoResolve is off (PS L3269-3280).
        private static Json.JObj DefaultResolution(string originalPath)
        {
            var o = new Json.JObj();
            o["originalPath"] = originalPath;
            o["resolvedPath"] = originalPath;
            o["resolved"] = true;
            o["attempts"] = new Json.JArr();
            return o;
        }

        // Resolve-TwinCatVariablePath (L3408-3448): try each dot->^ candidate and
        // return {originalPath, resolvedPath, resolved, attempts[]}.
        private static Json.JObj ResolveVariablePathData(dynamic sm, string variablePath)
        {
            var attempts = new Json.JArr();
            foreach (string candidate in ComHelpers.VariablePathCandidates(variablePath))
            {
                try
                {
                    dynamic item = ComHelpers.GetTreeItem(sm, candidate);
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

        // [string]$linkResult.producerResolution.resolvedPath (PS L4572-4573).
        private static string ResolutionResolvedPath(Json.JObj linkResult, string key)
        {
            Json.JObj res = linkResult.Obj(key);
            if (res == null) return null;
            return res.Str("resolvedPath");
        }

        // Get-VariableLinksFromXml (L3491-3543): parse one item's own ProduceXml
        // and return its <LinkedWith> endpoints (queried item is varA, each
        // LinkedWith target is varB). PLC-side endpoints also carry offsA/offsB/size.
        private static Json.JArr GetVariableLinksFromXml(dynamic treeItem)
        {
            string ownerPath = ComHelpers.SafeStr(delegate { return treeItem.PathName; });

            string xmlText = null;
            try { xmlText = (string)treeItem.ProduceXml(); }
            catch { xmlText = null; }
            if (string.IsNullOrEmpty(xmlText)) return new Json.JArr();

            var links = new Json.JArr();
            try
            {
                var doc = new XmlDocument();
                doc.LoadXml(xmlText);
                XmlNodeList nodes = doc.SelectNodes("//LinkedWith");
                if (nodes != null)
                {
                    foreach (XmlNode node in nodes)
                    {
                        string varB = node.InnerText;
                        if (string.IsNullOrWhiteSpace(varB)) continue;
                        links.Add(BuildLinkEntry(ownerPath, varB, node as XmlElement));
                    }
                }
            }
            catch { return new Json.JArr(); }

            return links;
        }

        // Get-VariableSubItemNames (L3545-3571): names of addressable PDO-channel /
        // slot-module sub-items embedded in a box's XML that are resolvable as
        // "<path>^<name>" but are NOT in the standard Child()/ChildCount collection.
        private static List<string> GetVariableSubItemNames(string xml)
        {
            var names = new List<string>();
            if (string.IsNullOrEmpty(xml)) return names;
            try
            {
                var doc = new XmlDocument();
                doc.LoadXml(xml);
                XmlNodeList nodes = doc.SelectNodes("//RxPdo/Name | //TxPdo/Name | //Slot/Module/Name");
                if (nodes != null)
                {
                    foreach (XmlNode nameNode in nodes)
                    {
                        string n = nameNode.InnerText;
                        if (!string.IsNullOrWhiteSpace(n)) names.Add(n);
                    }
                }
            }
            catch { return new List<string>(); }
            return names;
        }

        // Get-VariableLinksRecursive (L3573-3679): walk the queried item and its
        // descendants collecting every leaf's <LinkedWith>. A leaf answers from its
        // own XML; a box/group is walked via standard Child() children AND
        // addressable PDO-channel / slot-module sub-items. Bounded by MaxDepth and a
        // shared node Budget (passed as a single-element int[] to emulate the PS
        // [ref] so decrements propagate across recursive calls). Every COM/XML call
        // is guarded; a failure on one node is skipped rather than thrown.
        private static Json.JArr GetVariableLinksRecursive(dynamic sm, dynamic treeItem, int depth, int maxDepth, HashSet<string> seen, int[] budget)
        {
            var links = new Json.JArr();
            if (seen == null) seen = new HashSet<string>(StringComparer.Ordinal);
            if (depth > maxDepth) return links;
            if (budget != null && budget[0] <= 0) return links;

            string path = ComHelpers.SafeStr(delegate { return treeItem.PathName; });
            if (!string.IsNullOrWhiteSpace(path))
            {
                if (seen.Contains(path)) return links;
                seen.Add(path);
            }
            if (budget != null) budget[0] = budget[0] - 1;

            string ownXml = null;
            try { ownXml = (string)treeItem.ProduceXml(); }
            catch { ownXml = null; }

            // Direct links on this node (only present when it is itself a linked leaf).
            if (!string.IsNullOrEmpty(ownXml))
            {
                try
                {
                    var doc = new XmlDocument();
                    doc.LoadXml(ownXml);
                    XmlNodeList nodes = doc.SelectNodes("//LinkedWith");
                    if (nodes != null)
                    {
                        foreach (XmlNode node in nodes)
                        {
                            string varB = node.InnerText;
                            if (string.IsNullOrWhiteSpace(varB)) continue;
                            links.Add(BuildLinkEntry(path, varB, node as XmlElement));
                        }
                    }
                }
                catch { }
            }

            // Recurse into standard children.
            var childNames = new HashSet<string>(StringComparer.Ordinal);
            int count = ComHelpers.ChildCount(treeItem);
            for (int i = 1; i <= count; i++)
            {
                if (budget != null && budget[0] <= 0) break;
                dynamic child = ComHelpers.Child(treeItem, i);
                if (child == null) continue;
                string cn = ComHelpers.SafeStr(delegate { return child.Name; });
                if (!string.IsNullOrWhiteSpace(cn)) childNames.Add(cn);
                Json.JArr childLinks = GetVariableLinksRecursive(sm, child, depth + 1, maxDepth, seen, budget);
                foreach (object cl in childLinks) links.Add(cl);
            }

            // Recurse into addressable PDO-channel / slot-module sub-items not already covered.
            if (!string.IsNullOrWhiteSpace(path))
            {
                foreach (string subName in GetVariableSubItemNames(ownXml))
                {
                    if (budget != null && budget[0] <= 0) break;
                    if (childNames.Contains(subName)) continue;
                    dynamic subItem = null;
                    try { subItem = ComHelpers.GetTreeItem(sm, path + "^" + subName); }
                    catch { subItem = null; }
                    if (subItem == null) continue;
                    Json.JArr subLinks = GetVariableLinksRecursive(sm, subItem, depth + 1, maxDepth, seen, budget);
                    foreach (object sl in subLinks) links.Add(sl);
                }
            }

            return links;
        }

        // Shared link-entry builder: {varA, varB[, offsA][, offsB][, size]}. The
        // offs/size attributes are only added when present and non-blank (PS
        // L3634-3644 / L3526-3536).
        private static Json.JObj BuildLinkEntry(string varA, string varB, XmlElement node)
        {
            var entry = new Json.JObj();
            entry["varA"] = varA;
            entry["varB"] = varB;
            if (node != null)
            {
                string offsA = node.GetAttribute("offsA");
                string offsB = node.GetAttribute("offsB");
                string size = node.GetAttribute("size");
                if (!string.IsNullOrWhiteSpace(offsA)) entry["offsA"] = offsA;
                if (!string.IsNullOrWhiteSpace(offsB)) entry["offsB"] = offsB;
                if (!string.IsNullOrWhiteSpace(size)) entry["size"] = size;
            }
            return entry;
        }
    }
}
