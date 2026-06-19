# dialog-watch.ps1 — detect (and optionally auto-dismiss) modal dialogs that
# block te1000-bridge DTE/COM calls.
#
# When TcXaeShell pops a modal dialog (save-changes, activate confirm, "file
# changed externally", license, etc.) a synchronous DTE COM call blocks inside
# XAE's modal message loop until a human clears it. The MCP bridge call — and
# therefore the agent — then hangs indefinitely. This watcher runs as a separate
# process alongside each bridge call: it spots the modal dialog, reports its
# title/body/buttons (so the agent learns what is blocking it), and — for
# dialogs explicitly listed in the allowlist — clicks the safe button to
# unblock the COM call automatically.
#
# Modes:
#   guard  (default) — loop until -StopFile appears or -DurationMs elapses,
#                      writing the current dialog snapshot (JSON) to -OutFile
#                      each poll. With -AutoDismiss, clicks allowlisted dialogs.
#   probe            — one-shot; print the current dialog snapshot to stdout.
#
# Detection is deliberately narrow: only a window that is (a) owned by the XAE
# process, (b) visible & enabled, and (c) whose OWNER window is disabled — the
# defining trait of an application-modal dialog. Docked tool windows and
# non-modal popups do not disable their owner, so they are ignored.

param(
    [ValidateSet('guard', 'probe')]
    [string]$Mode = 'guard',
    [string]$ProcessName = 'TcXaeShell',
    [string]$OutFile = '',
    [string]$StopFile = '',
    [string]$AllowlistPath = '',
    [switch]$AutoDismiss,
    [int]$PollMs = 750,
    [int]$DurationMs = 1800000
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if (-not ('DlgWatch' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public sealed class DlgWin {
    public long   Hwnd;
    public string Title = "";
    public string Text = "";
    public string Class = "";
    public List<string> Buttons = new List<string>();
}

public static class DlgWatch {
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

    static string ClassOf(IntPtr h) {
        var sb = new StringBuilder(256);
        GetClassName(h, sb, sb.Capacity);
        return sb.ToString();
    }

    // WM_GETTEXT works cross-process (the dialog's UI thread pumps the modal
    // loop and answers the message); GetWindowText does not for child controls.
    static string CtlText(IntPtr h) {
        int len = (int)SendMessage(h, WM_GETTEXTLENGTH, IntPtr.Zero, IntPtr.Zero);
        if (len <= 0) return "";
        var sb = new StringBuilder(len + 1);
        SendMessageStr(h, WM_GETTEXT, (IntPtr)(len + 1), sb);
        return sb.ToString();
    }

    public static List<DlgWin> Find(uint pid) {
        var res = new List<DlgWin>();
        EnumWindows((h, l) => {
            uint wp; GetWindowThreadProcessId(h, out wp);
            if (wp != pid) return true;
            if (!IsWindowVisible(h) || !IsWindowEnabled(h)) return true;
            IntPtr owner = GetWindow(h, GW_OWNER);
            if (owner == IntPtr.Zero || IsWindowEnabled(owner)) return true; // not application-modal
            var d = new DlgWin { Hwnd = h.ToInt64(), Title = CtlText(h), Class = ClassOf(h) };
            var body = new StringBuilder();
            EnumChildWindows(h, (c, l2) => {
                string cls = ClassOf(c);
                string t = CtlText(c);
                if (cls == "Button") {
                    if (!string.IsNullOrWhiteSpace(t)) d.Buttons.Add(t.Replace("&", "").Trim());
                } else if (cls == "Static" || cls == "RichEdit20W" || cls.StartsWith("Edit")) {
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

    public static bool Click(long hwnd, string label) {
        string want = (label ?? "").Replace("&", "").Trim().ToLowerInvariant();
        IntPtr btn = IntPtr.Zero;
        EnumChildWindows((IntPtr)hwnd, (c, l) => {
            if (ClassOf(c) == "Button" && CtlText(c).Replace("&", "").Trim().ToLowerInvariant() == want) {
                btn = c;
                return false;
            }
            return true;
        }, IntPtr.Zero);
        if (btn == IntPtr.Zero) return false;
        IntPtr dlg = (IntPtr)hwnd;
        // BM_CLICK alone is honored by true MessageBoxes but not by some themed VS/TcXaeShell
        // dialogs. Drive the dialog proc directly via WM_COMMAND(controlId, BN_CLICKED=0), and
        // add a simulated mouse down/up, then BM_CLICK as a fallback.
        int id = GetDlgCtrlID(btn);
        if (id != 0) SendMessage(dlg, WM_COMMAND, (IntPtr)(id & 0xFFFF), btn);
        SendMessage(btn, WM_LBUTTONDOWN, (IntPtr)1, IntPtr.Zero);
        SendMessage(btn, WM_LBUTTONUP, IntPtr.Zero, IntPtr.Zero);
        SendMessage(btn, BM_CLICK, IntPtr.Zero, IntPtr.Zero);
        return true;
    }
}
'@
}

function Get-Snapshot {
    param([switch]$DoDismiss, $Rules)

    $pids = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
    $dlg = $null
    foreach ($p in $pids) {
        $hits = [DlgWatch]::Find([uint32]$p)
        if ($hits.Count -gt 0) { $dlg = $hits[0]; break }
    }

    if ($null -eq $dlg) {
        return [ordered]@{ found = $false; blocking = $false; ts = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
    }

    $title = [string]$dlg.Title
    $text = [string]$dlg.Text
    $buttons = @($dlg.Buttons)
    $dismissed = $false
    $dismissedButton = $null

    if ($DoDismiss -and $Rules) {
        foreach ($r in $Rules) {
            if (-not $r.match) { continue }
            $titleOk = $title -match $r.match
            $textOk = (-not $r.textMatch) -or ($text -match $r.textMatch)
            if ($titleOk -and $textOk) {
                if ([DlgWatch]::Click([int64]$dlg.Hwnd, [string]$r.button)) {
                    $dismissed = $true
                    $dismissedButton = [string]$r.button
                }
                break
            }
        }
    }

    return [ordered]@{
        found           = $true
        blocking        = (-not $dismissed)
        dismissed       = $dismissed
        dismissedButton = $dismissedButton
        title           = $title
        text            = $text
        class           = [string]$dlg.Class
        buttons         = $buttons
        hwnd            = [int64]$dlg.Hwnd
        ts              = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    }
}

# Load allowlist rules (best-effort).
$rules = $null
if ($AllowlistPath -and (Test-Path -LiteralPath $AllowlistPath)) {
    try {
        $parsed = Get-Content -LiteralPath $AllowlistPath -Raw | ConvertFrom-Json
        if ($parsed.rules) { $rules = @($parsed.rules) }
    } catch {
        $rules = $null
    }
}

function Write-Snap($obj) {
    $json = $obj | ConvertTo-Json -Depth 6 -Compress
    $tmp = "$OutFile.tmp"
    Set-Content -LiteralPath $tmp -Value $json -Encoding UTF8 -NoNewline
    Move-Item -LiteralPath $tmp -Destination $OutFile -Force
}

if ($Mode -eq 'probe') {
    (Get-Snapshot -DoDismiss:$AutoDismiss -Rules $rules) | ConvertTo-Json -Depth 6 -Compress
    return
}

# guard
$deadline = (Get-Date).AddMilliseconds($DurationMs)
while ($true) {
    if ($StopFile -and (Test-Path -LiteralPath $StopFile)) { break }
    if ((Get-Date) -gt $deadline) { break }
    try {
        $snap = Get-Snapshot -DoDismiss:$AutoDismiss -Rules $rules
        if ($OutFile) { Write-Snap $snap }
    } catch {
        # transient (window vanished mid-enumerate, etc.) — keep watching
    }
    Start-Sleep -Milliseconds $PollMs
}
