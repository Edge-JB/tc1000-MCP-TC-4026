using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

namespace Te1000Daemon
{
    // Acquires and CACHES the DTE + ITcSysManager once, with a cheap health-check
    // and transparent reconnect. Ports Get-PreferredDteFromRot (bridge L387-419),
    // Get-Dte (L533-579), and Get-SysManager (L623-676). All members are called
    // on the owning STA thread (ComWorker.Pump).
    public sealed class ComSession
    {
        private dynamic _dte;
        private dynamic _sysManager;
        private string _progId;
        private string _mode;
        private bool _stale;

        public void MarkStale() { _stale = true; _dte = null; _sysManager = null; }

        // Return a live, cached DTE for (progId, mode); reconnect if stale/dead.
        public dynamic GetDte(string progId, string mode, bool visible = true)
        {
            if (string.IsNullOrWhiteSpace(progId)) progId = "TcXaeShell.DTE.17.0";
            if (string.IsNullOrWhiteSpace(mode)) mode = "active";

            if (_dte != null && !_stale && _progId == progId)
            {
                if (IsDteAlive(_dte)) return _dte;
                _dte = null; _sysManager = null;
            }

            _dte = AcquireDte(progId, mode, visible);
            _progId = progId;
            _mode = mode;
            _sysManager = null;
            _stale = false;
            return _dte;
        }

        private static bool IsDteAlive(dynamic dte)
        {
            try { var _ = dte.Name; return true; }   // cheap property read
            catch { return false; }
        }

        // Get-Dte (L533-579): modes active / create / activeOrCreate.
        private dynamic AcquireDte(string progId, string mode, bool visible)
        {
            switch (mode)
            {
                case "active":
                {
                    dynamic d = GetPreferredDteFromRot(progId);
                    if (d != null) return d;
                    return Marshal.GetActiveObject(progId);
                }
                case "create":
                    return CreateDte(progId, visible);
                case "activeOrCreate":
                    try
                    {
                        dynamic d = GetPreferredDteFromRot(progId);
                        if (d != null) return d;
                        return Marshal.GetActiveObject(progId);
                    }
                    catch
                    {
                        return CreateDte(progId, visible);
                    }
                default:
                    throw new BridgeException("Unsupported DTE mode: " + mode);
            }
        }

        private dynamic CreateDte(string progId, bool visible)
        {
            Type t = Type.GetTypeFromProgID(progId);
            if (t == null) throw new BridgeException("ProgID not registered: " + progId);
            dynamic dte = Activator.CreateInstance(t);
            try { dte.SuppressUI = true; } catch { }
            try { dte.MainWindow.Visible = visible; } catch { }
            return dte;
        }

        // Get-PreferredDteFromRot (L387-419) + DteRotProbe (L286-371): enumerate
        // the Running Object Table for monikers matching the progId, prefer one
        // with an open solution (or TE1000_MCP_SOLUTION_PATH).
        private dynamic GetPreferredDteFromRot(string progId)
        {
            var entries = ListRunningDte(progId);
            if (entries.Count == 0) return null;

            string preferred = Environment.GetEnvironmentVariable("TE1000_MCP_SOLUTION_PATH");
            if (!string.IsNullOrWhiteSpace(preferred))
            {
                foreach (var e in entries)
                    if (!string.IsNullOrWhiteSpace(e.Solution) && string.Equals(e.Solution, preferred, StringComparison.OrdinalIgnoreCase))
                        return e.Dte;
            }
            foreach (var e in entries)
                if (!string.IsNullOrWhiteSpace(e.Solution)) return e.Dte;
            return entries[0].Dte;
        }

        private sealed class RotEntry { public string DisplayName; public string Solution; public dynamic Dte; }

        [DllImport("ole32.dll")] private static extern int GetRunningObjectTable(int reserved, out IRunningObjectTable prot);
        [DllImport("ole32.dll")] private static extern int CreateBindCtx(int reserved, out IBindCtx ppbc);

        private List<RotEntry> ListRunningDte(string progId)
        {
            var result = new List<RotEntry>();
            IRunningObjectTable rot;
            if (GetRunningObjectTable(0, out rot) != 0 || rot == null) return result;
            IBindCtx bindCtx;
            if (CreateBindCtx(0, out bindCtx) != 0 || bindCtx == null) return result;
            IEnumMoniker enumMoniker;
            rot.EnumRunning(out enumMoniker);
            if (enumMoniker == null) return result;

            var monikers = new IMoniker[1];
            while (enumMoniker.Next(1, monikers, IntPtr.Zero) == 0)
            {
                string displayName = "";
                try { monikers[0].GetDisplayName(bindCtx, null, out displayName); }
                catch { displayName = ""; }

                if (string.IsNullOrWhiteSpace(displayName) ||
                    displayName.IndexOf(progId, StringComparison.OrdinalIgnoreCase) < 0)
                    continue;

                try
                {
                    object raw;
                    rot.GetObject(monikers[0], out raw);
                    if (raw == null) continue;
                    dynamic dte = raw;
                    string solution = "";
                    try { solution = dte.Solution != null ? (string)dte.Solution.FullName : ""; }
                    catch { solution = ""; }
                    result.Add(new RotEntry { DisplayName = displayName, Solution = solution, Dte = dte });
                }
                catch { }
            }
            return result;
        }

        // Get-SysManager (L623-676): prefer the loaded .tsproj project Object
        // (stays bound to the live config), else DTE.GetObject('TcSysManager').
        // Cached; retries transient RPC busy.
        public dynamic GetSysManager()
        {
            if (_sysManager != null && !_stale)
            {
                if (IsSysManagerAlive(_sysManager)) return _sysManager;
                _sysManager = null;
            }
            if (_dte == null) throw new BridgeException("DTE not acquired");

            for (int attempt = 1; attempt <= 40; attempt++)
            {
                try
                {
                    dynamic solution = _dte.Solution;
                    if (solution != null && solution.Projects != null)
                    {
                        int count = (int)solution.Projects.Count;
                        for (int i = 1; i <= count; i++)
                        {
                            dynamic project = solution.Projects.Item(i);
                            if (project == null) continue;
                            string fullName = null;
                            try { fullName = (string)project.FullName; } catch { }
                            if (string.IsNullOrWhiteSpace(fullName) ||
                                !fullName.EndsWith(".tsproj", StringComparison.OrdinalIgnoreCase))
                                continue;
                            dynamic projectObject = null;
                            try { projectObject = project.Object; } catch { }
                            if (projectObject == null) continue;
                            // Probe GetTargetNetId() — proves it's the live config surface.
                            try
                            {
                                var probe = projectObject.GetTargetNetId();
                                if (probe != null) { _sysManager = projectObject; return _sysManager; }
                            }
                            catch { }
                        }
                    }
                    dynamic sm = _dte.GetObject("TcSysManager");
                    if (sm == null) throw new BridgeException("TcSysManager is null");
                    _sysManager = sm;
                    return _sysManager;
                }
                catch (BridgeException) { if (attempt >= 40) throw; System.Threading.Thread.Sleep(500); }
                catch (Exception ex)
                {
                    if (ComHelpers.IsRetryableComError(ex) && attempt < 40)
                    {
                        System.Threading.Thread.Sleep(500);
                        continue;
                    }
                    throw;
                }
            }
            throw new BridgeException("TcSysManager not available");
        }

        private static bool IsSysManagerAlive(dynamic sm)
        {
            try { var _ = sm.GetTargetNetId(); return true; }
            catch
            {
                // Some sysmanagers are the GetObject wrapper without GetTargetNetId;
                // fall back to a cheap call that always exists.
                try { var __ = sm.LookupTreeItem("TIID"); return true; } catch { return false; }
            }
        }

        public void Dispose()
        {
            try { Te1000MessageFilter.Revoke(); } catch { }
            _dte = null; _sysManager = null;
        }
    }
}
