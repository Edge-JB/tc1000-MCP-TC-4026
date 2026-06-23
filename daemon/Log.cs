using System;
using System.IO;
using System.Text;

namespace Te1000Daemon
{
    // Lightweight diagnostic log to a file under %TEMP% (or TE1000_DAEMON_LOG).
    // Never throws; never writes to stdout/stderr (the pipe is the only channel).
    public static class Log
    {
        private static readonly object _gate = new object();
        private static string _path;
        private static bool _enabled;

        public static void Init(string pipeName)
        {
            try
            {
                var custom = Environment.GetEnvironmentVariable("TE1000_DAEMON_LOG");
                if (!string.IsNullOrEmpty(custom))
                {
                    _path = custom;
                    _enabled = true;
                }
                else
                {
                    // Off by default unless TE1000_DAEMON_DEBUG is set, to avoid disk churn.
                    if (Environment.GetEnvironmentVariable("TE1000_DAEMON_DEBUG") == "1")
                    {
                        _path = Path.Combine(Path.GetTempPath(), "te1000-daemon-" + Sanitize(pipeName) + ".log");
                        _enabled = true;
                    }
                }
            }
            catch { _enabled = false; }
        }

        private static string Sanitize(string s)
        {
            if (string.IsNullOrEmpty(s)) return "default";
            var sb = new StringBuilder();
            foreach (char c in s) sb.Append(char.IsLetterOrDigit(c) ? c : '_');
            return sb.ToString();
        }

        public static void Write(string msg)
        {
            if (!_enabled) return;
            try
            {
                lock (_gate)
                {
                    File.AppendAllText(_path, DateTime.Now.ToString("HH:mm:ss.fff") + " " + msg + Environment.NewLine, Encoding.UTF8);
                }
            }
            catch { }
        }

        public static void Error(string msg, Exception ex)
        {
            Write(msg + " :: " + (ex == null ? "(null)" : ex.GetType().Name + ": " + ex.Message));
        }
    }
}
