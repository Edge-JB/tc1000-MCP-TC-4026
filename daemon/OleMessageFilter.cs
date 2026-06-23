using System;
using System.Runtime.InteropServices;

namespace Te1000Daemon
{
    // Verbatim port of Ensure-ComMessageFilter (te1000-bridge.ps1 L116-174).
    //
    // XAE/VS DTE rejects incoming COM calls while busy (RPC_E_CALL_REJECTED
    // 0x80010001). Beckhoff TE1000 docs require an IOleMessageFilter that retries
    // rejected calls. MUST be registered on the STA thread that owns the DTE
    // calls (CoRegisterMessageFilter is per-thread).
    [ComImport, Guid("00000016-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IOleMessageFilter
    {
        [PreserveSig] int HandleInComingCall(int dwCallType, IntPtr hTaskCaller, int dwTickCount, IntPtr lpInterfaceInfo);
        [PreserveSig] int RetryRejectedCall(IntPtr hTaskCallee, int dwTickCount, int dwRejectType);
        [PreserveSig] int MessagePending(IntPtr hTaskCallee, int dwTickCount, int dwPendingType);
    }

    public class Te1000MessageFilter : IOleMessageFilter
    {
        [DllImport("Ole32.dll")]
        private static extern int CoRegisterMessageFilter(IOleMessageFilter newFilter, out IOleMessageFilter oldFilter);

        public static void Register()
        {
            IOleMessageFilter oldFilter;
            CoRegisterMessageFilter(new Te1000MessageFilter(), out oldFilter);
        }

        public static void Revoke()
        {
            IOleMessageFilter oldFilter;
            CoRegisterMessageFilter(null, out oldFilter);
        }

        int IOleMessageFilter.HandleInComingCall(int dwCallType, IntPtr hTaskCaller, int dwTickCount, IntPtr lpInterfaceInfo)
        {
            return 0; // SERVERCALL_ISHANDLED
        }

        int IOleMessageFilter.RetryRejectedCall(IntPtr hTaskCallee, int dwTickCount, int dwRejectType)
        {
            // SERVERCALL_RETRYLATER: retry every 150 ms for up to 60 s, then give up.
            if (dwRejectType == 2 && dwTickCount < 60000)
            {
                return 150;
            }
            return -1; // cancel
        }

        int IOleMessageFilter.MessagePending(IntPtr hTaskCallee, int dwTickCount, int dwPendingType)
        {
            return 2; // PENDINGMSG_WAITDEFPROCESS
        }
    }
}
