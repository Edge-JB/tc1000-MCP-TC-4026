using System;
using System.IO;
using System.Threading;

namespace Te1000Daemon
{
    // Persistent native COM bridge for the te1000 MCP.
    //
    // Usage: Te1000Daemon.exe [--pipe <name>] [--no-watch] [--no-autodismiss]
    //                         [--grace-ms N] [--allowlist <path>]
    //
    // The main thread itself is STA (so any incidental COM on it is legal), but
    // ALL DTE/sysmanager calls run on the dedicated ComWorker STA thread.
    internal static class Program
    {
        [STAThread]
        private static int Main(string[] args)
        {
            string pipeName = "te1000-mcp";
            bool watch = true;
            bool autoDismiss = true;
            int graceMs = 4000;        // matches index.js TE1000_DIALOG_GRACE_MS default
            string allowlist = DefaultAllowlistPath();

            for (int i = 0; i < args.Length; i++)
            {
                switch (args[i])
                {
                    case "--pipe": pipeName = Next(args, ref i); break;
                    case "--no-watch": watch = false; break;
                    case "--no-autodismiss": autoDismiss = false; break;
                    case "--grace-ms": int.TryParse(Next(args, ref i), out graceMs); break;
                    case "--allowlist": allowlist = Next(args, ref i); break;
                }
            }

            Log.Init(pipeName);
            Log.Write("Te1000Daemon starting; pipe=" + pipeName + " watch=" + watch + " autoDismiss=" + autoDismiss + " graceMs=" + graceMs);

            // Single-instance guard keyed to the pipe name.
            bool createdNew;
            string mutexName = "Global\\Te1000Daemon_" + SanitizeMutex(pipeName);
            using (var mutex = new Mutex(true, mutexName, out createdNew))
            {
                if (!createdNew)
                {
                    Log.Write("Another daemon instance owns pipe '" + pipeName + "'; exiting.");
                    return 0;
                }

                DialogWatcher watcher = null;
                if (watch)
                {
                    watcher = new DialogWatcher(allowlist, autoDismiss);
                    watcher.Start();
                }

                using (var worker = new ComWorker(watcher, defaultTimeoutMs: 0, blockGraceMs: watch ? graceMs : 0))
                {
                    var dispatcher = new Dispatcher(worker);
                    Log.Write("Dispatcher ready; " + dispatcher.ActionCount + " actions registered.");
                    var server = new PipeServer(pipeName, dispatcher);

                    // Run the pipe server on the main thread (blocks until killed).
                    server.Run();

                    if (watcher != null) watcher.Stop();
                }
            }
            return 0;
        }

        private static string Next(string[] args, ref int i)
        {
            if (i + 1 >= args.Length) return "";
            return args[++i];
        }

        private static string SanitizeMutex(string s)
        {
            var sb = new System.Text.StringBuilder();
            foreach (char c in s) sb.Append(char.IsLetterOrDigit(c) ? c : '_');
            return sb.ToString();
        }

        // The allowlist ships alongside the PS bridge: <repo>/powershell/dialog-allowlist.json.
        // The exe lives at <repo>/daemon/bin/Release; walk up to find it.
        private static string DefaultAllowlistPath()
        {
            try
            {
                string dir = AppDomain.CurrentDomain.BaseDirectory;
                for (int up = 0; up < 6 && dir != null; up++)
                {
                    string candidate = Path.Combine(dir, "powershell", "dialog-allowlist.json");
                    if (File.Exists(candidate)) return candidate;
                    var parent = Directory.GetParent(dir);
                    dir = parent != null ? parent.FullName : null;
                }
            }
            catch { }
            return "";
        }
    }
}
