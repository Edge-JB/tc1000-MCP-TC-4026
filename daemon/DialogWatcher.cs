using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace Te1000Daemon
{
    // ---- DlgWin / DlgWatch: lifted VERBATIM from dialog-watch.ps1 L46-141 ----
    public sealed class DlgWin
    {
        public long Hwnd;
        public string Title = "";
        public string Text = "";
        public string Class = "";
        public List<string> Buttons = new List<string>();
    }

    public static class DlgWatch
    {
        delegate bool EnumProc(IntPtr h, IntPtr l);

        [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
        [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr p, EnumProc cb, IntPtr l);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
        [DllImport("user32.dll")] static extern bool IsWindowEnabled(IntPtr h);
        [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint cmd);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int max);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr SendMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "SendMessage")] static extern IntPtr SendMessageStr(IntPtr h, uint msg, IntPtr w, StringBuilder l);
        [DllImport("user32.dll")] static extern int GetDlgCtrlID(IntPtr h);

        const uint GW_OWNER = 4;
        const uint BM_CLICK = 0x00F5;
        const uint WM_COMMAND = 0x0111;
        const uint WM_LBUTTONDOWN = 0x0201;
        const uint WM_LBUTTONUP = 0x0202;
        const uint WM_GETTEXT = 0x000D;
        const uint WM_GETTEXTLENGTH = 0x000E;

        static string ClassOf(IntPtr h)
        {
            var sb = new StringBuilder(256);
            GetClassName(h, sb, sb.Capacity);
            return sb.ToString();
        }

        // WM_GETTEXT works cross-process (the dialog's UI thread pumps the modal
        // loop and answers the message); GetWindowText does not for child controls.
        static string CtlText(IntPtr h)
        {
            int len = (int)SendMessage(h, WM_GETTEXTLENGTH, IntPtr.Zero, IntPtr.Zero);
            if (len <= 0) return "";
            var sb = new StringBuilder(len + 1);
            SendMessageStr(h, WM_GETTEXT, (IntPtr)(len + 1), sb);
            return sb.ToString();
        }

        public static List<DlgWin> Find(uint pid)
        {
            var res = new List<DlgWin>();
            EnumWindows((h, l) =>
            {
                uint wp; GetWindowThreadProcessId(h, out wp);
                if (wp != pid) return true;
                if (!IsWindowVisible(h) || !IsWindowEnabled(h)) return true;
                IntPtr owner = GetWindow(h, GW_OWNER);
                if (owner == IntPtr.Zero || IsWindowEnabled(owner)) return true; // not application-modal
                var d = new DlgWin { Hwnd = h.ToInt64(), Title = CtlText(h), Class = ClassOf(h) };
                var body = new StringBuilder();
                EnumChildWindows(h, (c, l2) =>
                {
                    string cls = ClassOf(c);
                    string t = CtlText(c);
                    if (cls == "Button")
                    {
                        if (!string.IsNullOrWhiteSpace(t)) d.Buttons.Add(t.Replace("&", "").Trim());
                    }
                    else if (cls == "Static" || cls == "RichEdit20W" || cls.StartsWith("Edit"))
                    {
                        if (!string.IsNullOrWhiteSpace(t)) body.Append(t.Trim() + " ");
                    }
                    return true;
                }, IntPtr.Zero);
                d.Text = body.ToString().Trim();
                res.Add(d);
                return true;
            }, IntPtr.Zero);
            return res;
        }

        public static bool Click(long hwnd, string label)
        {
            string want = (label ?? "").Replace("&", "").Trim().ToLowerInvariant();
            IntPtr btn = IntPtr.Zero;
            EnumChildWindows((IntPtr)hwnd, (c, l) =>
            {
                if (ClassOf(c) == "Button" && CtlText(c).Replace("&", "").Trim().ToLowerInvariant() == want)
                {
                    btn = c;
                    return false;
                }
                return true;
            }, IntPtr.Zero);
            if (btn == IntPtr.Zero) return false;
            IntPtr dlg = (IntPtr)hwnd;
            int id = GetDlgCtrlID(btn);
            if (id != 0) SendMessage(dlg, WM_COMMAND, (IntPtr)(id & 0xFFFF), btn);
            SendMessage(btn, WM_LBUTTONDOWN, (IntPtr)1, IntPtr.Zero);
            SendMessage(btn, WM_LBUTTONUP, IntPtr.Zero, IntPtr.Zero);
            SendMessage(btn, BM_CLICK, IntPtr.Zero, IntPtr.Zero);
            return true;
        }
    }

    // Allowlist rule (mirrors dialog-allowlist.json shape).
    internal sealed class DlgRule
    {
        public string Match;       // regex tested against TITLE (case-insensitive)
        public string TextMatch;   // optional regex tested against BODY
        public string Button;      // exact button label to click
    }

    // Snapshot returned to the ComWorker / over the wire (same shape as the PS
    // watcher's Get-Snapshot output).
    public sealed class DialogSnapshot
    {
        public bool Found;
        public bool Blocking;
        public bool Dismissed;
        public string DismissedButton;
        public string Title = "";
        public string Text = "";
        public string Class = "";
        public List<string> Buttons = new List<string>();
        public long Hwnd;
        public long Ts;

        public Json.JObj ToJson()
        {
            var o = new Json.JObj();
            o["found"] = Found;
            o["blocking"] = Blocking;
            o["dismissed"] = Dismissed;
            o["dismissedButton"] = DismissedButton;
            o["title"] = Title;
            o["text"] = Text;
            o["class"] = Class;
            var arr = new Json.JArr();
            if (Buttons != null) foreach (var b in Buttons) arr.Add(b);
            o["buttons"] = arr;
            o["hwnd"] = Hwnd;
            o["ts"] = Ts;
            return o;
        }
    }

    // Background watcher thread. Polls ~750ms for an application-modal dialog
    // owned by the XAE process, auto-dismisses allowlisted ones, and exposes the
    // latest snapshot + a "blocking since" timestamp the ComWorker consults to
    // decide a call is hung on a modal dialog.
    public sealed class DialogWatcher
    {
        private readonly string _processName;
        private readonly int _pollMs;
        private readonly bool _autoDismiss;
        private readonly List<DlgRule> _rules;
        private Thread _thread;
        private volatile bool _stop;

        private readonly object _gate = new object();
        private DialogSnapshot _latest;
        private long _blockingSinceMs; // 0 when not currently blocking

        public DialogWatcher(string allowlistPath, bool autoDismiss, string processName = "TcXaeShell", int pollMs = 750)
        {
            _processName = processName;
            _pollMs = pollMs;
            _autoDismiss = autoDismiss;
            _rules = LoadRules(allowlistPath);
            _latest = new DialogSnapshot { Found = false, Blocking = false, Ts = NowMs() };
        }

        private static long NowMs() { return DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(); }

        private static List<DlgRule> LoadRules(string path)
        {
            var rules = new List<DlgRule>();
            try
            {
                if (string.IsNullOrEmpty(path) || !File.Exists(path)) return rules;
                var root = Json.ParseObject(File.ReadAllText(path));
                var arr = root.Arr("rules");
                if (arr == null) return rules;
                foreach (var item in arr)
                {
                    var ro = item as Json.JObj;
                    if (ro == null) continue;
                    var match = ro.Str("match");
                    if (string.IsNullOrEmpty(match)) continue;
                    rules.Add(new DlgRule { Match = match, TextMatch = ro.Str("textMatch"), Button = ro.Str("button") });
                }
            }
            catch (Exception ex) { Log.Error("DialogWatcher.LoadRules", ex); }
            return rules;
        }

        public void Start()
        {
            _thread = new Thread(Loop) { IsBackground = true, Name = "te1000-dialog-watcher" };
            _thread.Start();
        }

        public void Stop()
        {
            _stop = true;
            try { if (_thread != null) _thread.Join(2000); } catch { }
        }

        public DialogSnapshot Latest { get { lock (_gate) return _latest; } }

        // Milliseconds a blocking (non-allowlisted) dialog has been present, or 0.
        public long BlockingForMs
        {
            get
            {
                lock (_gate)
                {
                    if (_blockingSinceMs == 0) return 0;
                    return NowMs() - _blockingSinceMs;
                }
            }
        }

        private void Loop()
        {
            while (!_stop)
            {
                try
                {
                    var snap = Probe(_autoDismiss);
                    lock (_gate)
                    {
                        _latest = snap;
                        if (snap.Found && snap.Blocking)
                        {
                            if (_blockingSinceMs == 0) _blockingSinceMs = NowMs();
                        }
                        else
                        {
                            _blockingSinceMs = 0;
                        }
                    }
                }
                catch { /* window vanished mid-enumerate, etc. — keep watching */ }
                Thread.Sleep(_pollMs);
            }
        }

        // One-shot probe (also used for a pre-flight gate). Auto-dismisses an
        // allowlisted dialog when doDismiss is true.
        public DialogSnapshot Probe(bool doDismiss)
        {
            DlgWin dlg = null;
            foreach (var proc in SafeGetProcesses(_processName))
            {
                try
                {
                    var hits = DlgWatch.Find((uint)proc.Id);
                    if (hits != null && hits.Count > 0) { dlg = hits[0]; break; }
                }
                catch { }
            }

            if (dlg == null)
                return new DialogSnapshot { Found = false, Blocking = false, Ts = NowMs() };

            string title = dlg.Title ?? "";
            string text = dlg.Text ?? "";
            bool dismissed = false;
            string dismissedButton = null;

            if (doDismiss && _rules.Count > 0)
            {
                foreach (var r in _rules)
                {
                    if (string.IsNullOrEmpty(r.Match)) continue;
                    bool titleOk = Regex.IsMatch(title, r.Match, RegexOptions.IgnoreCase);
                    bool textOk = string.IsNullOrEmpty(r.TextMatch) || Regex.IsMatch(text, r.TextMatch, RegexOptions.IgnoreCase);
                    if (titleOk && textOk)
                    {
                        if (DlgWatch.Click(dlg.Hwnd, r.Button))
                        {
                            dismissed = true;
                            dismissedButton = r.Button;
                        }
                        break;
                    }
                }
            }

            return new DialogSnapshot
            {
                Found = true,
                Blocking = !dismissed,
                Dismissed = dismissed,
                DismissedButton = dismissedButton,
                Title = title,
                Text = text,
                Class = dlg.Class ?? "",
                Buttons = dlg.Buttons ?? new List<string>(),
                Hwnd = dlg.Hwnd,
                Ts = NowMs()
            };
        }

        private static Process[] SafeGetProcesses(string name)
        {
            try { return Process.GetProcessesByName(name); }
            catch { return new Process[0]; }
        }
    }
}
