using System;
using System.Collections.Generic;
using System.IO;

namespace Te1000Daemon
{
    // Tracks which PLC code objects are open in the IDE and whether each is
    // dirty, so the search text-cache never serves stale source for an object the
    // user is actively editing. Also owns a FileSystemWatcher over the loaded
    // project directory as the save-coverage backstop (edited-then-saved → clean
    // again but content changed, which .Saved alone misses).
    //
    // THREADING (critical):
    //  - Every member that touches the DTE / a COM RCW (RefreshOpenDocs, IsDirty,
    //    LookupTreeItem) runs INLINE on the STA worker thread. The only caller is
    //    plc_pou_search, which is already executing on that thread, so these are
    //    plain method calls — NOT job re-enqueues (re-enqueuing onto the single
    //    STA worker while it is busy with the search would deadlock).
    //  - The FileSystemWatcher fires on its OWN thread-pool thread. Its handler
    //    NEVER touches COM; it only computes a leaf name from the changed file and
    //    calls TreeCache.InvalidateFileLeaf (thread-safe, COM-free).
    //
    // The Document.Kind GUID for the TwinCAT PLC editor; monikers there look like
    // "<...\\MAIN.TcPOU>@<a0449_...>". We also accept any moniker that carries the
    // '@'-shape over a .TcPOU/.TcDUT/.TcGVL file, to be robust to Kind drift.
    public sealed class EditWatcher : IDisposable
    {
        private const string PlcEditorKind = "{CFF47BB1-5559-4BDE-A2AF-06B30BC64F6C}";

        private readonly Func<ComSession> _sessionProvider;
        private readonly TreeCache _cache;

        private ComSession _session { get { return _sessionProvider(); } }

        // Open-doc snapshot: tree-path -> Document RCW (for the on-demand .Saved
        // read). Rebuilt at most once per search (TTL-gated). STA-thread only.
        private Dictionary<string, dynamic> _openDocs =
            new Dictionary<string, dynamic>(StringComparer.Ordinal);
        private int _lastRefreshTick = -100000;
        private const int RefreshTtlMs = 1000;

        private FileSystemWatcher _fsw;
        private string _watchedDir;

        public EditWatcher(Func<ComSession> sessionProvider, TreeCache cache)
        {
            _sessionProvider = sessionProvider;
            _cache = cache;
        }

        // ---- open-document tracking (STA-thread only) -----------------------

        // Refresh the open-doc set if the TTL elapsed. Cheap no-op otherwise.
        // MUST be called on the STA worker thread (reads DTE.Documents).
        public void RefreshOpenDocsIfStale()
        {
            int now = Environment.TickCount;
            if (unchecked(now - _lastRefreshTick) < RefreshTtlMs && _lastRefreshTick != -100000)
                return;
            RefreshOpenDocs();
        }

        public void RefreshOpenDocs()
        {
            _lastRefreshTick = Environment.TickCount;
            var map = new Dictionary<string, dynamic>(StringComparer.Ordinal);
            dynamic sm = null;
            try { sm = _session.GetSysManager(); }
            catch { sm = null; }

            dynamic docs = null;
            try { docs = _dteDocuments(); }
            catch { docs = null; }
            if (docs == null) { _openDocs = map; return; }

            int count = 0;
            try { count = (int)docs.Count; } catch { count = 0; }
            for (int i = 1; i <= count; i++)
            {
                dynamic doc = null;
                try { doc = docs.Item(i); } catch { doc = null; }
                if (doc == null) continue;

                string moniker = null;
                try { moniker = (string)doc.FullName; } catch { moniker = null; }
                if (string.IsNullOrEmpty(moniker)) continue;

                if (!IsPlcEditorDoc(doc, moniker)) continue;

                string treePath = ResolveMonikerToTreePath(sm, moniker);
                if (treePath == null) continue;
                // Last writer wins; a tree object is backed by one open editor.
                map[treePath] = doc;
            }
            _openDocs = map;
        }

        private dynamic _dteDocuments()
        {
            dynamic dte = _session.GetDte(null, null, true);
            return dte != null ? dte.Documents : null;
        }

        private static bool IsPlcEditorDoc(dynamic doc, string moniker)
        {
            // Primary signal: the TwinCAT PLC editor Kind GUID.
            try
            {
                string kind = (string)doc.Kind;
                if (!string.IsNullOrEmpty(kind) &&
                    string.Equals(kind, PlcEditorKind, StringComparison.OrdinalIgnoreCase))
                    return true;
            }
            catch { }

            // Fallback: the @-moniker shape over a PLC source file. Covers Kind
            // drift across shell versions.
            return LooksLikePlcSourceMoniker(moniker);
        }

        private static bool LooksLikePlcSourceMoniker(string moniker)
        {
            if (string.IsNullOrEmpty(moniker)) return false;
            string filePart = moniker;
            int at = moniker.IndexOf('@');
            if (at >= 0) filePart = moniker.Substring(0, at);
            return EndsWithPlcExt(filePart);
        }

        private static bool EndsWithPlcExt(string p)
        {
            if (string.IsNullOrEmpty(p)) return false;
            return p.EndsWith(".TcPOU", StringComparison.OrdinalIgnoreCase)
                || p.EndsWith(".TcDUT", StringComparison.OrdinalIgnoreCase)
                || p.EndsWith(".TcGVL", StringComparison.OrdinalIgnoreCase);
        }

        // Map an open-editor moniker "<file>@<objName>" (or "<file>" for the file
        // itself) to its '^'-tree-path. The object NAME drives the lookup:
        //   - with '@': the in-file object name (e.g. an action 'a0449_...')
        //   - without '@': the file basename sans extension (the POU/DUT/GVL name)
        // We then find a cached tree-path whose trailing segment equals that name
        // (covers DUT/GVL/folder-nested POUs uniformly — names are unique in the
        // IEC namespace) and VALIDATE it with LookupTreeItem. This deliberately
        // does NOT assume any 'POUs^MAIN'-style prefix.
        private string ResolveMonikerToTreePath(dynamic sm, string moniker)
        {
            if (string.IsNullOrEmpty(moniker)) return null;
            string objName = ObjectNameFromMoniker(moniker);
            if (string.IsNullOrEmpty(objName)) return null;

            List<string> candidates = _cache.PathsForLeaf(objName);
            if (candidates.Count == 0) return null;

            // Validate against the live tree; prefer a path that resolves.
            if (sm != null)
            {
                foreach (string cand in candidates)
                {
                    if (ComHelpers.TryGetTreeItem(sm, cand) != null) return cand;
                }
            }
            // Unvalidated but indexed (corpus was warm): still usable as a key.
            return candidates.Count == 1 ? candidates[0] : null;
        }

        private static string ObjectNameFromMoniker(string moniker)
        {
            int at = moniker.IndexOf('@');
            if (at >= 0)
            {
                string name = moniker.Substring(at + 1);
                return string.IsNullOrWhiteSpace(name) ? null : name.Trim();
            }
            // No '@': the file itself — object name is the basename sans extension.
            return FileLeaf(moniker);
        }

        // Basename without the PLC extension, e.g. "...\\GvSys.TcGVL" -> "GvSys".
        public static string FileLeaf(string filePath)
        {
            if (string.IsNullOrEmpty(filePath)) return null;
            string name;
            try { name = Path.GetFileName(filePath); } catch { name = filePath; }
            if (string.IsNullOrEmpty(name)) return null;
            int dot = name.LastIndexOf('.');
            if (dot > 0) name = name.Substring(0, dot);
            return string.IsNullOrWhiteSpace(name) ? null : name;
        }

        // ---- dirty check (STA-thread only) ----------------------------------

        // True if `treePath` maps to an open editor that is dirty, OR if the
        // .Saved read is rejected/throws (RPC_E_CALL_REJECTED while the IDE STA is
        // busy → fail safe to DIRTY so we re-pull live). Closed objects → false.
        public bool IsDirty(string treePath)
        {
            if (string.IsNullOrEmpty(treePath)) return false;
            dynamic doc;
            if (!_openDocs.TryGetValue(treePath, out doc) || doc == null) return false;

            for (int attempt = 1; attempt <= 3; attempt++)
            {
                try
                {
                    bool saved = (bool)doc.Saved;
                    return !saved;   // dirty == not saved
                }
                catch (Exception ex)
                {
                    if (ComHelpers.IsRetryableComError(ex) && attempt < 3)
                    {
                        try { System.Threading.Thread.Sleep(50); } catch { }
                        continue;
                    }
                    // Busy/rejected or any other COM failure → fail safe to dirty.
                    return true;
                }
            }
            return true;
        }

        public bool IsOpen(string treePath)
        {
            if (string.IsNullOrEmpty(treePath)) return false;
            dynamic doc;
            return _openDocs.TryGetValue(treePath, out doc) && doc != null;
        }

        // ---- FileSystemWatcher backstop (own thread; COM-free) --------------

        // Re-init the watcher for the currently-loaded solution/project. Safe to
        // call repeatedly (e.g. on open_solution). STA-thread caller (reads DTE).
        public void ReinitFileWatcher()
        {
            string dir = null;
            try
            {
                dynamic dte = _session.GetDte(null, null, true);
                string sln = null;
                try { sln = dte != null && dte.Solution != null ? (string)dte.Solution.FullName : null; }
                catch { sln = null; }
                if (!string.IsNullOrEmpty(sln))
                {
                    try { dir = Path.GetDirectoryName(sln); } catch { dir = null; }
                }
            }
            catch { dir = null; }

            StartFileWatcher(dir);
        }

        private void StartFileWatcher(string dir)
        {
            if (string.IsNullOrEmpty(dir) || !Directory.Exists(dir))
            {
                DisposeFileWatcher();
                return;
            }
            if (_fsw != null && string.Equals(_watchedDir, dir, StringComparison.OrdinalIgnoreCase))
                return; // already watching this dir

            DisposeFileWatcher();
            try
            {
                var fsw = new FileSystemWatcher(dir);
                fsw.IncludeSubdirectories = true;
                fsw.NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.FileName | NotifyFilters.Size;
                // FileSystemWatcher takes a single filter; subscribe to all and
                // gate on the PLC extensions in the handler.
                fsw.Changed += OnFileChanged;
                fsw.Created += OnFileCreatedOrDeleted;
                fsw.Deleted += OnFileCreatedOrDeleted;
                fsw.Renamed += OnFileRenamed;
                fsw.EnableRaisingEvents = true;
                _fsw = fsw;
                _watchedDir = dir;
                Log.Write("EditWatcher: FileSystemWatcher armed on " + dir);
            }
            catch (Exception ex)
            {
                Log.Error("EditWatcher.StartFileWatcher", ex);
                _fsw = null;
                _watchedDir = null;
            }
        }

        // Fires on a thread-pool thread. MUST NOT touch COM. Only computes the
        // changed file's leaf name and invalidates the TEXT cache for its subtree.
        // A plain Changed event is a content save → text-only (membership is
        // unchanged), so it does NOT invalidate the enumeration cache.
        private void OnFileChanged(object sender, FileSystemEventArgs e)
        {
            try { InvalidateForFile(e.FullPath); } catch { }
        }

        // Created/Deleted change tree MEMBERSHIP → invalidate BOTH the text cache
        // (for the affected leaf) and the whole enumeration cache so the next
        // search re-walks. Thread-safe and COM-free.
        private void OnFileCreatedOrDeleted(object sender, FileSystemEventArgs e)
        {
            try { InvalidateForFile(e.FullPath); } catch { }
            try { _cache.InvalidateEnum(); } catch { }
        }

        // Rename changes both the path and tree membership → text + enum.
        private void OnFileRenamed(object sender, RenamedEventArgs e)
        {
            try { InvalidateForFile(e.FullPath); } catch { }
            try { InvalidateForFile(e.OldFullPath); } catch { }
            try { _cache.InvalidateEnum(); } catch { }
        }

        private void InvalidateForFile(string fullPath)
        {
            if (string.IsNullOrEmpty(fullPath) || !EndsWithPlcExt(fullPath)) return;
            string leaf = FileLeaf(fullPath);
            if (leaf == null) return;
            _cache.InvalidateFileLeaf(leaf);
        }

        private void DisposeFileWatcher()
        {
            FileSystemWatcher f = _fsw;
            _fsw = null;
            _watchedDir = null;
            if (f != null)
            {
                try { f.EnableRaisingEvents = false; } catch { }
                try { f.Changed -= OnFileChanged; } catch { }
                try { f.Created -= OnFileCreatedOrDeleted; } catch { }
                try { f.Deleted -= OnFileCreatedOrDeleted; } catch { }
                try { f.Renamed -= OnFileRenamed; } catch { }
                try { f.Dispose(); } catch { }
            }
        }

        public void Dispose()
        {
            DisposeFileWatcher();
            _openDocs = new Dictionary<string, dynamic>(StringComparer.Ordinal);
        }
    }
}
