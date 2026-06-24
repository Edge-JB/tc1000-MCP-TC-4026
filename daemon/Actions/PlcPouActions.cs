using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using System.Xml;
using TCatSysManagerLib;

namespace Te1000Daemon
{
    // plc_pou actions ported from te1000-bridge.ps1 (L5993-7159) — the largest
    // tool group: create/folder/import/get/set/replace/insert/append/outline/
    // tree/find/search/check/delete/rename/move over the IEC PLC project tree.
    //
    // SAFETY: every PLC-object verb refuses a TISC (safety) path via
    // PathUtil.AssertNotSafetyPath BEFORE touching COM. Nothing here may author
    // toward the EL6910 safety project.
    //
    // Typed vtable interfaces (ITcPlcDeclaration / ITcPlcImplementation /
    // ITcPlcPou / ITcPlcIECProject2) cannot be reached by late-bound dynamic
    // (IDispatch) — exactly as in the PS bridge, which uses the compiled
    // Te1000PlcPouHelper. We mirror that helper as PouHelper below (same typed
    // casts the already-compiled PlcProjectHelper proves are available). Tree-item
    // member access stays on `dynamic`.
    //
    // PERF: find/search/tree resolve the requested subtree via LookupTreeItem
    // (cache) and walk only that subtree, memoizing the bounded walk per
    // (path, depth) in ctx.Cache so repeat calls do not re-walk O(tree-size).
    //
    // C#5-clean (no interpolation, no out var, no expression-bodied members,
    // no pattern matching, no getter-only auto-props, no nameof).
    internal static class PlcPouActions
    {
        private const string CastUnavailable =
            "typed PLC cast unavailable on this shell (TCatSysManagerLib.dll / Te1000PlcPouHelper could not be loaded)";

        public static void Register(Dictionary<string, ActionHandler> h)
        {
            h["plc_pou_create"] = Create;
            h["plc_pou_create_batch"] = CreateBatch;
            h["plc_pou_create_folder"] = CreateFolder;
            h["plc_pou_create_folder_batch"] = CreateFolderBatch;
            h["plc_pou_import_template"] = ImportTemplate;
            h["plc_pou_get_decl"] = GetDecl;
            h["plc_pou_get_impl"] = GetImpl;
            h["plc_pou_outline"] = Outline;
            h["plc_pou_replace"] = Replace;
            h["plc_pou_replace_lines"] = ReplaceLines;
            h["plc_pou_insert"] = Insert;
            h["plc_pou_insert_in_var_block"] = InsertInVarBlock;
            h["plc_pou_append"] = Append;
            h["plc_pou_get_document"] = GetDocument;
            h["plc_pou_get_graphical"] = GetGraphical;
            h["plc_pou_set_decl"] = SetDecl;
            h["plc_pou_set_decl_batch"] = SetDeclBatch;
            h["plc_pou_set_impl"] = SetImpl;
            h["plc_pou_set_impl_batch"] = SetImplBatch;
            h["plc_pou_set_document"] = SetDocument;
            h["plc_pou_check_objects"] = CheckObjects;
            h["plc_pou_tree"] = Tree;
            h["plc_pou_find"] = Find;
            h["plc_pou_search"] = Search;
            h["plc_pou_delete"] = Delete;
            h["plc_pou_rename"] = Rename;
            h["plc_pou_move"] = Move;
        }

        // =================================================================
        // Typed POU accessors — mirror PS Te1000PlcPouHelper (L1319-1350).
        // =================================================================
        private static class PouHelper
        {
            public static string GetDeclaration(object o) { return ((ITcPlcDeclaration)o).DeclarationText; }
            public static void SetDeclaration(object o, string s) { ((ITcPlcDeclaration)o).DeclarationText = s; }
            public static string GetImplementation(object o) { return ((ITcPlcImplementation)o).ImplementationText; }
            public static int GetImplementationLanguage(object o) { return (int)((ITcPlcImplementation)o).Language; }
            public static void SetImplementationText(object o, string s) { ((ITcPlcImplementation)o).ImplementationText = s; }
            public static void SetImplementationXml(object o, string s) { ((ITcPlcImplementation)o).ImplementationXml = s; }
            public static string GetDocumentXml(object o) { return ((ITcPlcPou)o).DocumentXml; }
            public static void SetDocumentXml(object o, string s) { ((ITcPlcPou)o).DocumentXml = s; }
        }

        // ====================================================================
        // CREATE
        // ====================================================================

        // plc_pou_create (L5993-6007)
        private static Json.JObj Create(ActionContext ctx)
        {
            dynamic sm = ctx.SysManager();
            dynamic child = PouCreate(ctx, sm, ctx.Payload);

            string parent = ctx.Payload.Str("parent");
            ctx.Cache.Invalidate(parent);
            ctx.Cache.InvalidateEnum(); // structural: tree membership changed

            var data = new Json.JObj();
            data["parentPath"] = parent;
            data["child"] = ComHelpers.ConvertTreeItem(child);
            return data;
        }

        // plc_pou_create_batch (L6009-6047)
        private static Json.JObj CreateBatch(ActionContext ctx)
        {
            Json.JArr creates = ctx.Payload.Arr("creates");
            if (creates == null || creates.Count < 1)
                throw new BridgeException("creates must be a non-empty array");
            dynamic sm = ctx.SysManager();

            var results = new Json.JArr();
            int succeeded = 0;
            int failed = 0;
            foreach (object entryObj in creates)
            {
                Json.JObj entry = entryObj as Json.JObj ?? new Json.JObj();
                string p = entry.Truthy("parent") ? entry.Str("parent") : "";
                string n = entry.Truthy("name") ? entry.Str("name") : "";
                try
                {
                    dynamic child = PouCreate(ctx, sm, entry);
                    var row = new Json.JObj();
                    row["parent"] = p;
                    row["name"] = n;
                    row["ok"] = true;
                    row["child"] = ComHelpers.ConvertTreeItem(child);
                    results.Add(row);
                    succeeded++;
                }
                catch (Exception ex)
                {
                    var row = new Json.JObj();
                    row["parent"] = p;
                    row["name"] = n;
                    row["ok"] = false;
                    row["error"] = ex.Message;
                    results.Add(row);
                    failed++;
                }
            }

            SaveIfRequested(ctx);
            ctx.Cache.Clear();
            return BatchRollup(creates.Count, succeeded, failed, results);
        }

        // plc_pou_create_folder (L6049-6063)
        private static Json.JObj CreateFolder(ActionContext ctx)
        {
            dynamic sm = ctx.SysManager();
            dynamic child = PouCreateFolder(ctx, sm, ctx.Payload);

            string parent = ctx.Payload.Str("parent");
            ctx.Cache.Invalidate(parent);
            ctx.Cache.InvalidateEnum(); // structural: tree membership changed

            var data = new Json.JObj();
            data["parentPath"] = parent;
            data["child"] = ComHelpers.ConvertTreeItem(child);
            return data;
        }

        // plc_pou_create_folder_batch (L6065-6103)
        private static Json.JObj CreateFolderBatch(ActionContext ctx)
        {
            Json.JArr creates = ctx.Payload.Arr("creates");
            if (creates == null || creates.Count < 1)
                throw new BridgeException("creates must be a non-empty array");
            dynamic sm = ctx.SysManager();

            var results = new Json.JArr();
            int succeeded = 0;
            int failed = 0;
            foreach (object entryObj in creates)
            {
                Json.JObj entry = entryObj as Json.JObj ?? new Json.JObj();
                string p = entry.Truthy("parent") ? entry.Str("parent") : "";
                string n = entry.Truthy("name") ? entry.Str("name") : "";
                try
                {
                    dynamic child = PouCreateFolder(ctx, sm, entry);
                    var row = new Json.JObj();
                    row["parent"] = p;
                    row["name"] = n;
                    row["ok"] = true;
                    row["child"] = ComHelpers.ConvertTreeItem(child);
                    results.Add(row);
                    succeeded++;
                }
                catch (Exception ex)
                {
                    var row = new Json.JObj();
                    row["parent"] = p;
                    row["name"] = n;
                    row["ok"] = false;
                    row["error"] = ex.Message;
                    results.Add(row);
                    failed++;
                }
            }

            SaveIfRequested(ctx);
            ctx.Cache.Clear();
            return BatchRollup(creates.Count, succeeded, failed, results);
        }

        // plc_pou_import_template (L6105-6160). BUG FIX: the PS path-array build
        // never split on ':'; the ONE place a Windows path could be corrupted is
        // the vInfo handoff. We pass each paths[] element VERBATIM into CreateChild
        // (subType 58) — single string for one path, string[] for many — and NEVER
        // split on ':'.
        private static Json.JObj ImportTemplate(ActionContext ctx)
        {
            string parent = ctx.Payload.Str("parent");
            if (string.IsNullOrWhiteSpace(parent)) throw new BridgeException("parent is required");
            PathUtil.AssertNotSafetyPath(parent);

            Json.JArr rawPaths = ctx.Payload.Arr("paths");
            var paths = new List<string>();
            if (rawPaths != null)
            {
                foreach (object o in rawPaths)
                {
                    string s = o == null ? null : Convert.ToString(o, CultureInfo.InvariantCulture);
                    if (!string.IsNullOrWhiteSpace(s)) paths.Add(s); // VERBATIM — no ':' split
                }
            }
            if (paths.Count < 1)
                throw new BridgeException("paths must be a non-empty array of POU-template file paths");
            foreach (string pth in paths)
            {
                if (!System.IO.File.Exists(pth))
                    throw new BridgeException("POU template file not found: " + pth);
            }

            dynamic sm = ctx.SysManager();
            dynamic parentItem = ComHelpers.GetTreeItem(sm, parent);

            // Snapshot existing child names so we can report only the new imports.
            var before = new HashSet<string>(StringComparer.Ordinal);
            int countBefore = ComHelpers.ChildCount(parentItem);
            for (int i = 1; i <= countBefore; i++)
            {
                dynamic c = ComHelpers.Child(parentItem, i);
                string cn = c == null ? null : ComHelpers.SafeStr(MakeNameGetter(c));
                if (!string.IsNullOrWhiteSpace(cn)) before.Add(cn);
            }

            // subType 58 = POU template import. vInfo = single path string OR a
            // string[] of paths — passed VERBATIM (the bug was splitting on ':').
            object vInfo;
            if (paths.Count == 1) vInfo = paths[0];
            else vInfo = paths.ToArray();
            parentItem.CreateChild(null, 58, "", vInfo);

            var imported = new Json.JArr();
            int countAfter = ComHelpers.ChildCount(parentItem);
            for (int i = 1; i <= countAfter; i++)
            {
                dynamic c = ComHelpers.Child(parentItem, i);
                string cn = c == null ? null : ComHelpers.SafeStr(MakeNameGetter(c));
                if (!string.IsNullOrWhiteSpace(cn) && !before.Contains(cn)) imported.Add(cn);
            }

            SaveIfRequested(ctx);
            ctx.Cache.Invalidate(parent);
            ctx.Cache.InvalidateEnum(); // structural: imported objects changed membership

            var data = new Json.JObj();
            data["parent"] = parent;
            data["imported"] = imported;
            return data;
        }

        // ====================================================================
        // READ: get_decl / get_impl / outline / get_document / get_graphical
        // ====================================================================

        // plc_pou_get_decl (L6162-6184)
        private static Json.JObj GetDecl(ActionContext ctx)
        {
            string path = ctx.Payload.Str("path");
            if (string.IsNullOrWhiteSpace(path)) throw new BridgeException("path is required");
            PathUtil.AssertNotSafetyPath(path);
            dynamic sm = ctx.SysManager();
            dynamic item = ComHelpers.GetTreeItem(sm, path);

            string declText;
            try
            {
                declText = PouHelper.GetDeclaration((object)item);
            }
            catch (Exception ex)
            {
                throw new BridgeException("get_decl: '" + path +
                    "' has no declaration text (it is an implementation-only object such as an Action or Transition). Use get_impl instead. (underlying: " +
                    ex.Message + ")");
            }

            return BuildTextReadResult(declText, ctx.Payload, path);
        }

        // plc_pou_get_impl (L6186-6220)
        private static Json.JObj GetImpl(ActionContext ctx)
        {
            string path = ctx.Payload.Str("path");
            if (string.IsNullOrWhiteSpace(path)) throw new BridgeException("path is required");
            PathUtil.AssertNotSafetyPath(path);
            dynamic sm = ctx.SysManager();
            dynamic item = ComHelpers.GetTreeItem(sm, path);

            object language = TryGetLanguage(item);

            if (IsGraphicalLanguage(language))
            {
                var g = new Json.JObj();
                g["path"] = path;
                g["language"] = language;
                g["lineCount"] = 0;
                g["graphical"] = true;
                g["hint"] = "graphical body (no authoritative text); use get_graphical to inspect the network XML (read-only). get_document works only on a top-level POU, not on an Action/Method/Transition.";
                return g;
            }

            string implText = PouHelper.GetImplementation((object)item);
            Json.JObj data = BuildTextReadResult(implText, ctx.Payload, path);
            data["language"] = language;
            return data;
        }

        // plc_pou_outline (L6222-6298)
        private static Json.JObj Outline(ActionContext ctx)
        {
            string path = ctx.Payload.Str("path");
            if (string.IsNullOrWhiteSpace(path)) throw new BridgeException("path is required");
            PathUtil.AssertNotSafetyPath(path);
            dynamic sm = ctx.SysManager();
            dynamic item = ComHelpers.GetTreeItem(sm, path);

            string declText = "";
            bool hasDecl = true;
            try { declText = PouHelper.GetDeclaration((object)item); }
            catch { declText = ""; hasDecl = false; }

            List<string> declLines = SplitLines(declText);
            DeclOutline outline = GetDeclOutline(declLines);

            object implLineCount = null;
            object language = TryGetLanguage(item);
            if (!IsGraphicalLanguage(language))
            {
                try
                {
                    string implText = PouHelper.GetImplementation((object)item);
                    implLineCount = SplitLines(implText).Count;
                }
                catch { implLineCount = null; }
            }
            else
            {
                implLineCount = 0;
            }

            object objectKind = SafeIntObj(MakeIntGetter(item, "ItemType"));

            var children = new Json.JArr();
            int childCount = ComHelpers.ChildCount(item);
            for (int ci = 1; ci <= childCount; ci++)
            {
                dynamic childNode = ComHelpers.Child(item, ci);
                if (childNode == null) continue;
                string cn = ComHelpers.SafeStr(MakeNameGetter(childNode));
                if (string.IsNullOrWhiteSpace(cn)) continue;
                object cSub = TryGetSubType(childNode);
                string kind = "child";
                int cSubI = cSub == null ? -1 : ComHelpers.ToInt(cSub);
                switch (cSubI)
                {
                    case 608: kind = "action"; break;
                    case 609: kind = "method"; break;
                    case 611: kind = "property"; break;
                    case 616: kind = "transition"; break;
                    default: kind = "child"; break;
                }
                object cLang = TryGetLanguage(childNode);
                var crow = new Json.JObj();
                crow["name"] = cn;
                crow["kind"] = kind;
                crow["subType"] = cSub;
                crow["language"] = cLang;
                children.Add(crow);
            }

            var data = new Json.JObj();
            data["path"] = path;
            data["objectKind"] = objectKind;
            data["hasDeclaration"] = hasDecl;
            data["header"] = outline.Header;
            data["declLineCount"] = declLines.Count;
            data["implLineCount"] = implLineCount;
            data["varBlocks"] = outline.VarBlocks;
            data["children"] = children;
            return data;
        }

        // plc_pou_get_document (L6527-6546)
        private static Json.JObj GetDocument(ActionContext ctx)
        {
            string path = ctx.Payload.Str("path");
            if (string.IsNullOrWhiteSpace(path)) throw new BridgeException("path is required");
            dynamic sm = ctx.SysManager();
            dynamic item = ComHelpers.GetTreeItem(sm, path);
            string documentXml = PouHelper.GetDocumentXml((object)item);

            var data = new Json.JObj();
            data["path"] = path;
            data["xml"] = documentXml;
            return data;
        }

        // plc_pou_get_graphical (L6548-6610). READ-ONLY; refuses textual + TISC.
        private static Json.JObj GetGraphical(ActionContext ctx)
        {
            string path = ctx.Payload.Str("path");
            if (string.IsNullOrWhiteSpace(path)) throw new BridgeException("path is required");
            PathUtil.AssertNotSafetyPath(path);
            dynamic sm = ctx.SysManager();
            dynamic item = ComHelpers.GetTreeItem(sm, path);

            object language = TryGetLanguage(item);
            if (language != null && !IsGraphicalLanguage(language))
            {
                throw new BridgeException("get_graphical: '" + path + "' is a textual language (" +
                    LanguageName(language) + "); its body IS authoritative as text. Use get_impl instead.");
            }

            Json.JObj info = ComHelpers.ConvertTreeItem(item);
            string objName = info.Str("name");
            int itemType = info["itemType"] == null ? -1 : ComHelpers.ToInt(info["itemType"]);
            bool isPouLevel = (itemType == 602 || itemType == 603 || itemType == 604);

            string docXml;
            if (isPouLevel)
            {
                docXml = PouHelper.GetDocumentXml((object)item);
            }
            else
            {
                int idx = path.LastIndexOf('^');
                if (idx < 1) throw new BridgeException("get_graphical: '" + path + "' has no parent POU segment");
                string parentPath = path.Substring(0, idx);
                dynamic parentItem = ComHelpers.GetTreeItem(sm, parentPath);
                docXml = PouHelper.GetDocumentXml((object)parentItem);
            }

            string implXml = GetGraphicalImplXml(docXml, objName, isPouLevel);
            if (implXml == null)
            {
                throw new BridgeException("get_graphical: could not locate the <Implementation> for '" + objName +
                    "' in the POU document. (itemType=" + itemType.ToString(CultureInfo.InvariantCulture) +
                    ", isPouLevel=" + (isPouLevel ? "True" : "False") + ")");
            }

            var data = new Json.JObj();
            data["path"] = path;
            data["name"] = objName;
            data["language"] = language;
            data["languageName"] = LanguageName(language);
            data["itemType"] = itemType;
            data["source"] = "live-document";
            data["readOnly"] = true;
            data["note"] = "Graphical network XML (NWL/SFC/CFC archive). Read-only/diagnostic; not text-editable. To change graphical logic, edit in the XAE GUI.";
            data["xml"] = implXml;
            return data;
        }

        // ====================================================================
        // SURGICAL EDITS: replace / replace_lines / insert / insert_in_var_block
        //                 / append (all via the RMW wrapper)
        // ====================================================================

        // plc_pou_replace (L6300-6339)
        private static Json.JObj Replace(ActionContext ctx)
        {
            string path = ctx.Payload.Str("path");
            if (string.IsNullOrWhiteSpace(path)) throw new BridgeException("path is required");
            if (!ctx.Payload.Has("find") || ctx.Payload["find"] == null) throw new BridgeException("find is required");
            if (!ctx.Payload.Has("replaceWith") || ctx.Payload["replaceWith"] == null) throw new BridgeException("replaceWith is required");
            string target = GetTargetParam(ctx.Payload, "decl");
            string find = ctx.Payload.Str("find");
            string replaceWith = ctx.Payload.Str("replaceWith");
            int expectCount = (ctx.Payload.Has("expectCount") && ctx.Payload["expectCount"] != null) ? ctx.Payload.Int("expectCount", 1) : 1;

            dynamic sm = ctx.SysManager();

            int[] firstLast = new int[] { 0, 0 };
            int[] replacedRef = new int[] { 0 };
            RmwResult rmw = TextRmw((object)sm, path, target, (Mutator)delegate(string text, string eol, List<string> lines)
            {
                ApplyReplaceResult ar = ApplyReplace(text, find, replaceWith, expectCount);
                if (!ar.Ok) throw new BridgeException(ar.Error);
                replacedRef[0] = ar.Count;
                List<string> oldLines = SplitLines(text);
                List<string> newLines = SplitLines(ar.NewText);
                int? fc = GetFirstDivergentLine(oldLines, newLines);
                int? lc = GetLastDivergentLine(oldLines, newLines);
                firstLast[0] = fc.HasValue ? fc.Value : 0;
                firstLast[1] = lc.HasValue ? lc.Value : 0;
                return ar.NewText;
            });

            int startL = firstLast[0] != 0 ? firstLast[0] : 1;
            int endL = firstLast[1] != 0 ? firstLast[1] : startL;
            ChangedSnippet snip = GetChangedSnippet(rmw.NewLines, startL, endL, 2);
            SaveIfRequested(ctx);

            var data = new Json.JObj();
            data["path"] = path;
            data["target"] = target;
            data["replaced"] = replacedRef[0];
            data["lineCount"] = rmw.NewLineCount;
            data["eol"] = rmw.EolName;
            data["changedRange"] = snip.ChangedRange;
            data["snippet"] = snip.Snippet;
            AddValidateResult(ctx, sm, data);
            ctx.Cache.Invalidate(path);
            return data;
        }

        // plc_pou_replace_lines (L6342-6383)
        private static Json.JObj ReplaceLines(ActionContext ctx)
        {
            string path = ctx.Payload.Str("path");
            if (string.IsNullOrWhiteSpace(path)) throw new BridgeException("path is required");
            if (!ctx.Payload.Has("start") || ctx.Payload["start"] == null) throw new BridgeException("start is required");
            if (!ctx.Payload.Has("end") || ctx.Payload["end"] == null) throw new BridgeException("end is required");
            if (!ctx.Payload.Has("text") || ctx.Payload["text"] == null) throw new BridgeException("text is required");
            string target = GetTargetParam(ctx.Payload, "decl");
            int startReq = ctx.Payload.Int("start", 0);
            int endReq = ctx.Payload.Int("end", 0);
            string newText = ctx.Payload.Str("text");

            int[] region = new int[] { 0, 0 };
            dynamic sm = ctx.SysManager();
            RmwResult rmw = TextRmw((object)sm, path, target, (Mutator)delegate(string text, string eol, List<string> lines)
            {
                int count = lines.Count;
                if (startReq < 1 || endReq > count || startReq > endReq)
                {
                    throw new BridgeException("replace_lines range [" + startReq.ToString(CultureInfo.InvariantCulture) + ".." +
                        endReq.ToString(CultureInfo.InvariantCulture) + "] is out of bounds for lineCount " +
                        count.ToString(CultureInfo.InvariantCulture) + " (no change written)");
                }
                List<string> repLines = SplitLines(newText);
                var merged = new List<string>();
                for (int i = 0; i < startReq - 1; i++) merged.Add(lines[i]);
                merged.AddRange(repLines);
                for (int i = endReq; i < count; i++) merged.Add(lines[i]);
                region[0] = startReq;
                region[1] = startReq + repLines.Count - 1;
                if (region[1] < startReq) region[1] = startReq;
                return JoinLines(merged, eol, true);
            });

            ChangedSnippet snip = GetChangedSnippet(rmw.NewLines, region[0], region[1], 2);
            SaveIfRequested(ctx);

            var data = new Json.JObj();
            data["path"] = path;
            data["target"] = target;
            data["lineCount"] = rmw.NewLineCount;
            data["eol"] = rmw.EolName;
            data["changedRange"] = snip.ChangedRange;
            data["snippet"] = snip.Snippet;
            AddValidateResult(ctx, sm, data);
            ctx.Cache.Invalidate(path);
            return data;
        }

        // plc_pou_insert (L6386-6434)
        private static Json.JObj Insert(ActionContext ctx)
        {
            string path = ctx.Payload.Str("path");
            if (string.IsNullOrWhiteSpace(path)) throw new BridgeException("path is required");
            if (!ctx.Payload.Has("text") || ctx.Payload["text"] == null) throw new BridgeException("text is required");
            string target = GetTargetParam(ctx.Payload, "decl");
            bool hasAt = ctx.Payload.Has("at") && ctx.Payload["at"] != null;
            bool hasAfter = ctx.Payload.Has("after") && ctx.Payload["after"] != null;
            bool hasBefore = ctx.Payload.Has("before") && ctx.Payload["before"] != null;
            int supplied = (hasAt ? 1 : 0) + (hasAfter ? 1 : 0) + (hasBefore ? 1 : 0);
            if (supplied != 1) throw new BridgeException("insert requires exactly one of at / after / before");
            string insText = ctx.Payload.Str("text");

            int[] region = new int[] { 0, 0 };
            dynamic sm = ctx.SysManager();
            RmwResult rmw = TextRmw((object)sm, path, target, (Mutator)delegate(string text, string eol, List<string> lines)
            {
                int count = lines.Count;
                int pos;
                if (hasAfter) pos = ctx.Payload.Int("after", 0) + 1;
                else if (hasBefore) pos = ctx.Payload.Int("before", 0);
                else pos = ctx.Payload.Int("at", 0);
                if (pos < 1 || pos > (count + 1))
                {
                    throw new BridgeException("insert position " + pos.ToString(CultureInfo.InvariantCulture) +
                        " is out of bounds for lineCount " + count.ToString(CultureInfo.InvariantCulture) +
                        " (valid 1.." + (count + 1).ToString(CultureInfo.InvariantCulture) + ") (no change written)");
                }
                List<string> insLines = SplitLines(insText);
                var merged = new List<string>();
                for (int i = 0; i < pos - 1; i++) merged.Add(lines[i]);
                merged.AddRange(insLines);
                for (int i = pos - 1; i < count; i++) merged.Add(lines[i]);
                region[0] = pos;
                region[1] = pos + insLines.Count - 1;
                if (region[1] < pos) region[1] = pos;
                return JoinLines(merged, eol, true);
            });

            ChangedSnippet snip = GetChangedSnippet(rmw.NewLines, region[0], region[1], 2);
            SaveIfRequested(ctx);

            var data = new Json.JObj();
            data["path"] = path;
            data["target"] = target;
            data["lineCount"] = rmw.NewLineCount;
            data["eol"] = rmw.EolName;
            data["changedRange"] = snip.ChangedRange;
            data["snippet"] = snip.Snippet;
            AddValidateResult(ctx, sm, data);
            ctx.Cache.Invalidate(path);
            return data;
        }

        // plc_pou_insert_in_var_block (L6437-6485)
        private static Json.JObj InsertInVarBlock(ActionContext ctx)
        {
            string path = ctx.Payload.Str("path");
            if (string.IsNullOrWhiteSpace(path)) throw new BridgeException("path is required");
            if (string.IsNullOrWhiteSpace(ctx.Payload.Str("block"))) throw new BridgeException("block is required");
            if (!ctx.Payload.Has("text") || ctx.Payload["text"] == null) throw new BridgeException("text is required");
            string target = GetTargetParam(ctx.Payload, "decl");
            string block = ctx.Payload.Str("block");
            string insText = ctx.Payload.Str("text");
            int occurrence = (ctx.Payload.Has("occurrence") && ctx.Payload["occurrence"] != null) ? ctx.Payload.Int("occurrence", 1) : 1;

            int[] region = new int[] { 0, 0 };
            dynamic sm = ctx.SysManager();
            RmwResult rmw = TextRmw((object)sm, path, target, (Mutator)delegate(string text, string eol, List<string> lines)
            {
                int count = lines.Count;
                VarBlock vb = FindVarBlock(lines, block, occurrence);
                if (!vb.Found)
                {
                    throw new BridgeException("no " + block + " block found in " + path +
                        " (occurrence " + occurrence.ToString(CultureInfo.InvariantCulture) + ")");
                }
                int endVarLine = vb.EndVarLine;
                string indent = vb.Indent + "    ";
                List<string> insSrc = SplitLines(insText);
                var insLines = new List<string>();
                foreach (string l in insSrc)
                {
                    if (string.IsNullOrWhiteSpace(l)) insLines.Add(l);
                    else insLines.Add(indent + l.TrimStart());
                }
                int insertPos = endVarLine; // before END_VAR
                var merged = new List<string>();
                for (int i = 0; i < insertPos - 1; i++) merged.Add(lines[i]);
                merged.AddRange(insLines);
                for (int i = insertPos - 1; i < count; i++) merged.Add(lines[i]);
                region[0] = insertPos;
                region[1] = insertPos + insLines.Count - 1;
                if (region[1] < insertPos) region[1] = insertPos;
                return JoinLines(merged, eol, true);
            });

            ChangedSnippet snip = GetChangedSnippet(rmw.NewLines, region[0], region[1], 2);
            SaveIfRequested(ctx);

            var data = new Json.JObj();
            data["path"] = path;
            data["target"] = "decl";
            data["block"] = block;
            data["lineCount"] = rmw.NewLineCount;
            data["eol"] = rmw.EolName;
            data["changedRange"] = snip.ChangedRange;
            data["snippet"] = snip.Snippet;
            AddValidateResult(ctx, sm, data);
            ctx.Cache.Invalidate(path);
            return data;
        }

        // plc_pou_append (L6488-6525)
        private static Json.JObj Append(ActionContext ctx)
        {
            string path = ctx.Payload.Str("path");
            if (string.IsNullOrWhiteSpace(path)) throw new BridgeException("path is required");
            if (!ctx.Payload.Has("text") || ctx.Payload["text"] == null) throw new BridgeException("text is required");
            string target = GetTargetParam(ctx.Payload, "impl");
            string appText = ctx.Payload.Str("text");

            int[] region = new int[] { 0, 0 };
            dynamic sm = ctx.SysManager();
            RmwResult rmw = TextRmw((object)sm, path, target, (Mutator)delegate(string text, string eol, List<string> lines)
            {
                int oldCount = lines.Count;
                SplitResult appSplit = SplitLinesEx(appText);
                List<string> appLines = appSplit.Lines;
                if (oldCount == 0)
                {
                    region[0] = 1;
                    region[1] = Math.Max(1, appLines.Count);
                    return JoinLines(appLines, eol, appSplit.TrailingEol);
                }
                var merged = new List<string>(lines);
                merged.AddRange(appLines);
                region[0] = oldCount + 1;
                region[1] = merged.Count;
                return JoinLines(merged, eol, appSplit.TrailingEol);
            });

            ChangedSnippet snip = GetChangedSnippet(rmw.NewLines, region[0], region[1], 2);
            SaveIfRequested(ctx);

            var data = new Json.JObj();
            data["path"] = path;
            data["target"] = target;
            data["lineCount"] = rmw.NewLineCount;
            data["eol"] = rmw.EolName;
            data["changedRange"] = snip.ChangedRange;
            data["snippet"] = snip.Snippet;
            AddValidateResult(ctx, sm, data);
            ctx.Cache.Invalidate(path);
            return data;
        }

        // ====================================================================
        // SET: set_decl / set_decl_batch / set_impl / set_impl_batch / set_document
        // ====================================================================

        // plc_pou_set_decl (L6612-6633)
        private static Json.JObj SetDecl(ActionContext ctx)
        {
            string path = ctx.Payload.Str("path");
            if (string.IsNullOrWhiteSpace(path)) throw new BridgeException("path is required");
            if (!ctx.Payload.Has("declText") || ctx.Payload["declText"] == null) throw new BridgeException("declText is required");
            PathUtil.AssertNotSafetyPath(path);
            string declText = ctx.Payload.Str("declText");
            dynamic sm = ctx.SysManager();
            dynamic item = ComHelpers.GetTreeItem(sm, path);
            PouHelper.SetDeclaration((object)item, declText);
            ctx.Cache.Invalidate(path);

            var data = new Json.JObj();
            data["path"] = path;
            data["set"] = true;
            return data;
        }

        // plc_pou_set_decl_batch (L6636-6679)
        private static Json.JObj SetDeclBatch(ActionContext ctx)
        {
            Json.JArr items = ctx.Payload.Arr("items");
            if (items == null || items.Count < 1) throw new BridgeException("items must be a non-empty array");
            dynamic sm = ctx.SysManager();

            var results = new Json.JArr();
            int succeeded = 0;
            int failed = 0;
            foreach (object entryObj in items)
            {
                Json.JObj entry = entryObj as Json.JObj ?? new Json.JObj();
                string p = entry.Truthy("path") ? entry.Str("path") : "";
                try
                {
                    if (string.IsNullOrWhiteSpace(p)) throw new BridgeException("path is required");
                    if (!entry.Has("declText") || entry["declText"] == null) throw new BridgeException("declText is required");
                    PathUtil.AssertNotSafetyPath(p);
                    dynamic item = ComHelpers.GetTreeItem(sm, p);
                    PouHelper.SetDeclaration((object)item, entry.Str("declText"));
                    ctx.Cache.Invalidate(p);
                    var row = new Json.JObj();
                    row["path"] = p;
                    row["ok"] = true;
                    results.Add(row);
                    succeeded++;
                }
                catch (Exception ex)
                {
                    var row = new Json.JObj();
                    row["path"] = p;
                    row["ok"] = false;
                    row["error"] = ex.Message;
                    results.Add(row);
                    failed++;
                }
            }

            SaveIfRequested(ctx);
            return BatchRollup(items.Count, succeeded, failed, results);
        }

        // plc_pou_set_impl (L6682-6712)
        private static Json.JObj SetImpl(ActionContext ctx)
        {
            string path = ctx.Payload.Str("path");
            if (string.IsNullOrWhiteSpace(path)) throw new BridgeException("path is required");
            PathUtil.AssertNotSafetyPath(path);
            bool hasText = ctx.Payload.Has("implText") && ctx.Payload["implText"] != null;
            bool hasXml = ctx.Payload.Has("implXml") && ctx.Payload["implXml"] != null;
            if ((hasText && hasXml) || (!hasText && !hasXml))
                throw new BridgeException("exactly one of implText / implXml is required");
            dynamic sm = ctx.SysManager();
            dynamic item = ComHelpers.GetTreeItem(sm, path);
            string via = hasText ? "text" : "xml";
            if (hasText) PouHelper.SetImplementationText((object)item, ctx.Payload.Str("implText"));
            else PouHelper.SetImplementationXml((object)item, ctx.Payload.Str("implXml"));
            ctx.Cache.Invalidate(path);

            var data = new Json.JObj();
            data["path"] = path;
            data["set"] = true;
            data["via"] = via;
            return data;
        }

        // plc_pou_set_impl_batch (L6715-6767)
        private static Json.JObj SetImplBatch(ActionContext ctx)
        {
            Json.JArr items = ctx.Payload.Arr("items");
            if (items == null || items.Count < 1) throw new BridgeException("items must be a non-empty array");
            dynamic sm = ctx.SysManager();

            var results = new Json.JArr();
            int succeeded = 0;
            int failed = 0;
            foreach (object entryObj in items)
            {
                Json.JObj entry = entryObj as Json.JObj ?? new Json.JObj();
                string p = entry.Truthy("path") ? entry.Str("path") : "";
                try
                {
                    if (string.IsNullOrWhiteSpace(p)) throw new BridgeException("path is required");
                    bool hasText = entry.Has("implText") && entry["implText"] != null;
                    bool hasXml = entry.Has("implXml") && entry["implXml"] != null;
                    if ((hasText && hasXml) || (!hasText && !hasXml))
                        throw new BridgeException("exactly one of implText / implXml is required");
                    PathUtil.AssertNotSafetyPath(p);
                    dynamic item = ComHelpers.GetTreeItem(sm, p);
                    var row = new Json.JObj();
                    row["path"] = p;
                    row["ok"] = true;
                    if (hasText)
                    {
                        PouHelper.SetImplementationText((object)item, entry.Str("implText"));
                        row["via"] = "text";
                    }
                    else
                    {
                        PouHelper.SetImplementationXml((object)item, entry.Str("implXml"));
                        row["via"] = "xml";
                    }
                    ctx.Cache.Invalidate(p);
                    results.Add(row);
                    succeeded++;
                }
                catch (Exception ex)
                {
                    var row = new Json.JObj();
                    row["path"] = p;
                    row["ok"] = false;
                    row["error"] = ex.Message;
                    results.Add(row);
                    failed++;
                }
            }

            SaveIfRequested(ctx);
            return BatchRollup(items.Count, succeeded, failed, results);
        }

        // plc_pou_set_document (L6770-6792)
        private static Json.JObj SetDocument(ActionContext ctx)
        {
            string path = ctx.Payload.Str("path");
            if (string.IsNullOrWhiteSpace(path)) throw new BridgeException("path is required");
            if (!ctx.Payload.Has("documentXml") || ctx.Payload["documentXml"] == null) throw new BridgeException("documentXml is required");
            PathUtil.AssertNotSafetyPath(path);
            string documentXml = ctx.Payload.Str("documentXml");
            dynamic sm = ctx.SysManager();
            dynamic item = ComHelpers.GetTreeItem(sm, path);
            PouHelper.SetDocumentXml((object)item, documentXml);
            ctx.Cache.Invalidate(path);

            var data = new Json.JObj();
            data["path"] = path;
            data["set"] = true;
            return data;
        }

        // ====================================================================
        // CHECK / TREE / FIND / SEARCH
        // ====================================================================

        // plc_pou_check_objects (L6794-6867)
        private static Json.JObj CheckObjects(ActionContext ctx)
        {
            dynamic sm = ctx.SysManager();
            string plcPath = ctx.Payload.Str("plcPath");
            if (string.IsNullOrWhiteSpace(plcPath))
            {
                dynamic tipc = sm.LookupTreeItem("TIPC");
                if (ComHelpers.ChildCount(tipc) < 1) throw new BridgeException("No PLC project found under TIPC");
                plcPath = "TIPC^" + ((string)tipc.Child(1).Name);
            }
            dynamic root = ComHelpers.GetTreeItem(sm, plcPath);
            string rootName = ComHelpers.SafeStr(MakeNameGetter(root));

            var candidatePaths = new List<string>();
            if (!string.IsNullOrWhiteSpace(rootName)) candidatePaths.Add(plcPath + "^" + rootName + " Project");
            int childCount = ComHelpers.ChildCount(root);
            for (int ci = 1; ci <= childCount; ci++)
            {
                dynamic childNode = ComHelpers.Child(root, ci);
                if (childNode != null)
                {
                    string cn = ComHelpers.SafeStr(MakeNameGetter(childNode));
                    if (!string.IsNullOrWhiteSpace(cn))
                    {
                        string cp = plcPath + "^" + cn;
                        if (!candidatePaths.Contains(cp)) candidatePaths.Add(cp);
                    }
                }
            }
            if (!candidatePaths.Contains(plcPath)) candidatePaths.Add(plcPath);

            bool valid = false;
            string instancePath = plcPath;
            string lastErr = null;
            bool resolved = false;
            foreach (string candPath in candidatePaths)
            {
                try
                {
                    dynamic node = ComHelpers.GetTreeItem(sm, candPath);
                    valid = PlcProjectHelper.CheckAll((object)node);
                    instancePath = candPath;
                    resolved = true;
                    break;
                }
                catch (Exception ex)
                {
                    lastErr = ex.Message;
                }
            }
            if (!resolved)
            {
                throw new BridgeException("could not find a node implementing ITcPlcIECProject2 (CheckAllObjects) under '" +
                    plcPath + "'. Tried the '<name> Project' instance node and the PLC root's children. Last error: " + lastErr);
            }

            var data = new Json.JObj();
            data["plcPath"] = plcPath;
            data["instancePath"] = instancePath;
            data["allObjectsValid"] = valid;
            return data;
        }

        // plc_pou_tree (L6869-6909). PERF: walk only the requested subtree
        // (path/projectPath) at a bounded depth, memoized in ctx.Cache.
        private static Json.JObj Tree(ActionContext ctx)
        {
            dynamic sm = ctx.SysManager();
            ProjectNode resolved = GetPlcProjectNodePath(sm, ctx.Payload.Str("plcPath"));
            string plcPath = resolved.PlcPath;
            string projectPath = resolved.ProjectPath;

            string startPath = !string.IsNullOrWhiteSpace(ctx.Payload.Str("path")) ? ctx.Payload.Str("path") : projectPath;
            PathUtil.AssertNotSafetyPath(startPath);

            int maxDepth = 0;
            if (ctx.Payload.Has("depth") && ctx.Payload["depth"] != null)
            {
                maxDepth = ctx.Payload.Int("depth", 0);
                if (maxDepth < 1) maxDepth = 1;
            }

            Json.JObj rootNode = WalkSubtree(ctx, sm, startPath, maxDepth);

            Json.JArr treeArr = new Json.JArr();
            object typeSet = NormalizedTypeSet(ctx.Payload.Str("typeFilter"));
            if (typeSet != null)
            {
                Json.JObj pruned = PruneTree(rootNode, (HashSet<string>)typeSet);
                if (pruned != null) treeArr.Add(pruned);
            }
            else if (rootNode != null)
            {
                treeArr.Add(rootNode);
            }

            int count = 0;
            foreach (object t in treeArr) count += MeasureTreeNodeCount(t as Json.JObj);

            var data = new Json.JObj();
            data["plcPath"] = plcPath;
            data["projectPath"] = projectPath;
            data["rootPath"] = startPath;
            data["count"] = count;
            data["tree"] = treeArr;
            return data;
        }

        // plc_pou_find (L6911-6942). PERF: scope the walk to the requested subtree
        // (unbounded depth, memoized), then flatten + filter.
        private static Json.JObj Find(ActionContext ctx)
        {
            string namePattern = ctx.Payload.Str("name");
            string typeFilter = ctx.Payload.Str("typeFilter");
            if (string.IsNullOrWhiteSpace(namePattern) && string.IsNullOrWhiteSpace(typeFilter))
                throw new BridgeException("find requires at least one of name / typeFilter");

            dynamic sm = ctx.SysManager();
            ProjectNode resolved = GetPlcProjectNodePath(sm, ctx.Payload.Str("plcPath"));
            string plcPath = resolved.PlcPath;
            string projectPath = resolved.ProjectPath;

            string startPath = !string.IsNullOrWhiteSpace(ctx.Payload.Str("path")) ? ctx.Payload.Str("path") : projectPath;
            PathUtil.AssertNotSafetyPath(startPath);

            Json.JObj rootNode = WalkSubtree(ctx, sm, startPath, 0);

            object typeSet = NormalizedTypeSet(typeFilter);
            Json.JArr matches = SelectFlatTreeMatches(rootNode, namePattern, (HashSet<string>)typeSet);

            var data = new Json.JObj();
            data["plcPath"] = plcPath;
            data["projectPath"] = projectPath;
            data["count"] = matches.Count;
            data["matches"] = matches;
            return data;
        }

        // plc_pou_search (L6944-7024). PERF: enumerate code objects ONLY under the
        // requested subtree (LookupTreeItem-resolved root), reading decl/impl via
        // the typed helper and grepping line-by-line.
        private static Json.JObj Search(ActionContext ctx)
        {
            string pattern = ctx.Payload.Str("pattern");
            if (string.IsNullOrEmpty(pattern)) throw new BridgeException("pattern is required");
            bool ignoreCase = ctx.Payload.Has("ignoreCase") ? ctx.Payload.Bool("ignoreCase") : false;
            bool declOnly = ctx.Payload.Has("declOnly") ? ctx.Payload.Bool("declOnly") : false;
            bool implOnly = ctx.Payload.Has("implOnly") ? ctx.Payload.Bool("implOnly") : false;
            if (declOnly && implOnly) throw new BridgeException("declOnly and implOnly are mutually exclusive");
            bool refresh = ctx.Payload.Has("refresh") ? ctx.Payload.Bool("refresh") : false;

            int maxResults = 500;
            if (ctx.Payload.Has("maxResults") && ctx.Payload["maxResults"] != null)
            {
                maxResults = ctx.Payload.Int("maxResults", 500);
                if (maxResults < 1) maxResults = 1;
                if (maxResults > 5000) maxResults = 5000;
            }

            dynamic sm = ctx.SysManager();
            ProjectNode resolved = GetPlcProjectNodePath(sm, ctx.Payload.Str("plcPath"));
            string plcPath = resolved.PlcPath;
            string projectPath = resolved.ProjectPath;

            string startPath = !string.IsNullOrWhiteSpace(ctx.Payload.Str("path")) ? ctx.Payload.Str("path") : projectPath;
            PathUtil.AssertNotSafetyPath(startPath);

            // Validate the regex once up front so a bad pattern fails fast.
            FindMatchesInText("x", pattern, "decl", "", ignoreCase);

            // refresh:true forces a full re-pull for the searched scope (escape
            // hatch for structural ops or paranoia): drop both the text cache and
            // the enumeration cache so the walk and per-object reads are redone.
            if (refresh)
            {
                ctx.Cache.InvalidateText(startPath);
                ctx.Cache.InvalidateEnum();
            }

            // Enumeration: serve the flat descendant-path list from the enum cache
            // when warm (ZERO COM tree-walk); otherwise do the COM walk ONCE and
            // cache it. This is the dominant warm-search cost the text cache alone
            // did not address.
            List<string> paths = ctx.Cache.GetEnum(startPath);
            if (paths == null)
            {
                dynamic startNode = ctx.Cache.LookupItem(sm, startPath);
                var objects = new List<CodeObject>();
                CollectCodeObjects(sm, startPath, startNode, new HashSet<string>(StringComparer.Ordinal), objects);
                paths = new List<string>(objects.Count);
                foreach (CodeObject o in objects) paths.Add(o.Path);
                ctx.Cache.PutEnum(startPath, paths);
            }

            // Refresh the open-document set ONCE per search (TTL-gated) so the
            // per-object dirty check is a cheap dictionary lookup, not a re-enum.
            if (ctx.Edits != null)
            {
                try { ctx.Edits.RefreshOpenDocsIfStale(); } catch { }
            }

            int scanned = 0;
            int searched = 0;
            var matches = new Json.JArr();
            bool truncated = false;
            foreach (string objPath in paths)
            {
                scanned++;
                ObjectText txt = SelectPlcObjectTextCachedByPath(ctx, sm, objPath, declOnly, implOnly, refresh);
                bool didSearch = false;
                if (txt.HasDecl && !implOnly)
                {
                    didSearch = true;
                    foreach (Json.JObj m in FindMatchesInText(txt.Decl, pattern, "decl", objPath, ignoreCase))
                    {
                        matches.Add(m);
                        if (matches.Count >= maxResults) { truncated = true; break; }
                    }
                }
                if (!truncated && txt.HasImpl && !declOnly)
                {
                    didSearch = true;
                    foreach (Json.JObj m in FindMatchesInText(txt.Impl, pattern, "impl", objPath, ignoreCase))
                    {
                        matches.Add(m);
                        if (matches.Count >= maxResults) { truncated = true; break; }
                    }
                }
                if (didSearch) searched++;
                if (truncated) break;
            }

            var data = new Json.JObj();
            data["pattern"] = pattern;
            data["plcPath"] = plcPath;
            data["scanned"] = scanned;
            data["searched"] = searched;
            data["count"] = matches.Count;
            data["truncated"] = truncated;
            data["matches"] = matches;
            return data;
        }

        // ====================================================================
        // DELETE / RENAME / MOVE
        // ====================================================================

        // plc_pou_delete (L7026-7093)
        private static Json.JObj Delete(ActionContext ctx)
        {
            string parentPath = ctx.Payload.Str("parent");
            string childName = ctx.Payload.Str("name");
            string full = ctx.Payload.Str("path");
            if (!string.IsNullOrWhiteSpace(full) && (string.IsNullOrWhiteSpace(parentPath) || string.IsNullOrWhiteSpace(childName)))
            {
                int idx = full.LastIndexOf('^');
                if (idx < 1) throw new BridgeException("path '" + full + "' has no parent segment (expected a '^'-separated path)");
                parentPath = full.Substring(0, idx);
                childName = full.Substring(idx + 1);
            }
            if (string.IsNullOrWhiteSpace(parentPath) || string.IsNullOrWhiteSpace(childName))
                throw new BridgeException("delete requires either path, or parent and name");
            PathUtil.AssertNotSafetyPath(parentPath);

            bool dryRun = ctx.Payload.Has("dryRun") ? ctx.Payload.Bool("dryRun") : false;

            dynamic sm = ctx.SysManager();
            dynamic parent = ComHelpers.GetTreeItem(sm, parentPath);

            string childPath = parentPath + "^" + childName;
            dynamic childItem = ComHelpers.TryGetTreeItem(sm, childPath);
            if (childItem == null)
                throw new BridgeException("child '" + childName + "' not found under '" + parentPath + "' (nothing deleted)");

            Json.JObj cInfo = ComHelpers.ConvertTreeItem(childItem);
            string cSubTypeName = ComHelpers.SafeStr(MakeStrGetter(childItem, "ItemSubTypeName"));
            int cChildCount = cInfo["childCount"] == null ? 0 : ComHelpers.ToInt(cInfo["childCount"]);
            string cType = GetPlcObjectTypeName(cInfo["itemType"], cInfo["subType"], cSubTypeName, cInfo.Str("name"), cChildCount, false);

            if (dryRun)
            {
                var target = new Json.JObj();
                target["path"] = parentPath + "^" + childName;
                target["name"] = childName;
                target["type"] = cType;
                target["childCount"] = cChildCount;
                var dd = new Json.JObj();
                dd["wouldDelete"] = true;
                dd["target"] = target;
                return dd;
            }

            parent.DeleteChild(childName);
            ctx.Cache.Invalidate(parentPath);
            ctx.Cache.InvalidateEnum(); // structural: object removed from tree

            var data = new Json.JObj();
            data["parent"] = parentPath;
            data["name"] = childName;
            data["deleted"] = true;
            data["type"] = cType;
            return data;
        }

        // plc_pou_rename (L7095-7117)
        private static Json.JObj Rename(ActionContext ctx)
        {
            string path = ctx.Payload.Str("path");
            string newName = ctx.Payload.Str("newName");
            if (string.IsNullOrWhiteSpace(path)) throw new BridgeException("path is required");
            if (string.IsNullOrWhiteSpace(newName)) throw new BridgeException("newName is required");
            if (newName.Contains("^")) throw new BridgeException("newName must be a bare name, not a path (got '" + newName + "')");
            PathUtil.AssertNotSafetyPath(path);

            dynamic sm = ctx.SysManager();
            string newPath = ObjectRename(sm, path, newName);
            ctx.Cache.Invalidate(path);
            ctx.Cache.InvalidateEnum(); // structural: path/leaf membership changed

            var data = new Json.JObj();
            data["path"] = path;
            data["newName"] = newName;
            data["newPath"] = newPath;
            return data;
        }

        // plc_pou_move (L7119-7157)
        private static Json.JObj Move(ActionContext ctx)
        {
            string path = ctx.Payload.Str("path");
            string newParent = ctx.Payload.Str("newParent");
            if (string.IsNullOrWhiteSpace(path)) throw new BridgeException("path is required");
            if (string.IsNullOrWhiteSpace(newParent)) throw new BridgeException("newParent is required");
            string before = ctx.Payload.Truthy("before") ? ctx.Payload.Str("before") : "";
            PathUtil.AssertNotSafetyPath(path);
            PathUtil.AssertNotSafetyPath(newParent);
            PathUtil.ParentName splitInfo = PathUtil.SplitObjectPath(path);
            PathUtil.AssertMoveLegal(path, newParent);

            dynamic sm = ctx.SysManager();

            string tempPath = NewTempExportPath();
            string newPath;
            try
            {
                newPath = ObjectMove(sm, path, newParent, before, tempPath);
            }
            finally
            {
                if (System.IO.File.Exists(tempPath))
                {
                    try { System.IO.File.Delete(tempPath); } catch { }
                }
            }

            ctx.Cache.Invalidate(splitInfo.Parent);
            ctx.Cache.Invalidate(newParent);
            ctx.Cache.InvalidateEnum(); // structural: object moved to a new parent

            var data = new Json.JObj();
            data["path"] = path;
            data["newParent"] = newParent;
            data["newPath"] = newPath;
            data["name"] = splitInfo.Name;
            data["via"] = "export-delete-import";
            return data;
        }

        // ====================================================================
        // ===== private helpers ==============================================
        // ====================================================================

        private static Json.JObj BatchRollup(int count, int succeeded, int failed, Json.JArr results)
        {
            var data = new Json.JObj();
            data["count"] = count;
            data["succeeded"] = succeeded;
            data["failed"] = failed;
            data["results"] = results;
            return data;
        }

        private static void SaveIfRequested(ActionContext ctx)
        {
            if (ctx.Payload.Has("save") && ctx.Payload.Bool("save"))
            {
                ctx.Dte().ExecuteCommand("File.SaveAll");
            }
        }

        // ---- COM property getters (C#5 closures over dynamic) ---------------
        private static Func<object> MakeNameGetter(dynamic item) { return delegate { return item.Name; }; }
        private static Func<object> MakeStrGetter(dynamic item, string prop)
        {
            if (prop == "ItemSubTypeName") return delegate { return item.ItemSubTypeName; };
            if (prop == "PathName") return delegate { return item.PathName; };
            return delegate { return item.Name; };
        }
        private static Func<object> MakeIntGetter(dynamic item, string prop)
        {
            return delegate { return item.ItemType; };
        }

        private static object SafeIntObj(Func<object> f)
        {
            try { object v = f(); return v == null ? (object)null : ComHelpers.ToInt(v); }
            catch { return null; }
        }

        private static object TryGetLanguage(dynamic item)
        {
            try { return PouHelper.GetImplementationLanguage((object)item); }
            catch { return null; }
        }

        private static object TryGetSubType(dynamic node)
        {
            try { return node.SubType; }
            catch { try { return node.ItemSubType; } catch { return null; } }
        }

        // ---- Invoke-PlcPouCreate (L2726-2760) -------------------------------
        private static dynamic PouCreate(ActionContext ctx, dynamic sm, Json.JObj entry)
        {
            string parent = entry.Str("parent");
            string name = entry.Str("name");
            if (string.IsNullOrWhiteSpace(parent)) throw new BridgeException("parent is required");
            if (string.IsNullOrWhiteSpace(name)) throw new BridgeException("name is required");
            if (!entry.Has("subType") || entry["subType"] == null) throw new BridgeException("subType is required");
            int subType = entry.Int("subType", 0);
            PathUtil.AssertNotSafetyPath(parent);

            int language = (entry.Has("language") && entry["language"] != null) ? entry.Int("language", 1) : 1;
            string returnType = (entry.Has("returnType") && entry["returnType"] != null) ? entry.Str("returnType") : null;
            string extends = (entry.Has("extends") && entry["extends"] != null) ? entry.Str("extends") : null;
            string implements = (entry.Has("implements") && entry["implements"] != null) ? entry.Str("implements") : null;
            string declText = (entry.Has("declText") && entry["declText"] != null) ? entry.Str("declText") : null;
            string before = entry.Truthy("before") ? entry.Str("before") : "";

            dynamic parentItem = ComHelpers.GetTreeItem(sm, parent);
            object vInfo = BuildVInfo(subType, language, returnType, extends, implements, declText);

            dynamic child = parentItem.CreateChild(name, subType, before, vInfo);
            AssertWellFormedChild(parentItem, child, name, subType, parent);
            return child;
        }

        // ---- Invoke-PlcPouCreateFolder (L2762-2788) -------------------------
        private static dynamic PouCreateFolder(ActionContext ctx, dynamic sm, Json.JObj entry)
        {
            string parent = entry.Str("parent");
            string name = entry.Str("name");
            if (string.IsNullOrWhiteSpace(parent)) throw new BridgeException("parent is required");
            if (string.IsNullOrWhiteSpace(name)) throw new BridgeException("name is required");
            PathUtil.AssertNotSafetyPath(parent);
            string before = entry.Truthy("before") ? entry.Str("before") : "";

            dynamic parentItem = ComHelpers.GetTreeItem(sm, parent);
            dynamic child = parentItem.CreateChild(name, 601, before, null);
            AssertWellFormedChild(parentItem, child, name, 601, parent);
            return child;
        }

        // ---- New-PlcPouVInfo (L2652-2724) -----------------------------------
        private static object BuildVInfo(int subType, int language, string returnType, string extends, string implements, string declText)
        {
            switch (subType)
            {
                case 603:
                    if (string.IsNullOrWhiteSpace(returnType)) throw new BridgeException("returnType is required for Function (subType 603)");
                    return new object[] { language, returnType };
                case 611:
                    if (string.IsNullOrWhiteSpace(returnType)) throw new BridgeException("returnType is required for Property (subType 611)");
                    return new object[] { language, returnType };
                case 604:
                case 602:
                {
                    var info = new List<object>();
                    info.Add(language);
                    if (!string.IsNullOrWhiteSpace(extends)) { info.Add("Extends"); info.Add(extends); }
                    if (!string.IsNullOrWhiteSpace(implements)) { info.Add("Implements"); info.Add(implements); }
                    return info.ToArray();
                }
                case 608:
                case 609:
                case 616:
                    return new object[] { language };
                case 618:
                    if (string.IsNullOrWhiteSpace(extends)) return null;
                    return extends;
                case 605:
                case 606:
                case 607:
                case 615:
                case 623:
                case 629:
                    if (string.IsNullOrWhiteSpace(declText)) return null;
                    return declText;
                default:
                    return null;
            }
        }

        // ---- Assert-WellFormedChild (L3192-3241) ----------------------------
        private static void AssertWellFormedChild(dynamic parent, dynamic child, string requestedName, int subType, string parentPath)
        {
            string childActualName = ComHelpers.SafeStr(MakeNameGetter(child));
            string childPath = ComHelpers.SafeStr(MakeStrGetter(child, "PathName"));

            string reason = null;
            if (child == null) reason = "CreateChild returned null";
            else if (string.IsNullOrWhiteSpace(childActualName)) reason = "returned child has a blank name";
            else if (childActualName != requestedName)
                reason = "returned child name '" + childActualName + "' does not match requested name '" + requestedName + "'";
            else
            {
                string expectedPath = parentPath + "^" + requestedName;
                if (!string.IsNullOrWhiteSpace(childPath) && childPath != expectedPath)
                    reason = "returned child path '" + childPath + "' is not under requested parent (expected '" + expectedPath + "')";
            }

            if (reason == null) return;

            if (!string.IsNullOrWhiteSpace(childActualName))
            {
                try { parent.DeleteChild(childActualName); } catch { }
            }

            throw new BridgeException("CreateChild produced a malformed child (name='" + childActualName + "', path='" + childPath +
                "') for requested name='" + requestedName + "', subType=" + subType.ToString(CultureInfo.InvariantCulture) +
                " under '" + parentPath + "' (" + reason + "). This usually means the subType/createInfo is not valid for this parent " +
                "(EtherCAT boxes typically require a proper createInfo). No usable child was created. If a stray blank-named child remains, " +
                "remove it in the XAE GUI or via close-without-save.");
        }

        // ---- Get-PlcTargetParam (L2045-2054) --------------------------------
        private static string GetTargetParam(Json.JObj payload, string dflt)
        {
            if (payload.Has("target") && !string.IsNullOrWhiteSpace(payload.Str("target")))
            {
                string t = payload.Str("target").ToLowerInvariant();
                if (t != "decl" && t != "impl") throw new BridgeException("target must be 'decl' or 'impl'");
                return t;
            }
            return dflt;
        }

        // ====================================================================
        // PURE text helpers (Split/Join/EOL/replace/divergence/snippet/grep)
        // ====================================================================

        private sealed class EolInfo { public string Name; public string Eol; }

        // Get-TextEol (L1656-1673)
        private static EolInfo GetTextEol(string text)
        {
            var e = new EolInfo();
            if (string.IsNullOrEmpty(text)) { e.Name = "CRLF"; e.Eol = "\r\n"; return e; }
            int idx = text.IndexOf('\n');
            if (idx < 0)
            {
                // Lone-CR file (old-Mac style). Report it as "CR" (was mislabeled
                // "LF"); the round-trip EOL string stays "\r" so behavior is intact.
                if (text.IndexOf('\r') >= 0) { e.Name = "CR"; e.Eol = "\r"; return e; }
                e.Name = "CRLF"; e.Eol = "\r\n"; return e;
            }
            if (idx > 0 && text[idx - 1] == '\r') { e.Name = "CRLF"; e.Eol = "\r\n"; return e; }
            e.Name = "LF"; e.Eol = "\n"; return e;
        }

        private sealed class SplitResult { public List<string> Lines; public bool TrailingEol; }

        // Split-PlcLines (L1675-1695)
        private static SplitResult SplitLinesEx(string text)
        {
            var r = new SplitResult();
            if (string.IsNullOrEmpty(text)) { r.Lines = new List<string>(); r.TrailingEol = false; return r; }
            bool trailing = Regex.IsMatch(text, "(\r\n|\n|\r)$");
            string norm = text.Replace("\r\n", "\n").Replace("\r", "\n");
            string[] parts = norm.Split('\n');
            var list = new List<string>(parts);
            if (trailing && list.Count >= 1) list.RemoveAt(list.Count - 1);
            r.Lines = list;
            r.TrailingEol = trailing;
            return r;
        }

        private static List<string> SplitLines(string text) { return SplitLinesEx(text).Lines; }

        // Join-PlcLines (L1697-1710)
        private static string JoinLines(List<string> lines, string eol, bool trailingEol)
        {
            if (lines == null || lines.Count == 0) return "";
            string joined = string.Join(eol, lines.ToArray());
            if (trailingEol) joined = joined + eol;
            return joined;
        }

        private sealed class ApplyReplaceResult { public string NewText; public int Count; public bool Ok; public string Error; }

        // Apply-Replace (L1952-1983)
        private static ApplyReplaceResult ApplyReplace(string text, string find, string replaceWith, int expectCount)
        {
            var r = new ApplyReplaceResult();
            if (string.IsNullOrEmpty(find))
            {
                r.NewText = text; r.Count = 0; r.Ok = false; r.Error = "find must be a non-empty string"; return r;
            }
            string hay = text == null ? "" : text;
            int count = 0;
            int pos = 0;
            while (true)
            {
                int idx = hay.IndexOf(find, pos, StringComparison.Ordinal);
                if (idx < 0) break;
                count++;
                pos = idx + find.Length;
            }
            if (count == 0)
            {
                r.NewText = hay; r.Count = 0; r.Ok = false; r.Error = "find not present in target (no change written)"; return r;
            }
            if (count != expectCount)
            {
                r.NewText = hay; r.Count = count; r.Ok = false;
                r.Error = "expected " + expectCount.ToString(CultureInfo.InvariantCulture) + " occurrence(s), found " +
                    count.ToString(CultureInfo.InvariantCulture) + " (no change written)";
                return r;
            }
            r.NewText = hay.Replace(find, replaceWith); r.Count = count; r.Ok = true; r.Error = null;
            return r;
        }

        // Get-FirstDivergentLine (L2011-2029) — ordinal, case-sensitive.
        private static int? GetFirstDivergentLine(List<string> oldLines, List<string> newLines)
        {
            int oc = oldLines == null ? 0 : oldLines.Count;
            int nc = newLines == null ? 0 : newLines.Count;
            int max = Math.Max(oc, nc);
            for (int i = 0; i < max; i++)
            {
                bool oP = i < oc;
                bool nP = i < nc;
                if (oP != nP) return i + 1;
                string ov = oP ? (oldLines[i] ?? "") : "";
                string nv = nP ? (newLines[i] ?? "") : "";
                if (!string.Equals(ov, nv, StringComparison.Ordinal)) return i + 1;
            }
            return null;
        }

        // Get-LastDivergentLine (L2031-2043)
        private static int? GetLastDivergentLine(List<string> oldLines, List<string> newLines)
        {
            int oi = (oldLines == null ? 0 : oldLines.Count) - 1;
            int ni = (newLines == null ? 0 : newLines.Count) - 1;
            while (oi >= 0 && ni >= 0 && string.Equals(oldLines[oi] ?? "", newLines[ni] ?? "", StringComparison.Ordinal)) { oi--; ni--; }
            if (ni < 0 && oi < 0) return null;
            if (ni < 0) return 1;
            return ni + 1;
        }

        private sealed class ChangedSnippet { public Json.JObj ChangedRange; public Json.JArr Snippet; }

        // Get-ChangedSnippet (L1985-2009)
        private static ChangedSnippet GetChangedSnippet(List<string> newLines, int start, int end, int context)
        {
            var cs = new ChangedSnippet();
            int count = newLines == null ? 0 : newLines.Count;
            if (count == 0)
            {
                var zr = new Json.JObj(); zr["start"] = 0; zr["end"] = 0;
                cs.ChangedRange = zr; cs.Snippet = new Json.JArr(); return cs;
            }
            if (start < 1) start = 1;
            if (end > count) end = count;
            if (end < start) end = start;
            int lo = start - context; if (lo < 1) lo = 1;
            int hi = end + context; if (hi > count) hi = count;
            var snippet = new Json.JArr();
            for (int i = lo; i <= hi; i++)
            {
                var row = new Json.JObj();
                row["line"] = i;
                row["text"] = newLines[i - 1];
                snippet.Add(row);
            }
            var range = new Json.JObj();
            range["start"] = start;
            range["end"] = end;
            cs.ChangedRange = range;
            cs.Snippet = snippet;
            return cs;
        }

        // Select-GrepLines (L1734-1767) — for get_decl/get_impl grep.
        private static Json.JArr SelectGrepLines(List<string> lines, string pattern, int context)
        {
            var outArr = new Json.JArr();
            int count = lines == null ? 0 : lines.Count;
            if (count == 0) return outArr;
            if (context < 0) context = 0;
            Regex regex;
            try { regex = new Regex(pattern); }
            catch (Exception ex) { throw new BridgeException("invalid grep pattern: " + ex.Message); }
            var keep = new SortedSet<int>();
            for (int i = 0; i < count; i++)
            {
                if (regex.IsMatch(lines[i]))
                {
                    int lo = i - context; int hi = i + context;
                    if (lo < 0) lo = 0;
                    if (hi > count - 1) hi = count - 1;
                    for (int j = lo; j <= hi; j++) keep.Add(j);
                }
            }
            foreach (int idx in keep)
            {
                var row = new Json.JObj();
                row["line"] = idx + 1;
                row["text"] = lines[idx];
                outArr.Add(row);
            }
            return outArr;
        }

        // Get-LineSlice (L1712-1732) — clamped 1-based slice (reads never throw).
        private sealed class LineSlice { public List<string> Slice; public bool OutOfBounds; }
        private static LineSlice GetLineSlice(List<string> lines, int start, int end)
        {
            var r = new LineSlice();
            int count = lines == null ? 0 : lines.Count;
            if (count == 0) { r.Slice = new List<string>(); r.OutOfBounds = true; return r; }
            bool oob = (start < 1) || (end > count) || (start > end);
            int cs = start < 1 ? 1 : start;
            int ce = end > count ? count : end;
            if (cs > ce) { r.Slice = new List<string>(); r.OutOfBounds = true; return r; }
            var slice = new List<string>();
            for (int i = cs - 1; i <= ce - 1; i++) slice.Add(lines[i]);
            r.Slice = slice; r.OutOfBounds = oob; return r;
        }

        // Get-PlcTextReadResult (L2056-2097)
        private static Json.JObj BuildTextReadResult(string text, Json.JObj payload, string path)
        {
            EolInfo eolInfo = GetTextEol(text);
            List<string> lines = SplitLines(text);
            int lineCount = lines.Count;

            bool hasRange = payload.Has("range") && payload["range"] != null;
            bool hasGrep = payload.Has("grep") && payload["grep"] != null;
            if (hasRange && hasGrep) throw new BridgeException("range and grep are mutually exclusive");

            var data = new Json.JObj();
            data["path"] = path;
            data["lineCount"] = lineCount;
            data["eol"] = eolInfo.Name;

            if (hasGrep)
            {
                Json.JObj grep = payload.Obj("grep");
                string pattern = grep == null ? null : grep.Str("pattern");
                if (string.IsNullOrEmpty(pattern)) throw new BridgeException("grep.pattern is required");
                int ctxN = (grep.Has("context") && grep["context"] != null) ? grep.Int("context", 2) : 2;
                data["matches"] = SelectGrepLines(lines, pattern, ctxN);
                return data;
            }

            if (hasRange)
            {
                Json.JObj range = payload.Obj("range");
                int start = range.Int("start", 0);
                int end = range.Int("end", 0);
                LineSlice sl = GetLineSlice(lines, start, end);
                data["text"] = JoinLines(sl.Slice, eolInfo.Eol, false);
                if (sl.OutOfBounds) data["truncated"] = true;
                return data;
            }

            data["text"] = text;
            return data;
        }

        // ---- language helpers (L2099-2123) ----------------------------------
        private static string LanguageName(object language)
        {
            int l = language == null ? -1 : ComHelpers.ToInt(language);
            switch (l)
            {
                case 0: return "NONE";
                case 1: return "ST";
                case 2: return "IL";
                case 3: return "SFC";
                case 4: return "FBD";
                case 5: return "CFC";
                case 6: return "LD";
                default: return "UNKNOWN";
            }
        }

        private static bool IsGraphicalLanguage(object language)
        {
            if (language == null) return false;
            int l = ComHelpers.ToInt(language);
            return !(l == 1 || l == 2);
        }

        // ---- Find-VarBlock support (L1806-1876) -----------------------------
        private static readonly string[] VarKeywords = new string[] {
            "VAR","VAR_GLOBAL","VAR_INPUT","VAR_OUTPUT","VAR_IN_OUT","VAR_STAT","VAR_TEMP","VAR_INST","VAR_CONFIG","VAR_EXTERNAL"
        };

        private static string StrippedToken(string line)
        {
            if (line == null) return "";
            string t = line.Trim();
            if (t == "") return "";
            if (t.StartsWith("//")) return "";
            if (t.StartsWith("(*")) return "";
            int ci = t.IndexOf("//", StringComparison.Ordinal);
            if (ci >= 0) t = t.Substring(0, ci).Trim();
            int bi = t.IndexOf("(*", StringComparison.Ordinal);
            if (bi >= 0) t = t.Substring(0, bi).Trim();
            if (t == "") return "";
            string[] parts = Regex.Split(t, "\\s+");
            return parts[0];
        }

        private sealed class VarBlock { public bool Found; public int StartLine; public int EndVarLine; public string Indent; }

        private static VarBlock FindVarBlock(List<string> lines, string blockKeyword, int occurrence)
        {
            var nf = new VarBlock(); nf.Found = false; nf.Indent = "";
            int count = lines == null ? 0 : lines.Count;
            if (count == 0) return nf;
            if (occurrence < 1) occurrence = 1;
            string[] wantTokens = Regex.Split(blockKeyword.Trim(), "\\s+");
            string wantHead = wantTokens[0].ToUpperInvariant();
            int found = 0;
            int i = 0;
            while (i < count)
            {
                string tok = StrippedToken(lines[i]).ToUpperInvariant();
                if (tok == wantHead && Array.IndexOf(VarKeywords, tok) >= 0)
                {
                    found++;
                    if (found == occurrence)
                    {
                        int startLine = i + 1;
                        string indent = "";
                        Match m = Regex.Match(lines[i], "^(\\s*)");
                        if (m.Success) indent = m.Groups[1].Value;
                        for (int k = i + 1; k < count; k++)
                        {
                            string et = StrippedToken(lines[k]).ToUpperInvariant();
                            if (et == "END_VAR")
                            {
                                var r = new VarBlock();
                                r.Found = true; r.StartLine = startLine; r.EndVarLine = k + 1; r.Indent = indent;
                                return r;
                            }
                        }
                        return nf;
                    }
                    for (int k = i + 1; k < count; k++)
                    {
                        string et = StrippedToken(lines[k]).ToUpperInvariant();
                        if (et == "END_VAR") { i = k; break; }
                    }
                }
                i++;
            }
            return nf;
        }

        // ---- Get-DeclOutline (L1878-1950) -----------------------------------
        private sealed class DeclOutline { public Json.JObj Header; public Json.JArr VarBlocks; }

        private static readonly string[] HeaderKeywords = new string[] {
            "FUNCTION_BLOCK","FUNCTION","PROGRAM","INTERFACE","TYPE","STRUCT","UNION","VAR_GLOBAL"
        };

        private static DeclOutline GetDeclOutline(List<string> lines)
        {
            int count = lines == null ? 0 : lines.Count;
            var header = new Json.JObj();
            header["keyword"] = null; header["name"] = null; header["extends"] = null;
            header["implements"] = null; header["returnType"] = null;

            for (int i = 0; i < count; i++)
            {
                string tok = StrippedToken(lines[i]).ToUpperInvariant();
                if (tok == "") continue;
                if (Array.IndexOf(HeaderKeywords, tok) >= 0)
                {
                    string clean = lines[i];
                    int ci = clean.IndexOf("//", StringComparison.Ordinal); if (ci >= 0) clean = clean.Substring(0, ci);
                    clean = clean.Trim();
                    header["keyword"] = tok;
                    Match em = Regex.Match(clean, "(?i)\\bEXTENDS\\s+([A-Za-z_][A-Za-z0-9_\\.]*)");
                    if (em.Success) header["extends"] = em.Groups[1].Value;
                    Match im = Regex.Match(clean, "(?i)\\bIMPLEMENTS\\s+(.+)$");
                    if (im.Success)
                    {
                        string impl = im.Groups[1].Value;
                        impl = Regex.Replace(impl, "(?i)\\bEXTENDS\\b.*$", "").Trim();
                        header["implements"] = impl;
                    }
                    string firstTok = lines[i].Trim().Split(' ')[0];
                    Match nm = Regex.Match(clean, "(?i)^" + Regex.Escape(firstTok) + "\\s+([A-Za-z_][A-Za-z0-9_]*)");
                    if (nm.Success) header["name"] = nm.Groups[1].Value;
                    Match rm = Regex.Match(clean, ":\\s*([A-Za-z_][A-Za-z0-9_\\.]*)\\s*$");
                    if (rm.Success && tok == "FUNCTION") header["returnType"] = rm.Groups[1].Value;
                    break;
                }
                if (Array.IndexOf(VarKeywords, tok) >= 0) break;
            }

            var blocks = new Json.JArr();
            int x = 0;
            while (x < count)
            {
                string tok = StrippedToken(lines[x]).ToUpperInvariant();
                if (Array.IndexOf(VarKeywords, tok) >= 0)
                {
                    int startLine = x + 1;
                    string opener = lines[x].Trim();
                    int oc = opener.IndexOf("//", StringComparison.Ordinal); if (oc >= 0) opener = opener.Substring(0, oc).Trim();
                    int ob = opener.IndexOf("(*", StringComparison.Ordinal); if (ob >= 0) opener = opener.Substring(0, ob).Trim();
                    string kind = opener;
                    int? endLine = null;
                    int varCount = 0;
                    for (int k = x + 1; k < count; k++)
                    {
                        string et = StrippedToken(lines[k]).ToUpperInvariant();
                        if (et == "END_VAR") { endLine = k + 1; break; }
                        string body = StrippedToken(lines[k]);
                        if (body != "" && lines[k].IndexOf(':') >= 0) varCount++;
                    }
                    if (endLine.HasValue)
                    {
                        var b = new Json.JObj();
                        b["kind"] = kind;
                        b["startLine"] = startLine;
                        b["endLine"] = endLine.Value;
                        b["varCount"] = varCount;
                        blocks.Add(b);
                        x = endLine.Value - 1;
                    }
                }
                x++;
            }

            var o = new DeclOutline();
            o.Header = header;
            o.VarBlocks = blocks;
            return o;
        }

        // ---- Find-MatchesInText (L1769-1804) --------------------------------
        private static List<Json.JObj> FindMatchesInText(string text, string pattern, string section, string path, bool ignoreCase)
        {
            var outList = new List<Json.JObj>();
            if (string.IsNullOrEmpty(text)) return outList;
            RegexOptions opts = ignoreCase ? RegexOptions.IgnoreCase : RegexOptions.None;
            Regex regex;
            try { regex = new Regex(pattern, opts); }
            catch (Exception ex) { throw new BridgeException("invalid pattern: " + ex.Message); }
            string norm = text.Replace("\r\n", "\n").Replace("\r", "\n");
            string[] lines = norm.Split('\n');
            for (int i = 0; i < lines.Length; i++)
            {
                if (regex.IsMatch(lines[i]))
                {
                    var row = new Json.JObj();
                    row["path"] = path;
                    row["section"] = section;
                    row["line"] = i + 1;
                    row["text"] = (lines[i] ?? "").Trim();
                    outList.Add(row);
                }
            }
            return outList;
        }

        // ---- Get-GraphicalImplXml (L2132-2185) ------------------------------
        private static string GetGraphicalImplXml(string documentXml, string objectName, bool isPouLevel)
        {
            if (string.IsNullOrWhiteSpace(documentXml)) return null;
            var doc = new XmlDocument();
            doc.PreserveWhitespace = true;
            doc.LoadXml(documentXml);
            XmlElement root = doc.DocumentElement;
            if (root == null) return null;

            XmlNode container = null;
            foreach (XmlNode c in root.ChildNodes)
            {
                if (c.NodeType != XmlNodeType.Element) continue;
                if (c.LocalName == "POU") { container = c; break; }
                if (container == null) container = c;
            }
            if (container == null) return null;

            if (isPouLevel)
            {
                foreach (XmlNode n in container.ChildNodes)
                {
                    if (n.NodeType == XmlNodeType.Element && n.LocalName == "Implementation") return n.OuterXml;
                }
                return null;
            }

            var kinds = new string[] { "Action", "Method", "Transition", "Property" };
            foreach (XmlNode n in container.ChildNodes)
            {
                if (n.NodeType != XmlNodeType.Element) continue;
                if (Array.IndexOf(kinds, n.LocalName) < 0) continue;
                XmlElement el = n as XmlElement;
                string nm = el == null ? null : el.GetAttribute("Name");
                if (nm == objectName)
                {
                    foreach (XmlNode impl in n.ChildNodes)
                    {
                        if (impl.NodeType == XmlNodeType.Element && impl.LocalName == "Implementation") return impl.OuterXml;
                    }
                }
            }
            return null;
        }

        // ---- Get-PlcObjectTypeName (L2193-2256) ------------------------------
        private static string GetPlcObjectTypeName(object itemType, object itemSubType, string itemSubTypeName, string name, int childCount, bool hasDecl)
        {
            string nm = name == null ? "" : name;
            int it = itemType == null ? -1 : ComHelpers.ToInt(itemType);
            int st = itemSubType == null ? -1 : ComHelpers.ToInt(itemSubType);

            if (Regex.IsMatch(nm, "\\sProject$")) return "Project";
            string[] folderNames = new string[] { "References", "POUs", "DUTs", "GVLs", "VISUs", "FBs", "PRGs" };
            if (Array.IndexOf(folderNames, nm) >= 0 && childCount > 0 && !hasDecl) return "Folder";

            switch (it)
            {
                case 9: return "Project";
                case 600: return "App";
                case 621: return "Task";
                case 8: return "Folder";
                default: break;
            }

            switch (st)
            {
                case 602: return "Program";
                case 603: return "Function";
                case 604: return "FunctionBlock";
                case 605: return "Enum";
                case 606: return "Struct";
                case 607: return "Union";
                case 608: return "Action";
                case 609: return "Method";
                case 611: return "Property";
                case 615: return "GVL";
                case 616: return "Transition";
                case 618: return "Interface";
                case 619: return "Visualization";
                case 623: return "Alias";
                case 629: return "ParameterList";
                case 631: return "UML";
                default: break;
            }

            if (!string.IsNullOrWhiteSpace(itemSubTypeName)) return itemSubTypeName.Trim();
            return "Unknown";
        }

        // ====================================================================
        // Tree walk (PERF) + project-node resolution
        // ====================================================================

        // Resolve-PlcRootPath (L1164-1177)
        private static string ResolvePlcRootPath(dynamic sm, string path)
        {
            if (!string.IsNullOrWhiteSpace(path)) return path;
            dynamic tipc = ComHelpers.GetTreeItem(sm, "TIPC");
            if (ComHelpers.ChildCount(tipc) < 1) throw new BridgeException("No PLC project found under TIPC");
            dynamic first = ComHelpers.Child(tipc, 1);
            string firstName = ComHelpers.SafeStr(MakeNameGetter(first));
            return "TIPC^" + firstName;
        }

        private sealed class ProjectNode { public string PlcPath; public string ProjectPath; }

        // Get-PlcProjectNodePath (L2258-2310)
        private static ProjectNode GetPlcProjectNodePath(dynamic sm, string plcPathIn)
        {
            string plcPath = ResolvePlcRootPath(sm, plcPathIn);
            PathUtil.AssertNotSafetyPath(plcPath);
            dynamic root = ComHelpers.GetTreeItem(sm, plcPath);
            string rootName = ComHelpers.SafeStr(MakeNameGetter(root));

            var candidatePaths = new List<string>();
            if (!string.IsNullOrWhiteSpace(rootName)) candidatePaths.Add(plcPath + "^" + rootName + " Project");
            int childCount = ComHelpers.ChildCount(root);
            for (int ci = 1; ci <= childCount; ci++)
            {
                dynamic childNode = ComHelpers.Child(root, ci);
                if (childNode != null)
                {
                    string cn = ComHelpers.SafeStr(MakeNameGetter(childNode));
                    if (!string.IsNullOrWhiteSpace(cn))
                    {
                        string cp = plcPath + "^" + cn;
                        if (!candidatePaths.Contains(cp)) candidatePaths.Add(cp);
                    }
                }
            }
            if (!candidatePaths.Contains(plcPath)) candidatePaths.Add(plcPath);

            string lastErr = null;
            string firstResolvable = null;
            for (int idx = 0; idx < candidatePaths.Count; idx++)
            {
                string candPath = candidatePaths[idx];
                try
                {
                    dynamic node = ComHelpers.GetTreeItem(sm, candPath);
                    string nn = ComHelpers.SafeStr(MakeNameGetter(node));
                    bool isLast = (idx == candidatePaths.Count - 1);
                    if ((nn != null && Regex.IsMatch(nn, "\\sProject$")) || isLast)
                    {
                        var pn = new ProjectNode(); pn.PlcPath = plcPath; pn.ProjectPath = candPath; return pn;
                    }
                    // PS overwrites on every no-error iteration (last resolvable wins).
                    if (lastErr == null) firstResolvable = candPath;
                }
                catch (Exception ex) { lastErr = ex.Message; }
            }
            if (firstResolvable != null)
            {
                var pn = new ProjectNode(); pn.PlcPath = plcPath; pn.ProjectPath = firstResolvable; return pn;
            }
            throw new BridgeException("could not resolve the IEC project node under '" + plcPath + "'. Last error: " + lastErr);
        }

        // PERF: resolve the subtree root via cache + memoize the bounded walk.
        // Returns the single root node (Invoke-PlcTreeWalk shape) or null.
        private static Json.JObj WalkSubtree(ActionContext ctx, dynamic sm, string startPath, int maxDepth)
        {
            Json.JArr cached = ctx.Cache.GetWalk(startPath, maxDepth);
            if (cached != null && cached.Count == 1) return cached[0] as Json.JObj;

            dynamic startNode = ctx.Cache.LookupItem(sm, startPath);
            Json.JObj root = TreeWalk(sm, startNode, startPath, 1, maxDepth);

            var memo = new Json.JArr();
            if (root != null) memo.Add(root);
            ctx.Cache.PutWalk(startPath, maxDepth, memo);
            return root;
        }

        // Invoke-PlcTreeWalk (L2312-2368). Depth 1 = start node; MaxDepth 0 = unbounded.
        private static Json.JObj TreeWalk(dynamic sm, dynamic node, string basePath, int depth, int maxDepth)
        {
            Json.JObj info = ComHelpers.ConvertTreeItem(node);
            string subTypeName = ComHelpers.SafeStr(MakeStrGetter(node, "ItemSubTypeName"));
            int childCount = info["childCount"] == null ? 0 : ComHelpers.ToInt(info["childCount"]);
            string type = GetPlcObjectTypeName(info["itemType"], info["subType"], subTypeName, info.Str("name"), childCount, false);

            var result = new Json.JObj();
            result["path"] = basePath;
            result["name"] = info["name"];
            result["type"] = type;
            result["itemType"] = info["itemType"];
            result["subType"] = info["subType"];
            result["childCount"] = childCount;
            if (!string.IsNullOrWhiteSpace(subTypeName)) result["subTypeName"] = subTypeName;

            if (childCount > 0)
            {
                if (maxDepth > 0 && depth > maxDepth)
                {
                    result["truncated"] = true;
                }
                else
                {
                    var children = new Json.JArr();
                    for (int i = 1; i <= childCount; i++)
                    {
                        dynamic childNode = ComHelpers.Child(node, i);
                        if (childNode == null) continue;
                        string childName = ComHelpers.SafeStr(MakeNameGetter(childNode));
                        if (string.IsNullOrWhiteSpace(childName)) continue;
                        string childPath = basePath + "^" + childName;
                        children.Add(TreeWalk(sm, childNode, childPath, depth + 1, maxDepth));
                    }
                    if (children.Count > 0) result["children"] = children;
                }
            }
            return result;
        }

        // ConvertTo-NormalizedTypeSet (L2442-2454) -> HashSet<string> or null.
        private static object NormalizedTypeSet(string typeFilter)
        {
            if (string.IsNullOrWhiteSpace(typeFilter)) return null;
            var set = new HashSet<string>(StringComparer.Ordinal);
            foreach (string t in typeFilter.Split(','))
            {
                string tt = t.Trim().ToLowerInvariant();
                if (tt != "") set.Add(tt);
            }
            if (set.Count == 0) return null;
            return set;
        }

        // Test-NodeNameMatch (L2456-2470)
        private static bool TestNodeNameMatch(string name, string pattern)
        {
            if (string.IsNullOrWhiteSpace(pattern)) return true;
            string nm = name == null ? "" : name;
            if (pattern.Length >= 2 && pattern.StartsWith("/") && pattern.EndsWith("/"))
            {
                string rx = pattern.Substring(1, pattern.Length - 2);
                try { return Regex.IsMatch(nm, rx, RegexOptions.IgnoreCase); }
                catch (Exception ex) { throw new BridgeException("invalid name regex: " + ex.Message); }
            }
            return nm.ToLowerInvariant().Contains(pattern.ToLowerInvariant());
        }

        // Select-FlatTreeMatches (L2472-2506) — flatten nested walk + filter.
        private static Json.JArr SelectFlatTreeMatches(Json.JObj nestedRoot, string namePattern, HashSet<string> typeSet)
        {
            var outArr = new Json.JArr();
            if (nestedRoot == null) return outArr;
            var stack = new Stack<Json.JObj>();
            stack.Push(nestedRoot);
            while (stack.Count > 0)
            {
                Json.JObj n = stack.Pop();
                bool nameOk = TestNodeNameMatch(n.Str("name"), namePattern);
                bool typeOk = true;
                if (typeSet != null) typeOk = typeSet.Contains((n.Str("type") ?? "").ToLowerInvariant());
                if (nameOk && typeOk)
                {
                    var flat = new Json.JObj();
                    flat["path"] = n["path"];
                    flat["name"] = n["name"];
                    flat["type"] = n["type"];
                    flat["itemType"] = n["itemType"];
                    flat["subType"] = n["subType"];
                    flat["childCount"] = n["childCount"];
                    if (n.Has("subTypeName")) flat["subTypeName"] = n["subTypeName"];
                    outArr.Add(flat);
                }
                Json.JArr kids = n.Arr("children");
                if (kids != null)
                {
                    foreach (object c in kids) { Json.JObj cj = c as Json.JObj; if (cj != null) stack.Push(cj); }
                }
            }
            return outArr;
        }

        // Select-PrunedTree (L2508-2528) — keep ancestors of any kept node.
        private static Json.JObj PruneTree(Json.JObj node, HashSet<string> typeSet)
        {
            if (node == null) return null;
            bool selfKept = typeSet.Contains((node.Str("type") ?? "").ToLowerInvariant());
            var keptChildren = new Json.JArr();
            Json.JArr kids = node.Arr("children");
            if (kids != null)
            {
                foreach (object c in kids)
                {
                    Json.JObj pc = PruneTree(c as Json.JObj, typeSet);
                    if (pc != null) keptChildren.Add(pc);
                }
            }
            if (!selfKept && keptChildren.Count == 0) return null;
            var copy = new Json.JObj();
            foreach (string k in node.Keys) { if (k != "children") copy[k] = node[k]; }
            if (keptChildren.Count > 0) copy["children"] = keptChildren;
            return copy;
        }

        // Measure-TreeNodeCount (L2530-2539)
        private static int MeasureTreeNodeCount(Json.JObj node)
        {
            if (node == null) return 0;
            int n = 1;
            Json.JArr kids = node.Arr("children");
            if (kids != null)
            {
                foreach (object c in kids) n += MeasureTreeNodeCount(c as Json.JObj);
            }
            return n;
        }

        // ====================================================================
        // SEARCH support: code-object enumeration + per-object text read
        // ====================================================================

        private sealed class CodeObject { public string Path; public dynamic Item; }

        // Get-PlcCodeObjects (L2370-2403) — flat de-duped descendant list.
        private static void CollectCodeObjects(dynamic sm, string rootPath, dynamic rootItem, HashSet<string> seen, List<CodeObject> outList)
        {
            if (seen.Add(rootPath))
            {
                var co = new CodeObject(); co.Path = rootPath; co.Item = rootItem; outList.Add(co);
            }
            int childCount = ComHelpers.ChildCount(rootItem);
            for (int i = 1; i <= childCount; i++)
            {
                dynamic childNode = ComHelpers.Child(rootItem, i);
                if (childNode == null) continue;
                string childName = ComHelpers.SafeStr(MakeNameGetter(childNode));
                if (string.IsNullOrWhiteSpace(childName)) continue;
                string childPath = rootPath + "^" + childName;
                if (seen.Contains(childPath)) continue;
                CollectCodeObjects(sm, childPath, childNode, seen, outList);
            }
        }

        private sealed class ObjectText { public bool HasDecl; public string Decl; public bool HasImpl; public string Impl; }

        // Read the FULL decl/impl text + impl language for a code object via COM
        // (the ~3 typed gets that dominate search latency). Cached unfiltered so a
        // single entry serves any decl/impl/declOnly/implOnly query later. Returns
        // a TreeCache.TextEntry suitable for PutText.
        private static TreeCache.TextEntry ReadFullObjectText(dynamic item)
        {
            var e = new TreeCache.TextEntry();
            e.HasDecl = false; e.HasImpl = false; e.Language = null;
            try { e.Decl = PouHelper.GetDeclaration((object)item); e.HasDecl = true; }
            catch { e.HasDecl = false; }

            object lang = null;
            try { lang = PouHelper.GetImplementationLanguage((object)item); }
            catch { lang = null; }
            e.Language = lang;
            if (lang != null && !IsGraphicalLanguage(lang))
            {
                try { e.Impl = PouHelper.GetImplementation((object)item); e.HasImpl = true; }
                catch { e.HasImpl = false; }
            }
            return e;
        }

        // Project a cached full-text entry down to the requested decl/impl scope.
        private static ObjectText ProjectObjectText(TreeCache.TextEntry e, bool declOnly, bool implOnly)
        {
            var res = new ObjectText();
            res.HasDecl = !implOnly && e.HasDecl;
            if (res.HasDecl) res.Decl = e.Decl;
            res.HasImpl = !declOnly && e.HasImpl;
            if (res.HasImpl) res.Impl = e.Impl;
            return res;
        }

        // Cache-aware per-object text fetch used by Search. On a hit it returns the
        // cached strings (sub-ms); on a miss it does the COM reads and populates
        // the cache. CORRECTNESS GATE: for any object whose tree-path is in the
        // current open-document set, re-check the editor's .Saved (busy-retry,
        // rejected⇒dirty) and bypass+refresh the cache if dirty. `forceRefresh`
        // (search refresh:true) always re-pulls live. Closed objects always serve
        // from cache. Caller is on the STA worker thread.
        private static ObjectText SelectPlcObjectTextCached(ActionContext ctx, dynamic item, string path,
            bool declOnly, bool implOnly, bool forceRefresh)
        {
            TreeCache.TextEntry cached = forceRefresh ? null : ctx.Cache.GetText(path);
            if (cached != null && ctx.Edits != null && ctx.Edits.IsOpen(path) && ctx.Edits.IsDirty(path))
                cached = null; // open + dirty (or busy) → re-pull live

            if (cached == null)
            {
                cached = ReadFullObjectText(item);
                ctx.Cache.PutText(path, cached);
            }
            return ProjectObjectText(cached, declOnly, implOnly);
        }

        // Path-only variant used by Search's warm path. CRITICAL: on a full cache
        // hit this resolves NO COM tree item — the item is lazily resolved via
        // ctx.Cache.LookupItem ONLY on a text miss (or a dirty open doc, or
        // forceRefresh). The open-doc gate is COM-free for closed objects
        // (IsOpen = dict lookup) and only pays the .Saved COM read for the small
        // set of actually-open documents. Caller is on the STA worker thread.
        private static ObjectText SelectPlcObjectTextCachedByPath(ActionContext ctx, dynamic sm, string path,
            bool declOnly, bool implOnly, bool forceRefresh)
        {
            TreeCache.TextEntry cached = forceRefresh ? null : ctx.Cache.GetText(path);
            if (cached != null && ctx.Edits != null && ctx.Edits.IsOpen(path) && ctx.Edits.IsDirty(path))
                cached = null; // open + dirty (or busy) → re-pull live

            if (cached == null)
            {
                // Text miss / dirty / forceRefresh: NOW (and only now) pay the COM
                // item resolution and full-text read.
                dynamic item = ctx.Cache.LookupItem(sm, path);
                cached = ReadFullObjectText(item);
                ctx.Cache.PutText(path, cached);
            }
            return ProjectObjectText(cached, declOnly, implOnly);
        }

        // Background corpus pre-warm (Option 3). Walks the whole IEC project once
        // on the STA thread, populating the text cache so the first user search is
        // already warm. Fire-and-forget; every COM access tolerates the solution
        // closing mid-walk. Skips objects already cached so a re-run is cheap.
        public static void PrewarmSearchCache(ActionContext ctx)
        {
            dynamic sm;
            try { sm = ctx.SysManager(); } catch { return; }

            ProjectNode resolved;
            try { resolved = GetPlcProjectNodePath(sm, null); }
            catch { return; }
            string startPath = resolved.ProjectPath;
            try { PathUtil.AssertNotSafetyPath(startPath); } catch { return; }

            dynamic startNode;
            try { startNode = ctx.Cache.LookupItem(sm, startPath); }
            catch { return; }

            var objects = new List<CodeObject>();
            try { CollectCodeObjects(sm, startPath, startNode, new HashSet<string>(StringComparer.Ordinal), objects); }
            catch { return; }

            // Populate the enum cache so the FIRST user search does no COM walk.
            var paths = new List<string>(objects.Count);
            foreach (CodeObject po in objects) paths.Add(po.Path);
            ctx.Cache.PutEnum(startPath, paths);

            int warmed = 0;
            foreach (CodeObject obj in objects)
            {
                if (ctx.Cache.GetText(obj.Path) != null) continue;
                try
                {
                    TreeCache.TextEntry e = ReadFullObjectText(obj.Item);
                    ctx.Cache.PutText(obj.Path, e);
                    warmed++;
                }
                catch { /* solution closing or transient COM — stop being greedy */ }
            }
            Log.Write("PrewarmSearchCache: warmed " + warmed + " of " + objects.Count + " code objects under " + startPath);
        }

        // ====================================================================
        // RMW (read-modify-write) wrapper — all COM lives here.
        // ====================================================================

        private sealed class RmwResult
        {
            public string NewText; public string Eol; public string EolName; public bool TrailingEol;
            public int OldLineCount; public int NewLineCount; public List<string> NewLines; public object Language;
        }

        private delegate string Mutator(string text, string eol, List<string> lines);

        // Invoke-PlcTextRMW (L2541-2595)
        private static RmwResult TextRmw(object smObj, string path, string target, Mutator mutator)
        {
            dynamic sm = smObj;
            PathUtil.AssertNotSafetyPath(path);
            dynamic item = ComHelpers.GetTreeItem(sm, path);
            object language = null;
            string text;
            if (target == "impl")
            {
                language = TryGetLanguage(item);
                if (IsGraphicalLanguage(language))
                {
                    throw new BridgeException("Refused surgical text edit on " + path +
                        ": implementation language is " + LanguageName(language) +
                        "; ImplementationText is not authoritative for graphical languages. Use set_impl implXml (whole-XML round-trip) instead.");
                }
                text = PouHelper.GetImplementation((object)item);
            }
            else
            {
                text = PouHelper.GetDeclaration((object)item);
            }
            EolInfo eolInfo = GetTextEol(text);
            SplitResult split = SplitLinesEx(text);
            List<string> oldLines = split.Lines;
            string newText = mutator(text, eolInfo.Eol, oldLines);
            if (newText == null) newText = "";
            if (target == "impl") PouHelper.SetImplementationText((object)item, newText);
            else PouHelper.SetDeclaration((object)item, newText);
            SplitResult newSplit = SplitLinesEx(newText);

            var r = new RmwResult();
            r.NewText = newText;
            r.Eol = eolInfo.Eol;
            r.EolName = eolInfo.Name;
            r.TrailingEol = split.TrailingEol;
            r.OldLineCount = oldLines.Count;
            r.NewLineCount = newSplit.Lines.Count;
            r.NewLines = newSplit.Lines;
            r.Language = language;
            return r;
        }

        // Add-ValidateResult (L2605-2650) — optional post-write CheckAllObjects.
        private static void AddValidateResult(ActionContext ctx, dynamic sm, Json.JObj data)
        {
            if (!(ctx.Payload.Has("validate") && ctx.Payload.Bool("validate"))) return;
            try
            {
                dynamic tipc = sm.LookupTreeItem("TIPC");
                if (ComHelpers.ChildCount(tipc) < 1) { data["validated"] = false; return; }
                string plcPath = "TIPC^" + ((string)tipc.Child(1).Name);
                dynamic root = ComHelpers.GetTreeItem(sm, plcPath);
                string rootName = ComHelpers.SafeStr(MakeNameGetter(root));
                var candidatePaths = new List<string>();
                if (!string.IsNullOrWhiteSpace(rootName)) candidatePaths.Add(plcPath + "^" + rootName + " Project");
                int childCount = ComHelpers.ChildCount(root);
                for (int ci = 1; ci <= childCount; ci++)
                {
                    dynamic childNode = ComHelpers.Child(root, ci);
                    if (childNode != null)
                    {
                        string cn = ComHelpers.SafeStr(MakeNameGetter(childNode));
                        if (!string.IsNullOrWhiteSpace(cn))
                        {
                            string cp = plcPath + "^" + cn;
                            if (!candidatePaths.Contains(cp)) candidatePaths.Add(cp);
                        }
                    }
                }
                if (!candidatePaths.Contains(plcPath)) candidatePaths.Add(plcPath);
                foreach (string candPath in candidatePaths)
                {
                    try
                    {
                        dynamic node = ComHelpers.GetTreeItem(sm, candPath);
                        data["validated"] = PlcProjectHelper.CheckAll((object)node);
                        return;
                    }
                    catch { }
                }
                data["validated"] = false;
            }
            catch { data["validated"] = false; }
        }

        // ====================================================================
        // RENAME / MOVE COM
        // ====================================================================

        // New-PlcTempExportPath (L1635-1647) — ExportChild target is a plain .zip.
        private static string NewTempExportPath()
        {
            string name = "te1000-plcmove-" + Guid.NewGuid().ToString("N") + ".zip";
            return System.IO.Path.Combine(System.IO.Path.GetTempPath(), name);
        }

        // Invoke-PlcObjectRename (L3076-3111)
        private static string ObjectRename(dynamic sm, string path, string newName)
        {
            if (string.IsNullOrWhiteSpace(newName)) throw new BridgeException("newName is required");
            dynamic item = ComHelpers.GetTreeItem(sm, path);

            bool renamed = false;
            try { item.Name = newName; renamed = true; }
            catch { renamed = false; }

            if (!renamed)
            {
                string escapedName = PathUtil.XmlEscape(newName);
                string xml = "<TreeItem><ItemName>" + escapedName + "</ItemName></TreeItem>";
                try { item.ConsumeXml(xml); }
                catch (Exception)
                {
                    string xmlError = null;
                    try { xmlError = (string)item.GetLastXmlError(); } catch { }
                    if (!string.IsNullOrEmpty(xmlError)) throw new BridgeException("ConsumeXml failed: " + xmlError);
                    throw;
                }
            }

            return ComHelpers.SafeStr(MakeStrGetter(item, "PathName"));
        }

        // Invoke-PlcObjectMove (L3113-3190) — export(.zip)/delete/import, one attach.
        private static string ObjectMove(dynamic sm, string path, string newParent, string before, string tempPath)
        {
            PathUtil.ParentName split = PathUtil.SplitObjectPath(path);
            PathUtil.AssertMoveLegal(path, newParent);
            PathUtil.AssertNotSafetyPath(path);
            PathUtil.AssertNotSafetyPath(newParent);

            dynamic oldParent = ComHelpers.GetTreeItem(sm, split.Parent);
            dynamic newParentItem = ComHelpers.GetTreeItem(sm, newParent);
            string beforeName = string.IsNullOrWhiteSpace(before) ? "" : before;

            // 1) export backup
            oldParent.ExportChild(split.Name, tempPath);

            // 2) delete original FIRST (global namespace -> preserve exact name)
            try { oldParent.DeleteChild(split.Name); }
            catch (Exception ex)
            {
                throw new BridgeException("Move aborted: could not delete the original '" + split.Name + "' under '" +
                    split.Parent + "': " + ex.Message + ". Nothing was moved; the original is intact.");
            }

            // 3) import under new parent
            string importErr = null;
            try { newParentItem.ImportChild(tempPath, beforeName, true, ""); }
            catch (Exception ex) { importErr = ex.Message; }

            // 4) verify by name-path
            string newPath = newParent + "^" + split.Name;
            dynamic verified = null;
            if (importErr == null) verified = ComHelpers.TryGetTreeItem(sm, newPath);

            if (verified == null)
            {
                bool recovered = false;
                try
                {
                    oldParent.ImportChild(tempPath, "", true, "");
                    dynamic restored = ComHelpers.TryGetTreeItem(sm, path);
                    if (restored != null) recovered = true;
                }
                catch { recovered = false; }

                string detail = importErr != null
                    ? " (import error: " + importErr + ")"
                    : " (object not found under the new parent after import)";
                if (recovered)
                {
                    throw new BridgeException("Move failed but the original was RESTORED at '" + path + "' (no data lost)" + detail + ".");
                }

                string preserved = System.IO.Path.Combine(System.IO.Path.GetTempPath(),
                    "te1000-plcmove-RECOVER-" + split.Name + "-" + System.IO.Path.GetFileName(tempPath));
                try { System.IO.File.Copy(tempPath, preserved, true); }
                catch { preserved = tempPath; }
                throw new BridgeException("Move FAILED and the original could not be auto-restored. '" + split.Name +
                    "' was exported to a recovery archive at '" + preserved +
                    "' -- import it manually (right-click the parent -> Import) to restore" + detail + ".");
            }

            return ComHelpers.SafeStr(MakeStrGetter(verified, "PathName"));
        }
    }
}
