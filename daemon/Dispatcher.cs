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

        public Dispatcher(ComWorker worker)
        {
            _worker = worker;
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

        // Default per-call timeout (ms); long builds pass their own (0 = no limit).
        private const int DefaultTimeoutMs = 0; // 0 = wait indefinitely (parity with index.js HARD_TIMEOUT default off)

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
                arr.Add("ping"); arr.Add("list_actions");
                var data = new Json.JObj();
                data["actions"] = arr;
                data["count"] = arr.Count;
                resp["result"] = data;
                return resp;
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
                var ctx = new ActionContext(action, payload, _worker.Session, _cache);
                Json.JObj data = handler(ctx);
                return data ?? new Json.JObj();
            }, timeout);

            if (result.Ok)
            {
                resp["ok"] = true;
                resp["result"] = result.Data;
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

        // Build/activate/long-running actions may carry their own timeoutMs.
        private static int TimeoutFor(string action, Json.JObj payload)
        {
            if (payload.Has("timeoutMs"))
            {
                int t = payload.Int("timeoutMs", 0);
                if (t > 0) return t;
            }
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
