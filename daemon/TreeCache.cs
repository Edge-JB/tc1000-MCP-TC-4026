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
    public sealed class TreeCache
    {
        private readonly Dictionary<string, dynamic> _items = new Dictionary<string, dynamic>(StringComparer.Ordinal);

        // Cached bounded-walk results: path -> (depth -> JArr of node summaries).
        private readonly Dictionary<string, Dictionary<int, Json.JArr>> _walks =
            new Dictionary<string, Dictionary<int, Json.JArr>>(StringComparer.Ordinal);

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
        }
    }
}
