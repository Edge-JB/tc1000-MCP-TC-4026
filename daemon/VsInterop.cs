using System;
using System.IO;
using System.Reflection;
using System.Threading;

namespace Te1000Daemon
{
    // Runtime loader for the EnvDTE PIAs used by the typed DTE paths (see
    // XaeActions.ReadErrorList). The daemon exe lives under C:\ProgramData and the
    // PIAs (EnvDTE / EnvDTE80 / Microsoft.VisualStudio.Interop) are neither copied
    // local nor in a GAC view the runtime probes, so we resolve them from the
    // TcXaeShell PublicAssemblies dir on demand — mirroring the PS bridge's
    // Get-XaePublicAssembliesPath (te1000-bridge.ps1 L64-76).
    public static class VsInterop
    {
        private static int _installed;

        // Same candidate roots as build.ps1 / Get-XaePublicAssembliesPath: prefer
        // the 64-bit install, fall back to x86.
        private static readonly string[] Roots =
        {
            @"C:\Program Files\Beckhoff\TcXaeShell\Common7\IDE\PublicAssemblies",
            @"C:\Program Files (x86)\Beckhoff\TcXaeShell\Common7\IDE\PublicAssemblies",
        };

        private static readonly string[] Wanted =
        {
            "EnvDTE", "EnvDTE80", "Microsoft.VisualStudio.Interop",
        };

        // Idempotent; safe to call from any thread before the first typed-DTE use.
        public static void EnsureResolver()
        {
            if (Interlocked.Exchange(ref _installed, 1) == 1) return;
            AppDomain.CurrentDomain.AssemblyResolve += Resolve;
        }

        private static Assembly Resolve(object sender, ResolveEventArgs e)
        {
            string name;
            try { name = new AssemblyName(e.Name).Name; }
            catch { return null; }

            bool wanted = false;
            for (int i = 0; i < Wanted.Length; i++)
                if (string.Equals(name, Wanted[i], StringComparison.OrdinalIgnoreCase)) { wanted = true; break; }
            if (!wanted) return null;

            foreach (var root in Roots)
            {
                try
                {
                    var path = Path.Combine(root, name + ".dll");
                    if (File.Exists(path)) return Assembly.LoadFrom(path);
                }
                catch (Exception ex) { Log.Error("VsInterop.Resolve failed for " + name + " in " + root, ex); }
            }
            return null;
        }
    }
}
