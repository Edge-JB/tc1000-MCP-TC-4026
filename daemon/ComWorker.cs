using System;
using System.Collections.Concurrent;
using System.Threading;

namespace Te1000Daemon
{
    // Error classification carried over the wire as `errorKind`; index.js maps
    // these back to the existing user-facing messages.
    public enum ErrorKind
    {
        ComError,       // generic COM/automation error -> "com_error"
        DialogBlocked,  // a modal dialog blocked the call -> "dialog_blocked"
        Timeout         // hard wall-clock timeout, no dialog -> "timeout"
    }

    // Thrown by handlers/helpers to produce a clean {ok:false,error,errorKind}.
    public sealed class BridgeException : Exception
    {
        private readonly ErrorKind _kind;
        private readonly DialogSnapshot _dialog;
        public ErrorKind Kind { get { return _kind; } }
        public DialogSnapshot Dialog { get { return _dialog; } }
        public BridgeException(string message, ErrorKind kind = ErrorKind.ComError, DialogSnapshot dialog = null)
            : base(message) { _kind = kind; _dialog = dialog; }
    }

    // Result of a worker job.
    internal sealed class WorkResult
    {
        public bool Ok;
        public Json.JObj Data;       // the `data` payload on success (may be null)
        public string Error;        // error message on failure
        public ErrorKind Kind = ErrorKind.ComError;
        public DialogSnapshot Dialog;
    }

    internal sealed class WorkItem
    {
        public Func<Json.JObj> Job;            // runs on the STA thread
        public readonly ManualResetEventSlim Done = new ManualResetEventSlim(false);
        public WorkResult Result;
    }

    // Owns the single STA thread that makes all DTE/COM calls. Serializes
    // requests through a blocking queue. On a per-request hard timeout (or a
    // persistent modal dialog), abandons the STA thread and spins up a fresh one,
    // re-acquiring the session — without killing the daemon.
    public sealed class ComWorker : IDisposable
    {
        private readonly DialogWatcher _watcher;
        private readonly int _defaultTimeoutMs;
        private readonly int _blockGraceMs;

        private BlockingCollection<WorkItem> _queue;
        private Thread _sta;
        private ComSession _session;
        private readonly object _lifecycleGate = new object();
        private volatile bool _disposed;

        // Re-acquire callback runs on the STA thread after a recycle.
        public ComWorker(DialogWatcher watcher, int defaultTimeoutMs, int blockGraceMs)
        {
            _watcher = watcher;
            _defaultTimeoutMs = defaultTimeoutMs;
            _blockGraceMs = blockGraceMs;
            StartThread();
        }

        public ComSession Session { get { return _session; } }

        private void StartThread()
        {
            _queue = new BlockingCollection<WorkItem>();
            _session = new ComSession();
            _sta = new Thread(Pump) { IsBackground = true, Name = "te1000-com-sta" };
            _sta.SetApartmentState(ApartmentState.STA);
            _sta.Start();
        }

        private void Pump()
        {
            // Register the message filter on THIS STA thread (per-thread).
            try { Te1000MessageFilter.Register(); } catch (Exception ex) { Log.Error("MessageFilter.Register", ex); }

            foreach (var item in _queue.GetConsumingEnumerable())
            {
                WorkResult res = new WorkResult();
                try
                {
                    var data = item.Job();
                    res.Ok = true;
                    res.Data = data;
                }
                catch (BridgeException bex)
                {
                    res.Ok = false;
                    res.Error = bex.Message;
                    res.Kind = bex.Kind;
                    res.Dialog = bex.Dialog;
                }
                catch (Exception ex)
                {
                    res.Ok = false;
                    res.Error = ex.Message;
                    res.Kind = ErrorKind.ComError;
                }
                item.Result = res;
                item.Done.Set();
            }
        }

        // Enqueue a job and wait for it on the STA thread, honoring a hard
        // timeout and the modal-dialog grace window. Returns the WorkResult.
        internal WorkResult Run(Func<Json.JObj> job, int timeoutMs)
        {
            if (_disposed) throw new ObjectDisposedException("ComWorker");
            int budget = timeoutMs > 0 ? timeoutMs : _defaultTimeoutMs;

            WorkItem item;
            lock (_lifecycleGate)
            {
                item = new WorkItem { Job = job };
                _queue.Add(item);
            }

            // Wait loop: poll for completion, the dialog grace window, and the
            // hard timeout. 0/negative budget => wait indefinitely (long builds).
            long start = Environment.TickCount;
            int pollMs = 100;
            while (true)
            {
                if (item.Done.Wait(pollMs)) return item.Result;

                // Modal dialog persisting past the grace window -> abandon.
                long blockedFor = _watcher != null ? _watcher.BlockingForMs : 0;
                if (blockedFor >= _blockGraceMs && _blockGraceMs > 0)
                {
                    var snap = _watcher.Latest;
                    RecycleAsync();
                    return new WorkResult
                    {
                        Ok = false,
                        Kind = ErrorKind.DialogBlocked,
                        Dialog = snap,
                        Error = "XAE is blocked on a modal dialog."
                    };
                }

                if (budget > 0 && (Environment.TickCount - start) >= budget)
                {
                    RecycleAsync();
                    return new WorkResult
                    {
                        Ok = false,
                        Kind = ErrorKind.Timeout,
                        Error = "Call exceeded timeout of " + budget + " ms; no modal dialog detected — XAE may be busy."
                    };
                }
            }
        }

        // Abandon the (likely-stuck-in-a-modal-loop) STA thread and start a fresh
        // one. The old thread is a background thread so it dies with the process
        // if it ever unblocks; we simply stop feeding it.
        private void RecycleAsync()
        {
            lock (_lifecycleGate)
            {
                try { _queue.CompleteAdding(); } catch { }
                Log.Write("ComWorker: recycling STA thread (abandoning stuck worker)");
                var oldSession = _session;
                StartThread();
                // The new session will re-acquire DTE lazily on next use.
                try { if (oldSession != null) oldSession.MarkStale(); } catch { }
            }
        }

        public void Dispose()
        {
            _disposed = true;
            try { _queue.CompleteAdding(); } catch { }
            try { if (_session != null) _session.Dispose(); } catch { }
        }
    }
}
