using System;
using System.Collections.Generic;

namespace Te1000Daemon
{
    public delegate Json.JObj ActionHandler(ActionContext ctx);

    // Maps action name -> handler, builds the ActionContext, and runs the handler
    // on the ComWorker STA thread. Produces the wire response envelope.
    public sealed class Dispatcher
    {
        private readonly Dictionary<string, ActionHandler> _handlers =
            new Dictionary<string, ActionHandler>(StringComparer.Ordinal);
        private readonly ComWorker _worker;
        private readonly TreeCache _cache = new TreeCache();
        private readonly EditWatcher _edits;

        public Dispatcher(ComWorker worker)
        {
            _worker = worker;
            // EditWatcher resolves the CURRENT session lazily (it changes after a
            // worker recycle), so pass a provider rather than a captured instance.
            _edits = new EditWatcher(delegate { return _worker.Session; }, _cache);
            RegisterAll();
        }

        public int ActionCount { get { return _handlers.Count; } }
        public IEnumerable<string> Actions { get { return _handlers.Keys; } }

        private void RegisterAll()
        {
            // ping is COM-free; handled specially in Handle().
            XaeActions.Register(_handlers);
            TreeActions.Register(_handlers);
            LinkActions.Register(_handlers);
            PlcProjectActions.Register(_handlers);
            PlcPouActions.Register(_handlers);
            PlcLibraryActions.Register(_handlers);
            TaskActions.Register(_handlers);
            MappingRouteActions.Register(_handlers);
            FieldbusActions.Register(_handlers);
            ModuleCppActions.Register(_handlers);
            MeasurementActions.Register(_handlers);
            LicenseVariantActions.Register(_handlers);
            NcActions.Register(_handlers);
            SessionDownloadActions.Register(_handlers);
        }

        // Default per-call ceiling (ms). The legacy bridge left its wall-clock
        // backstop OFF by default (TE1000_BRIDGE_TIMEOUT_MS=0), but with budget==0
        // the daemon's ComWorker.Run loop never trips its timeout branch, so a
        // wedged non-dialog COM call would hang that request forever. Give a finite,
        // generous default ceiling so a stuck request eventually recycles the worker
        // and returns a timeout error. Long-running actions (builds, etc.) still
        // pass their own larger timeoutMs in the payload, which overrides this.
        private const int DefaultTimeoutMs = 180000; // 3 min generous ceiling

        // Returns the response JObj: {id, ok, result?|error?, errorKind?}.
        public Json.JObj Handle(Json.JObj request)
        {
            var resp = new Json.JObj();
            object idVal = request["id"];
            resp["id"] = idVal;
            string action = request.Str("action");

            // ---- COM-free actions -------------------------------------------
            if (action == "ping")
            {
                resp["ok"] = true;
                var data = new Json.JObj();
                data["pong"] = true;
                data["actionCount"] = _handlers.Count;
                data["pid"] = System.Diagnostics.Process.GetCurrentProcess().Id;
                data["ts"] = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
                resp["result"] = data;
                return resp;
            }
            if (action == "list_actions")
            {
                resp["ok"] = true;
                var arr = new Json.JArr();
                foreach (var k in _handlers.Keys) arr.Add(k);
                arr.Add("ping"); arr.Add("list_actions"); arr.Add("dialog_probe"); arr.Add("dialog_resolve");
                var data = new Json.JObj();
                data["actions"] = arr;
                data["count"] = arr.Count;
                resp["result"] = data;
                return resp;
            }
            // dialog_probe: COM-free diagnostic. Runs a one-shot window enumeration
            // (no COM, no STA hop) and returns the current modal-dialog snapshot —
            // the same shape the watcher feeds the grace recycle. Report-only: it
            // never auto-dismisses (doDismiss:false), so it is safe to call against a
            // live cell to ask "is XAE blocked on a dialog right now, and on what?".
            if (action == "dialog_probe")
            {
                resp["ok"] = true;
                var data = new Json.JObj();
                DialogWatcher w = _worker.Watcher;
                if (w == null)
                {
                    data["watching"] = false;
                    data["found"] = false;
                }
                else
                {
                    data["watching"] = true;
                    DialogSnapshot snap = w.Probe(false);
                    data["snapshot"] = snap.ToJson();
                    data["found"] = snap.Found;
                    data["blocking"] = snap.Blocking;
                    data["blockingForMs"] = w.BlockingForMs;
                }
                resp["result"] = data;
                return resp;
            }
            // dialog_resolve: COM-free. Clicks a human-chosen button on the live
            // modal dialog and (optionally, remember:true) appends an auto-dismiss
            // rule to dialog-allowlist.json + hot-applies it to the running watcher.
            // Destructive prompts are refused for auto-remember (the one-time click
            // is still performed). Mirrors dialog_probe's plumbing (no STA hop).
            if (action == "dialog_resolve")
            {
                return HandleDialogResolve(resp, request);
            }

            ActionHandler handler;
            if (!_handlers.TryGetValue(action, out handler))
            {
                resp["ok"] = false;
                resp["error"] = "Unsupported action: " + action;
                resp["errorKind"] = "com_error";
                return resp;
            }

            var payload = request.Obj("payload") ?? new Json.JObj();
            int timeout = TimeoutFor(action, payload);

            var result = _worker.Run(() =>
            {
                var ctx = new ActionContext(action, payload, _worker.Session, _cache, _edits);
                Json.JObj data = handler(ctx);
                return data ?? new Json.JObj();
            }, timeout);

            if (result.Ok)
            {
                resp["ok"] = true;
                resp["result"] = result.Data;
                // After a successful solution open, re-arm the save-coverage
                // FileSystemWatcher for the new project dir and kick a background
                // corpus pre-warm so the first user search is already cache-warm.
                // Both run on the STA worker; neither blocks this response.
                if (action == "xae_open_solution")
                {
                    PostOpenSolution();
                }
            }
            else
            {
                resp["ok"] = false;
                resp["error"] = result.Error;
                resp["errorKind"] = KindString(result.Kind);
                if (result.Dialog != null) resp["dialog"] = result.Dialog.ToJson();
            }
            return resp;
        }

        // dialog_resolve handler. COM-free; runs on the pipe thread (no STA hop),
        // exactly like dialog_probe. Clicks a chosen button on the live modal and
        // optionally remembers it (unless the prompt looks destructive).
        private Json.JObj HandleDialogResolve(Json.JObj resp, Json.JObj request)
        {
            try
            {
                Json.JObj payload = request.Obj("payload") ?? new Json.JObj();
                string button = payload.Str("button");
                bool remember = payload.Bool("remember", false);

                DialogWatcher w = _worker.Watcher;
                if (w == null)
                {
                    resp["ok"] = false;
                    resp["error"] = "dialog watcher disabled (daemon started with --no-watch)";
                    resp["errorKind"] = "com_error";
                    return resp;
                }
                if (string.IsNullOrEmpty(button))
                {
                    resp["ok"] = false;
                    resp["error"] = "'button' is required for action=dialog_resolve";
                    resp["errorKind"] = "com_error";
                    return resp;
                }

                // Report-only probe — do NOT auto-dismiss; we click explicitly below.
                DialogSnapshot snap = w.Probe(false);
                if (!snap.Found)
                {
                    resp["ok"] = true;
                    var none = new Json.JObj();
                    none["resolved"] = false;
                    none["reason"] = "no modal dialog is currently open";
                    resp["result"] = none;
                    return resp;
                }

                // Validate the requested button against the live dialog (case- and
                // accelerator-insensitive). Reuse the exact label from the snapshot.
                string want = NormalizeButton(button);
                string matchedButton = null;
                if (snap.Buttons != null)
                {
                    foreach (var b in snap.Buttons)
                    {
                        if (NormalizeButton(b) == want) { matchedButton = b; break; }
                    }
                }
                if (matchedButton == null)
                {
                    resp["ok"] = false;
                    string have = (snap.Buttons != null) ? string.Join(", ", snap.Buttons.ToArray()) : "";
                    resp["error"] = "button '" + button + "' is not on the dialog. Buttons: " + (have.Length > 0 ? have : "(none detected)");
                    resp["errorKind"] = "com_error";
                    return resp;
                }

                string title = snap.Title ?? "";
                string text = snap.Text ?? "";

                // Destructive denylist: never auto-remember a prompt that activates
                // config, changes run-mode, restarts/downloads/boots, or touches
                // TwinSAFE/safety. The one-time human-chosen click still happens.
                string hay = title + " " + text;
                bool looksDestructive = System.Text.RegularExpressions.Regex.IsMatch(
                    hay,
                    @"activate.*config|run[\s-]*mode|restart|download|boot\s*project|twinsafe|safety|set.*run|reset.*twincat",
                    System.Text.RegularExpressions.RegexOptions.IgnoreCase);

                // Perform the one-time click the human chose.
                bool clicked = DlgWatch.Click(snap.Hwnd, matchedButton);

                bool remembered = false;
                bool rememberRefused = false;
                string refuseReason = null;

                if (remember)
                {
                    if (looksDestructive)
                    {
                        rememberRefused = true;
                        refuseReason = "destructive prompt — left out of the auto-dismiss allowlist by policy; the click was performed once";
                    }
                    else if (w.HasRuleFor(title, text))
                    {
                        refuseReason = "already covered by an existing rule";
                    }
                    else
                    {
                        string escapedTitle = System.Text.RegularExpressions.Regex.Escape(title);
                        bool appended = AppendAllowlistRule(w.AllowlistPath, escapedTitle, matchedButton);
                        // Sync the running watcher's in-memory rules either way so it
                        // auto-dismisses next time without a daemon restart.
                        w.AddRule(escapedTitle, null, matchedButton);
                        remembered = true;
                        if (!appended)
                            refuseReason = "rule applied in-memory but the allowlist file could not be updated (see daemon log)";
                    }
                }

                resp["ok"] = true;
                var data = new Json.JObj();
                data["resolved"] = true;
                data["clicked"] = clicked;
                data["button"] = matchedButton;
                data["remembered"] = remembered;
                if (rememberRefused) data["rememberRefused"] = true;
                if (refuseReason != null) data["refuseReason"] = refuseReason;
                data["title"] = title;
                resp["result"] = data;
                return resp;
            }
            catch (Exception ex)
            {
                Log.Error("dialog_resolve", ex);
                resp["ok"] = false;
                resp["error"] = "dialog_resolve failed: " + ex.Message;
                resp["errorKind"] = "com_error";
                return resp;
            }
        }

        // Lower-case, accelerator-stripped, trimmed button label for comparison.
        private static string NormalizeButton(string s)
        {
            return (s ?? "").Replace("&", "").Trim().ToLowerInvariant();
        }

        // Append a literal-title rule to dialog-allowlist.json. Prefers a targeted
        // insertion that preserves the file's hand-readable formatting; falls back
        // to a parse->add->compact rewrite. Writes atomically. Returns true on
        // success (file now contains valid JSON with the new rule).
        private static bool AppendAllowlistRule(string path, string escapedTitle, string button)
        {
            try
            {
                if (string.IsNullOrEmpty(path) || !System.IO.File.Exists(path)) return false;
                string original = System.IO.File.ReadAllText(path);

                // Validate the current file parses and locate the rules array.
                Json.JObj root = Json.ParseObject(original);
                Json.JArr rules = root.Arr("rules");
                if (rules == null) return false;

                string newText = null;

                // --- Targeted insertion (preserves formatting) -------------------
                // Find the "rules": [ ... ] block, insert a new object line as the
                // last element, fixing the previously-last element's trailing comma.
                int rulesKey = original.IndexOf("\"rules\"", StringComparison.Ordinal);
                if (rulesKey >= 0)
                {
                    int open = original.IndexOf('[', rulesKey);
                    if (open >= 0)
                    {
                        int close = FindMatchingBracket(original, open);
                        if (close > open)
                        {
                            // Detect the indentation of existing rule lines (the
                            // first non-ws char on the line after '[').
                            string indent = "    ";
                            int lineStart = original.IndexOf('\n', open);
                            if (lineStart >= 0)
                            {
                                int p = lineStart + 1;
                                int ws = p;
                                while (ws < original.Length && (original[ws] == ' ' || original[ws] == '\t')) ws++;
                                if (ws > p) indent = original.Substring(p, ws - p);
                            }

                            string newRule = "{ \"match\": " + Json.Write(escapedTitle) + ", \"button\": " + Json.Write(button) + " }";

                            // Inner content between [ and ] (exclusive).
                            string before = original.Substring(0, open + 1);
                            string inner = original.Substring(open + 1, close - open - 1);
                            string after = original.Substring(close); // starts at ']'

                            string trimmedInner = inner.TrimEnd();
                            string sb;
                            if (trimmedInner.Length == 0)
                            {
                                // Empty array.
                                sb = before + "\n" + indent + newRule + "\n" + Indent(after, close, original);
                            }
                            else
                            {
                                // Append a comma to the last element, then our line.
                                sb = before + trimmedInner + ",\n" + indent + newRule + "\n" + Indent(after, close, original);
                            }
                            newText = sb;
                        }
                    }
                }

                // --- Fallback: parse -> add -> compact rewrite -------------------
                if (newText == null)
                {
                    var ro = new Json.JObj();
                    ro["match"] = escapedTitle;
                    ro["button"] = button;
                    rules.Add(ro);
                    newText = Json.Write(root);
                }

                // Re-parse to confirm we produced valid JSON before committing.
                try { Json.ParseObject(newText); }
                catch
                {
                    // Targeted insertion produced bad JSON — fall back to compact.
                    Json.JObj root2 = Json.ParseObject(original);
                    Json.JArr rules2 = root2.Arr("rules");
                    if (rules2 == null) return false;
                    var ro = new Json.JObj();
                    ro["match"] = escapedTitle;
                    ro["button"] = button;
                    rules2.Add(ro);
                    newText = Json.Write(root2);
                    Json.ParseObject(newText); // throws if still bad
                }

                // Atomic write: temp file + replace.
                string tmp = path + ".tmp";
                System.IO.File.WriteAllText(tmp, newText, new System.Text.UTF8Encoding(false));
                try { System.IO.File.Delete(path); } catch { }
                System.IO.File.Move(tmp, path);
                return true;
            }
            catch (Exception ex)
            {
                Log.Error("AppendAllowlistRule", ex);
                return false;
            }
        }

        // Recompute the closing-bracket portion's leading indentation: keep the ']'
        // (and trailing content) exactly as in the original tail.
        private static string Indent(string after, int closeIdx, string original)
        {
            // 'after' already begins at ']' — find the indentation that preceded it
            // on its own line and prepend it so the bracket stays aligned.
            int lineStart = original.LastIndexOf('\n', closeIdx);
            string pad = "";
            if (lineStart >= 0)
            {
                int p = lineStart + 1;
                int ws = p;
                while (ws < closeIdx && (original[ws] == ' ' || original[ws] == '\t')) ws++;
                pad = original.Substring(p, ws - p);
            }
            return pad + after;
        }

        // Index of the ']' matching the '[' at openIdx, accounting for nested
        // brackets and bracket chars inside JSON strings.
        private static int FindMatchingBracket(string s, int openIdx)
        {
            int depth = 0;
            bool inStr = false;
            for (int i = openIdx; i < s.Length; i++)
            {
                char c = s[i];
                if (inStr)
                {
                    if (c == '\\') { i++; continue; }
                    if (c == '"') inStr = false;
                    continue;
                }
                if (c == '"') { inStr = true; continue; }
                if (c == '[') depth++;
                else if (c == ']') { depth--; if (depth == 0) return i; }
            }
            return -1;
        }

        // Background, fire-and-forget post-open work on the STA thread: re-arm the
        // FileSystemWatcher and pre-warm the search text cache. Cancellable/safe if
        // the solution closes (every COM access is wrapped and swallowed).
        private void PostOpenSolution()
        {
            _worker.EnqueueBackground(delegate
            {
                try
                {
                    var ctx = new ActionContext("__prewarm", new Json.JObj(), _worker.Session, _cache, _edits);
                    try { _edits.ReinitFileWatcher(); } catch (Exception ex) { Log.Error("EditWatcher.ReinitFileWatcher", ex); }
                    try { PlcPouActions.PrewarmSearchCache(ctx); } catch (Exception ex) { Log.Error("PrewarmSearchCache", ex); }
                }
                catch (Exception ex) { Log.Error("PostOpenSolution", ex); }
                return new Json.JObj();
            });
        }

        // Build/activate/long-running actions may carry their own timeoutMs.
        // Actions that can legitimately run far longer than the default ceiling
        // (solution/C++ builds, activate, download, restart, boot-gen, library/IO
        // scans, rescan, timed scope record, network broadcast search). These keep
        // the legacy no-limit behavior (budget 0 = wait indefinitely) unless the
        // caller passes an explicit timeoutMs; the dialog watcher still recovers
        // them if they wedge on a modal. Without this allowlist the 180 s ceiling
        // would kill a legitimate multi-minute build/activate and recycle the worker.
        private static readonly System.Collections.Generic.HashSet<string> LongRunningActions =
            new System.Collections.Generic.HashSet<string>(System.StringComparer.OrdinalIgnoreCase)
            {
                "xae_solution_build", "twincat_cpp_build_project",
                "twincat_activate_configuration", "twincat_restart_runtime",
                "plc_download", "plc_login", "plc_project_generate_boot",
                "measurement_scope_record", "twincat_route_broadcast_search",
                "plc_library_scan", "twincat_rescan_plc_project",
                "twincat_scan_io_boxes", "twincat_license_activate_response",
            };

        private static int TimeoutFor(string action, Json.JObj payload)
        {
            if (payload.Has("timeoutMs"))
            {
                int t = payload.Int("timeoutMs", 0);
                if (t > 0) return t;
            }
            // Long-running ops keep the legacy infinite wait absent an explicit
            // override; ordinary fast COM calls get the finite safety ceiling.
            if (action != null && LongRunningActions.Contains(action)) return 0;
            return DefaultTimeoutMs;
        }

        private static string KindString(ErrorKind k)
        {
            switch (k)
            {
                case ErrorKind.DialogBlocked: return "dialog_blocked";
                case ErrorKind.Timeout: return "timeout";
                default: return "com_error";
            }
        }
    }
}
