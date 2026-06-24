using System;
using System.Collections.Generic;

namespace Te1000Daemon
{
    // Caches resolved tree-item lookups and bounded-walk results keyed by
    // '^'-path. Single-threaded use (only touched on the STA worker thread), so
    // no locking. Mutating actions invalidate the affected subtree.
    //
    // NOTE: COM RCWs can go stale across config changes; we cache live RCW
    // references but every consumer that uses a cached item must tolerate a COM
    // failure and re-resolve (handlers go through ComHelpers.GetTreeItem which
    // re-LookupTreeItems on a miss). The cache is a hot-path optimization for the
    // O(tree-size) walk that previously dominated find/search latency.
    //
    // TEXT CACHE: in addition to the item/walk caches above, this also caches the
    // decl/impl SOURCE TEXT of each code object (keyed by '^'-tree-path). The
    // per-object COM reads (DeclarationText / ImplementationText / Language) are
    // what made plc_pou_search take ~16 s on a full project; serving them from
    // this store drops a warm repeat to sub-100 ms. Invalidation: every mutator
    // already calls Invalidate(path)/Clear(), and both now also drop text entries,
    // so the text cache is automatically correct across edits made THROUGH this
    // daemon. Edits made in the IDE (open editors, user saves) are covered by the
    // EditWatcher (.Saved on-demand check) and the FileSystemWatcher backstop,
    // which call InvalidateFileLeaf(...) on save.
    //
    // The text store and its leaf index are touched both on the STA worker thread
    // (Search read/populate) AND on the FileSystemWatcher's own thread
    // (invalidation only). All text-store members therefore lock _textGate. The
    // item/walk caches remain STA-only and unlocked, as before.
    public sealed class TreeCache
    {
        private readonly Dictionary<string, dynamic> _items = new Dictionary<string, dynamic>(StringComparer.Ordinal);

        // Cached bounded-walk results: path -> (depth -> JArr of node summaries).
        private readonly Dictionary<string, Dictionary<int, Json.JArr>> _walks =
            new Dictionary<string, Dictionary<int, Json.JArr>>(StringComparer.Ordinal);

        // ---- text cache ------------------------------------------------------
        public sealed class TextEntry
        {
            public bool HasDecl;
            public string Decl;
            public bool HasImpl;
            public string Impl;
            public object Language;   // boxed int (impl language) or null
        }

        private readonly object _textGate = new object();
        private readonly Dictionary<string, TextEntry> _texts =
            new Dictionary<string, TextEntry>(StringComparer.Ordinal);

        // ---- enumeration cache ----------------------------------------------
        // Maps a search scope's startPath -> the ordered list of descendant
        // '^'-tree-paths that CollectCodeObjects would produce (the flat code
        // object list). This is the MAJORITY of warm-search COM cost: the tree
        // walk (ChildCount + Child(i) + name-get per node, ~2,900 round-trips on
        // a full project). Serving it from here makes a warm full-project search
        // do ZERO COM tree-walk.
        //
        // Reflects tree MEMBERSHIP only — invalidated ONLY on structural changes
        // (create/delete/rename/move/import) via InvalidateEnum(), NOT on content
        // edits (set_decl/set_impl/replace/...). The generic Invalidate(path) used
        // by content mutators deliberately does NOT touch this. Coarse: any
        // structural change drops the WHOLE enum cache (structural ops are rare).
        //
        // Touched on the STA worker thread (Search read/populate) AND on the
        // FileSystemWatcher thread (Created/Deleted/Renamed -> InvalidateEnum), so
        // all members lock _enumGate.
        private readonly object _enumGate = new object();
        private readonly Dictionary<string, List<string>> _enum =
            new Dictionary<string, List<string>>(StringComparer.Ordinal);

        // leaf-name (lower) -> set of '^'-tree-paths whose trailing segment is that
        // name. Used to map an on-disk file (X.TcPOU/.TcDUT/.TcGVL) or an open-doc
        // moniker (<file>@<objName>) back to the tree object it backs, without any
        // COM file-path member (tree items do not expose their backing file).
        private readonly Dictionary<string, HashSet<string>> _leafIndex =
            new Dictionary<string, HashSet<string>>(StringComparer.OrdinalIgnoreCase);

        public bool Enabled = true;

        public dynamic LookupItem(dynamic sysManager, string path)
        {
            if (!Enabled) return ComHelpers.GetTreeItem(sysManager, path);
            dynamic item;
            if (_items.TryGetValue(path, out item) && item != null)
            {
                // Validate cheaply; on COM failure, drop and re-resolve.
                try { var _ = item.Name; return item; }
                catch { _items.Remove(path); }
            }
            item = ComHelpers.GetTreeItem(sysManager, path);
            _items[path] = item;
            return item;
        }

        public Json.JArr GetWalk(string path, int depth)
        {
            if (!Enabled) return null;
            Dictionary<int, Json.JArr> byDepth;
            if (_walks.TryGetValue(path, out byDepth))
            {
                Json.JArr arr;
                if (byDepth.TryGetValue(depth, out arr)) return arr;
            }
            return null;
        }

        public void PutWalk(string path, int depth, Json.JArr result)
        {
            if (!Enabled) return;
            Dictionary<int, Json.JArr> byDepth;
            if (!_walks.TryGetValue(path, out byDepth))
            {
                byDepth = new Dictionary<int, Json.JArr>();
                _walks[path] = byDepth;
            }
            byDepth[depth] = result;
        }

        // ---- enumeration cache accessors ------------------------------------

        // Returns the cached descendant path list for `startPath`, or null on a
        // miss. The returned list is the live stored reference — callers MUST NOT
        // mutate it (they only iterate). Thread-safe.
        public List<string> GetEnum(string startPath)
        {
            if (!Enabled || string.IsNullOrEmpty(startPath)) return null;
            lock (_enumGate)
            {
                List<string> list;
                return _enum.TryGetValue(startPath, out list) ? list : null;
            }
        }

        public void PutEnum(string startPath, List<string> paths)
        {
            if (!Enabled || string.IsNullOrEmpty(startPath) || paths == null) return;
            lock (_enumGate)
            {
                _enum[startPath] = paths;
            }
        }

        // Drop the ENTIRE enumeration cache. Called only by STRUCTURAL mutators
        // (create/delete/rename/move/import) and the FileSystemWatcher on
        // Created/Deleted/Renamed. Deliberately coarse (membership rarely changes)
        // and deliberately SEPARATE from Invalidate(path) so content edits — which
        // keep membership identical — do NOT force a re-walk. Thread-safe; never
        // touches COM.
        public void InvalidateEnum()
        {
            lock (_enumGate)
            {
                _enum.Clear();
            }
        }

        // ---- text cache accessors -------------------------------------------

        public TextEntry GetText(string path)
        {
            if (!Enabled || string.IsNullOrEmpty(path)) return null;
            lock (_textGate)
            {
                TextEntry e;
                return _texts.TryGetValue(path, out e) ? e : null;
            }
        }

        public void PutText(string path, TextEntry entry)
        {
            if (!Enabled || string.IsNullOrEmpty(path) || entry == null) return;
            lock (_textGate)
            {
                _texts[path] = entry;
                IndexLeafLocked(path);
            }
        }

        // Resolve every cached tree-path whose trailing segment equals `leaf`
        // (case-insensitive). Used by the FileSystemWatcher and EditWatcher to map
        // a file/object name to the tree object(s) it backs.
        public List<string> PathsForLeaf(string leaf)
        {
            var outList = new List<string>();
            if (string.IsNullOrEmpty(leaf)) return outList;
            lock (_textGate)
            {
                HashSet<string> set;
                if (_leafIndex.TryGetValue(leaf, out set))
                {
                    foreach (string p in set) outList.Add(p);
                }
            }
            return outList;
        }

        // Drop the text cache for every object backed by a file/object whose leaf
        // name is `leaf` — i.e. that object's subtree (a .TcPOU like MAIN backs
        // many @-action children, all sharing the MAIN^... prefix). Thread-safe;
        // called from the FileSystemWatcher thread (NEVER touches COM).
        public void InvalidateFileLeaf(string leaf)
        {
            if (string.IsNullOrEmpty(leaf)) return;
            List<string> roots = PathsForLeaf(leaf);
            foreach (string root in roots) InvalidateText(root);
        }

        // Drop text entries at/under `path` (subtree). Thread-safe.
        public void InvalidateText(string path)
        {
            if (string.IsNullOrEmpty(path)) { ClearText(); return; }
            string prefix = path + "^";
            lock (_textGate)
            {
                var kill = new List<string>();
                foreach (var k in _texts.Keys)
                    if (k == path || k.StartsWith(prefix, StringComparison.Ordinal)) kill.Add(k);
                foreach (var k in kill) RemoveTextLocked(k);
            }
        }

        private void IndexLeafLocked(string path)
        {
            string leaf = LeafOf(path);
            if (leaf == null) return;
            HashSet<string> set;
            if (!_leafIndex.TryGetValue(leaf, out set))
            {
                set = new HashSet<string>(StringComparer.Ordinal);
                _leafIndex[leaf] = set;
            }
            set.Add(path);
        }

        private void RemoveTextLocked(string path)
        {
            _texts.Remove(path);
            string leaf = LeafOf(path);
            if (leaf == null) return;
            HashSet<string> set;
            if (_leafIndex.TryGetValue(leaf, out set))
            {
                set.Remove(path);
                if (set.Count == 0) _leafIndex.Remove(leaf);
            }
        }

        private static string LeafOf(string path)
        {
            if (string.IsNullOrEmpty(path)) return null;
            int idx = path.LastIndexOf('^');
            return idx < 0 ? path : path.Substring(idx + 1);
        }

        private void ClearText()
        {
            lock (_textGate)
            {
                _texts.Clear();
                _leafIndex.Clear();
            }
        }

        // Invalidate everything at/under the given path (subtree). A null/empty
        // path clears the entire cache (used after broad mutations).
        public void Invalidate(string path)
        {
            if (string.IsNullOrEmpty(path)) { Clear(); return; }
            string prefix = path + "^";
            RemoveMatching(_items, path, prefix);

            var killWalks = new List<string>();
            foreach (var k in _walks.Keys)
                if (k == path || k.StartsWith(prefix, StringComparison.Ordinal) || path.StartsWith(k + "^", StringComparison.Ordinal))
                    killWalks.Add(k);
            foreach (var k in killWalks) _walks.Remove(k);

            // Text cache uses pure subtree semantics (at/under path); a parent
            // walk being dropped does not require dropping the child's text.
            InvalidateText(path);
        }

        private static void RemoveMatching(Dictionary<string, dynamic> map, string path, string prefix)
        {
            var kill = new List<string>();
            foreach (var k in map.Keys)
                if (k == path || k.StartsWith(prefix, StringComparison.Ordinal)) kill.Add(k);
            foreach (var k in kill) map.Remove(k);
        }

        public void Clear()
        {
            _items.Clear();
            _walks.Clear();
            ClearText();
            InvalidateEnum();
        }
    }
}
