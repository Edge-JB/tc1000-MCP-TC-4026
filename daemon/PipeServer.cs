using System;
using System.IO;
using System.IO.Pipes;
using System.Text;
using System.Threading;

namespace Te1000Daemon
{
    // Named-pipe server. Newline-delimited JSON: each line is one request
    // {id, action, payload}; each response is one line {id, ok, result?|error?,
    // errorKind?}. Multiple concurrent client connections are accepted; all
    // enqueue to the single ComWorker via the Dispatcher (which serializes).
    public sealed class PipeServer
    {
        private readonly string _pipeName;
        private readonly Dispatcher _dispatcher;
        private volatile bool _stop;

        public PipeServer(string pipeName, Dispatcher dispatcher)
        {
            _pipeName = pipeName;
            _dispatcher = dispatcher;
        }

        public void Run()
        {
            Log.Write("PipeServer listening on \\\\.\\pipe\\" + _pipeName);
            while (!_stop)
            {
                NamedPipeServerStream server = null;
                try
                {
                    server = new NamedPipeServerStream(
                        _pipeName,
                        PipeDirection.InOut,
                        NamedPipeServerStream.MaxAllowedServerInstances,
                        PipeTransmissionMode.Byte,
                        PipeOptions.Asynchronous);
                    server.WaitForConnection();
                    var conn = server;
                    var t = new Thread(() => ServeConnection(conn)) { IsBackground = true, Name = "te1000-pipe-conn" };
                    t.Start();
                }
                catch (Exception ex)
                {
                    Log.Error("PipeServer.Accept", ex);
                    if (server != null) { try { server.Dispose(); } catch { } }
                    if (_stop) break;
                    Thread.Sleep(200);
                }
            }
        }

        private void ServeConnection(NamedPipeServerStream server)
        {
            try
            {
                var reader = new StreamReader(server, new UTF8Encoding(false), false, 1 << 16, leaveOpen: true);
                var writer = new StreamWriter(server, new UTF8Encoding(false), 1 << 16, leaveOpen: true) { AutoFlush = false };

                string line;
                while (server.IsConnected && (line = reader.ReadLine()) != null)
                {
                    if (line.Length == 0) continue;
                    string responseLine;
                    try
                    {
                        var request = Json.ParseObject(line);
                        var resp = _dispatcher.Handle(request);
                        responseLine = Json.Write(resp);
                    }
                    catch (Exception ex)
                    {
                        // Malformed request or unexpected dispatcher failure.
                        var resp = new Json.JObj();
                        resp["ok"] = false;
                        resp["error"] = "Daemon request handling failed: " + ex.Message;
                        resp["errorKind"] = "com_error";
                        responseLine = Json.Write(resp);
                    }
                    writer.Write(responseLine);
                    writer.Write('\n');
                    writer.Flush();
                }
            }
            catch (Exception ex)
            {
                Log.Error("PipeServer.Serve", ex);
            }
            finally
            {
                try { server.Disconnect(); } catch { }
                try { server.Dispose(); } catch { }
            }
        }

        public void Stop() { _stop = true; }
    }
}
