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
    // ---- DlgWin / DlgWatch: native C# dialog watchdog ----
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
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern IntPtr SendMessageTimeout(IntPtr h, uint msg, IntPtr w, IntPtr l, uint flags, uint timeoutMs, out IntPtr result);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "SendMessageTimeoutW")]
        static extern IntPtr SendMessageTimeoutStr(IntPtr h, uint msg, IntPtr w, StringBuilder l, uint flags, uint timeoutMs, out IntPtr result);
        [DllImport("user32.dll")] static extern int GetDlgCtrlID(IntPtr h);

        const uint SMTO_ABORTIFHUNG = 0x0002;
        const uint ClickTimeoutMs = 1500;

        // Cross-process SendMessage with a short timeout so a wedged dialog owner
        // cannot stall the watcher thread (which would freeze BlockingForMs and
        // prevent the grace recycle from ever firing).
        static void SendTimed(IntPtr h, uint msg, IntPtr w, IntPtr l)
        {
            IntPtr res;
            try { SendMessageTimeout(h, msg, w, l, SMTO_ABORTIFHUNG, ClickTimeoutMs, out res); }
            catch { }
        }

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
        // Uses SendMessageTimeout(SMTO_ABORTIFHUNG) — never a plain SendMessage — so a
        // wedged XAE UI thread cannot hang the watcher poll or a dialog_probe call
        // (a probe sold as "is XAE stuck right now?" must stay responsive when it is).
        static string CtlText(IntPtr h)
        {
            IntPtr lenRes;
            if (SendMessageTimeout(h, WM_GETTEXTLENGTH, IntPtr.Zero, IntPtr.Zero, SMTO_ABORTIFHUNG, ClickTimeoutMs, out lenRes) == IntPtr.Zero)
                return ""; // timed out / hung UI thread
            int len = (int)lenRes;
            if (len <= 0) return "";
            var sb = new StringBuilder(len + 1);
            IntPtr res;
            SendMessageTimeoutStr(h, WM_GETTEXT, (IntPtr)(len + 1), sb, SMTO_ABORTIFHUNG, ClickTimeoutMs, out res);
            return sb.ToString();
        }

        const string StdDialogClass = "#32770"; // the standard Win32 dialog-box class (MessageBox & friends)

        public static List<DlgWin> Find(uint pid)
        {
            var res = new List<DlgWin>();
            EnumWindows((h, l) =>
            {
                uint wp; GetWindowThreadProcessId(h, out wp);
                if (wp != pid) return true;
                if (!IsWindowVisible(h)) return true;

                IntPtr owner = GetWindow(h, GW_OWNER);

                // Two shapes of blocking modal dialog must be recognized:
                //
                //  (1) Classic application-modal: an OWNED window whose owner is
                //      DISABLED (the defining trait — WPF/WinForms dialogs such as
                //      the VS "file changed outside the environment" prompt). The
                //      dialog itself is enabled while it holds the modal loop.
                //
                //  (2) Standard dialog box (#32770) showing the ABNORMAL trait the
                //      owner-disabled heuristic misses: OWNER-LESS or self-WS_DISABLED.
                //      These are the MessageBox-style prompts the TwinCAT System
                //      Manager raises — e.g. "Unrestored variables links found" — which
                //      are owner-less, do not disable the main window, and may even be
                //      self-disabled (a nested confirm can sit on top), yet still block
                //      the synchronous DTE/COM call (verified live: owner=0,
                //      self-disabled, main enabled). A normal owned, self-ENABLED #32770
                //      is a MODELESS tool window (VS Find/Replace, Go To Line, Find
                //      Symbol Results) that does NOT block COM — it must be EXCLUDED, or
                //      leaving one open would spuriously trip the grace recycle and fail
                //      unrelated commands.
                bool ownerModal = owner != IntPtr.Zero && !IsWindowEnabled(owner);
                bool abnormal = owner == IntPtr.Zero || !IsWindowEnabled(h); // owner-less or self-disabled

                // Only an owner-modal or abnormal window can be a blocking dialog; skip
                // the GetClassName P/Invoke for the many ordinary owned, enabled windows
                // a VS/XAE process has (this runs every poll, for every visible window).
                if (!ownerModal && !abnormal) return true;

                string cls = ClassOf(h);
                bool stdDialog = cls == StdDialogClass && abnormal;
                if (!ownerModal && !stdDialog) return true;

                // The classic (owner-disabled) path still requires the dialog window
                // itself be enabled — a disabled, non-#32770 window is not the active
                // modal. The #32770 path intentionally allows a self-disabled dialog.
                if (ownerModal && !stdDialog && !IsWindowEnabled(h)) return true;

                var d = new DlgWin { Hwnd = h.ToInt64(), Title = CtlText(h), Class = cls };
                var body = new StringBuilder();
                EnumChildWindows(h, (c, l2) =>
                {
                    string ccls = ClassOf(c);
                    string t = CtlText(c);
                    if (ccls == "Button")
                    {
                        if (!string.IsNullOrWhiteSpace(t)) d.Buttons.Add(t.Replace("&", "").Trim());
                    }
                    else if (ccls == "Static" || ccls == "RichEdit20W" || ccls.StartsWith("Edit"))
                    {
                        if (!string.IsNullOrWhiteSpace(t)) body.Append(t.Trim() + " ");
                    }
                    return true;
                }, IntPtr.Zero);
                d.Text = body.ToString().Trim();

                // A #32770 matched purely on class must carry real content (a button
                // or a message) to count — guards against transient empty dialog
                // shells. Owner-modal dialogs are trusted regardless.
                if (stdDialog && !ownerModal && d.Buttons.Count == 0 && d.Text.Length == 0) return true;

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
            if (id != 0) SendTimed(dlg, WM_COMMAND, (IntPtr)(id & 0xFFFF), btn);
            SendTimed(btn, WM_LBUTTONDOWN, (IntPtr)1, IntPtr.Zero);
            SendTimed(btn, WM_LBUTTONUP, IntPtr.Zero, IntPtr.Zero);
            SendTimed(btn, BM_CLICK, IntPtr.Zero, IntPtr.Zero);
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
        private readonly string[] _processNames;
        private readonly int _pollMs;
        private readonly bool _autoDismiss;
        private readonly string _allowlistPath;
        // Copy-on-write rule list: the watcher thread reads this field into a local
        // and iterates that immutable snapshot, while AddRule (runtime) reassigns
        // the field wholesale under _gate — so a runtime add can never race the
        // poll mid-iteration. Plain field (NOT readonly) so it can be reassigned.
        private List<DlgRule> _rules;
        private Thread _thread;
        private volatile bool _stop;

        private readonly object _gate = new object();
        private DialogSnapshot _latest;
        private long _blockingSinceMs; // 0 when not currently blocking

        // The XAE shell can be hosted under different process names depending on
        // how TwinCAT is installed (TcXaeShell, the 64-bit TcXaeShell64, or a
        // VS-hosted devenv). Watch the whole candidate set so the dialog-grace
        // recycle still triggers when XAE isn't the default TcXaeShell.exe.
        private static readonly string[] DefaultProcessNames = { "TcXaeShell", "TcXaeShell64", "devenv" };

        public DialogWatcher(string allowlistPath, bool autoDismiss, string processName = null, int pollMs = 750)
        {
            _processNames = string.IsNullOrWhiteSpace(processName)
                ? DefaultProcessNames
                : new[] { processName };
            _pollMs = pollMs;
            _autoDismiss = autoDismiss;
            _allowlistPath = allowlistPath;
            _rules = LoadRules(allowlistPath);
            _latest = new DialogSnapshot { Found = false, Blocking = false, Ts = NowMs() };
        }

        // The dialog-allowlist.json path this watcher loaded its rules from, so
        // dialog_resolve can append a remembered rule to the same file.
        public string AllowlistPath { get { return _allowlistPath; } }

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

        // The allowlist rule whose title (and optional text) regex matches this
        // dialog, or null. Used by Probe both to drive the auto-dismiss click and to
        // tell the report-only path whether the dialog will be cleared automatically.
        private DlgRule MatchRule(string title, string text)
        {
            // Read the copy-on-write field ONCE into a local so we iterate an
            // immutable snapshot even if AddRule reassigns the field mid-walk.
            var rules = _rules;
            foreach (var r in rules)
            {
                if (string.IsNullOrEmpty(r.Match)) continue;
                bool titleOk = Regex.IsMatch(title ?? "", r.Match, RegexOptions.IgnoreCase);
                bool textOk = string.IsNullOrEmpty(r.TextMatch) || Regex.IsMatch(text ?? "", r.TextMatch, RegexOptions.IgnoreCase);
                if (titleOk && textOk) return r;
            }
            return null;
        }

        // Runtime-add a rule (copy-on-write): build a NEW list = current + the new
        // rule, then reassign the field under _gate. The watcher thread reads the
        // field into a local before iterating, so it never sees a half-built list.
        public void AddRule(string match, string textMatch, string button)
        {
            if (string.IsNullOrEmpty(match)) return;
            lock (_gate)
            {
                var next = new List<DlgRule>(_rules);
                next.Add(new DlgRule { Match = match, TextMatch = textMatch, Button = button });
                _rules = next;
            }
        }

        // True if any current rule already matches this dialog (same title/text
        // logic as the auto-dismiss path). Used to avoid duplicate appends and to
        // tell dialog_resolve the dialog is already covered.
        public bool HasRuleFor(string title, string text)
        {
            return MatchRule(title, text) != null;
        }

        // One-shot probe (also used for a pre-flight gate). Auto-dismisses an
        // allowlisted dialog when doDismiss is true.
        public DialogSnapshot Probe(bool doDismiss)
        {
            DlgWin dlg = null;
            foreach (var name in _processNames)
            {
                foreach (var proc in SafeGetProcesses(name))
                {
                    try
                    {
                        var hits = DlgWatch.Find((uint)proc.Id);
                        if (hits != null && hits.Count > 0) { dlg = hits[0]; break; }
                    }
                    catch { }
                    finally { try { proc.Dispose(); } catch { } }
                }
                if (dlg != null) break;
            }

            if (dlg == null)
                return new DialogSnapshot { Found = false, Blocking = false, Ts = NowMs() };

            string title = dlg.Title ?? "";
            string text = dlg.Text ?? "";
            // The allowlist rule (if any) that applies — the one the watcher Loop
            // would auto-click. Resolved WITHOUT clicking so the report-only path can
            // distinguish a true block from an about-to-be-auto-dismissed dialog.
            DlgRule rule = MatchRule(title, text);
            bool dismissed = false;
            string dismissedButton = null;

            if (doDismiss && rule != null && DlgWatch.Click(dlg.Hwnd, rule.Button))
            {
                dismissed = true;
                dismissedButton = rule.Button;
            }

            return new DialogSnapshot
            {
                Found = true,
                // Blocking = present AND not going to clear on its own. When dismissing,
                // a still-blocking result means the click failed. When only reporting
                // (doDismiss:false), a dialog that matches an allowlist rule is NOT a
                // persistent block — the watcher Loop will dismiss it — so don't flag it.
                Blocking = doDismiss ? !dismissed : (rule == null),
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
