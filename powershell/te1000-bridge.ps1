param(
    [Parameter(Mandatory = $true)]
    [string]$Action,

    [Parameter(Mandatory = $false)]
    [string]$PayloadBase64 = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Write-JsonResult([hashtable]$Result) {
    $json = $Result | ConvertTo-Json -Depth 20 -Compress
    [Console]::Out.WriteLine($json)
}

function Fail([string]$Message) {
    Write-JsonResult @{
        ok = $false
        error = $Message
    }
    exit 1
}

function Get-Payload {
    if ([string]::IsNullOrWhiteSpace($PayloadBase64)) {
        return @{}
    }

    $json = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($PayloadBase64))
    if ([string]::IsNullOrWhiteSpace($json)) {
        return @{}
    }

    $obj = $json | ConvertFrom-Json
    if ($null -eq $obj) {
        return @{}
    }

    return $obj
}

function Get-ErrorCode([System.Exception]$Exception) {
    if ($null -eq $Exception) {
        return ''
    }
    return ('0x{0:X8}' -f ($Exception.HResult -band 0xffffffff))
}

function Get-SafeValue {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock
    )

    try {
        Write-Output -NoEnumerate (& $ScriptBlock)
        return
    } catch {
        return $null
    }
}

function Get-XaePublicAssembliesPath {
    $candidates = @(
        'C:\Program Files (x86)\Beckhoff\TcXaeShell\Common7\IDE\PublicAssemblies',
        'C:\Program Files\Beckhoff\TcXaeShell\Common7\IDE\PublicAssemblies'
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath (Join-Path $candidate 'envdte.dll')) {
            return $candidate
        }
    }
    return $candidates[0]
}

function Ensure-VisualStudioInteropLoaded {
    $publicAssemblies = Get-XaePublicAssembliesPath
    $envDtePath = Join-Path $publicAssemblies 'envdte.dll'
    $envDte80Path = Join-Path $publicAssemblies 'envdte80.dll'

    if (-not (Test-Path -LiteralPath $envDtePath)) {
        throw "EnvDTE interop assembly not found: $envDtePath"
    }
    if (-not (Test-Path -LiteralPath $envDte80Path)) {
        throw "EnvDTE80 interop assembly not found: $envDte80Path"
    }

    $null = [System.Reflection.Assembly]::LoadFrom($envDtePath)
    $null = [System.Reflection.Assembly]::LoadFrom($envDte80Path)

    # VS2022-era shells (TcXaeShell 64) forward DTE/DTE2 types to Microsoft.VisualStudio.Interop.
    $vsInteropPath = Join-Path $publicAssemblies 'Microsoft.VisualStudio.Interop.dll'
    if (Test-Path -LiteralPath $vsInteropPath) {
        $null = [System.Reflection.Assembly]::LoadFrom($vsInteropPath)
    } else {
        $vsInteropPath = $null
    }

    return @{
        envDte = $envDtePath
        envDte80 = $envDte80Path
        vsInterop = $vsInteropPath
    }
}

function Get-InteropReferenceList {
    param([hashtable]$Assemblies)
    $refs = @($Assemblies.envDte, $Assemblies.envDte80)
    if ($Assemblies.vsInterop) {
        $refs += $Assemblies.vsInterop
    }
    return $refs
}

function Ensure-ComMessageFilter {
    # XAE/VS DTE rejects incoming COM calls while busy (RPC_E_CALL_REJECTED 0x80010001).
    # Beckhoff TE1000 docs require an IOleMessageFilter that retries rejected calls.
    if (-not ('Te1000MessageFilter' -as [type])) {
        $code = @"
using System;
using System.Runtime.InteropServices;

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
"@
        Add-Type -TypeDefinition $code
    }

    [Te1000MessageFilter]::Register()
}

function Ensure-XaeErrorListProbeType {
    if ('XaeErrorListProbe' -as [type]) {
        return
    }

    $assemblies = Ensure-VisualStudioInteropLoaded
    $code = @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;
using EnvDTE80;

public sealed class XaeErrorListItem
{
    public string Description { get; set; }
    public string FileName { get; set; }
    public int Line { get; set; }
    public int Column { get; set; }
    public string Project { get; set; }
    public string ErrorLevel { get; set; }
}

public sealed class XaeErrorListResult
{
    public int TotalCount { get; set; }
    public XaeErrorListItem[] Items { get; set; }
}

public static class XaeErrorListProbe
{
    public static XaeErrorListResult Read(string progId, int limit)
    {
        object raw = Marshal.GetActiveObject(progId);
        IntPtr pUnk = Marshal.GetIUnknownForObject(raw);
        try
        {
            DTE2 dte = (DTE2)Marshal.GetTypedObjectForIUnknown(pUnk, typeof(DTE2));
            dte.ExecuteCommand("View.ErrorList", " ");
            Thread.Sleep(1000);

            var errorList = dte.ToolWindows.ErrorList;
            if (errorList == null)
            {
                return null;
            }

            errorList.ShowErrors = true;
            errorList.ShowWarnings = true;
            errorList.ShowMessages = true;

            var errorItems = errorList.ErrorItems;
            int totalCount = errorItems.Count;
            int returnedCount = Math.Min(totalCount, limit);
            var results = new List<XaeErrorListItem>(returnedCount);

            for (int i = 1; i <= returnedCount; i++)
            {
                var item = errorItems.Item(i);
                results.Add(new XaeErrorListItem
                {
                    Description = item.Description,
                    FileName = item.FileName,
                    Line = item.Line,
                    Column = item.Column,
                    Project = item.Project,
                    ErrorLevel = item.ErrorLevel.ToString()
                });
            }

            return new XaeErrorListResult
            {
                TotalCount = totalCount,
                Items = results.ToArray()
            };
        }
        finally
        {
            if (pUnk != IntPtr.Zero)
            {
                Marshal.Release(pUnk);
            }
        }
    }
}
"@

    Add-Type -TypeDefinition $code -ReferencedAssemblies (Get-InteropReferenceList -Assemblies $assemblies)
}

function Ensure-DteRotProbeType {
    if ('DteRotProbe' -as [type]) {
        return
    }

    $assemblies = Ensure-VisualStudioInteropLoaded
    $code = @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using EnvDTE80;

public sealed class DteRotEntry
{
    public string DisplayName { get; set; }
    public string SolutionFullName { get; set; }
    public object Dte { get; set; }
}

public static class DteRotProbe
{
    [DllImport("ole32.dll")]
    private static extern int GetRunningObjectTable(int reserved, out IRunningObjectTable prot);

    [DllImport("ole32.dll")]
    private static extern int CreateBindCtx(int reserved, out IBindCtx ppbc);

    public static DteRotEntry[] List(string progId)
    {
        IRunningObjectTable rot;
        if (GetRunningObjectTable(0, out rot) != 0 || rot == null)
        {
            return new DteRotEntry[0];
        }

        IBindCtx bindCtx;
        if (CreateBindCtx(0, out bindCtx) != 0 || bindCtx == null)
        {
            return new DteRotEntry[0];
        }

        IEnumMoniker enumMoniker;
        rot.EnumRunning(out enumMoniker);
        if (enumMoniker == null)
        {
            return new DteRotEntry[0];
        }

        var result = new List<DteRotEntry>();
        IMoniker[] monikers = new IMoniker[1];
        IntPtr fetched = IntPtr.Zero;

        while (enumMoniker.Next(1, monikers, fetched) == 0)
        {
            string displayName = "";
            try
            {
                monikers[0].GetDisplayName(bindCtx, null, out displayName);
            }
            catch
            {
                displayName = "";
            }

            if (String.IsNullOrWhiteSpace(displayName) ||
                displayName.IndexOf(progId, StringComparison.OrdinalIgnoreCase) < 0)
            {
                continue;
            }

            object raw = null;
            try
            {
                rot.GetObject(monikers[0], out raw);
                DTE2 dte = raw as DTE2;
                if (dte == null)
                {
                    continue;
                }

                string solution = "";
                try
                {
                    solution = dte.Solution != null ? dte.Solution.FullName : "";
                }
                catch
                {
                    solution = "";
                }

                result.Add(new DteRotEntry
                {
                    DisplayName = displayName,
                    SolutionFullName = solution,
                    Dte = dte
                });
            }
            catch
            {
            }
        }

        return result.ToArray();
    }
}
"@

    Add-Type -TypeDefinition $code -ReferencedAssemblies (Get-InteropReferenceList -Assemblies $assemblies)
}

function Get-RunningDteEntries {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProgId
    )

    Ensure-DteRotProbeType
    return [DteRotProbe]::List($ProgId)
}

function Get-PreferredDteFromRot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProgId
    )

    $entries = @(Get-RunningDteEntries -ProgId $ProgId)
    if ($entries.Count -eq 0) {
        return $null
    }

    # Optional: set TE1000_MCP_SOLUTION_PATH to prefer a specific running
    # solution when several XAE shells are open. If unset, the first open
    # solution found is used.
    $preferredSolution = $env:TE1000_MCP_SOLUTION_PATH

    if (-not [string]::IsNullOrWhiteSpace($preferredSolution)) {
        foreach ($entry in $entries) {
            if (-not [string]::IsNullOrWhiteSpace($entry.SolutionFullName) -and
                [string]::Equals($entry.SolutionFullName, $preferredSolution, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $entry.Dte
            }
        }
    }

    foreach ($entry in $entries) {
        if (-not [string]::IsNullOrWhiteSpace($entry.SolutionFullName)) {
            return $entry.Dte
        }
    }

    return $entries[0].Dte
}

function Get-XaeErrorListItems {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProgId,

        [Parameter(Mandatory = $true)]
        [int]$Limit
    )

    Ensure-XaeErrorListProbeType
    return [XaeErrorListProbe]::Read($ProgId, $Limit)
}

function Normalize-ScalarValue {
    param(
        [Parameter(Mandatory = $false)]
        $Value
    )

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [System.Array]) {
        if ($Value.Count -gt 0) {
            Write-Output -NoEnumerate $Value[0]
            return
        }
        return $null
    }

    Write-Output -NoEnumerate $Value
    return
}

function Strip-TreeImage {
    param(
        [Parameter(Mandatory = $false)]
        [string]$Xml
    )

    if ([string]::IsNullOrEmpty($Xml)) {
        return $Xml
    }

    return [regex]::Replace($Xml, '<TreeImageData16x14>.*?</TreeImageData16x14>', '', 'Singleline')
}

function Get-TreeItemChildCount {
    param(
        [Parameter(Mandatory = $true)]
        [object]$TreeItem
    )

    $value = Normalize-ScalarValue (Get-SafeValue { $TreeItem.ChildCount })
    if ($null -eq $value) {
        return 0
    }
    return [int]$value
}

function Get-TreeItemChild {
    param(
        [Parameter(Mandatory = $true)]
        [object]$TreeItem,

        [Parameter(Mandatory = $true)]
        [int]$Index
    )

    try {
        $item = $TreeItem.Child($Index)
    } catch {
        $item = $null
    }
    Write-Output -NoEnumerate ([ref]$item)
    return
}

function Is-RetryableComError([System.Exception]$Exception) {
    if ($null -eq $Exception) {
        return $false
    }

    $code = $Exception.HResult
    return $code -eq -2147418111 -or $code -eq -2147023174
}

function Invoke-WithRetry {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock,

        [int]$Attempts = 30,

        [int]$DelayMs = 500
    )

    for ($i = 1; $i -le $Attempts; $i++) {
        try {
            Write-Output -NoEnumerate (& $ScriptBlock)
            return
        } catch {
            if ((Is-RetryableComError $_.Exception) -and $i -lt $Attempts) {
                Start-Sleep -Milliseconds $DelayMs
                continue
            }
            throw
        }
    }
}

function Get-Dte {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProgId,

        [Parameter(Mandatory = $true)]
        [string]$Mode,

        [bool]$Visible = $true
    )

    switch ($Mode) {
        'active' {
            $dte = Get-PreferredDteFromRot -ProgId $ProgId
            if ($null -ne $dte) {
                return $dte
            }
            return [System.Runtime.InteropServices.Marshal]::GetActiveObject($ProgId)
        }
        'create' {
            $dte = New-Object -ComObject $ProgId
            try {
                $dte.SuppressUI = $true
            } catch {
            }
            try {
                $dte.MainWindow.Visible = $Visible
            } catch {
            }
            return $dte
        }
        'activeOrCreate' {
            try {
                $dte = Get-PreferredDteFromRot -ProgId $ProgId
                if ($null -ne $dte) {
                    return $dte
                }
                return [System.Runtime.InteropServices.Marshal]::GetActiveObject($ProgId)
            } catch {
                return Get-Dte -ProgId $ProgId -Mode 'create' -Visible $Visible
            }
        }
        default {
            throw "Unsupported DTE mode: $Mode"
        }
    }
}

function Get-SolutionInfo($Dte) {
    $solution = $Dte.Solution
    $fullName = $null
    $isOpen = $false

    try {
        $fullName = $solution.FullName
    } catch {
    }

    try {
        $isOpen = $solution.IsOpen
    } catch {
        $isOpen = -not [string]::IsNullOrWhiteSpace($fullName)
    }

    return @{
        isOpen = [bool]$isOpen
        fullName = $fullName
    }
}

# Save the whole solution once (same mechanism as the xae_save_all action).
# Used by the opt-in save:true on mutating batch ops so the caller doesn't have
# to make a separate xae save_all round-trip after a bulk mutation.
function Save-Solution($Dte) {
    $Dte.ExecuteCommand('File.SaveAll')
}

function Wait-ForSolutionOpen($Dte, [string]$ExpectedPath) {
    return Invoke-WithRetry -Attempts 60 -DelayMs 500 -ScriptBlock {
        $info = Get-SolutionInfo -Dte $Dte
        if (-not $info.isOpen) {
            throw "Solution is not open yet"
        }
        if (-not [string]::IsNullOrWhiteSpace($ExpectedPath) -and $info.fullName -ne $ExpectedPath) {
            throw "Different solution is active: $($info.fullName)"
        }
        return $info
    }
}

function Get-SysManager($Dte) {
    for ($attempt = 1; $attempt -le 40; $attempt++) {
        try {
            $solution = $Dte.Solution
            if ($null -ne $solution -and $null -ne $solution.Projects) {
                for ($i = 1; $i -le $solution.Projects.Count; $i++) {
                    $project = $solution.Projects.Item($i)
                    if ($null -eq $project) {
                        continue
                    }

                    $fullName = $null
                    try {
                        $fullName = [string]$project.FullName
                    } catch {
                    }
                    if ([string]::IsNullOrWhiteSpace($fullName) -or -not $fullName.EndsWith('.tsproj', [System.StringComparison]::OrdinalIgnoreCase)) {
                        continue
                    }

                    $projectObject = $null
                    try {
                        $projectObject = $project.Object
                    } catch {
                    }
                    if ($null -eq $projectObject) {
                        continue
                    }

                    # In some XAE sessions DTE.GetObject('TcSysManager') returns a stale
                    # COM wrapper. The TwinCAT project object is the same automation
                    # surface, but remains bound to the loaded .tsproj.
                    $probe = Get-SafeValue { $projectObject.GetTargetNetId() }
                    if ($null -ne $probe) {
                        Write-Output -NoEnumerate ([ref]$projectObject)
                        return
                    }
                }
            }
        $sm = $Dte.GetObject('TcSysManager')
        if ($null -eq $sm) {
            throw 'TcSysManager is null'
        }
        Write-Output -NoEnumerate ([ref]$sm)
        return
        } catch {
            if ((Is-RetryableComError $_.Exception) -and $attempt -lt 40) {
                Start-Sleep -Milliseconds 500
                continue
            }
            throw
        }
    }
}

function Wait-ForBuildFinish($SolutionBuild, [int]$TimeoutMs) {
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)

    while ((Get-Date) -lt $deadline) {
        $state = $SolutionBuild.BuildState
        if ([int]$state -ne 2) {
            return @{
                buildState = [int]$state
                lastBuildInfo = [int]$SolutionBuild.LastBuildInfo
            }
        }
        Start-Sleep -Milliseconds 500
    }

    throw "Timed out waiting for build completion after $TimeoutMs ms"
}

function Get-AutomationSettings($Dte) {
    return Invoke-WithRetry -Attempts 20 -DelayMs 250 -ScriptBlock {
        $settings = $Dte.GetObject('TcAutomationSettings')
        if ($null -eq $settings) {
            throw 'TcAutomationSettings is null'
        }
        return $settings
    }
}

function Invoke-DteCommand {
    param(
        [Parameter(Mandatory = $true)]
        $Dte,

        [Parameter(Mandatory = $true)]
        [string]$CommandName
    )

    if ([string]::IsNullOrWhiteSpace($CommandName)) {
        throw 'CommandName is required'
    }

    $null = Get-AutomationSettings -Dte $Dte
    try {
        $cmd = $Dte.Commands.Item($CommandName, 0)
    } catch {
        throw "Command lookup failed for '$CommandName': $($_.Exception.Message)"
    }

    if ($null -eq $cmd) {
        throw "Command not found: $CommandName"
    }

    $isAvailable = $true
    try {
        $isAvailable = [bool]$cmd.IsAvailable
    } catch {
    }

    if (-not $isAvailable) {
        throw "Command is not available in the current XAE context: $CommandName"
    }

    try {
        $Dte.ExecuteCommand($CommandName)
    } catch {
        throw "ExecuteCommand failed for '$CommandName': $($_.Exception.Message)"
    }

    return @{
        commandName = $CommandName
        isAvailable = $isAvailable
        executed = $true
    }
}

function Get-TcSysManagerLibPath {
    $candidates = @(
        'C:\Program Files (x86)\Beckhoff\TwinCAT\Functions\TE2000-HMI-Engineering\VisualStudio\TcXaeShell\TCatSysManagerLib.dll',
        'C:\Program Files (x86)\Beckhoff\TwinCAT\Functions\TE2000-HMI-Engineering\VisualStudio\2026\TCatSysManagerLib.dll',
        'C:\Program Files (x86)\Beckhoff\TwinCAT\Functions\TE2000-HMI-Engineering\VisualStudio\2022\TCatSysManagerLib.dll',
        'C:\Program Files (x86)\Beckhoff\TwinCAT\Functions\TE2000-HMI-Engineering\VisualStudio\2019\TCatSysManagerLib.dll',
        'C:\Program Files (x86)\Beckhoff\TwinCAT\Functions\TE2000-HMI-Engineering\VisualStudio\2017\TCatSysManagerLib.dll'
    )
    foreach ($path in $candidates) {
        if (Test-Path -LiteralPath $path) {
            return $path
        }
    }
    return $null
}

function Ensure-TcPlcProjectHelper {
    # ITcPlcProject is a vtable (IUnknown) interface; PowerShell cannot cast a
    # __ComObject to it ([Interface]$obj is not a CLR QI in PS), so the QI and
    # member calls are done in a small compiled C# helper instead. Note the
    # interface lives on the PLC root node (TIPC^<name>); QI also requires the
    # interface to be registered in the 64-bit registry view for marshaling.
    if ('Te1000PlcProjectHelper' -as [type]) {
        return $true
    }
    $libPath = Get-TcSysManagerLibPath
    if (-not $libPath) {
        return $false
    }
    $null = [System.Reflection.Assembly]::LoadFrom($libPath)
    Add-Type -ReferencedAssemblies $libPath -TypeDefinition @'
using System;
using TCatSysManagerLib;
public static class Te1000PlcProjectHelper {
    public static bool GetAutostart(object plcProject) {
        return ((ITcPlcProject)plcProject).BootProjectAutostart;
    }
    public static void Deploy(object plcProject, bool autostart, bool activate) {
        ITcPlcProject typed = (ITcPlcProject)plcProject;
        typed.BootProjectAutostart = autostart;
        typed.GenerateBootProject(activate);
    }

    // --- plc_project tool: typed (vtable QI) members PowerShell cannot reach ---
    // ITcPlcProject lives on the PLC ROOT node (TIPC^<name>); set config-only flags.
    public static object[] SetBootFlags(object plcProject, bool hasAutostart, bool autostart, bool hasTmc, bool tmc) {
        ITcPlcProject typed = (ITcPlcProject)plcProject;
        if (hasAutostart) { typed.BootProjectAutostart = autostart; }
        if (hasTmc) { typed.TmcFileCopy = tmc; }
        return new object[] { typed.BootProjectAutostart, typed.TmcFileCopy };
    }

    // CheckAllObjects (build-validate) lives on ITcPlcIECProject2 on the nested
    // project INSTANCE node.
    public static bool CheckAll(object iecProject) {
        return ((ITcPlcIECProject2)iecProject).CheckAllObjects();
    }

    // ITcProjectRoot.NestedProject is the documented identity read on the PLC root.
    public static string GetNestedProjectName(object projectRoot) {
        try {
            ITcProjectRoot typed = (ITcProjectRoot)projectRoot;
            object nested = typed.NestedProject;
            if (nested == null) { return null; }
            return ((ITcSmTreeItem)nested).Name;
        } catch { return null; }
    }

    // First child of the PLC root is the project instance node ('<name> Project').
    public static string GetInstanceName(object treeItem) {
        try {
            ITcSmTreeItem typed = (ITcSmTreeItem)treeItem;
            if (typed.ChildCount < 1) { return null; }
            ITcSmTreeItem child = typed.get_Child(1);
            return child == null ? null : child.Name;
        } catch { return null; }
    }

    // ITcPlcTaskReference lives on the PlcTask node under the project instance.
    public static string SetLinkedTask(object taskRef, string taskPath) {
        ITcPlcTaskReference typed = (ITcPlcTaskReference)taskRef;
        typed.LinkedTask = taskPath;
        return typed.LinkedTask;
    }

    // ITcPlcIECProject on the project INSTANCE node: PLCopen + library.
    public static void PlcOpenExport(object iecProject, string file, string selection) {
        ((ITcPlcIECProject)iecProject).PlcOpenExport(file, selection);
    }
    public static void PlcOpenImport(object iecProject, string file, int options, string selection, bool folderStructure) {
        // Installed interop: ITcPlcIECProject.PlcOpenImport(string, Int32, string, bool).
        // The options parameter is a plain Int32 (PLCIMPORTOPTIONS enum: 0 NONE/1 REPLACE/2 RENAME/3 SKIP),
        // NOT a 'PlcImportOptions' type (that name does not exist in this TCatSysManagerLib build).
        ((ITcPlcIECProject)iecProject).PlcOpenImport(file, options, selection, folderStructure);
    }
    public static void SaveAsLibrary(object iecProject, string file, bool install) {
        ((ITcPlcIECProject)iecProject).SaveAsLibrary(file, install);
    }
}
'@
    return $null -ne ('Te1000PlcProjectHelper' -as [type])
}

# --- tc_measurement helpers ------------------------------------------------
# Resolve the TE130X Scope View Automation Interface assembly. The product may
# not be installed (then this returns $null and the scope actions fail with a
# clear 'tooling not installed' message rather than a raw COM HRESULT).
function Get-MeasurementLibPath {
    $name = 'TwinCAT.Measurement.AutomationInterface.dll'
    $dirs = @(
        'C:\TwinCAT\Functions\TE130X-Scope-View',
        'C:\Program Files (x86)\Beckhoff\TwinCAT\Functions\TE130X-Scope-View',
        'C:\Program Files\Beckhoff\TwinCAT\Functions\TE130X-Scope-View',
        (Get-XaePublicAssembliesPath)
    )
    foreach ($dir in $dirs) {
        if ([string]::IsNullOrWhiteSpace($dir) -or -not (Test-Path -LiteralPath $dir)) { continue }
        $direct = Join-Path $dir $name
        if (Test-Path -LiteralPath $direct) { return $direct }
        $hit = Get-ChildItem -LiteralPath $dir -Filter $name -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $hit) { return $hit.FullName }
    }
    return $null
}

# Resolve a Scope project template (.tcmproj). The leaf filename varies by
# install/version, so probe the Templates\Projects dir rather than hardcode it.
function Get-ScopeTemplatePath {
    $dirs = @(
        'C:\TwinCAT\Functions\TE130X-Scope-View\Templates\Projects',
        'C:\Program Files (x86)\Beckhoff\TwinCAT\Functions\TE130X-Scope-View\Templates\Projects',
        'C:\Program Files\Beckhoff\TwinCAT\Functions\TE130X-Scope-View\Templates\Projects'
    )
    foreach ($dir in $dirs) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        $hit = Get-ChildItem -LiteralPath $dir -Filter '*.tcmproj' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $hit) { return $hit.FullName }
    }
    return $null
}

# Resolve a TwinCAT Analytics project template. The exact leaf filename is not
# documented, so probe the known Analytics product template dirs.
function Get-AnalyticsTemplatePath {
    $roots = @(
        'C:\TwinCAT\Functions\TE3500-Analytics-Workbench',
        'C:\TwinCAT\Functions\TE3520-Analytics-Service-Tool',
        'C:\Program Files (x86)\Beckhoff\TwinCAT\Functions\TE3500-Analytics-Workbench',
        'C:\Program Files (x86)\Beckhoff\TwinCAT\Functions\TE3520-Analytics-Service-Tool'
    )
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($pat in @('*.tcaproj', '*.tcanalyticsproj', '*.tsproj')) {
            $hit = Get-ChildItem -LiteralPath $root -Filter $pat -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -match '[\\/]Templates[\\/]' } | Select-Object -First 1
            if ($null -ne $hit) { return $hit.FullName }
        }
    }
    return $null
}

# IMeasurementScope is a vtable (IUnknown-derived) interface; PowerShell cannot
# QI a __ComObject to it ([Interface]$obj is not a CLR QI in PS), so the member
# calls go through a compiled C# helper, exactly as Te1000PlcProjectHelper does
# for ITcPlcProject. Because the exact interface namespace is not documented and
# the TE130X product may be absent here, the shim discovers the IMeasurementScope
# interface type by name from the loaded assembly via reflection and invokes its
# members by name (CreateChild/ChangeName/StartRecord/StopRecord) — the VERIFIED
# surface only. Returns $false if the assembly can't be loaded (callers then
# throw a clear 'TE130X Scope automation assembly not found' error).
# NOTE: SaveSVD/ExportCSV/LookUpChild are deliberately NOT exposed (UNVERIFIED).
function Ensure-MeasurementScopeHelper {
    if ('Te1000MeasurementHelper' -as [type]) {
        return $true
    }
    $libPath = Get-MeasurementLibPath
    if (-not $libPath) {
        return $false
    }
    try {
        $null = [System.Reflection.Assembly]::LoadFrom($libPath)
    } catch {
        return $false
    }
    Add-Type -TypeDefinition @'
using System;
using System.Linq;
using System.Reflection;
public static class Te1000MeasurementHelper {
    // Find the IMeasurementScope interface across all loaded assemblies.
    static Type ScopeType() {
        foreach (Assembly a in AppDomain.CurrentDomain.GetAssemblies()) {
            Type t = null;
            try { t = a.GetTypes().FirstOrDefault(x => x.IsInterface && x.Name == "IMeasurementScope"); }
            catch { t = null; }
            if (t != null) return t;
        }
        return null;
    }
    public static bool Is(object o) {
        if (o == null) return false;
        Type t = ScopeType();
        return t != null && t.IsInstanceOfType(o);
    }
    // CreateChild(out object item, string name, int elementType) -> int rc.
    public static int CreateChild(object scope, out object child, string name, int elementType) {
        child = null;
        Type t = ScopeType();
        if (t == null) throw new InvalidOperationException("IMeasurementScope type not found");
        MethodInfo m = t.GetMethod("CreateChild");
        if (m == null) throw new MissingMethodException("IMeasurementScope.CreateChild");
        object[] args = new object[] { null, name == null ? "" : name, elementType };
        object rc = m.Invoke(scope, args);
        child = args[0];
        return rc == null ? 0 : Convert.ToInt32(rc);
    }
    public static int ChangeName(object el, string n) {
        Type t = ScopeType();
        MethodInfo m = t.GetMethod("ChangeName");
        if (m == null) throw new MissingMethodException("IMeasurementScope.ChangeName");
        object rc = m.Invoke(el, new object[] { n });
        return rc == null ? 0 : Convert.ToInt32(rc);
    }
    public static int StartRecord(object s) {
        Type t = ScopeType();
        MethodInfo m = t.GetMethod("StartRecord");
        if (m == null) throw new MissingMethodException("IMeasurementScope.StartRecord");
        object rc = m.Invoke(s, null);
        return rc == null ? 0 : Convert.ToInt32(rc);
    }
    public static int StopRecord(object s) {
        Type t = ScopeType();
        MethodInfo m = t.GetMethod("StopRecord");
        if (m == null) throw new MissingMethodException("IMeasurementScope.StopRecord");
        object rc = m.Invoke(s, null);
        return rc == null ? 0 : Convert.ToInt32(rc);
    }
    // Enumerate a parent scope element's children (for name-walking parentPath).
    // Tries common collection members; returns an empty array if none resolve.
    public static object[] Children(object el) {
        if (el == null) return new object[0];
        Type t = el.GetType();
        foreach (string p in new string[] { "Children", "ChildCollection", "Items" }) {
            try {
                PropertyInfo pi = t.GetProperty(p);
                if (pi != null) {
                    object col = pi.GetValue(el, null);
                    if (col is System.Collections.IEnumerable) {
                        return ((System.Collections.IEnumerable)col).Cast<object>().ToArray();
                    }
                }
            } catch { }
        }
        return new object[0];
    }
    public static string NameOf(object el) {
        if (el == null) return null;
        try {
            PropertyInfo pi = el.GetType().GetProperty("Name");
            if (pi != null) { object v = pi.GetValue(el, null); return v == null ? null : v.ToString(); }
        } catch { }
        return null;
    }
}
'@
    return $null -ne ('Te1000MeasurementHelper' -as [type])
}

# Locate a Scope/Analytics EnvDTE.Project by Name in the open solution and return
# its .Object (the IMeasurementScope-capable automation object). These projects
# are SEPARATE EnvDTE.Project nodes, NOT System Manager tree items.
function Get-ScopeProjectObject($Dte, [string]$ProjectName) {
    if ([string]::IsNullOrWhiteSpace($ProjectName)) { throw 'project is required' }
    $solution = $Dte.Solution
    if ($null -eq $solution -or -not [bool]$solution.IsOpen) {
        throw 'No solution is open'
    }
    $projects = $solution.Projects
    if ($null -ne $projects) {
        for ($i = 1; $i -le $projects.Count; $i++) {
            $proj = $null
            try { $proj = $projects.Item($i) } catch { continue }
            if ($null -eq $proj) { continue }
            $pname = Get-SafeValue { [string]$proj.Name }
            if ($pname -eq $ProjectName) {
                $obj = $null
                try { $obj = $proj.Object } catch { }
                if ($null -eq $obj) { throw "Scope project '$ProjectName' has no automation object (.Object is null)" }
                return $obj
            }
        }
    }
    throw "Scope project not found in the open solution: $ProjectName"
}

# Walk a ^-separated parentPath of element names from a scope root object,
# resolving each segment by enumerating the parent's children by name. Returns
# the resolved parent object (the root itself when parentPath is empty).
# NOTE: LookUpChild is UNVERIFIED; resolution is by enumeration only.
function Resolve-ScopeElement($Root, [string]$ElementPath) {
    $current = $Root
    if ([string]::IsNullOrWhiteSpace($ElementPath)) { return $current }
    $segments = $ElementPath -split '\^'
    foreach ($seg in $segments) {
        if ([string]::IsNullOrWhiteSpace($seg)) { continue }
        $children = [Te1000MeasurementHelper]::Children($current)
        $match = $null
        foreach ($c in $children) {
            $cn = [Te1000MeasurementHelper]::NameOf($c)
            if ($cn -eq $seg) { $match = $c; break }
        }
        if ($null -eq $match) {
            throw "Scope element segment not found by name: '$seg' (path '$ElementPath'). Child enumeration is the only verified resolution; LookUpChild is unsupported. Restrict the path to existing named children."
        }
        $current = $match
    }
    return $current
}

function Ensure-TcPlcTaskRefHelper {
    # ITcPlcTaskReference is a vtable (IUnknown) interface; PowerShell cannot QI a
    # __ComObject to it ([Interface]$obj is not a CLR QI in PS), so the LinkedTask
    # get/set is done in a compiled C# helper, exactly as Te1000PlcProjectHelper does
    # for ITcPlcProject. The interface lives on the PLC project root/instance node
    # (TIPC^<name>); QI/marshaling also requires the interface registered in the
    # 64-bit registry view. Returns $false if TCatSysManagerLib.dll is unavailable.
    if ('Te1000PlcTaskRefHelper' -as [type]) {
        return $true
    }
    $libPath = Get-TcSysManagerLibPath
    if (-not $libPath) {
        return $false
    }
    $null = [System.Reflection.Assembly]::LoadFrom($libPath)
    Add-Type -ReferencedAssemblies $libPath -TypeDefinition @'
using System;
using TCatSysManagerLib;
public static class Te1000PlcTaskRefHelper {
    public static string GetLinkedTask(object n) {
        return ((ITcPlcTaskReference)n).LinkedTask;
    }
    public static void SetLinkedTask(object n, string t) {
        ((ITcPlcTaskReference)n).LinkedTask = t;
    }
}
'@
    return $null -ne ('Te1000PlcTaskRefHelper' -as [type])
}

function Ensure-Te1000ModuleHelper {
    # ITcSysManager3.GetModuleManager(), ITcModuleManager3 enumeration, and
    # ITcModuleInstance2.SetModuleContext are vtable (IUnknown) calls; PowerShell
    # cannot QI a __ComObject to those interfaces nor enumerate them, so the work
    # is done in a compiled C# helper, exactly as Te1000PlcProjectHelper does for
    # ITcPlcProject. Requires TCatSysManagerLib.dll and the interfaces registered
    # in the 64-bit registry view for marshaling. Returns $false if the DLL is
    # unavailable.
    if ('Te1000ModuleHelper' -as [type]) {
        return $true
    }
    $libPath = Get-TcSysManagerLibPath
    if (-not $libPath) {
        return $false
    }
    $null = [System.Reflection.Assembly]::LoadFrom($libPath)
    Add-Type -ReferencedAssemblies $libPath -TypeDefinition @'
using System;
using System.Collections.Generic;
using TCatSysManagerLib;
public static class Te1000ModuleHelper {
    // GetModuleManager() is on ITcSysManager4+ (NOT on ITcSysManager3 -- it has no
    // such member on this installed TCatSysManagerLib). It returns ITcModuleManager,
    // which we QI to ITcModuleManager3 to enumerate the module instances under
    // TIRC^TcCOM Objects. The enumerator yields ITcModuleInstance2 elements, which
    // expose ModuleTypeName/ModuleInstanceName/ClassID/oid/ParentOID. There is no
    // 'ObjectId' member on this build, so objectId is reported as the same value as
    // oid (XAE merely displays it in hex). oids are decimal. An empty cell (no TcCOM
    // module instances) yields an empty list, not an error.
    public static object[] List(object sysManager) {
        ITcSysManager4 sm = (ITcSysManager4)sysManager;
        ITcModuleManager3 mgr = (ITcModuleManager3)sm.GetModuleManager();
        List<object> list = new List<object>();
        foreach (object o in mgr) {
            ITcModuleInstance2 mi = o as ITcModuleInstance2;
            if (mi == null) { continue; }
            uint oid = mi.oid;
            list.Add(new object[] {
                mi.ModuleTypeName,
                mi.ModuleInstanceName,
                mi.ClassID.ToString(),
                oid,
                oid,
                mi.ParentOID
            });
        }
        return list.ToArray();
    }

    // Assign a module instance to a task's execution context. taskObjectId and
    // contextId are DECIMAL oids (XAE displays them in hex). Changes the
    // activated mapping/runtime context -> guarded in index.js.
    public static void SetContext(object moduleInstance, int contextId, int taskObjectId) {
        // Installed ITcModuleInstance2.SetModuleContext takes (UInt32 contextId, UInt32 taskObjectId).
        ((ITcModuleInstance2)moduleInstance).SetModuleContext((uint)contextId, (uint)taskObjectId);
    }
}
'@
    return $null -ne ('Te1000ModuleHelper' -as [type])
}

# Resolve the PLC project root node path under TIPC. Defaults to the first child
# of TIPC (TIPC^<name>). Shared by tc_task get/set_linked_task.
function Resolve-PlcRootPath {
    param(
        [Parameter(Mandatory = $true)] $SysManager,
        [AllowNull()][string]$Path
    )
    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        return $Path
    }
    $tipc = $SysManager.LookupTreeItem('TIPC')
    if ([int]$tipc.ChildCount -lt 1) {
        throw 'No PLC project found under TIPC'
    }
    return "TIPC^$([string]$tipc.Child(1).Name)"
}

# Build the ordered list of candidate tree PATHS (strings, NOT cached RCWs) that
# might implement ITcPlcTaskReference (GetLinkedTask/SetLinkedTask). That interface
# is NOT on the PLC ROOT (TIPC^<name>) -- it lives on a task-reference sub-node
# (e.g. 'PlcTask') under the nested IEC PROJECT node ('<name> Project'). This mirrors
# the plc_pou check_objects resolution: emit candidate PATHS and let the caller
# LookupTreeItem a FRESH RCW per attempt (looping over cached RCWs QI-fails
# E_NOINTERFACE). When $Path is supplied it is used as-is (single candidate).
function Resolve-PlcTaskRefCandidates {
    param(
        [Parameter(Mandatory = $true)] $SysManager,
        [AllowNull()][string]$Path
    )
    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        return , @($Path)
    }
    $plcPath = Resolve-PlcRootPath -SysManager $SysManager -Path $null
    $root = (Get-TreeItem -SysManager $SysManager -TreePath $plcPath).Value
    $rootName = Normalize-ScalarValue (Get-SafeValue { [string]$root.Name })

    $candidatePaths = New-Object System.Collections.ArrayList

    # The task-reference node lives under the '<name> Project' node. Probe its
    # children (a 'PlcTask'-named child first, then any other child) before falling
    # back to the project/instance/root nodes. Paths are resolved by name later.
    $projectPaths = New-Object System.Collections.ArrayList
    if (-not [string]::IsNullOrWhiteSpace($rootName)) {
        [void]$projectPaths.Add("$plcPath^$rootName Project")
    }
    $rootChildCount = Get-TreeItemChildCount -TreeItem $root
    for ($ri = 1; $ri -le $rootChildCount; $ri++) {
        $rc = (Get-SafeValue { (Get-TreeItemChild -TreeItem $root -Index $ri).Value })
        if ($null -ne $rc) {
            $rcn = Normalize-ScalarValue (Get-SafeValue { [string]$rc.Name })
            if (-not [string]::IsNullOrWhiteSpace($rcn)) {
                $rcp = "$plcPath^$rcn"
                if (-not $projectPaths.Contains($rcp)) { [void]$projectPaths.Add($rcp) }
            }
        }
    }

    foreach ($projPath in $projectPaths) {
        $projNode = (Get-SafeValue { (Get-TreeItem -SysManager $SysManager -TreePath $projPath).Value })
        if ($null -eq $projNode) { continue }
        $named = New-Object System.Collections.ArrayList
        $other = New-Object System.Collections.ArrayList

        # Enumerate the project node's children. .Child() enumeration can disagree
        # with LookupTreeItem-by-name on some shells, so we resolve each candidate by
        # NAME-PATH later; here we only collect the child names.
        $childCount = Get-TreeItemChildCount -TreeItem $projNode
        for ($ci = 1; $ci -le $childCount; $ci++) {
            $childNode = (Get-SafeValue { (Get-TreeItemChild -TreeItem $projNode -Index $ci).Value })
            if ($null -eq $childNode) { continue }
            $cn = Normalize-ScalarValue (Get-SafeValue { [string]$childNode.Name })
            if ([string]::IsNullOrWhiteSpace($cn)) { continue }
            $cp = "$projPath^$cn"
            if ($cn -eq 'PlcTask') { [void]$named.Add($cp) } else { [void]$other.Add($cp) }
        }

        # Always also probe the well-known task-reference child names by path, in case
        # .Child() enumeration did not surface them (LookupTreeItem resolves by name).
        foreach ($wk in @('PlcTask', 'VISU_TASK')) {
            $wkp = "$projPath^$wk"
            if ((-not $named.Contains($wkp)) -and (-not $other.Contains($wkp))) {
                if ($wk -eq 'PlcTask') { [void]$named.Add($wkp) } else { [void]$other.Add($wkp) }
            }
        }

        foreach ($p in $named) { if (-not $candidatePaths.Contains($p)) { [void]$candidatePaths.Add($p) } }
        foreach ($p in $other) { if (-not $candidatePaths.Contains($p)) { [void]$candidatePaths.Add($p) } }
    }

    # Fall back to the project/instance/root nodes themselves (older layouts).
    foreach ($p in $projectPaths) { if (-not $candidatePaths.Contains($p)) { [void]$candidatePaths.Add($p) } }
    if (-not $candidatePaths.Contains($plcPath)) { [void]$candidatePaths.Add($plcPath) }

    if ($candidatePaths.Count -lt 1) {
        throw "No task-reference node found under PLC project '$plcPath' (nothing implementing ITcPlcTaskReference)"
    }
    return , @($candidatePaths.ToArray())
}

# Map a CpuAffinity name (or pass through a raw #x.. hex token) to a TwinCAT
# affinity token #x{16 hex}. Used by tc_task_bind_cpu.
function Convert-CpuAffinity {
    param([Parameter(Mandatory = $true)][string]$Affinity)
    $a = $Affinity.Trim()
    if ($a -match '^#x') {
        return $a
    }
    $cpu1 = [uint64]0x1; $cpu2 = [uint64]0x2; $cpu3 = [uint64]0x4; $cpu4 = [uint64]0x8
    $cpu5 = [uint64]0x10; $cpu6 = [uint64]0x20; $cpu7 = [uint64]0x40; $cpu8 = [uint64]0x80
    $mask = $null
    switch ($a.ToUpperInvariant()) {
        'NONE'      { $mask = [uint64]0 }
        'CPU1'      { $mask = $cpu1 }
        'CPU2'      { $mask = $cpu2 }
        'CPU3'      { $mask = $cpu3 }
        'CPU4'      { $mask = $cpu4 }
        'CPU5'      { $mask = $cpu5 }
        'CPU6'      { $mask = $cpu6 }
        'CPU7'      { $mask = $cpu7 }
        'CPU8'      { $mask = $cpu8 }
        'MASKSINGLE' { $mask = $cpu1 }
        'MASKDUAL'  { $mask = $cpu1 -bor $cpu2 }
        'MASKQUAD'  { $mask = $cpu1 -bor $cpu2 -bor $cpu3 -bor $cpu4 }
        'MASKHEXA'  { $mask = $cpu1 -bor $cpu2 -bor $cpu3 -bor $cpu4 -bor $cpu5 -bor $cpu6 }
        'MASKOCT'   { $mask = $cpu1 -bor $cpu2 -bor $cpu3 -bor $cpu4 -bor $cpu5 -bor $cpu6 -bor $cpu7 -bor $cpu8 }
        'MASKALL'   { $mask = [uint64]::MaxValue }
        default {
            throw "Unrecognized affinity '$Affinity'. Use a name (CPU1..CPU8, MaskSingle/Dual/Quad/Hexa/Oct/All, None) or a raw #x.. hex token."
        }
    }
    return ('#x{0:x16}' -f $mask)
}

# XML-escape a scalar value for safe inclusion in a ConsumeXml envelope.
function ConvertTo-XmlText([AllowNull()]$Value) {
    if ($null -eq $Value) { return '' }
    return ([string]$Value).Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
}

function Ensure-TcPlcPouHelper {
    # ITcPlcPou / ITcPlcDeclaration / ITcPlcImplementation / ITcPlcIECProject2 are
    # vtable (IUnknown) interfaces; PowerShell cannot QI a __ComObject to them
    # ([Interface]$obj is not a CLR QI in PS), so the declaration/implementation/
    # document accessors are done in a compiled C# helper, exactly as
    # Te1000PlcProjectHelper does for ITcPlcProject. Requires TCatSysManagerLib.dll
    # and the interfaces registered in the 64-bit registry view for marshaling.
    if ('Te1000PlcPouHelper' -as [type]) {
        return $true
    }
    $libPath = Get-TcSysManagerLibPath
    if (-not $libPath) {
        return $false
    }
    $null = [System.Reflection.Assembly]::LoadFrom($libPath)
    Add-Type -ReferencedAssemblies $libPath -TypeDefinition @'
using System;
using TCatSysManagerLib;
public static class Te1000PlcPouHelper {
    public static string GetDeclaration(object o) {
        return ((ITcPlcDeclaration)o).DeclarationText;
    }
    public static void SetDeclaration(object o, string s) {
        ((ITcPlcDeclaration)o).DeclarationText = s;
    }
    public static string GetImplementation(object o) {
        return ((ITcPlcImplementation)o).ImplementationText;
    }
    public static int GetImplementationLanguage(object o) {
        return (int)((ITcPlcImplementation)o).Language;
    }
    public static void SetImplementationText(object o, string s) {
        ((ITcPlcImplementation)o).ImplementationText = s;
    }
    public static void SetImplementationXml(object o, string s) {
        ((ITcPlcImplementation)o).ImplementationXml = s;
    }
    public static string GetImplementationXml(object o) {
        return ((ITcPlcImplementation)o).ImplementationXml;
    }
    public static string GetDocumentXml(object o) {
        return ((ITcPlcPou)o).DocumentXml;
    }
    public static void SetDocumentXml(object o, string s) {
        ((ITcPlcPou)o).DocumentXml = s;
    }
    public static bool CheckAllObjects(object o) {
        return ((ITcPlcIECProject2)o).CheckAllObjects();
    }
}
'@
    return $null -ne ('Te1000PlcPouHelper' -as [type])
}

function Ensure-TcPlcLibraryManagerHelper {
    # ITcPlcLibraryManager (and ITcPlcReferences / ITcPlcLibRef / ITcPlcLibrary /
    # ITcPlcPlaceholderRef / ITcPlcLibRepositories / ITcPlcLibRepository) are vtable
    # (IUnknown) interfaces; PowerShell cannot cast a __ComObject to them
    # ([Interface]$obj is not a CLR QI in PS), so every QI + member call is done in a
    # compiled C# helper, exactly as Te1000PlcProjectHelper / Te1000PlcPouHelper do.
    # The manager lives on the References node (TIPC^<plc>^<plc> Project^References);
    # QI/marshaling also requires the interfaces registered in the 64-bit registry view.
    if ('Te1000PlcLibraryHelper' -as [type]) {
        return $true
    }
    $libPath = Get-TcSysManagerLibPath
    if (-not $libPath) {
        return $false
    }
    $null = [System.Reflection.Assembly]::LoadFrom($libPath)
    Add-Type -ReferencedAssemblies $libPath -TypeDefinition @'
using System;
using System.Collections.Generic;
using TCatSysManagerLib;
public static class Te1000PlcLibraryHelper {
    // --- readers -----------------------------------------------------------
    public static object[] ListReferences(object refsItem) {
        ITcPlcLibraryManager mgr = (ITcPlcLibraryManager)refsItem;
        ITcPlcReferences refs = mgr.References;
        var list = new List<object[]>();
        int count = refs.Count;
        for (int i = 0; i < count; i++) {
            ITcPlcLibRef r = refs[i];
            string name = null, displayName = null, distributor = null, version = null, kind = "reference";
            try { name = r.Name; } catch {}
            ITcPlcPlaceholderRef ph = r as ITcPlcPlaceholderRef;
            ITcPlcLibrary lib = r as ITcPlcLibrary;
            if (ph != null) {
                kind = "placeholder";
                // Installed ITcPlcPlaceholderRef only exposes Name / PlaceholderName /
                // CurrentLibrary / EffectiveResolution. DisplayName, Distributor and
                // Version are NOT on the placeholder ref itself -- derive them from the
                // resolved ITcPlcLibrary (EffectiveResolution preferred, else CurrentLibrary).
                try { if (name == null) name = ph.Name; } catch {}
                ITcPlcLibrary res = null;
                try { res = ph.EffectiveResolution; } catch {}
                if (res == null) { try { res = ph.CurrentLibrary; } catch {} }
                if (res != null) {
                    try { displayName = res.DisplayName; } catch {}
                    try { distributor = res.Distributor; } catch {}
                    try { version = res.Version; } catch {}
                }
            } else if (lib != null) {
                kind = "library";
                try { displayName = lib.DisplayName; } catch {}
                try { distributor = lib.Distributor; } catch {}
                try { if (name == null) name = lib.Name; } catch {}
                try { version = lib.Version; } catch {}
            }
            list.Add(new object[] { name, kind, displayName, distributor, version });
        }
        return list.ToArray();
    }
    public static object[] ScanLibraries(object refsItem) {
        ITcPlcLibraryManager mgr = (ITcPlcLibraryManager)refsItem;
        ITcPlcReferences libs = mgr.ScanLibraries();
        var list = new List<object[]>();
        int count = libs.Count;
        for (int i = 0; i < count; i++) {
            ITcPlcLibRef r = libs[i];
            string name = null, version = null, distributor = null, displayName = null;
            ITcPlcLibrary lib = r as ITcPlcLibrary;
            if (lib != null) {
                try { name = lib.Name; } catch {}
                try { version = lib.Version; } catch {}
                try { distributor = lib.Distributor; } catch {}
                try { displayName = lib.DisplayName; } catch {}
            } else {
                try { name = r.Name; } catch {}
            }
            list.Add(new object[] { name, version, distributor, displayName });
        }
        return list.ToArray();
    }
    public static object[] ListRepositories(object refsItem) {
        ITcPlcLibraryManager mgr = (ITcPlcLibraryManager)refsItem;
        ITcPlcLibRepositories repos = mgr.Repositories;
        var list = new List<object[]>();
        int count = repos.Count;
        for (int i = 0; i < count; i++) {
            ITcPlcLibRepository repo = repos[i];
            string name = null, folder = null;
            try { name = repo.Name; } catch {}
            try { folder = repo.Folder; } catch {}
            list.Add(new object[] { name, folder });
        }
        return list.ToArray();
    }
    // --- writers (project-local .plcproj edits) ----------------------------
    public static void AddLibrary(object refsItem, string name, string ver, string co) {
        ((ITcPlcLibraryManager)refsItem).AddLibrary(name, ver, co);
    }
    public static void AddPlaceholder(object refsItem, string name, string defLib, string defVer, string defDist) {
        ((ITcPlcLibraryManager)refsItem).AddPlaceholder(name, defLib, defVer, defDist);
    }
    public static void AddPlaceholderNameOnly(object refsItem, string name) {
        ((ITcPlcLibraryManager)refsItem).AddPlaceholder(name);
    }
    public static void SetEffectiveResolution(object refsItem, string ph, string lib, string ver, string dist) {
        ((ITcPlcLibraryManager)refsItem).SetEffectiveResolution(ph, lib, ver, dist);
    }
    public static void FreezePlaceholder(object refsItem, string name) {
        ((ITcPlcLibraryManager)refsItem).FreezePlaceholder(name);
    }
    public static void FreezePlaceholderAll(object refsItem) {
        ((ITcPlcLibraryManager)refsItem).FreezePlaceholder();
    }
    public static void RemoveReference(object refsItem, string name) {
        ((ITcPlcLibraryManager)refsItem).RemoveReference(name);
    }
    // --- repo admin (machine-wide library store mutations) -----------------
    public static void InstallLibrary(object refsItem, string repo, string path, bool overwrite) {
        ((ITcPlcLibraryManager)refsItem).InstallLibrary(repo, path, overwrite);
    }
    public static void UninstallLibrary(object refsItem, string repo, string lib, string ver, string dist) {
        ((ITcPlcLibraryManager)refsItem).UninstallLibrary(repo, lib, ver, dist);
    }
    public static void InsertRepository(object refsItem, string name, string folder, int idx) {
        ((ITcPlcLibraryManager)refsItem).InsertRepository(name, folder, idx);
    }
    public static void RemoveRepository(object refsItem, string name) {
        ((ITcPlcLibraryManager)refsItem).RemoveRepository(name);
    }
    public static void MoveRepository(object refsItem, string name, int idx) {
        ((ITcPlcLibraryManager)refsItem).MoveRepository(name, idx);
    }
}
'@
    return $null -ne ('Te1000PlcLibraryHelper' -as [type])
}

function Ensure-TcSettingsHelper {
    # FALLBACK for tc_settings. ITcSysManager7.ConfigurationManager /
    # ITcConfigManager.ActiveTargetPlatform, ITcSysManager9.SaveAsArchive, and
    # ITcSmTreeItem6.SaveInOwnFile are accessed late-bound first; if a versioned
    # member is vtable-only on the 64-bit TcXaeShell (as ITcPlcProject was),
    # PowerShell cannot reach it without a CLR QI. This compiled helper QIs the
    # typed interfaces, exactly as Te1000PlcProjectHelper does. Returns $false if
    # TCatSysManagerLib.dll is unavailable.
    if ('Te1000SettingsHelper' -as [type]) {
        return $true
    }
    $libPath = Get-TcSysManagerLibPath
    if (-not $libPath) {
        return $false
    }
    $null = [System.Reflection.Assembly]::LoadFrom($libPath)
    Add-Type -ReferencedAssemblies $libPath -TypeDefinition @'
using System;
using TCatSysManagerLib;
public static class Te1000SettingsHelper {
    public static string GetActiveTargetPlatform(object project) {
        ITcConfigManager cfg = ((ITcSysManager7)project).ConfigurationManager;
        return cfg.ActiveTargetPlatform;
    }
    public static void SetActiveTargetPlatform(object project, string platform) {
        ITcConfigManager cfg = ((ITcSysManager7)project).ConfigurationManager;
        cfg.ActiveTargetPlatform = platform;
    }
    public static void SaveAsArchive(object project, string file) {
        ((ITcSysManager9)project).SaveAsArchive(file);
    }
    public static bool GetSaveInOwnFile(object treeItem) {
        return ((ITcSmTreeItem6)treeItem).SaveInOwnFile;
    }
    public static void SetSaveInOwnFile(object treeItem, bool enabled) {
        ((ITcSmTreeItem6)treeItem).SaveInOwnFile = enabled;
    }
}
'@
    return $null -ne ('Te1000SettingsHelper' -as [type])
}

function Resolve-PlcReferencesPath {
    # Shared resolution for the plc_library verbs: returns the References-node tree
    # path. Defaults to the first PLC under TIPC (TIPC^<plc>^<plc> Project^References).
    param(
        [Parameter(Mandatory = $true)] $SysManager,
        [AllowNull()][string]$ReferencesPath
    )
    if (-not [string]::IsNullOrWhiteSpace($ReferencesPath)) {
        return $ReferencesPath
    }
    $tipc = $SysManager.LookupTreeItem('TIPC')
    if ([int]$tipc.ChildCount -lt 1) {
        throw 'No PLC project found under TIPC'
    }
    $plcName = [string]$tipc.Child(1).Name
    return "TIPC^$plcName^$plcName Project^References"
}

function Get-PlcLibraryReferencesItem {
    # Resolve the References node and return the tree item, ensuring the typed
    # ITcPlcLibraryManager helper is loaded (same failure message as plc_download).
    param(
        [Parameter(Mandatory = $true)] $SysManager,
        [AllowNull()][string]$ReferencesPath
    )
    $path = Resolve-PlcReferencesPath -SysManager $SysManager -ReferencesPath $ReferencesPath
    $refsItem = (Get-TreeItem -SysManager $SysManager -TreePath $path).Value
    if (-not (Ensure-TcPlcLibraryManagerHelper)) {
        throw 'TCatSysManagerLib.dll could not be loaded; the typed ITcPlcLibraryManager cast is required for PLC library operations on this shell'
    }
    return @{ path = $path; item = $refsItem }
}

$script:PlcLibraryRefNote = '.plcproj reference change requires a solution close+reopen in XAE to take effect (adding/removing/repinning a library or placeholder, set resolution); adding source files alone does not.'

function Assert-PlcLibraryRepoConfirm {
    param([AllowNull()][string]$Confirm)
    if ($Confirm -ne 'ALLOW_PLC_LIBRARY_REPO') {
        throw 'Blocked: confirm=ALLOW_PLC_LIBRARY_REPO required for repository administration.'
    }
}

function Assert-NotSafetyPath {
    # Project policy: nothing in this toolchain may write toward the EL6910 safety
    # system. The safety project lives under the TISC root, so reject any parent /
    # target tree path that addresses it so plc_pou can never author safety objects.
    param([Parameter(Mandatory = $true)][AllowNull()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }
    if ($Path -match '^\s*TISC(\^|$)') {
        throw "Refused: '$Path' targets the TISC safety project. plc_pou must not author toward the safety system (project policy: nothing writes toward safety)."
    }
}

# =====================================================================
# plc_pou code_engine: PURE text-manipulation helpers (no COM/XAE).
# These take strings/arrays in and return strings/arrays/hashtables out,
# so they are unit-testable standalone. All COM lives in Invoke-PlcTextRMW
# and the dispatch verbs; these never touch the tree.
# =====================================================================

function Get-TextEol {
    # PURE. Inspect the first line terminator; return CRLF or LF.
    # Default CRLF when none present (TwinCAT default).
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) {
        return @{ name = 'CRLF'; eol = "`r`n" }
    }
    $idx = $Text.IndexOf("`n")
    if ($idx -lt 0) {
        # No LF at all: maybe a lone CR (old Mac) or no terminator.
        if ($Text.IndexOf("`r") -ge 0) { return @{ name = 'LF'; eol = "`r" } }
        return @{ name = 'CRLF'; eol = "`r`n" }
    }
    if ($idx -gt 0 -and $Text[$idx - 1] -eq "`r") {
        return @{ name = 'CRLF'; eol = "`r`n" }
    }
    return @{ name = 'LF'; eol = "`n" }
}

function Split-PlcLines {
    # PURE. Split into lines WITHOUT terminators, on CRLF or lone LF/CR.
    # Empty string => @() (lineCount 0). Returns a hashtable carrying the
    # line array AND whether the original text ended with an EOL so a
    # round-trip preserves trailing-newline semantics.
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) {
        return @{ lines = @(); trailingEol = $false }
    }
    $trailing = ($Text -match "(`r`n|`n|`r)$")
    # Normalize CRLF and lone CR to LF, then split on LF.
    $norm = $Text -replace "`r`n", "`n"
    $norm = $norm -replace "`r", "`n"
    $parts = $norm -split "`n", -1
    # If the text ended in an EOL the split yields a trailing empty element;
    # drop it (we track trailingEol separately for fidelity).
    if ($trailing -and @($parts).Count -ge 1) {
        $parts = $parts[0..($parts.Count - 2)]
    }
    return @{ lines = @($parts); trailingEol = [bool]$trailing }
}

function Join-PlcLines {
    # PURE. Re-join with the detected EOL, optionally re-adding a trailing EOL.
    param(
        [AllowNull()][string[]]$Lines,
        [string]$Eol = "`r`n",
        [bool]$TrailingEol = $true
    )
    if ($null -eq $Lines -or @($Lines).Count -eq 0) {
        return ''
    }
    $joined = [string]::Join($Eol, $Lines)
    if ($TrailingEol) { $joined = $joined + $Eol }
    return $joined
}

function Get-LineSlice {
    # PURE. 1-based inclusive slice with clamp. Returns the slice plus the
    # clamped bounds and an outOfBounds flag (for reads — never throws).
    param(
        [AllowNull()][string[]]$Lines,
        [int]$Start,
        [int]$End
    )
    $count = if ($null -eq $Lines) { 0 } else { @($Lines).Count }
    if ($count -eq 0) {
        return @{ slice = @(); clampedStart = 0; clampedEnd = 0; outOfBounds = $true }
    }
    $oob = ($Start -lt 1) -or ($End -gt $count) -or ($Start -gt $End)
    $cs = if ($Start -lt 1) { 1 } else { $Start }
    $ce = if ($End -gt $count) { $count } else { $End }
    if ($cs -gt $ce) {
        return @{ slice = @(); clampedStart = $cs; clampedEnd = $ce; outOfBounds = $true }
    }
    $slice = @($Lines[($cs - 1)..($ce - 1)])
    return @{ slice = $slice; clampedStart = $cs; clampedEnd = $ce; outOfBounds = [bool]$oob }
}

function Select-GrepLines {
    # PURE. Regex match over lines + N context lines each side, de-duplicated
    # and merged, 1-based line numbers. Empty array on no match (NOT an error).
    # Throws a clear error on an invalid regex pattern.
    param(
        [AllowNull()][string[]]$Lines,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [int]$Context = 2
    )
    $count = if ($null -eq $Lines) { 0 } else { @($Lines).Count }
    if ($count -eq 0) { return @() }
    if ($Context -lt 0) { $Context = 0 }
    $regex = $null
    try {
        $regex = [System.Text.RegularExpressions.Regex]::new($Pattern)
    } catch {
        throw "invalid grep pattern: $($_.Exception.Message)"
    }
    $keep = New-Object 'System.Collections.Generic.SortedSet[int]'
    for ($i = 0; $i -lt $count; $i++) {
        if ($regex.IsMatch($Lines[$i])) {
            $lo = $i - $Context
            $hi = $i + $Context
            if ($lo -lt 0) { $lo = 0 }
            if ($hi -gt ($count - 1)) { $hi = $count - 1 }
            for ($j = $lo; $j -le $hi; $j++) { [void]$keep.Add($j) }
        }
    }
    $out = @()
    foreach ($idx in $keep) {
        $out += @{ line = ($idx + 1); text = $Lines[$idx] }
    }
    return @($out)
}

function Find-MatchesInText {
    # PURE, offline-unit-testable grep core for the project-wide plc_pou search.
    # Split on CRLF/CR/LF (normalized), 1-based line numbering, build ONE [regex]
    # with RegexOptions.IgnoreCase as requested (so it composes with multiline),
    # test each line, and emit {path,section,line,text=trimmed matched line} per
    # hit. No COM, no DTE. Empty/whitespace text => @() (0 matches, not error).
    # Throws a clear 'invalid pattern: ...' on a bad regex.
    param(
        [AllowNull()][string]$Text,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][ValidateSet('decl','impl')][string]$Section,
        [Parameter(Mandatory = $true)][string]$Path,
        [bool]$IgnoreCase = $false
    )
    if ([string]::IsNullOrEmpty($Text)) { return @() }
    $opts = [System.Text.RegularExpressions.RegexOptions]::None
    if ($IgnoreCase) { $opts = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase }
    $regex = $null
    try {
        $regex = [System.Text.RegularExpressions.Regex]::new($Pattern, $opts)
    } catch {
        throw "invalid pattern: $($_.Exception.Message)"
    }
    # Normalize CRLF and lone CR to LF, then split (keep all lines, 1-based).
    $norm = $Text -replace "`r`n", "`n"
    $norm = $norm -replace "`r", "`n"
    $lines = $norm -split "`n", -1
    $count = @($lines).Count
    $out = @()
    for ($i = 0; $i -lt $count; $i++) {
        if ($regex.IsMatch($lines[$i])) {
            $out += @{ path = $Path; section = $Section; line = ($i + 1); text = ([string]$lines[$i]).Trim() }
        }
    }
    return @($out)
}

function Get-StrippedToken {
    # PURE helper for VAR-block scanning: return the first whitespace-delimited
    # token of a line with line/block comment leaders ignored; '' for a line
    # that is blank or starts with // or (*.
    param([AllowNull()][string]$Line)
    if ($null -eq $Line) { return '' }
    $t = $Line.Trim()
    if ($t -eq '') { return '' }
    if ($t.StartsWith('//')) { return '' }
    if ($t.StartsWith('(*')) { return '' }
    # Cut an inline trailing comment before tokenizing.
    $ci = $t.IndexOf('//')
    if ($ci -ge 0) { $t = $t.Substring(0, $ci).Trim() }
    $bi = $t.IndexOf('(*')
    if ($bi -ge 0) { $t = $t.Substring(0, $bi).Trim() }
    if ($t -eq '') { return '' }
    $parts = $t -split '\s+'
    return $parts[0]
}

function Find-VarBlock {
    # PURE. Locate the chosen VAR-block (1-based occurrence) and its END_VAR.
    # Matches on the first token of a line (case-insensitive), tolerant of
    # CONSTANT/PERSISTENT/RETAIN modifiers and trailing comments; ignores lines
    # that start with // or (*. No nesting in IEC VAR blocks, so the first
    # END_VAR after a start line closes it. Returns
    # {found, startLine, endVarLine, indent} (1-based lines).
    param(
        [AllowNull()][string[]]$Lines,
        [Parameter(Mandatory = $true)][string]$BlockKeyword,
        [int]$Occurrence = 1
    )
    $count = if ($null -eq $Lines) { 0 } else { @($Lines).Count }
    if ($count -eq 0) { return @{ found = $false } }
    if ($Occurrence -lt 1) { $Occurrence = 1 }
    # Normalize the requested keyword: collapse spaces (e.g. "VAR PERSISTENT").
    $wantTokens = @(($BlockKeyword.Trim() -split '\s+') | Where-Object { $_ -ne '' })
    $wantHead = $wantTokens[0].ToUpperInvariant()
    $varKeywords = @('VAR','VAR_GLOBAL','VAR_INPUT','VAR_OUTPUT','VAR_IN_OUT','VAR_STAT','VAR_TEMP','VAR_INST','VAR_CONFIG','VAR_EXTERNAL')
    $found = 0
    $i = 0
    while ($i -lt $count) {
        $tok = (Get-StrippedToken -Line $Lines[$i]).ToUpperInvariant()
        if ($tok -eq $wantHead -and ($varKeywords -contains $tok)) {
            # This is a VAR-block opener matching the requested head keyword.
            $found++
            if ($found -eq $Occurrence) {
                $startLine = $i + 1
                $indent = ''
                $m = [System.Text.RegularExpressions.Regex]::Match($Lines[$i], '^(\s*)')
                if ($m.Success) { $indent = $m.Groups[1].Value }
                # Walk forward to the matching END_VAR.
                for ($k = $i + 1; $k -lt $count; $k++) {
                    $et = (Get-StrippedToken -Line $Lines[$k]).ToUpperInvariant()
                    if ($et -eq 'END_VAR') {
                        return @{ found = $true; startLine = $startLine; endVarLine = ($k + 1); indent = $indent }
                    }
                }
                # Opener with no END_VAR (malformed) — report not found cleanly.
                return @{ found = $false }
            }
            # Skip to this block's END_VAR before continuing the outer scan.
            for ($k = $i + 1; $k -lt $count; $k++) {
                $et = (Get-StrippedToken -Line $Lines[$k]).ToUpperInvariant()
                if ($et -eq 'END_VAR') { $i = $k; break }
            }
        }
        $i++
    }
    return @{ found = $false }
}

function Get-DeclOutline {
    # PURE. Parse the leading POU header + every VAR.../END_VAR pair.
    # Returns {header:{keyword,name,extends,implements,returnType}, varBlocks:[...]}.
    param([AllowNull()][string[]]$Lines)
    $count = if ($null -eq $Lines) { 0 } else { @($Lines).Count }
    $header = @{ keyword = $null; name = $null; extends = $null; implements = $null; returnType = $null }
    $varKeywords = @('VAR','VAR_GLOBAL','VAR_INPUT','VAR_OUTPUT','VAR_IN_OUT','VAR_STAT','VAR_TEMP','VAR_INST','VAR_CONFIG','VAR_EXTERNAL')
    $headerKeywords = @('FUNCTION_BLOCK','FUNCTION','PROGRAM','INTERFACE','TYPE','STRUCT','UNION','VAR_GLOBAL')

    # Find the header line (first non-blank, non-comment line whose first token is a header keyword).
    for ($i = 0; $i -lt $count; $i++) {
        $tok = (Get-StrippedToken -Line $Lines[$i]).ToUpperInvariant()
        if ($tok -eq '') { continue }
        if ($headerKeywords -contains $tok) {
            $line = $Lines[$i]
            # Strip trailing comment for parsing.
            $clean = $line
            $ci = $clean.IndexOf('//'); if ($ci -ge 0) { $clean = $clean.Substring(0, $ci) }
            $clean = $clean.Trim()
            $header.keyword = $tok
            # EXTENDS
            $em = [System.Text.RegularExpressions.Regex]::Match($clean, '(?i)\bEXTENDS\s+([A-Za-z_][A-Za-z0-9_\.]*)')
            if ($em.Success) { $header.extends = $em.Groups[1].Value }
            # IMPLEMENTS (comma list)
            $im = [System.Text.RegularExpressions.Regex]::Match($clean, '(?i)\bIMPLEMENTS\s+(.+)$')
            if ($im.Success) {
                $impl = $im.Groups[1].Value
                # cut off at EXTENDS if it followed
                $impl = ($impl -replace '(?i)\bEXTENDS\b.*$', '').Trim()
                $header.implements = $impl
            }
            # name = the token right after the keyword
            $nm = [System.Text.RegularExpressions.Regex]::Match($clean, '(?i)^' + [System.Text.RegularExpressions.Regex]::Escape($Lines[$i].Trim().Split(' ')[0]) + '\s+([A-Za-z_][A-Za-z0-9_]*)')
            if ($nm.Success) { $header.name = $nm.Groups[1].Value }
            # FUNCTION / METHOD-style return type ": TYPE"
            $rm = [System.Text.RegularExpressions.Regex]::Match($clean, ':\s*([A-Za-z_][A-Za-z0-9_\.]*)\s*$')
            if ($rm.Success -and ($tok -eq 'FUNCTION')) { $header.returnType = $rm.Groups[1].Value }
            break
        }
        if ($varKeywords -contains $tok) { break } # a GVL may open straight into VAR_GLOBAL
    }

    # Enumerate VAR blocks.
    $blocks = @()
    $i = 0
    while ($i -lt $count) {
        $tok = (Get-StrippedToken -Line $Lines[$i]).ToUpperInvariant()
        if ($varKeywords -contains $tok) {
            $startLine = $i + 1
            # kind = full opener keyword phrase incl. modifiers (e.g. "VAR_GLOBAL CONSTANT").
            $opener = $Lines[$i].Trim()
            $oc = $opener.IndexOf('//'); if ($oc -ge 0) { $opener = $opener.Substring(0, $oc).Trim() }
            $ob = $opener.IndexOf('(*'); if ($ob -ge 0) { $opener = $opener.Substring(0, $ob).Trim() }
            $kind = $opener
            # find END_VAR
            $endLine = $null
            $varCount = 0
            for ($k = $i + 1; $k -lt $count; $k++) {
                $et = (Get-StrippedToken -Line $Lines[$k]).ToUpperInvariant()
                if ($et -eq 'END_VAR') { $endLine = $k + 1; break }
                # count declaration lines: non-blank, non-comment lines containing ':'
                $body = (Get-StrippedToken -Line $Lines[$k])
                if ($body -ne '' -and $Lines[$k] -match ':') { $varCount++ }
            }
            if ($null -ne $endLine) {
                $blocks += @{ kind = $kind; startLine = $startLine; endLine = $endLine; varCount = $varCount }
                $i = $endLine - 1
            }
        }
        $i++
    }
    return @{ header = $header; varBlocks = @($blocks) }
}

function Apply-Replace {
    # PURE. Literal (non-regex) count + replace-all with an expected count gate.
    # Returns {newText, count, ok, error}. ok=false (no change) when count==0
    # or count != expectCount. Mirrors the Edit tool's anchored-unique semantics.
    param(
        [AllowNull()][string]$Text,
        [Parameter(Mandatory = $true)][string]$Find,
        [Parameter(Mandatory = $true)][string]$ReplaceWith,
        [int]$ExpectCount = 1
    )
    if ([string]::IsNullOrEmpty($Find)) {
        return @{ newText = $Text; count = 0; ok = $false; error = 'find must be a non-empty string' }
    }
    $hay = if ($null -eq $Text) { '' } else { $Text }
    # Count literal occurrences (ordinal).
    $count = 0
    $pos = 0
    while ($true) {
        $idx = $hay.IndexOf($Find, $pos, [System.StringComparison]::Ordinal)
        if ($idx -lt 0) { break }
        $count++
        $pos = $idx + $Find.Length
    }
    if ($count -eq 0) {
        return @{ newText = $hay; count = 0; ok = $false; error = "find not present in target (no change written)" }
    }
    if ($count -ne $ExpectCount) {
        return @{ newText = $hay; count = $count; ok = $false; error = "expected $ExpectCount occurrence(s), found $count (no change written)" }
    }
    $newText = $hay.Replace($Find, $ReplaceWith)
    return @{ newText = $newText; count = $count; ok = $true; error = $null }
}

function Get-ChangedSnippet {
    # PURE. Given the NEW line array + the changed region (1-based inclusive),
    # return {changedRange:{start,end}, snippet:[{line,text}]} for the new region
    # +/- 2 context lines. The compact 'only the changed region' payload.
    param(
        [AllowNull()][string[]]$NewLines,
        [int]$Start,
        [int]$End,
        [int]$Context = 2
    )
    $count = if ($null -eq $NewLines) { 0 } else { @($NewLines).Count }
    if ($count -eq 0) {
        return @{ changedRange = @{ start = 0; end = 0 }; snippet = @() }
    }
    if ($Start -lt 1) { $Start = 1 }
    if ($End -gt $count) { $End = $count }
    if ($End -lt $Start) { $End = $Start }
    $lo = $Start - $Context; if ($lo -lt 1) { $lo = 1 }
    $hi = $End + $Context; if ($hi -gt $count) { $hi = $count }
    $snippet = @()
    for ($i = $lo; $i -le $hi; $i++) {
        $snippet += @{ line = $i; text = $NewLines[$i - 1] }
    }
    return @{ changedRange = @{ start = $Start; end = $End }; snippet = @($snippet) }
}

function Get-FirstDivergentLine {
    # PURE. 1-based index of the first line that differs between two arrays
    # (or the first extra line if one is longer). $null if identical.
    param([AllowNull()][string[]]$OldLines, [AllowNull()][string[]]$NewLines)
    $o = @($OldLines); $n = @($NewLines)
    $max = [Math]::Max($o.Count, $n.Count)
    for ($i = 0; $i -lt $max; $i++) {
        $ov = if ($i -lt $o.Count) { $o[$i] } else { $null }
        $nv = if ($i -lt $n.Count) { $n[$i] } else { $null }
        if ($ov -ne $nv) { return ($i + 1) }
    }
    return $null
}

function Get-LastDivergentLine {
    # PURE. 1-based index (in the NEW array) of the last line that differs,
    # scanning from the end. $null if identical.
    param([AllowNull()][string[]]$OldLines, [AllowNull()][string[]]$NewLines)
    $o = @($OldLines); $n = @($NewLines)
    $oi = $o.Count - 1
    $ni = $n.Count - 1
    while ($oi -ge 0 -and $ni -ge 0 -and $o[$oi] -eq $n[$ni]) { $oi--; $ni-- }
    if ($ni -lt 0 -and $oi -lt 0) { return $null }
    if ($ni -lt 0) { return 1 }
    return ($ni + 1)
}

function Get-PlcTargetParam {
    # Read the optional 'target' param (decl|impl) with a default; validate.
    param([Parameter(Mandatory = $true)]$Payload, [string]$Default = 'decl')
    if ($Payload.PSObject.Properties.Name -contains 'target' -and -not [string]::IsNullOrWhiteSpace([string]$Payload.target)) {
        $t = ([string]$Payload.target).ToLowerInvariant()
        if ($t -ne 'decl' -and $t -ne 'impl') { throw "target must be 'decl' or 'impl'" }
        return $t
    }
    return $Default
}

function Get-PlcTextReadResult {
    # Build the get_decl / get_impl return shape from a raw text blob and the
    # request payload (range XOR grep). PURE apart from reading $Payload props.
    param(
        [AllowNull()][string]$Text,
        [Parameter(Mandatory = $true)]$Payload,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $eolInfo = Get-TextEol -Text $Text
    $split = Split-PlcLines -Text $Text
    $lines = @($split.lines)
    $lineCount = $lines.Count

    $hasRange = ($Payload.PSObject.Properties.Name -contains 'range') -and ($null -ne $Payload.range)
    $hasGrep = ($Payload.PSObject.Properties.Name -contains 'grep') -and ($null -ne $Payload.grep)
    if ($hasRange -and $hasGrep) {
        throw 'range and grep are mutually exclusive'
    }

    $data = @{ path = $Path; lineCount = $lineCount; eol = $eolInfo.name }

    if ($hasGrep) {
        $pattern = [string]$Payload.grep.pattern
        if ([string]::IsNullOrEmpty($pattern)) { throw 'grep.pattern is required' }
        $ctx = if ($null -ne $Payload.grep.context) { [int]$Payload.grep.context } else { 2 }
        $data.matches = @(Select-GrepLines -Lines $lines -Pattern $pattern -Context $ctx)
        return $data
    }

    if ($hasRange) {
        $start = [int]$Payload.range.start
        $end = [int]$Payload.range.end
        $sl = Get-LineSlice -Lines $lines -Start $start -End $end
        $data.text = Join-PlcLines -Lines @($sl.slice) -Eol $eolInfo.eol -TrailingEol $false
        if ($sl.outOfBounds) { $data.truncated = $true }
        return $data
    }

    # No range, no grep: full text (back-compat) plus lineCount.
    $data.text = $Text
    return $data
}

function Get-PlcLanguageName {
    # PURE. Map IECLANGUAGETYPES int -> name. 0 NONE/1 ST/2 IL/3 SFC/4 FBD/5 CFC/6 LD.
    param([AllowNull()]$Language)
    switch ([int]$Language) {
        0 { return 'NONE' }
        1 { return 'ST' }
        2 { return 'IL' }
        3 { return 'SFC' }
        4 { return 'FBD' }
        5 { return 'CFC' }
        6 { return 'LD' }
        default { return 'UNKNOWN' }
    }
}

function Test-PlcGraphicalLanguage {
    # PURE. Graphical languages where ImplementationText is not authoritative.
    # Allowlist textual languages (ST=1, IL=2); refuse everything NOT in {1,2}
    # when a language is actually known (per the caveat: prefer allowlisting
    # text over denylisting 3-6 in case a build returns usable text for a type).
    param([AllowNull()]$Language)
    if ($null -eq $Language) { return $false }
    $l = [int]$Language
    return -not ($l -eq 1 -or $l -eq 2)
}

function Refuse-GraphicalText {
    # Throw the standard refusal for a surgical impl write on a graphical language.
    param([string]$Path, [AllowNull()]$Language)
    $name = Get-PlcLanguageName -Language $Language
    throw "Refused surgical text edit on $($Path): implementation language is $name; ImplementationText is not authoritative for graphical languages. Use set_impl implXml (whole-XML round-trip) instead."
}

# =====================================================================
# plc_pou list/find/delete: IEC project tree-walk helpers.
# Get-PlcObjectTypeName is PURE (int/string in, label out) and unit-testable
# with no COM. Get-PlcProjectNodePath and Invoke-PlcTreeWalk do touch COM.
# =====================================================================

function Get-PlcObjectTypeName {
    # PURE. Map a tree node's identity (ItemType + optional ItemSubType /
    # ItemSubTypeName / Name) to a normalized type label. No COM. Logic order:
    #   1. name heuristics for non-IEC scaffolding the walk crosses
    #   2. ItemType (TwinCAT AI section 16.6)
    #   3. ItemSubType against the CreateChild sub-types (section 16.5)
    #   4. fall back to ItemSubTypeName string if present
    #   5. Unknown
    param(
        [AllowNull()]$ItemType,
        [AllowNull()]$ItemSubType,
        [AllowNull()][string]$ItemSubTypeName,
        [AllowNull()][string]$Name,
        [int]$ChildCount = 0,
        [bool]$HasDecl = $false
    )
    $nm = if ($null -eq $Name) { '' } else { [string]$Name }
    $it = if ($null -eq $ItemType) { -1 } else { [int]$ItemType }
    $st = if ($null -eq $ItemSubType) { -1 } else { [int]$ItemSubType }

    # (1) name heuristics for scaffolding nodes the walk crosses.
    if ($nm -match '\sProject$') { return 'Project' }
    $folderNames = @('References','POUs','DUTs','GVLs','VISUs','FBs','PRGs')
    if (($folderNames -contains $nm) -and ($ChildCount -gt 0) -and (-not $HasDecl)) {
        return 'Folder'
    }

    # (2) ItemType (section 16.6).
    switch ($it) {
        9   { return 'Project' }   # IECPRJ
        600 { return 'App' }       # PLCAPP
        621 { return 'Task' }      # PLCTASK
        8   { return 'Folder' }    # VARGRP
        default { }
    }

    # (3) ItemSubType against CreateChild sub-types (section 16.5).
    switch ($st) {
        602 { return 'Program' }
        603 { return 'Function' }
        604 { return 'FunctionBlock' }
        605 { return 'Enum' }
        606 { return 'Struct' }
        607 { return 'Union' }
        608 { return 'Action' }
        609 { return 'Method' }
        611 { return 'Property' }
        615 { return 'GVL' }
        616 { return 'Transition' }
        618 { return 'Interface' }
        619 { return 'Visualization' }
        623 { return 'Alias' }
        629 { return 'ParameterList' }
        631 { return 'UML' }
        default { }
    }

    # (4) fall back to the ItemSubTypeName string when present.
    if (-not [string]::IsNullOrWhiteSpace($ItemSubTypeName)) {
        return ([string]$ItemSubTypeName).Trim()
    }

    return 'Unknown'
}

function Get-PlcProjectNodePath {
    # Resolve the nested IEC PROJECT node path ('<plcPath>^<rootName> Project'
    # or the right child) using the EXACT candidate-paths probe pattern lifted
    # from plc_pou_check_objects: Resolve-PlcRootPath for the root, build ordered
    # candidate ^paths, LookupTreeItem a FRESH RCW per candidate, return the first
    # that resolves. Returns @{ plcPath; projectPath }. NOT pure (needs SysManager).
    param(
        [Parameter(Mandatory = $true)]$SysManager,
        [AllowNull()][string]$PlcPath
    )
    $plcPath = Resolve-PlcRootPath -SysManager $SysManager -Path $PlcPath
    Assert-NotSafetyPath -Path $plcPath
    $root = (Get-TreeItem -SysManager $SysManager -TreePath $plcPath).Value
    $rootName = Normalize-ScalarValue (Get-SafeValue { [string]$root.Name })

    $candidatePaths = New-Object System.Collections.ArrayList
    if (-not [string]::IsNullOrWhiteSpace($rootName)) {
        [void]$candidatePaths.Add("$plcPath^$rootName Project")
    }
    $childCount = Get-TreeItemChildCount -TreeItem $root
    for ($ci = 1; $ci -le $childCount; $ci++) {
        $childNode = (Get-SafeValue { (Get-TreeItemChild -TreeItem $root -Index $ci).Value })
        if ($null -ne $childNode) {
            $cn = Normalize-ScalarValue (Get-SafeValue { [string]$childNode.Name })
            if (-not [string]::IsNullOrWhiteSpace($cn)) {
                $cp = "$plcPath^$cn"
                if (-not $candidatePaths.Contains($cp)) { [void]$candidatePaths.Add($cp) }
            }
        }
    }
    if (-not $candidatePaths.Contains($plcPath)) { [void]$candidatePaths.Add($plcPath) }

    $lastErr = $null
    foreach ($candPath in $candidatePaths) {
        try {
            $node = (Get-TreeItem -SysManager $SysManager -TreePath $candPath).Value
            # Prefer the node whose name ends in ' Project' (the IEC project node);
            # accept any resolvable node as a fallback for older layouts.
            $nn = Normalize-ScalarValue (Get-SafeValue { [string]$node.Name })
            if (($nn -match '\sProject$') -or ($candPath -eq $candidatePaths[$candidatePaths.Count - 1])) {
                return @{ plcPath = $plcPath; projectPath = $candPath }
            }
            # Remember the first resolvable candidate in case none look like a project.
            if ($null -eq $lastErr) { $firstResolvable = $candPath }
        } catch {
            $lastErr = $_.Exception.Message
        }
    }
    if ($firstResolvable) {
        return @{ plcPath = $plcPath; projectPath = $firstResolvable }
    }
    throw "could not resolve the IEC project node under '$plcPath'. Last error: $lastErr"
}

function Invoke-PlcTreeWalk {
    # Recursive Child() walker over the IEC project tree. Emits one hashtable per
    # node: {path,name,type,itemType,subType,childCount,children?,truncated?}.
    # NO ProduceXml -- POU methods/props/actions/transitions are real Child()
    # children. Pruning by TypeFilter / flat-vs-nested are post-processing passes
    # on the nested result (see the dispatch verbs), so this walk feeds both
    # tree and find. Depth 1 = direct children only; MaxDepth 0 = unlimited.
    param(
        [Parameter(Mandatory = $true)]$SysManager,
        [Parameter(Mandatory = $true)]$Node,
        [Parameter(Mandatory = $true)][string]$BasePath,
        [int]$Depth = 1,
        [int]$MaxDepth = 0
    )
    $info = Convert-TreeItem -TreeItem $Node
    $subTypeName = Normalize-ScalarValue (Get-SafeValue { [string]$Node.ItemSubTypeName })
    $childCount = [int]$info.childCount
    $type = Get-PlcObjectTypeName -ItemType $info.itemType -ItemSubType $info.subType `
        -ItemSubTypeName $subTypeName -Name $info.name -ChildCount $childCount

    $node = @{
        path = $BasePath
        name = $info.name
        type = $type
        itemType = $info.itemType
        subType = $info.subType
        childCount = $childCount
    }
    if (-not [string]::IsNullOrWhiteSpace($subTypeName)) { $node.subTypeName = $subTypeName }

    if ($childCount -gt 0) {
        if (($MaxDepth -gt 0) -and ($Depth -ge $MaxDepth)) {
            # Stopped by depth but children remain.
            $node.truncated = $true
        } else {
            $children = @()
            for ($i = 1; $i -le $childCount; $i++) {
                $childNode = (Get-SafeValue { (Get-TreeItemChild -TreeItem $Node -Index $i).Value })
                if ($null -eq $childNode) { continue }
                $childName = Normalize-ScalarValue (Get-SafeValue { [string]$childNode.Name })
                if ([string]::IsNullOrWhiteSpace($childName)) { continue }
                $childPath = "$BasePath^$childName"
                $children += Invoke-PlcTreeWalk -SysManager $SysManager -Node $childNode `
                    -BasePath $childPath -Depth ($Depth + 1) -MaxDepth $MaxDepth
            }
            if (@($children).Count -gt 0) { $node.children = @($children) }
        }
    }
    return $node
}

function Get-PlcCodeObjects {
    # Recursive Child() enumeration over the resolved IEC project subtree, building
    # a FLAT list of @{path; item(RCW)} for EVERY descendant (no type filtering:
    # folders/actions/methods/properties are all walked so nested members like
    # FB^Action are reachable). De-dupes by ^-path (Ordinal) so an aliased/double
    # surfaced child is not visited twice. Reads TEXT off the child RCWs returned
    # by Child(n) directly (the per-node QI to the typed helper is tolerated when
    # caught in Select-PlcObjectText). NOT pure (touches COM); the recursion/path
    # building mirrors Invoke-PlcTreeWalk and is exercised indirectly by search.
    param(
        [Parameter(Mandatory = $true)]$SysManager,
        [Parameter(Mandatory = $true)][string]$RootPath,
        [Parameter(Mandatory = $true)]$RootItem,
        [AllowNull()]$Seen = $null
    )
    if ($null -eq $Seen) {
        $Seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    }
    $out = @()
    if ($Seen.Add($RootPath)) {
        $out += @{ path = $RootPath; item = $RootItem }
    }
    $childCount = Get-TreeItemChildCount -TreeItem $RootItem
    for ($i = 1; $i -le $childCount; $i++) {
        $childNode = (Get-SafeValue { (Get-TreeItemChild -TreeItem $RootItem -Index $i).Value })
        if ($null -eq $childNode) { continue }
        $childName = Normalize-ScalarValue (Get-SafeValue { [string]$childNode.Name })
        if ([string]::IsNullOrWhiteSpace($childName)) { continue }
        $childPath = "$RootPath^$childName"
        if ($Seen.Contains($childPath)) { continue }
        $out += Get-PlcCodeObjects -SysManager $SysManager -RootPath $childPath -RootItem $childNode -Seen $Seen
    }
    return @($out)
}

function Select-PlcObjectText {
    # Read wrapper around Te1000PlcPouHelper for ONE RCW. Returns
    # @{hasDecl; decl; hasImpl; impl; language}. A node that does not QI to
    # ITcPlcDeclaration/ITcPlcImplementation throws E_NOINTERFACE -> caught ->
    # hasDecl/hasImpl=$false (folders, the project node, visualizations skip
    # cleanly). Honors declOnly (skip impl read) / implOnly (skip decl read).
    # Graphical-language impl (SFC/FBD/CFC/LD) is gated out (no greppable text);
    # the node is still counted as scanned by the caller. COM-failure handling
    # lives here so one failing cast never aborts the whole walk.
    param(
        [Parameter(Mandatory = $true)]$Item,
        [bool]$DeclOnly = $false,
        [bool]$ImplOnly = $false
    )
    $res = @{ hasDecl = $false; decl = $null; hasImpl = $false; impl = $null; language = $null }
    if (-not $ImplOnly) {
        try {
            $res.decl = [Te1000PlcPouHelper]::GetDeclaration($Item)
            $res.hasDecl = $true
        } catch { $res.hasDecl = $false }
    }
    if (-not $DeclOnly) {
        $lang = $null
        try { $lang = [Te1000PlcPouHelper]::GetImplementationLanguage($Item) } catch { $lang = $null }
        $res.language = $lang
        # Only ST/IL carry usefully-greppable ImplementationText; graphical bodies
        # (and nodes with no impl interface) contribute nothing.
        if (($null -ne $lang) -and (-not (Test-PlcGraphicalLanguage -Language $lang))) {
            try {
                $res.impl = [Te1000PlcPouHelper]::GetImplementation($Item)
                $res.hasImpl = $true
            } catch { $res.hasImpl = $false }
        }
    }
    return $res
}

function ConvertTo-NormalizedTypeSet {
    # PURE. Parse a 'FB,Method,Struct' comma list into a lower-cased hashset for
    # case-insensitive membership tests. Returns $null when no filter supplied.
    param([AllowNull()][string]$TypeFilter)
    if ([string]::IsNullOrWhiteSpace($TypeFilter)) { return $null }
    $set = @{}
    foreach ($t in ($TypeFilter -split ',')) {
        $tt = $t.Trim().ToLowerInvariant()
        if ($tt -ne '') { $set[$tt] = $true }
    }
    if ($set.Count -eq 0) { return $null }
    return $set
}

function Test-NodeNameMatch {
    # PURE. Match a node name against a substring or /regex/ pattern (case-insensitive).
    param([AllowNull()][string]$Name, [AllowNull()][string]$Pattern)
    if ([string]::IsNullOrWhiteSpace($Pattern)) { return $true }
    $nm = if ($null -eq $Name) { '' } else { [string]$Name }
    if ($Pattern.Length -ge 2 -and $Pattern.StartsWith('/') -and $Pattern.EndsWith('/')) {
        $rx = $Pattern.Substring(1, $Pattern.Length - 2)
        try {
            return [System.Text.RegularExpressions.Regex]::IsMatch($nm, $rx, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        } catch {
            throw "invalid name regex: $($_.Exception.Message)"
        }
    }
    return ($nm.ToLowerInvariant().Contains($Pattern.ToLowerInvariant()))
}

function Select-FlatTreeMatches {
    # PURE. Flatten the nested walk result and keep nodes matching name and/or
    # typeFilter. Returns a flat array of {path,name,type,itemType,subType,
    # subTypeName?,childCount} (no children key). At least one of name/typeSet
    # is expected (enforced by the caller). $TypeSet is a hashtable or $null.
    param(
        [AllowNull()]$NestedRoot,
        [AllowNull()][string]$NamePattern,
        [AllowNull()]$TypeSet
    )
    $out = @()
    if ($null -eq $NestedRoot) { return @($out) }
    $stack = New-Object System.Collections.Stack
    $stack.Push($NestedRoot)
    while ($stack.Count -gt 0) {
        $n = $stack.Pop()
        $nameOk = Test-NodeNameMatch -Name $n.name -Pattern $NamePattern
        $typeOk = $true
        if ($null -ne $TypeSet) {
            $typeOk = $TypeSet.ContainsKey(([string]$n.type).ToLowerInvariant())
        }
        if ($nameOk -and $typeOk) {
            $flat = @{
                path = $n.path; name = $n.name; type = $n.type
                itemType = $n.itemType; subType = $n.subType; childCount = $n.childCount
            }
            if ($n.ContainsKey('subTypeName')) { $flat.subTypeName = $n.subTypeName }
            $out += $flat
        }
        if ($n.ContainsKey('children') -and $null -ne $n.children) {
            foreach ($c in @($n.children)) { $stack.Push($c) }
        }
    }
    return @($out)
}

function Select-PrunedTree {
    # PURE. Filter the nested tree by a normalized type set, KEEPING ancestor
    # nodes of any kept node so the tree stays connected (scaffolding retained).
    # Returns the pruned node (with rebuilt children) or $null if nothing under
    # it (including itself) matched. $TypeSet is a hashtable (non-null caller).
    param([AllowNull()]$Node, [Parameter(Mandatory = $true)]$TypeSet)
    if ($null -eq $Node) { return $null }
    $selfKept = $TypeSet.ContainsKey(([string]$Node.type).ToLowerInvariant())
    $keptChildren = @()
    if ($Node.ContainsKey('children') -and $null -ne $Node.children) {
        foreach ($c in @($Node.children)) {
            $pc = Select-PrunedTree -Node $c -TypeSet $TypeSet
            if ($null -ne $pc) { $keptChildren += $pc }
        }
    }
    if ((-not $selfKept) -and (@($keptChildren).Count -eq 0)) { return $null }
    $copy = @{}
    foreach ($k in $Node.Keys) { if ($k -ne 'children') { $copy[$k] = $Node[$k] } }
    if (@($keptChildren).Count -gt 0) { $copy.children = @($keptChildren) }
    return $copy
}

function Measure-TreeNodeCount {
    # PURE. Count total emitted nodes in a nested tree (for the 'count' field).
    param([AllowNull()]$Node)
    if ($null -eq $Node) { return 0 }
    $n = 1
    if ($Node.ContainsKey('children') -and $null -ne $Node.children) {
        foreach ($c in @($Node.children)) { $n += Measure-TreeNodeCount -Node $c }
    }
    return $n
}

function Invoke-PlcTextRMW {
    # THE read-modify-write wrapper. ALL COM lives here; the $Mutator is pure
    # string logic (param($text,$eol,$lines) -> new text string).
    #   - resolves the tree item via Get-TreeItem
    #   - Assert-NotSafetyPath
    #   - Ensure-TcPlcPouHelper (else throw the standard 'typed PLC cast' message)
    #   - target='impl': read language; if graphical (not ST/IL) throw Refuse-GraphicalText
    #   - read via GetDeclaration / GetImplementation
    #   - detect EOL (Get-TextEol), split (Split-PlcLines)
    #   - run $Mutator to get new text
    #   - write back via SetDeclaration / SetImplementationText
    # Returns @{ newText; eol; eolName; trailingEol; oldLineCount; newLineCount; language? }.
    param(
        [Parameter(Mandatory = $true)]$SysManager,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet('decl','impl')][string]$Target,
        [Parameter(Mandatory = $true)][scriptblock]$Mutator
    )
    Assert-NotSafetyPath -Path $Path
    $item = (Get-TreeItem -SysManager $SysManager -TreePath $Path).Value
    if (-not (Ensure-TcPlcPouHelper)) {
        throw 'typed PLC cast unavailable on this shell (TCatSysManagerLib.dll / Te1000PlcPouHelper could not be loaded)'
    }
    $language = $null
    if ($Target -eq 'impl') {
        try { $language = [Te1000PlcPouHelper]::GetImplementationLanguage($item) } catch { $language = $null }
        if (Test-PlcGraphicalLanguage -Language $language) {
            Refuse-GraphicalText -Path $Path -Language $language
        }
        $text = [Te1000PlcPouHelper]::GetImplementation($item)
    } else {
        $text = [Te1000PlcPouHelper]::GetDeclaration($item)
    }
    $eolInfo = Get-TextEol -Text $text
    $split = Split-PlcLines -Text $text
    $oldLines = @($split.lines)
    $newText = & $Mutator $text $eolInfo.eol $oldLines
    if ($null -eq $newText) { $newText = '' }
    if ($Target -eq 'impl') {
        [Te1000PlcPouHelper]::SetImplementationText($item, [string]$newText)
    } else {
        [Te1000PlcPouHelper]::SetDeclaration($item, [string]$newText)
    }
    $newSplit = Split-PlcLines -Text ([string]$newText)
    return @{
        newText = [string]$newText
        eol = $eolInfo.eol
        eolName = $eolInfo.name
        trailingEol = $split.trailingEol
        oldLineCount = @($oldLines).Count
        newLineCount = @($newSplit.lines).Count
        newLines = @($newSplit.lines)
        language = $language
    }
}

function Save-IfRequested {
    # Save the solution once if the payload requested it (save:true).
    param([Parameter(Mandatory = $true)]$Payload, [Parameter(Mandatory = $true)]$Dte)
    if ($Payload.PSObject.Properties.Name -contains 'save' -and [bool]$Payload.save) {
        Save-Solution -Dte $Dte
    }
}

function Add-ValidateResult {
    # OPTIONAL post-write build-check. When the payload sets validate:true, run
    # CheckAllObjects on the nested IEC project (reusing the check_objects
    # resolution: the first PLC under TIPC, then its '<name> Project' instance
    # node). Surfaces {validated:bool}. Default off (no key added) to stay fast.
    param(
        [Parameter(Mandatory = $true)]$Payload,
        [Parameter(Mandatory = $true)]$SysManager,
        [Parameter(Mandatory = $true)][hashtable]$Data
    )
    if (-not (($Payload.PSObject.Properties.Name -contains 'validate') -and [bool]$Payload.validate)) {
        return
    }
    try {
        $tipc = $SysManager.LookupTreeItem('TIPC')
        if ([int]$tipc.ChildCount -lt 1) { $Data.validated = $false; return }
        $plcPath = "TIPC^$([string]$tipc.Child(1).Name)"
        $root = (Get-TreeItem -SysManager $SysManager -TreePath $plcPath).Value
        if (-not (Ensure-TcPlcProjectHelper)) { $Data.validated = $false; return }
        $rootName = Normalize-ScalarValue (Get-SafeValue { [string]$root.Name })
        $candidatePaths = New-Object System.Collections.ArrayList
        if (-not [string]::IsNullOrWhiteSpace($rootName)) { [void]$candidatePaths.Add("$plcPath^$rootName Project") }
        $childCount = Get-TreeItemChildCount -TreeItem $root
        for ($ci = 1; $ci -le $childCount; $ci++) {
            $childNode = (Get-SafeValue { (Get-TreeItemChild -TreeItem $root -Index $ci).Value })
            if ($null -ne $childNode) {
                $cn = Normalize-ScalarValue (Get-SafeValue { [string]$childNode.Name })
                if (-not [string]::IsNullOrWhiteSpace($cn)) {
                    $cp = "$plcPath^$cn"
                    if (-not $candidatePaths.Contains($cp)) { [void]$candidatePaths.Add($cp) }
                }
            }
        }
        if (-not $candidatePaths.Contains($plcPath)) { [void]$candidatePaths.Add($plcPath) }
        foreach ($candPath in $candidatePaths) {
            try {
                $node = (Get-TreeItem -SysManager $SysManager -TreePath $candPath).Value
                $Data.validated = [bool]([Te1000PlcProjectHelper]::CheckAll($node))
                return
            } catch { }
        }
        $Data.validated = $false
    } catch {
        $Data.validated = $false
    }
}

function New-PlcPouVInfo {
    # Build the VARIANT vInfo argument for ITcSmTreeItem.CreateChild per PLC sub-type
    # (infosys 242732427). Multi-element cases MUST be a typed [object[]] / [string[]]
    # so PowerShell marshals a SAFEARRAY-of-VARIANT (not a flattened pipeline).
    #   603 Function / 611 Property => [object[]]{ langInt, returnType }   (returnType mandatory)
    #   604 FunctionBlock / 602 Program => [object[]]{ langInt [,'Extends',ext][,'Implements',impl] }
    #   608 Action / 609 Method / 616 Transition => [object[]]{ langInt }
    #   618 Interface => extends string or $null (vInfo[0] = extend type)
    #   605/606/607/615/623/629 (DUT/GVL/Alias/ParamList) => declText or $null
    #   619 Visualization / 631 UML => $null
    param(
        [Parameter(Mandatory = $true)][int]$SubType,
        [int]$Language = 1,
        [AllowNull()][string]$ReturnType,
        [AllowNull()][string]$Extends,
        [AllowNull()][string]$Implements,
        [AllowNull()][string]$DeclText
    )

    switch ($SubType) {
        603 {
            if ([string]::IsNullOrWhiteSpace($ReturnType)) {
                throw 'returnType is required for Function (subType 603)'
            }
            Write-Output -NoEnumerate ([object[]]@($Language, [string]$ReturnType))
            return
        }
        611 {
            if ([string]::IsNullOrWhiteSpace($ReturnType)) {
                throw 'returnType is required for Property (subType 611)'
            }
            Write-Output -NoEnumerate ([object[]]@($Language, [string]$ReturnType))
            return
        }
        { $_ -eq 604 -or $_ -eq 602 } {
            $info = New-Object System.Collections.Generic.List[object]
            $info.Add($Language)
            if (-not [string]::IsNullOrWhiteSpace($Extends)) {
                $info.Add('Extends'); $info.Add([string]$Extends)
            }
            if (-not [string]::IsNullOrWhiteSpace($Implements)) {
                $info.Add('Implements'); $info.Add([string]$Implements)
            }
            Write-Output -NoEnumerate ([object[]]$info.ToArray())
            return
        }
        { $_ -eq 608 -or $_ -eq 609 -or $_ -eq 616 } {
            Write-Output -NoEnumerate ([object[]]@($Language))
            return
        }
        618 {
            if ([string]::IsNullOrWhiteSpace($Extends)) {
                Write-Output -NoEnumerate $null
            } else {
                Write-Output -NoEnumerate ([string]$Extends)
            }
            return
        }
        { $_ -eq 605 -or $_ -eq 606 -or $_ -eq 607 -or $_ -eq 615 -or $_ -eq 623 -or $_ -eq 629 } {
            if ([string]::IsNullOrWhiteSpace($DeclText)) {
                Write-Output -NoEnumerate $null
            } else {
                Write-Output -NoEnumerate ([string]$DeclText)
            }
            return
        }
        default {
            # 619 Visualization / 631 UML and any other code-less type: null vInfo.
            Write-Output -NoEnumerate $null
            return
        }
    }
}

function Invoke-PlcPouCreate {
    # Shared CreateChild path used by both plc_pou_create and the batch verb.
    # $Entry is a payload-shaped object with parent/name/subType[/language/returnType/extends/implements/declText/before].
    param(
        [Parameter(Mandatory = $true)]$SysManager,
        [Parameter(Mandatory = $true)]$Entry
    )

    $parent = [string]$Entry.parent
    $name = [string]$Entry.name
    if ([string]::IsNullOrWhiteSpace($parent)) { throw 'parent is required' }
    if ([string]::IsNullOrWhiteSpace($name)) { throw 'name is required' }
    if ($null -eq $Entry.subType) { throw 'subType is required' }
    $subType = [int]$Entry.subType
    Assert-NotSafetyPath -Path $parent

    $language = 1
    if ($null -ne $Entry.language) { $language = [int]$Entry.language }
    $returnType = if ($null -ne $Entry.returnType) { [string]$Entry.returnType } else { $null }
    $extends = if ($null -ne $Entry.extends) { [string]$Entry.extends } else { $null }
    $implements = if ($null -ne $Entry.implements) { [string]$Entry.implements } else { $null }
    $declText = if ($null -ne $Entry.declText) { [string]$Entry.declText } else { $null }
    $before = if ($Entry.before) { [string]$Entry.before } else { '' }

    $parentItem = (Get-TreeItem -SysManager $SysManager -TreePath $parent).Value
    $vInfo = New-PlcPouVInfo -SubType $subType -Language $language -ReturnType $returnType -Extends $extends -Implements $implements -DeclText $declText

    $child = $parentItem.CreateChild($name, $subType, $before, $vInfo)
    Assert-WellFormedChild -Parent $parentItem -Child $child -RequestedName $name -SubType $subType -ParentPath $parent
    return $child
}

function Expand-UIHierarchyChildren {
    param($Item)

    $children = Get-SafeValue { $Item.UIHierarchyItems }
    if ($null -eq $children) {
        return $null
    }
    try {
        if (-not $children.Expanded) {
            $children.Expanded = $true
        }
    } catch {
    }
    return $children
}

function Find-UIHierarchyChildByName {
    param($Item, [string]$Name)

    $children = Expand-UIHierarchyChildren -Item $Item
    if ($null -eq $children) {
        return $null
    }
    foreach ($child in $children) {
        $childName = Get-SafeValue { [string]$child.Name }
        if ($childName -eq $Name) {
            return $child
        }
    }
    return $null
}

function Select-PlcProjectInSolutionExplorer {
    # PLC login/download/logout DTE commands are selection-context-sensitive: they stay
    # IsAvailable=false until the "<plc> Project" node is selected in Solution Explorer.
    # ExpandView()/focus is not enough; only UIHierarchyItem.Select() establishes context.
    param(
        $Dte,
        [string]$PlcItemName
    )

    $sysManager = (Get-SysManager -Dte $Dte).Value
    $plcName = $null
    try {
        $tipc = $sysManager.LookupTreeItem('TIPC')
        if ([int]$tipc.ChildCount -ge 1) {
            $plcName = [string]$tipc.Child(1).Name
        }
    } catch {
    }

    if ([string]::IsNullOrWhiteSpace($PlcItemName)) {
        if ([string]::IsNullOrWhiteSpace($plcName)) {
            throw 'Could not determine the PLC project name from TIPC'
        }
        $PlcItemName = "$plcName Project"
    }

    $null = Get-SafeValue { $Dte.ExecuteCommand('View.SolutionExplorer') }
    $solutionExplorer = $Dte.ToolWindows.SolutionExplorer
    $rootItems = Get-SafeValue { $solutionExplorer.UIHierarchyItems }
    if ($null -eq $rootItems -or (Get-SafeValue { [int]$rootItems.Count }) -lt 1) {
        throw 'Solution Explorer hierarchy is empty'
    }

    $target = $null
    $solutionNode = $rootItems.Item(1)
    $projectNodes = Expand-UIHierarchyChildren -Item $solutionNode
    if ($null -ne $projectNodes) {
        foreach ($projectNode in $projectNodes) {
            $plcFolder = Find-UIHierarchyChildByName -Item $projectNode -Name 'PLC'
            if ($null -eq $plcFolder) {
                continue
            }

            $plcRoots = @()
            if (-not [string]::IsNullOrWhiteSpace($plcName)) {
                $named = Find-UIHierarchyChildByName -Item $plcFolder -Name $plcName
                if ($null -ne $named) {
                    $plcRoots += $named
                }
            }
            if ($plcRoots.Count -eq 0) {
                $allRoots = Expand-UIHierarchyChildren -Item $plcFolder
                if ($null -ne $allRoots) {
                    foreach ($root in $allRoots) {
                        $plcRoots += $root
                    }
                }
            }

            foreach ($plcRoot in $plcRoots) {
                $target = Find-UIHierarchyChildByName -Item $plcRoot -Name $PlcItemName
                if ($null -eq $target) {
                    $rootChildren = Expand-UIHierarchyChildren -Item $plcRoot
                    if ($null -ne $rootChildren) {
                        foreach ($child in $rootChildren) {
                            $childName = Get-SafeValue { [string]$child.Name }
                            if ($childName -like '* Project') {
                                $target = $child
                                break
                            }
                        }
                    }
                }
                if ($null -ne $target) {
                    break
                }
            }
            if ($null -ne $target) {
                break
            }
        }
    }

    if ($null -eq $target) {
        throw "Could not locate '$PlcItemName' under a PLC node in Solution Explorer"
    }

    $target.Select(1) # vsUISelectionTypeSelect
    Start-Sleep -Milliseconds 400
    return $PlcItemName
}

function Invoke-PlcProjectCommand {
    param(
        $Dte,
        [Parameter(Mandatory = $true)]
        [string[]]$CandidateCommands,
        [string]$FallbackPattern,
        [string]$PlcItemName
    )

    $settings = Get-SafeValue { Get-AutomationSettings -Dte $Dte }
    $prevSilent = $null
    if ($null -ne $settings) {
        $prevSilent = Get-SafeValue { [bool]$settings.SilentMode }
        try {
            $settings.SilentMode = $true
        } catch {
        }
    }

    try {
        $selectedItem = Select-PlcProjectInSolutionExplorer -Dte $Dte -PlcItemName $PlcItemName

        $tried = @()
        foreach ($name in $CandidateCommands) {
            if ([string]::IsNullOrWhiteSpace($name)) {
                continue
            }
            $cmd = $null
            try {
                $cmd = $Dte.Commands.Item($name, 0)
            } catch {
            }
            if ($null -eq $cmd) {
                $tried += "$name (not found)"
                continue
            }
            $isAvailable = $true
            try {
                $isAvailable = [bool]$cmd.IsAvailable
            } catch {
            }
            if (-not $isAvailable) {
                $tried += "$name (unavailable)"
                continue
            }
            $Dte.ExecuteCommand($name)
            return @{
                commandName = $name
                executed = $true
                selectedItem = $selectedItem
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($FallbackPattern)) {
            foreach ($cmd in $Dte.Commands) {
                $name = Get-SafeValue { [string]$cmd.Name }
                if ([string]::IsNullOrWhiteSpace($name) -or $name -notmatch $FallbackPattern) {
                    continue
                }
                $isAvailable = $false
                try {
                    $isAvailable = [bool]$cmd.IsAvailable
                } catch {
                }
                if ($isAvailable) {
                    $Dte.ExecuteCommand($name)
                    return @{
                        commandName = $name
                        executed = $true
                        selectedItem = $selectedItem
                        viaFallbackScan = $true
                    }
                }
                $tried += "$name (unavailable)"
            }
        }

        throw ("No PLC command was available after selecting '" + $selectedItem + "' in Solution Explorer. Tried: " + ($tried -join ', '))
    } finally {
        if ($null -ne $settings -and $null -ne $prevSilent) {
            try {
                $settings.SilentMode = $prevSilent
            } catch {
            }
        }
    }
}

function Convert-SelectedItem {
    param(
        [Parameter(Mandatory = $true)]
        $SelectedItem
    )

    $projectItem = Get-SafeValue { $SelectedItem.ProjectItem }
    $projectItemObject = $null
    if ($null -ne $projectItem) {
        $projectItemObject = Get-SafeValue { $projectItem.Object }
    }

    return @{
        name = Normalize-ScalarValue (Get-SafeValue { [string]$SelectedItem.Name })
        projectName = Normalize-ScalarValue (Get-SafeValue { [string]$SelectedItem.Project.Name })
        projectItemName = Normalize-ScalarValue (Get-SafeValue { [string]$projectItem.Name })
        projectItemKind = Normalize-ScalarValue (Get-SafeValue { [string]$projectItem.Kind })
        treePath = Normalize-ScalarValue (Get-SafeValue { [string]$projectItemObject.PathName })
    }
}

function Convert-ErrorItem {
    param(
        [Parameter(Mandatory = $true)]
        $ErrorItem
    )

    return @{
        description = Normalize-ScalarValue (Get-SafeValue { [string]$ErrorItem.Description })
        errorLevel = Normalize-ScalarValue (Get-SafeValue { [string]$ErrorItem.ErrorLevel })
        fileName = Normalize-ScalarValue (Get-SafeValue { [string]$ErrorItem.FileName })
        line = Normalize-ScalarValue (Get-SafeValue { [int]$ErrorItem.Line })
        column = Normalize-ScalarValue (Get-SafeValue { [int]$ErrorItem.Column })
        project = Normalize-ScalarValue (Get-SafeValue { [string]$ErrorItem.Project })
    }
}

function Get-TreeItem($SysManager, [string]$TreePath) {
    $rawItem = $SysManager.LookupTreeItem($TreePath)
    $item = Normalize-ScalarValue $rawItem
    if ($null -eq $item) {
        throw "Tree item not found: $TreePath"
    }
    Write-Output -NoEnumerate ([ref]$item)
    return
}

function Rename-TreeItem($SysManager, [string]$TargetPath, [string]$NewName) {
    if ([string]::IsNullOrWhiteSpace($NewName)) {
        throw 'newName is required'
    }
    $item = (Get-TreeItem -SysManager $SysManager -TreePath $TargetPath).Value

    $escapedName = $NewName.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
    $xml = "<TreeItem><ItemName>$escapedName</ItemName></TreeItem>"

    try {
        $item.ConsumeXml($xml)
    } catch {
        $xmlError = $null
        try {
            $xmlError = $item.GetLastXmlError()
        } catch {
        }

        if ($xmlError) {
            throw "ConsumeXml failed: $xmlError"
        }
        throw
    }

    return (Normalize-ScalarValue (Get-SafeValue { [string]$item.PathName }))
}

function Assert-WellFormedChild {
    # Validates a child returned by ITcSmTreeItem.CreateChild(...) and, if it is
    # malformed (a "ghost"), attempts best-effort cleanup and THROWS a descriptive
    # error. A bad subType/createInfo can make CreateChild return SUCCESS while
    # actually inserting a blank-named, unaddressable child under the wrong parent
    # (observed: subType 9099 with no ESI createInfo on an EtherCAT device). Without
    # this check the caller is told it succeeded.
    #
    # Returns nothing on success; the caller continues to use $Child.
    param(
        [Parameter(Mandatory = $true)] [object]$Parent,
        [Parameter(Mandatory = $true)] [AllowNull()] [object]$Child,
        [Parameter(Mandatory = $true)] [string]$RequestedName,
        [Parameter(Mandatory = $true)] [int]$SubType,
        [Parameter(Mandatory = $true)] [string]$ParentPath
    )

    # Read back identity defensively — a ghost can throw on property access.
    $childActualName = Get-SafeValue { [string]$Child.Name }
    $childPath = Get-SafeValue { [string]$Child.PathName }

    $reason = $null
    if ($null -eq $Child) {
        $reason = 'CreateChild returned null'
    } elseif ([string]::IsNullOrWhiteSpace([string]$childActualName)) {
        $reason = 'returned child has a blank name'
    } elseif (([string]$childActualName) -ne $RequestedName) {
        $reason = "returned child name '$childActualName' does not match requested name '$RequestedName'"
    } else {
        # The child must live directly under the requested parent. A correct child's
        # path is "<parentPath>^<name>"; anything else means it landed unexpectedly.
        $expectedPath = "$ParentPath^$RequestedName"
        if (-not [string]::IsNullOrWhiteSpace([string]$childPath) -and ([string]$childPath) -ne $expectedPath) {
            $reason = "returned child path '$childPath' is not under requested parent (expected '$expectedPath')"
        }
    }

    if ($null -eq $reason) {
        return
    }

    # Best-effort cleanup: only delete by name when we actually have a non-blank
    # name. If the name is blank we cannot safely address the stray child, so we
    # do NOT guess — leave it for manual removal in the XAE GUI / close-without-save.
    if (-not [string]::IsNullOrWhiteSpace([string]$childActualName)) {
        try { $Parent.DeleteChild([string]$childActualName) } catch { }
    }

    throw "CreateChild produced a malformed child (name='$childActualName', path='$childPath') for requested name='$RequestedName', subType=$SubType under '$ParentPath' ($reason). This usually means the subType/createInfo is not valid for this parent (EtherCAT boxes typically require a proper createInfo). No usable child was created. If a stray blank-named child remains, remove it in the XAE GUI or via close-without-save."
}

function Set-TreeItemXml($SysManager, [string]$TargetPath, [string]$Xml) {
    $item = (Get-TreeItem -SysManager $SysManager -TreePath $TargetPath).Value

    try {
        $item.ConsumeXml($Xml)
    } catch {
        $xmlError = $null
        try {
            $xmlError = $item.GetLastXmlError()
        } catch {
        }

        if ($xmlError) {
            throw "ConsumeXml failed: $xmlError"
        }
        throw
    }

    return $item
}

function Link-Variables($SysManager, [string]$Producer, [string]$Consumer, [bool]$AutoResolve) {
    if ([string]::IsNullOrWhiteSpace($Producer) -or [string]::IsNullOrWhiteSpace($Consumer)) {
        throw 'producer and consumer are required'
    }

    $producerResolution = @{
        originalPath = $Producer
        resolvedPath = $Producer
        resolved = $true
        attempts = @()
    }
    $consumerResolution = @{
        originalPath = $Consumer
        resolvedPath = $Consumer
        resolved = $true
        attempts = @()
    }

    if ($AutoResolve) {
        $producerResolution = Resolve-TwinCatVariablePath -SysManager $SysManager -VariablePath $Producer
        $consumerResolution = Resolve-TwinCatVariablePath -SysManager $SysManager -VariablePath $Consumer
        $Producer = [string]$producerResolution.resolvedPath
        $Consumer = [string]$consumerResolution.resolvedPath
    }

    $SysManager.LinkVariables($Producer, $Consumer)

    return @{
        producer = $Producer
        consumer = $Consumer
        producerResolution = $producerResolution
        consumerResolution = $consumerResolution
        linked = $true
    }
}

function Convert-TreeItem {
    param(
        [Parameter(Mandatory = $true)]
        [object]$TreeItem
    )

    $subType = $null
    try {
        $subType = $TreeItem.SubType
    } catch {
        try {
            $subType = $TreeItem.ItemSubType
        } catch {
        }
    }

    return @{
        name = Normalize-ScalarValue (Get-SafeValue { [string]$TreeItem.Name })
        pathName = Normalize-ScalarValue (Get-SafeValue { [string]$TreeItem.PathName })
        itemType = Normalize-ScalarValue (Get-SafeValue { [int]$TreeItem.ItemType })
        subType = $subType
        childCount = Get-TreeItemChildCount -TreeItem $TreeItem
    }
}

# --- tc_fieldbus helpers ---------------------------------------------------
# Shared CreateChild path for NON-EtherCAT fieldbus masters/slaves/boxes
# (PROFINET / PROFIBUS / CANopen / DeviceNet / EAP). Mirrors twincat_create_child:
# CreateChild(name, subType, before, vInfo) then Assert-WellFormedChild so a
# wrong subType/vInfo "ghost" (blank-named child) is cleaned up and surfaced as a
# failure rather than a false success. OFFLINE config only — no cell write.
# $Entry is a payload-shaped object with parent?/name/subType[/before/vInfo/claimIndex].
function Invoke-FieldbusCreateDevice {
    param(
        [Parameter(Mandatory = $true)]$SysManager,
        [Parameter(Mandatory = $true)]$Entry
    )

    $name = if ($Entry.PSObject.Properties.Name -contains 'name') { [string]$Entry.name } else { $null }
    if ([string]::IsNullOrWhiteSpace($name)) { throw 'name is required' }
    if ($null -eq $Entry.subType) { throw 'subType is required' }
    $subType = [int]$Entry.subType

    $parentPath = if ($Entry.PSObject.Properties.Name -contains 'parent' -and -not [string]::IsNullOrWhiteSpace([string]$Entry.parent)) { [string]$Entry.parent } else { 'TIID' }
    Assert-NotSafetyPath -Path $parentPath
    $before = if ($Entry.PSObject.Properties.Name -contains 'before' -and $Entry.before) { [string]$Entry.before } else { '' }
    $vInfo = if ($Entry.PSObject.Properties.Name -contains 'vInfo' -and -not [string]::IsNullOrWhiteSpace([string]$Entry.vInfo)) { [string]$Entry.vInfo } else { $null }

    $parent = (Get-TreeItem -SysManager $SysManager -TreePath $parentPath).Value
    $child = $parent.CreateChild($name, $subType, $before, $vInfo)
    Assert-WellFormedChild -Parent $parent -Child $child -RequestedName $name -SubType $subType -ParentPath $parentPath

    $claimed = $null
    if ($Entry.PSObject.Properties.Name -contains 'claimIndex' -and $null -ne $Entry.claimIndex) {
        $claimIndex = [int]$Entry.claimIndex
        try {
            # ClaimResources lives on ITcSmTreeItem5/2; PowerShell late-binds it
            # directly on the COM object (same as CreateChild/ConsumeXml). OFFLINE
            # config binding of the node to underlying FC/EL hardware — NOT a cell write.
            $child.ClaimResources($claimIndex)
            $claimed = $true
        } catch {
            $claimed = $false
        }
    }

    return @{
        parentPath = $parentPath
        child = Convert-TreeItem -TreeItem $child
        claimed = $claimed
    }
}

function Get-TwinCatVariablePathCandidates {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VariablePath
    )

    $candidates = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($VariablePath)) {
        $candidates.Add($VariablePath)
    }

    $parts = $VariablePath -split '\^'
    if ($parts.Count -lt 1) {
        return $candidates.ToArray()
    }

    $last = $parts[$parts.Count - 1]
    $dotMatches = [regex]::Matches($last, '\.')
    for ($i = $dotMatches.Count - 1; $i -ge 0; $i--) {
        $chars = $last.ToCharArray()
        for ($j = $i; $j -lt $dotMatches.Count; $j++) {
            $chars[$dotMatches[$j].Index] = '^'
        }

        $variantParts = @($parts)
        $variantParts[$variantParts.Count - 1] = -join $chars
        $candidate = $variantParts -join '^'
        if (-not $candidates.Contains($candidate)) {
            $candidates.Add($candidate)
        }
    }

    return $candidates.ToArray()
}

function Resolve-TwinCatVariablePath {
    param(
        [Parameter(Mandatory = $true)]
        $SysManager,

        [Parameter(Mandatory = $true)]
        [string]$VariablePath
    )

    $attempts = @()
    foreach ($candidate in (Get-TwinCatVariablePathCandidates -VariablePath $VariablePath)) {
        try {
            $item = (Get-TreeItem -SysManager $SysManager -TreePath $candidate).Value
            $attempts += @{
                path = $candidate
                exists = $true
                item = Convert-TreeItem -TreeItem $item
            }

            return @{
                originalPath = $VariablePath
                resolvedPath = $candidate
                resolved = $true
                attempts = $attempts
            }
        } catch {
            $attempts += @{
                path = $candidate
                exists = $false
                error = $_.Exception.Message
            }
        }
    }

    return @{
        originalPath = $VariablePath
        resolvedPath = $VariablePath
        resolved = $false
        attempts = $attempts
    }
}

function Resolve-NcTaskPath($SysManager, [string]$RequestedTaskPath) {
    if (-not [string]::IsNullOrWhiteSpace($RequestedTaskPath)) {
        return $RequestedTaskPath
    }

    $motionRoot = (Get-TreeItem -SysManager $SysManager -TreePath 'TINC').Value
    if ((Get-TreeItemChildCount -TreeItem $motionRoot) -lt 1) {
        throw 'No NC tasks were found under TINC'
    }

    $firstTask = (Get-TreeItemChild -TreeItem $motionRoot -Index 1).Value
    $name = Normalize-ScalarValue (Get-SafeValue { [string]$firstTask.Name })
    if (-not [string]::IsNullOrWhiteSpace($name)) {
        return "TINC^$name"
    }

    throw 'Unable to resolve an NC task path under TINC'
}

function Get-ChildTreeItemByName {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ParentItem,

        [Parameter(Mandatory = $true)]
        [string]$ChildName
    )

    $count = Get-TreeItemChildCount -TreeItem $ParentItem
    for ($i = 1; $i -le $count; $i++) {
        $child = (Get-TreeItemChild -TreeItem $ParentItem -Index $i).Value
        $name = Normalize-ScalarValue (Get-SafeValue { [string]$child.Name })
        if ($name -eq $ChildName) {
            Write-Output -NoEnumerate ([ref]$child)
            return
        }
    }

    throw "Child '$ChildName' was not found under '$((Normalize-ScalarValue (Get-SafeValue { [string]$ParentItem.PathName })))'"
}

function Get-VariableLinksFromXml {
    # Variable links are NOT serialized in a box/device's ProduceXml as <Mappings>/<Link>
    # (that shape only exists in the on-disk .xti written by the project saver). Live, a
    # LINKED LEAF VARIABLE carries its links inside its own ProduceXml under
    # <VarDef><LinkedWith>: InnerText is the full ^-path of the other endpoint. PLC-side
    # endpoints also carry attributes (offsA/offsB/size/removeLink); IO-side carry a bare
    # element. Group/box nodes do NOT embed their descendants' variable XML, so to answer
    # "what is this box linked to?" the caller must walk descendants and collect each leaf's
    # <LinkedWith>. This helper parses one item's own ProduceXml and returns its <LinkedWith>
    # endpoints (the queried item is varA, each LinkedWith target is varB).
    param(
        [Parameter(Mandatory = $true)]
        [object]$TreeItem
    )

    $ownerPath = Normalize-ScalarValue (Get-SafeValue { [string]$TreeItem.PathName })

    $xmlText = $null
    try {
        $xmlText = $TreeItem.ProduceXml()
    } catch {
        $xmlText = $null
    }
    if ([string]::IsNullOrEmpty($xmlText)) {
        return @()
    }

    $links = @()
    try {
        [xml]$doc = $xmlText
        foreach ($node in $doc.SelectNodes('//LinkedWith')) {
            $varB = [string]$node.InnerText
            if ([string]::IsNullOrWhiteSpace($varB)) {
                continue
            }
            $entry = @{
                varA = $ownerPath
                varB = $varB
            }
            $offsA = Get-SafeValue { [string]$node.GetAttribute('offsA') }
            $offsB = Get-SafeValue { [string]$node.GetAttribute('offsB') }
            $size = Get-SafeValue { [string]$node.GetAttribute('size') }
            if (-not [string]::IsNullOrWhiteSpace($offsA)) { $entry.offsA = $offsA }
            if (-not [string]::IsNullOrWhiteSpace($offsB)) { $entry.offsB = $offsB }
            if (-not [string]::IsNullOrWhiteSpace($size)) { $entry.size = $size }
            $links += $entry
        }
    } catch {
        return @()
    }

    return $links
}

function Get-VariableSubItemNames {
    # Names of addressable sub-items a box/group node carries that are NOT in its standard
    # Child()/ChildCount collection but ARE resolvable as "<path>^<name>": IO terminals expose
    # their PDO channels as <RxPdo>/<TxPdo>/<Pdo> <Name> in the box XML, and Festo-style carriers
    # expose <Slot><Module><Name>. Used to walk descendants when collecting links on a box.
    param(
        [Parameter(Mandatory = $false)]
        [string]$Xml
    )

    $names = @()
    if ([string]::IsNullOrEmpty($Xml)) {
        return $names
    }
    try {
        [xml]$doc = $Xml
        foreach ($nameNode in $doc.SelectNodes('//RxPdo/Name | //TxPdo/Name | //Slot/Module/Name')) {
            $n = [string]$nameNode.InnerText
            if (-not [string]::IsNullOrWhiteSpace($n)) {
                $names += $n
            }
        }
    } catch {
        return @()
    }
    return $names
}

function Get-VariableLinksRecursive {
    # Walk the queried item and its descendants collecting every leaf's <LinkedWith>. A leaf
    # variable answers directly from its own XML; a box/group is walked into via both standard
    # Child() children AND addressable PDO-channel / slot-module sub-items (Get-VariableSubItemNames).
    # Bounded by MaxNodes/MaxDepth so a whole-device query cannot run away. Every COM/XML call
    # is guarded; a failure on one node is skipped rather than thrown.
    param(
        [Parameter(Mandatory = $true)]
        $SysManager,

        [Parameter(Mandatory = $true)]
        [object]$TreeItem,

        [int]$Depth = 0,

        [int]$MaxDepth = 8,

        [System.Collections.Generic.HashSet[string]]$Seen,

        [ref]$Budget
    )

    if ($null -eq $Seen) {
        $Seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    }

    $links = @()
    if ($Depth -gt $MaxDepth) {
        return $links
    }
    if ($null -ne $Budget -and $Budget.Value -le 0) {
        return $links
    }

    $path = Normalize-ScalarValue (Get-SafeValue { [string]$TreeItem.PathName })
    if (-not [string]::IsNullOrWhiteSpace($path)) {
        if ($Seen.Contains($path)) {
            return $links
        }
        [void]$Seen.Add($path)
    }
    if ($null -ne $Budget) {
        $Budget.Value = $Budget.Value - 1
    }

    $ownXml = $null
    try {
        $ownXml = $TreeItem.ProduceXml()
    } catch {
        $ownXml = $null
    }

    # Direct links on this node (only present when it is itself a linked leaf variable).
    if (-not [string]::IsNullOrEmpty($ownXml)) {
        try {
            [xml]$doc = $ownXml
            foreach ($node in $doc.SelectNodes('//LinkedWith')) {
                $varB = [string]$node.InnerText
                if ([string]::IsNullOrWhiteSpace($varB)) {
                    continue
                }
                $entry = @{
                    varA = $path
                    varB = $varB
                }
                $offsA = Get-SafeValue { [string]$node.GetAttribute('offsA') }
                $offsB = Get-SafeValue { [string]$node.GetAttribute('offsB') }
                $size = Get-SafeValue { [string]$node.GetAttribute('size') }
                if (-not [string]::IsNullOrWhiteSpace($offsA)) { $entry.offsA = $offsA }
                if (-not [string]::IsNullOrWhiteSpace($offsB)) { $entry.offsB = $offsB }
                if (-not [string]::IsNullOrWhiteSpace($size)) { $entry.size = $size }
                $links += $entry
            }
        } catch {
        }
    }

    # Recurse into standard children.
    $childNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $count = Get-TreeItemChildCount -TreeItem $TreeItem
    for ($i = 1; $i -le $count; $i++) {
        if ($null -ne $Budget -and $Budget.Value -le 0) { break }
        $child = (Get-TreeItemChild -TreeItem $TreeItem -Index $i).Value
        if ($null -eq $child) { continue }
        $cn = Normalize-ScalarValue (Get-SafeValue { [string]$child.Name })
        if (-not [string]::IsNullOrWhiteSpace($cn)) { [void]$childNames.Add($cn) }
        $links += Get-VariableLinksRecursive -SysManager $SysManager -TreeItem $child -Depth ($Depth + 1) -MaxDepth $MaxDepth -Seen $Seen -Budget $Budget
    }

    # Recurse into addressable PDO-channel / slot-module sub-items not already covered.
    if (-not [string]::IsNullOrWhiteSpace($path)) {
        foreach ($subName in (Get-VariableSubItemNames -Xml $ownXml)) {
            if ($null -ne $Budget -and $Budget.Value -le 0) { break }
            if ($childNames.Contains($subName)) { continue }
            $subItem = $null
            try {
                $subItem = (Get-TreeItem -SysManager $SysManager -TreePath ("$path^" + $subName)).Value
            } catch {
                $subItem = $null
            }
            if ($null -eq $subItem) { continue }
            $links += Get-VariableLinksRecursive -SysManager $SysManager -TreeItem $subItem -Depth ($Depth + 1) -MaxDepth $MaxDepth -Seen $Seen -Budget $Budget
        }
    }

    return $links
}

$payload = Get-Payload
$progId = if ($payload.progId) { [string]$payload.progId } else { 'TcXaeShell.DTE.17.0' }
$mode = if ($payload.mode) { [string]$payload.mode } else { 'active' }

Ensure-ComMessageFilter

try {
    switch ($Action) {
        'xae_status' {
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $solution = Get-SolutionInfo -Dte $dte
            $automationSettings = $null
            $sysManagerAvailable = $false

            try {
                $automationSettings = Get-AutomationSettings -Dte $dte
            } catch {
            }

            try {
                $null = Get-SysManager -Dte $dte
                $sysManagerAvailable = $true
            } catch {
                $sysManagerAvailable = $false
            }

            Write-JsonResult @{
                ok = $true
                data = @{
                    progId = $progId
                    mode = $mode
                    solution = $solution
                    automationSettingsAvailable = ($null -ne $automationSettings)
                    sysManagerAvailable = $sysManagerAvailable
                }
            }
            exit 0
        }

        'xae_open_solution' {
            $solutionPath = [string]$payload.solutionPath
            if ([string]::IsNullOrWhiteSpace($solutionPath)) {
                throw 'solutionPath is required'
            }
            if (-not (Test-Path -LiteralPath $solutionPath)) {
                throw "Solution file not found: $solutionPath"
            }

            $visible = $true
            if ($null -ne $payload.visible) {
                $visible = [bool]$payload.visible
            }

            $closeExisting = $false
            if ($null -ne $payload.closeExisting) {
                $closeExisting = [bool]$payload.closeExisting
            }

            $discardChanges = $false
            if ($payload.PSObject.Properties.Name -contains 'discardChanges') {
                $discardChanges = [bool]$payload.discardChanges
            }

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $visible
            try {
                $dte.MainWindow.Visible = $visible
            } catch {
            }

            $current = Get-SolutionInfo -Dte $dte
            if ($current.isOpen -and $closeExisting) {
                $dte.Solution.Close(-not $discardChanges)
            }

            $dte.Solution.Open($solutionPath)
            $solution = Wait-ForSolutionOpen -Dte $dte -ExpectedPath $solutionPath
            $null = Get-AutomationSettings -Dte $dte

            Write-JsonResult @{
                ok = $true
                data = @{
                    progId = $progId
                    solution = $solution
                }
            }
            exit 0
        }

        'xae_list_commands' {
            $filter = if ($payload.filter) { [string]$payload.filter } else { $null }
            $limit = 250
            if ($null -ne $payload.limit) {
                $limit = [int]$payload.limit
            }

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $commands = New-Object System.Collections.Generic.List[string]

            foreach ($cmd in $dte.Commands) {
                try {
                    $name = [string]$cmd.Name
                    if ([string]::IsNullOrWhiteSpace($name)) {
                        continue
                    }
                    if ($filter -and ($name -notmatch $filter)) {
                        continue
                    }
                    $commands.Add($name)
                } catch {
                }
            }

            $result = $commands | Sort-Object -Unique | Select-Object -First $limit
            Write-JsonResult @{
                ok = $true
                data = @{
                    filter = $filter
                    count = @($result).Count
                    commands = @($result)
                }
            }
            exit 0
        }

        'xae_execute_command' {
            $commandName = [string]$payload.commandName
            if ([string]::IsNullOrWhiteSpace($commandName)) {
                throw 'commandName is required'
            }
            $args = if ($payload.PSObject.Properties.Name -contains 'args') { [string]$payload.args } else { '' }

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $null = Get-AutomationSettings -Dte $dte
            $cmd = $dte.Commands.Item($commandName, 0)
            if ($null -eq $cmd) {
                throw "Command not found: $commandName"
            }
            $isAvailable = $true
            try {
                $isAvailable = [bool]$cmd.IsAvailable
            } catch {
            }
            if (-not $isAvailable) {
                throw "Command is not available in the current XAE context: $commandName"
            }

            if ([string]::IsNullOrWhiteSpace($args)) {
                $dte.ExecuteCommand($commandName)
            } else {
                $dte.ExecuteCommand($commandName, $args)
            }

            Write-JsonResult @{
                ok = $true
                data = @{
                    commandName = $commandName
                    args = $args
                    isAvailable = $isAvailable
                    executed = $true
                }
            }
            exit 0
        }

        'xae_get_active_document' {
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $doc = Get-SafeValue { $dte.ActiveDocument }

            Write-JsonResult @{
                ok = $true
                data = @{
                    hasActiveDocument = ($null -ne $doc)
                    name = Get-SafeValue { [string]$doc.Name }
                    fullName = Get-SafeValue { [string]$doc.FullName }
                    kind = Get-SafeValue { [string]$doc.Kind }
                    projectItemName = Get-SafeValue { [string]$doc.ProjectItem.Name }
                }
            }
            exit 0
        }

        'xae_get_selected_items' {
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $items = @()
            $count = 0

            try {
                $count = [int]$dte.SelectedItems.Count
            } catch {
            }

            for ($i = 1; $i -le $count; $i++) {
                $items += Convert-SelectedItem -SelectedItem $dte.SelectedItems.Item($i)
            }

            Write-JsonResult @{
                ok = $true
                data = @{
                    count = $count
                    items = $items
                }
            }
            exit 0
        }

        'xae_focus_tree_item' {
            $treePath = [string]$payload.treePath
            if ([string]::IsNullOrWhiteSpace($treePath)) {
                throw 'treePath is required'
            }

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $item = (Get-TreeItem -SysManager $sysManager -TreePath $treePath).Value
            $vsProjectItem = Get-SafeValue { $item.VSProjectItem }
            if ($null -eq $vsProjectItem) {
                throw "No VSProjectItem is available for tree item: $treePath"
            }

            $null = Get-SafeValue { $dte.ExecuteCommand('View.SolutionExplorer') }
            $null = Get-SafeValue { $vsProjectItem.ExpandView() }

            Write-JsonResult @{
                ok = $true
                data = @{
                    treePath = $treePath
                    expanded = $true
                    note = 'Best effort only. XAE did not expose a reliable programmatic selection method in this environment.'
                }
            }
            exit 0
        }

        'xae_get_error_list' {
            $limit = 200
            if ($null -ne $payload.limit) {
                $limit = [int]$payload.limit
            }

            $errorListResult = Get-XaeErrorListItems -ProgId $progId -Limit $limit
            if ($null -eq $errorListResult) {
                Write-JsonResult @{
                    ok = $true
                    data = @{
                        available = $false
                        count = 0
                        items = @()
                    }
                }
                exit 0
            }

            $resultItems = @()
            foreach ($item in $errorListResult.Items) {
                $resultItems += @{
                    description = Normalize-ScalarValue (Get-SafeValue { [string]$item.Description })
                    fileName = Normalize-ScalarValue (Get-SafeValue { [string]$item.FileName })
                    line = Normalize-ScalarValue (Get-SafeValue { [int]$item.Line })
                    column = Normalize-ScalarValue (Get-SafeValue { [int]$item.Column })
                    project = Normalize-ScalarValue (Get-SafeValue { [string]$item.Project })
                    errorLevel = Normalize-ScalarValue (Get-SafeValue { [string]$item.ErrorLevel })
                }
            }

            Write-JsonResult @{
                ok = $true
                data = @{
                    available = $true
                    count = [int]$errorListResult.TotalCount
                    returned = @($resultItems).Count
                    items = $resultItems
                }
            }
            exit 0
        }

        'xae_clear_error_list' {
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $showResult = Invoke-DteCommand -Dte $dte -CommandName 'View.ErrorList'
            $clearResult = Invoke-DteCommand -Dte $dte -CommandName 'OtherContextMenus.ErrorList.Clear'

            Write-JsonResult @{
                ok = $true
                data = @{
                    cleared = $true
                    showCommand = $showResult
                    clearCommand = $clearResult
                }
            }
            exit 0
        }

        'twincat_lookup_tree_item' {
            $treePath = [string]$payload.treePath
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $item = (Get-TreeItem -SysManager $sysManager -TreePath $treePath).Value

            Write-JsonResult @{
                ok = $true
                data = Convert-TreeItem -TreeItem $item
            }
            exit 0
        }

        'twincat_test_item_path' {
            $treePath = [string]$payload.treePath
            if ([string]::IsNullOrWhiteSpace($treePath)) {
                throw 'treePath is required'
            }

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $exists = $false
            try {
                $item = (Get-TreeItem -SysManager $sysManager -TreePath $treePath).Value
                $exists = ($null -ne $item)
            } catch {
                $exists = $false
            }

            Write-JsonResult @{
                ok = $true
                data = @{
                    treePath = $treePath
                    exists = $exists
                }
            }
            exit 0
        }

        'twincat_test_item_paths' {
            $paths = $payload.paths
            if ($null -eq $paths -or @($paths).Count -eq 0) {
                throw 'paths is required'
            }

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value

            $results = @()
            $found = 0
            $missing = 0

            foreach ($entry in $paths) {
                $entryPath = [string]$entry
                try {
                    $exists = $false
                    try {
                        $item = (Get-TreeItem -SysManager $sysManager -TreePath $entryPath).Value
                        $exists = ($null -ne $item)
                    } catch {
                        $exists = $false
                    }

                    if ($exists) { $found++ } else { $missing++ }
                    $results += @{
                        path = $entryPath
                        exists = $exists
                    }
                } catch {
                    $missing++
                    $results += @{
                        path = $entryPath
                        exists = $false
                        error = [string]$_.Exception.Message
                    }
                }
            }

            Write-JsonResult @{
                ok = $true
                data = @{
                    count = @($paths).Count
                    found = $found
                    missing = $missing
                    results = $results
                }
            }
            exit 0
        }

        'twincat_lookup_tree_items' {
            $paths = $payload.paths
            if ($null -eq $paths -or @($paths).Count -eq 0) {
                throw 'paths is required'
            }

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value

            $results = @()
            $succeeded = 0
            $failed = 0

            foreach ($entry in $paths) {
                $entryPath = [string]$entry
                try {
                    $item = (Get-TreeItem -SysManager $sysManager -TreePath $entryPath).Value
                    $converted = Convert-TreeItem -TreeItem $item
                    $converted.path = $entryPath
                    $converted.ok = $true
                    $succeeded++
                    $results += $converted
                } catch {
                    $failed++
                    $results += @{
                        path = $entryPath
                        ok = $false
                        error = [string]$_.Exception.Message
                    }
                }
            }

            Write-JsonResult @{
                ok = $true
                data = @{
                    count = @($paths).Count
                    succeeded = $succeeded
                    failed = $failed
                    results = $results
                }
            }
            exit 0
        }

        'twincat_resolve_variable_path' {
            $variablePath = [string]$payload.variablePath
            if ([string]::IsNullOrWhiteSpace($variablePath)) {
                throw 'variablePath is required'
            }

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $resolution = Resolve-TwinCatVariablePath -SysManager $sysManager -VariablePath $variablePath

            Write-JsonResult @{
                ok = $true
                data = $resolution
            }
            exit 0
        }

        'twincat_list_children' {
            $treePath = [string]$payload.treePath
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $item = (Get-TreeItem -SysManager $sysManager -TreePath $treePath).Value

            $children = @()
            $count = Get-TreeItemChildCount -TreeItem $item
            $listedNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
            for ($i = 1; $i -le $count; $i++) {
                $childEntry = Convert-TreeItem -TreeItem (Get-TreeItemChild -TreeItem $item -Index $i).Value
                $childEntry['kind'] = 'child'
                $children += $childEntry
                $childName = [string]$childEntry['name']
                if (-not [string]::IsNullOrEmpty($childName)) {
                    [void]$listedNames.Add($childName)
                }
            }

            # Augmentation: some boxes (e.g. Festo CPX-AP-A-EC-M12 EtherCAT couplers)
            # carry addressable sub-modules that are NOT in the standard Child/ChildCount
            # collection but DO live in the box's ProduceXml() as <Slot><Module> entries
            # and ARE resolvable by their full "<boxPath>^<moduleName>" path. Surface them
            # so the tree is fully discoverable by walking. This must never break a normal
            # children call, so every step is defensively guarded.
            #
            # GATE: only run this on nodes with ZERO standard children ($count -eq 0).
            # The CPX-AP-A-EC-M12 carrier reports ChildCount == 0 (its modules are not
            # standard children), while EtherCAT devices and normal couplers report
            # ChildCount > 0 and carry no <Slot><Module> entries. Gating on $count -eq 0
            # confines the expensive ProduceXml() to the actual carriers and avoids
            # serializing+parsing the entire bus (hundreds of KB to MB) on every call —
            # e.g. when listing the children of an EtherCAT device root.
            # Trade-off: a hypothetical box with BOTH standard children AND slot-modules
            # would have its modules missed here — an accepted trade for not
            # ProduceXml-ing every node.
            if ($count -eq 0) {
                $boxXml = $null
                try {
                    $boxXml = $item.ProduceXml()
                } catch {
                    $boxXml = $null
                }

                if (-not [string]::IsNullOrEmpty($boxXml)) {
                    $moduleNames = @()
                    try {
                        [xml]$doc = $boxXml
                        foreach ($nameNode in $doc.SelectNodes('//Slot/Module/Name')) {
                            $moduleName = [string]$nameNode.InnerText
                            if (-not [string]::IsNullOrEmpty($moduleName)) {
                                $moduleNames += $moduleName
                            }
                        }
                    } catch {
                        $moduleNames = @()
                    }

                    foreach ($moduleName in $moduleNames) {
                        if ($listedNames.Contains($moduleName)) {
                            continue
                        }
                        $moduleItem = $null
                        try {
                            $moduleItem = (Get-TreeItem -SysManager $sysManager -TreePath ("$treePath^" + $moduleName)).Value
                        } catch {
                            $moduleItem = $null
                        }
                        if ($null -eq $moduleItem) {
                            continue
                        }
                        $moduleEntry = Convert-TreeItem -TreeItem $moduleItem
                        $moduleEntry['kind'] = 'module'
                        $children += $moduleEntry
                        [void]$listedNames.Add($moduleName)
                    }
                }
            }

            Write-JsonResult @{
                ok = $true
                data = @{
                    treePath = $treePath
                    childCount = $children.Count
                    children = $children
                }
            }
            exit 0
        }

        'twincat_get_tree_item_xml' {
            $treePath = [string]$payload.treePath
            $summary = $false
            if ($payload.PSObject.Properties.Name -contains 'summary') {
                $summary = [bool]$payload.summary
            }

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $item = (Get-TreeItem -SysManager $sysManager -TreePath $treePath).Value

            if (-not $summary) {
                $xml = Strip-TreeImage $item.ProduceXml()

                Write-JsonResult @{
                    ok = $true
                    data = @{
                        treePath = $treePath
                        xml = $xml
                    }
                }
                exit 0
            }

            # Compact summary: identity + slot/module list, without the big XML blob.
            $summaryData = Convert-TreeItem -TreeItem $item

            $moduleNames = @()
            $boxXml = $null
            try {
                $boxXml = $item.ProduceXml()
            } catch {
                $boxXml = $null
            }
            if (-not [string]::IsNullOrEmpty($boxXml)) {
                try {
                    [xml]$doc = $boxXml
                    foreach ($nameNode in $doc.SelectNodes('//Slot/Module/Name')) {
                        $moduleName = [string]$nameNode.InnerText
                        if (-not [string]::IsNullOrEmpty($moduleName)) {
                            $moduleNames += $moduleName
                        }
                    }
                } catch {
                    $moduleNames = @()
                }
            }

            $summaryData['modules'] = $moduleNames

            Write-JsonResult @{
                ok = $true
                data = @{
                    treePath = $treePath
                    summary = $summaryData
                }
            }
            exit 0
        }

        'twincat_set_tree_item_xml' {
            $treePath = [string]$payload.treePath
            $xml = [string]$payload.xml
            if ([string]::IsNullOrWhiteSpace($xml)) {
                throw 'xml is required'
            }

            $returnXml = $false
            if ($payload.PSObject.Properties.Name -contains 'returnXml') {
                $returnXml = [bool]$payload.returnXml
            }

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value

            $item = Set-TreeItemXml -SysManager $sysManager -TargetPath $treePath -Xml $xml

            $data = @{
                treePath = $treePath
            }
            if ($returnXml) {
                $data.xml = Strip-TreeImage $item.ProduceXml()
            }

            Write-JsonResult @{
                ok = $true
                data = $data
            }
            exit 0
        }

        'twincat_rename_tree_item' {
            $treePath = [string]$payload.treePath
            $newName = [string]$payload.newName
            if ([string]::IsNullOrWhiteSpace($newName)) {
                throw 'newName is required'
            }

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value

            $newPath = Rename-TreeItem -SysManager $sysManager -TargetPath $treePath -NewName $newName

            Write-JsonResult @{
                ok = $true
                data = @{
                    treePath = $treePath
                    newName = $newName
                    newPath = $newPath
                }
            }
            exit 0
        }

        'twincat_rename_tree_items' {
            $basePath = [string]$payload.basePath
            $renames = $payload.renames
            if ($null -eq $renames -or @($renames).Count -eq 0) {
                throw 'renames is required'
            }
            $save = $false
            if ($payload.PSObject.Properties.Name -contains 'save') {
                $save = [bool]$payload.save
            }

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value

            $results = @()
            $succeeded = 0
            $failed = 0

            foreach ($entry in $renames) {
                $entryName = $null
                if ($entry.PSObject.Properties.Name -contains 'name') {
                    $entryName = [string]$entry.name
                }
                $entryPath = $null
                if ($entry.PSObject.Properties.Name -contains 'path') {
                    $entryPath = [string]$entry.path
                }
                $entryNewName = $null
                if ($entry.PSObject.Properties.Name -contains 'newName') {
                    $entryNewName = [string]$entry.newName
                }

                if ([string]::IsNullOrWhiteSpace($entryName)) { $entryName = $null }

                $targetPath = $null
                if (-not [string]::IsNullOrWhiteSpace($entryPath)) {
                    $targetPath = $entryPath
                } elseif ($null -ne $entryName) {
                    $targetPath = "$basePath^" + $entryName
                }

                if ($null -eq $targetPath) {
                    $failed++
                    $results += @{
                        name = $entryName
                        newName = $entryNewName
                        ok = $false
                        error = 'entry needs name or path'
                    }
                    continue
                }

                try {
                    [void](Rename-TreeItem -SysManager $sysManager -TargetPath $targetPath -NewName $entryNewName)
                    $succeeded++
                    $results += @{
                        name = $entryName
                        newName = $entryNewName
                        ok = $true
                    }
                } catch {
                    $failed++
                    $results += @{
                        name = $entryName
                        newName = $entryNewName
                        ok = $false
                        error = [string]$_.Exception.Message
                    }
                }
            }

            $data = @{
                parent = $basePath
                count = @($renames).Count
                succeeded = $succeeded
                failed = $failed
                results = $results
            }
            if ($save) {
                $saved = $false
                try { Save-Solution -Dte $dte; $saved = $true } catch { $saved = $false }
                $data.saved = $saved
            }

            Write-JsonResult @{
                ok = $true
                data = $data
            }
            exit 0
        }

        'twincat_set_tree_item_xml_batch' {
            $items = $payload.items
            if ($null -eq $items -or @($items).Count -eq 0) {
                throw 'items is required'
            }

            $returnXml = $false
            if ($payload.PSObject.Properties.Name -contains 'returnXml') {
                $returnXml = [bool]$payload.returnXml
            }
            $save = $false
            if ($payload.PSObject.Properties.Name -contains 'save') {
                $save = [bool]$payload.save
            }

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value

            $results = @()
            $succeeded = 0
            $failed = 0

            foreach ($entry in $items) {
                $entryPath = $null
                if ($entry.PSObject.Properties.Name -contains 'path') {
                    $entryPath = [string]$entry.path
                }
                $entryXml = $null
                if ($entry.PSObject.Properties.Name -contains 'xml') {
                    $entryXml = [string]$entry.xml
                }

                if ([string]::IsNullOrWhiteSpace($entryPath) -or [string]::IsNullOrWhiteSpace($entryXml)) {
                    $failed++
                    $results += @{
                        path = $entryPath
                        ok = $false
                        error = 'entry needs path and xml'
                    }
                    continue
                }

                try {
                    $item = Set-TreeItemXml -SysManager $sysManager -TargetPath $entryPath -Xml $entryXml
                    $succeeded++
                    $entryResult = @{
                        path = $entryPath
                        ok = $true
                    }
                    if ($returnXml) {
                        $entryResult.xml = Strip-TreeImage $item.ProduceXml()
                    }
                    $results += $entryResult
                } catch {
                    $failed++
                    $results += @{
                        path = $entryPath
                        ok = $false
                        error = [string]$_.Exception.Message
                    }
                }
            }

            $data = @{
                count = @($items).Count
                succeeded = $succeeded
                failed = $failed
                results = $results
            }
            if ($save) {
                $saved = $false
                try { Save-Solution -Dte $dte; $saved = $true } catch { $saved = $false }
                $data.saved = $saved
            }

            Write-JsonResult @{
                ok = $true
                data = $data
            }
            exit 0
        }

        'twincat_link_variables' {
            $producer = [string]$payload.producer
            $consumer = [string]$payload.consumer
            $autoResolve = $true
            if ($payload.PSObject.Properties.Name -contains 'autoResolve') {
                $autoResolve = [bool]$payload.autoResolve
            }
            if ([string]::IsNullOrWhiteSpace($producer) -or [string]::IsNullOrWhiteSpace($consumer)) {
                throw 'producer and consumer are required'
            }

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value

            $result = Link-Variables -SysManager $sysManager -Producer $producer -Consumer $consumer -AutoResolve $autoResolve

            Write-JsonResult @{
                ok = $true
                data = $result
            }
            exit 0
        }

        'twincat_link_variables_batch' {
            $links = $payload.links
            if ($null -eq $links -or @($links).Count -eq 0) {
                throw 'links is required'
            }
            $autoResolve = $true
            if ($payload.PSObject.Properties.Name -contains 'autoResolve') {
                $autoResolve = [bool]$payload.autoResolve
            }
            $save = $false
            if ($payload.PSObject.Properties.Name -contains 'save') {
                $save = [bool]$payload.save
            }

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value

            $results = @()
            $succeeded = 0
            $failed = 0

            foreach ($entry in $links) {
                $entryA = $null
                if ($entry.PSObject.Properties.Name -contains 'a') {
                    $entryA = [string]$entry.a
                }
                $entryB = $null
                if ($entry.PSObject.Properties.Name -contains 'b') {
                    $entryB = [string]$entry.b
                }

                if ([string]::IsNullOrWhiteSpace($entryA) -or [string]::IsNullOrWhiteSpace($entryB)) {
                    $failed++
                    $results += @{
                        a = $entryA
                        b = $entryB
                        ok = $false
                        error = 'entry needs a and b'
                    }
                    continue
                }

                try {
                    $linkResult = Link-Variables -SysManager $sysManager -Producer $entryA -Consumer $entryB -AutoResolve $autoResolve
                    $succeeded++
                    $results += @{
                        a = $entryA
                        b = $entryB
                        resolvedA = [string]$linkResult.producerResolution.resolvedPath
                        resolvedB = [string]$linkResult.consumerResolution.resolvedPath
                        ok = $true
                    }
                } catch {
                    $failed++
                    $results += @{
                        a = $entryA
                        b = $entryB
                        ok = $false
                        error = [string]$_.Exception.Message
                    }
                }
            }

            $data = @{
                count = @($links).Count
                succeeded = $succeeded
                failed = $failed
                results = $results
            }
            if ($save) {
                $saved = $false
                try { Save-Solution -Dte $dte; $saved = $true } catch { $saved = $false }
                $data.saved = $saved
            }

            Write-JsonResult @{
                ok = $true
                data = $data
            }
            exit 0
        }

        'twincat_unlink_variables' {
            $variableA = [string]$payload.variableA
            $variableB = if ($payload.PSObject.Properties.Name -contains 'variableB') { [string]$payload.variableB } else { $null }
            if ([string]::IsNullOrWhiteSpace($variableA)) {
                throw 'variableA is required'
            }

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value

            if ([string]::IsNullOrWhiteSpace($variableB)) {
                $sysManager.UnlinkVariables($variableA)
            } else {
                $sysManager.UnlinkVariables($variableA, $variableB)
            }

            Write-JsonResult @{
                ok = $true
                data = @{
                    variableA = $variableA
                    variableB = $variableB
                    unlinked = $true
                }
            }
            exit 0
        }

        'twincat_unlink_variables_batch' {
            $links = $payload.links
            if ($null -eq $links -or @($links).Count -eq 0) {
                throw 'links is required'
            }
            $save = $false
            if ($payload.PSObject.Properties.Name -contains 'save') {
                $save = [bool]$payload.save
            }

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value

            $results = @()
            $succeeded = 0
            $failed = 0

            foreach ($entry in $links) {
                $entryA = $null
                if ($entry.PSObject.Properties.Name -contains 'a') {
                    $entryA = [string]$entry.a
                }
                $entryB = $null
                if ($entry.PSObject.Properties.Name -contains 'b') {
                    $entryB = [string]$entry.b
                }

                if ([string]::IsNullOrWhiteSpace($entryA)) {
                    $failed++
                    $results += @{
                        a = $entryA
                        b = $entryB
                        ok = $false
                        error = 'entry needs a'
                    }
                    continue
                }

                try {
                    if ([string]::IsNullOrWhiteSpace($entryB)) {
                        $sysManager.UnlinkVariables($entryA)
                    } else {
                        $sysManager.UnlinkVariables($entryA, $entryB)
                    }
                    $succeeded++
                    $results += @{
                        a = $entryA
                        b = $entryB
                        ok = $true
                    }
                } catch {
                    $failed++
                    $results += @{
                        a = $entryA
                        b = $entryB
                        ok = $false
                        error = [string]$_.Exception.Message
                    }
                }
            }

            $data = @{
                count = @($links).Count
                succeeded = $succeeded
                failed = $failed
                results = $results
            }
            if ($save) {
                $saved = $false
                try { Save-Solution -Dte $dte; $saved = $true } catch { $saved = $false }
                $data.saved = $saved
            }

            Write-JsonResult @{
                ok = $true
                data = $data
            }
            exit 0
        }

        'twincat_get_variable_links' {
            $path = [string]$payload.path
            if ([string]::IsNullOrWhiteSpace($path)) {
                throw 'path is required'
            }

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $item = (Get-TreeItem -SysManager $sysManager -TreePath $path).Value

            # A linked leaf variable lists its links directly in its own ProduceXml under
            # <VarDef><LinkedWith>. If the queried path is itself such a leaf, that's all we
            # need. Otherwise (a box/terminal/group) its own Xml carries no <LinkedWith>, so
            # walk descendants and collect each leaf's links (bounded recursion).
            $directLinks = @()
            try {
                $directLinks = @(Get-VariableLinksFromXml -TreeItem $item)
            } catch {
                $directLinks = @()
            }

            $links = $directLinks
            if (@($links).Count -eq 0) {
                try {
                    $budget = [ref]2000
                    $links = @(Get-VariableLinksRecursive -SysManager $sysManager -TreeItem $item -Budget $budget)
                } catch {
                    $links = @()
                }
            }

            Write-JsonResult @{
                ok = $true
                data = @{
                    path = $path
                    count = @($links).Count
                    links = @($links)
                }
            }
            exit 0
        }

        'twincat_create_child' {
            $parentPath = [string]$payload.parentPath
            $childName = [string]$payload.childName
            $subType = [int]$payload.subType
            $beforeChildName = if ($payload.beforeChildName) { [string]$payload.beforeChildName } else { '' }
            $createInfo = if ($payload.PSObject.Properties.Name -contains 'createInfo' -and -not [string]::IsNullOrWhiteSpace([string]$payload.createInfo)) { [string]$payload.createInfo } else { $null }

            if ([string]::IsNullOrWhiteSpace($parentPath) -or [string]::IsNullOrWhiteSpace($childName)) {
                throw 'parentPath and childName are required'
            }

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $parent = (Get-TreeItem -SysManager $sysManager -TreePath $parentPath).Value
            $child = $parent.CreateChild($childName, $subType, $beforeChildName, $createInfo)

            # Validate the created child; on a malformed "ghost" this throws (with
            # best-effort cleanup) instead of returning a false success.
            Assert-WellFormedChild -Parent $parent -Child $child -RequestedName $childName -SubType $subType -ParentPath $parentPath

            Write-JsonResult @{
                ok = $true
                data = @{
                    parentPath = $parentPath
                    child = Convert-TreeItem -TreeItem $child
                }
            }
            exit 0
        }

        'twincat_delete_child' {
            $parentPath = [string]$payload.parentPath
            $childName = [string]$payload.childName
            if ([string]::IsNullOrWhiteSpace($parentPath) -or [string]::IsNullOrWhiteSpace($childName)) {
                throw 'parentPath and childName are required'
            }

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $parent = (Get-TreeItem -SysManager $sysManager -TreePath $parentPath).Value
            $parent.DeleteChild($childName)

            Write-JsonResult @{
                ok = $true
                data = @{
                    parentPath = $parentPath
                    childName = $childName
                    deleted = $true
                }
            }
            exit 0
        }

        'twincat_create_children' {
            $creates = $payload.creates
            if ($null -eq $creates -or @($creates).Count -eq 0) {
                throw 'creates is required'
            }
            $save = $false
            if ($payload.PSObject.Properties.Name -contains 'save') {
                $save = [bool]$payload.save
            }

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value

            $results = @()
            $succeeded = 0
            $failed = 0

            foreach ($entry in $creates) {
                $entryParent = $null
                if ($entry.PSObject.Properties.Name -contains 'parent') {
                    $entryParent = [string]$entry.parent
                }
                $entryName = $null
                if ($entry.PSObject.Properties.Name -contains 'name') {
                    $entryName = [string]$entry.name
                }
                $entrySubType = $null
                if ($entry.PSObject.Properties.Name -contains 'subType') {
                    $entrySubType = $entry.subType
                }
                $entryBefore = if ($entry.PSObject.Properties.Name -contains 'before' -and $entry.before) { [string]$entry.before } else { '' }
                $entryCreateInfo = if ($entry.PSObject.Properties.Name -contains 'createInfo' -and -not [string]::IsNullOrWhiteSpace([string]$entry.createInfo)) { [string]$entry.createInfo } else { $null }

                if ([string]::IsNullOrWhiteSpace($entryParent) -or [string]::IsNullOrWhiteSpace($entryName) -or $null -eq $entrySubType) {
                    $failed++
                    $results += @{
                        parent = $entryParent
                        name = $entryName
                        ok = $false
                        error = 'entry needs parent, name, subType'
                    }
                    continue
                }

                try {
                    $parent = (Get-TreeItem -SysManager $sysManager -TreePath $entryParent).Value
                    $child = $parent.CreateChild($entryName, [int]$entrySubType, $entryBefore, $entryCreateInfo)
                    # Validate per entry; a malformed ghost throws (with best-effort
                    # cleanup) and is recorded below as this entry's ok:false error,
                    # while the loop continues — never reported as a success.
                    Assert-WellFormedChild -Parent $parent -Child $child -RequestedName $entryName -SubType ([int]$entrySubType) -ParentPath $entryParent
                    $succeeded++
                    $results += @{
                        parent = $entryParent
                        ok = $true
                        child = Convert-TreeItem -TreeItem $child
                    }
                } catch {
                    $failed++
                    $results += @{
                        parent = $entryParent
                        name = $entryName
                        ok = $false
                        error = [string]$_.Exception.Message
                    }
                }
            }

            $data = @{
                count = @($creates).Count
                succeeded = $succeeded
                failed = $failed
                results = $results
            }
            if ($save) {
                $saved = $false
                try { Save-Solution -Dte $dte; $saved = $true } catch { $saved = $false }
                $data.saved = $saved
            }

            Write-JsonResult @{
                ok = $true
                data = $data
            }
            exit 0
        }

        'twincat_delete_children' {
            $deletes = $payload.deletes
            if ($null -eq $deletes -or @($deletes).Count -eq 0) {
                throw 'deletes is required'
            }
            $dryRun = $false
            if ($payload.PSObject.Properties.Name -contains 'dryRun') {
                $dryRun = [bool]$payload.dryRun
            }
            $save = $false
            if ($payload.PSObject.Properties.Name -contains 'save') {
                $save = [bool]$payload.save
            }

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value

            if ($dryRun) {
                # Preview only — never deletes anything. For each entry, resolve the
                # parent and report whether the named child currently exists.
                $results = @()
                $present = 0
                $missing = 0
                foreach ($entry in $deletes) {
                    $entryParent = $null
                    if ($entry.PSObject.Properties.Name -contains 'parent') {
                        $entryParent = [string]$entry.parent
                    }
                    $entryName = $null
                    if ($entry.PSObject.Properties.Name -contains 'name') {
                        $entryName = [string]$entry.name
                    }

                    $exists = $false
                    if (-not [string]::IsNullOrWhiteSpace($entryParent) -and -not [string]::IsNullOrWhiteSpace($entryName)) {
                        try {
                            $parent = (Get-TreeItem -SysManager $sysManager -TreePath $entryParent).Value
                            try {
                                [void](Get-ChildTreeItemByName -ParentItem $parent -ChildName $entryName)
                                $exists = $true
                            } catch {
                                $exists = $false
                            }
                        } catch {
                            $exists = $false
                        }
                    }

                    if ($exists) { $present++ } else { $missing++ }
                    $results += @{
                        parent = $entryParent
                        name = $entryName
                        exists = $exists
                    }
                }

                Write-JsonResult @{
                    ok = $true
                    data = @{
                        mode = 'dryRun'
                        count = @($deletes).Count
                        present = $present
                        missing = $missing
                        results = $results
                    }
                }
                exit 0
            }

            $results = @()
            $succeeded = 0
            $failed = 0

            foreach ($entry in $deletes) {
                $entryParent = $null
                if ($entry.PSObject.Properties.Name -contains 'parent') {
                    $entryParent = [string]$entry.parent
                }
                $entryName = $null
                if ($entry.PSObject.Properties.Name -contains 'name') {
                    $entryName = [string]$entry.name
                }

                if ([string]::IsNullOrWhiteSpace($entryParent) -or [string]::IsNullOrWhiteSpace($entryName)) {
                    $failed++
                    $results += @{
                        parent = $entryParent
                        name = $entryName
                        ok = $false
                        error = 'entry needs parent, name'
                    }
                    continue
                }

                try {
                    $parent = (Get-TreeItem -SysManager $sysManager -TreePath $entryParent).Value
                    $parent.DeleteChild($entryName)
                    $succeeded++
                    $results += @{
                        parent = $entryParent
                        name = $entryName
                        ok = $true
                    }
                } catch {
                    $failed++
                    $results += @{
                        parent = $entryParent
                        name = $entryName
                        ok = $false
                        error = [string]$_.Exception.Message
                    }
                }
            }

            $data = @{
                count = @($deletes).Count
                succeeded = $succeeded
                failed = $failed
                results = $results
            }
            if ($save) {
                $saved = $false
                try { Save-Solution -Dte $dte; $saved = $true } catch { $saved = $false }
                $data.saved = $saved
            }

            Write-JsonResult @{
                ok = $true
                data = $data
            }
            exit 0
        }

        'twincat_import_child' {
            $parentPath = [string]$payload.parentPath
            $filePath = [string]$payload.filePath
            if ([string]::IsNullOrWhiteSpace($parentPath) -or [string]::IsNullOrWhiteSpace($filePath)) {
                throw 'parentPath and filePath are required'
            }
            if (-not (Test-Path -LiteralPath $filePath)) {
                throw "Import file not found: $filePath"
            }

            $beforeChildName = if ($payload.beforeChildName) { [string]$payload.beforeChildName } else { '' }
            $reconnect = $true
            if ($null -ne $payload.reconnect) {
                $reconnect = [bool]$payload.reconnect
            }
            $importAsName = if ($payload.importAsName) { [string]$payload.importAsName } else { '' }

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $parent = (Get-TreeItem -SysManager $sysManager -TreePath $parentPath).Value
            $child = $parent.ImportChild($filePath, $beforeChildName, $reconnect, $importAsName)

            Write-JsonResult @{
                ok = $true
                data = @{
                    parentPath = $parentPath
                    filePath = $filePath
                    child = Convert-TreeItem -TreeItem $child
                }
            }
            exit 0
        }

        'twincat_export_child' {
            $parentPath = [string]$payload.parentPath
            $childName = [string]$payload.childName
            $filePath = [string]$payload.filePath
            if ([string]::IsNullOrWhiteSpace($parentPath) -or [string]::IsNullOrWhiteSpace($childName) -or [string]::IsNullOrWhiteSpace($filePath)) {
                throw 'parentPath, childName, and filePath are required'
            }

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $parent = (Get-TreeItem -SysManager $sysManager -TreePath $parentPath).Value
            $parent.ExportChild($childName, $filePath)

            Write-JsonResult @{
                ok = $true
                data = @{
                    parentPath = $parentPath
                    childName = $childName
                    filePath = $filePath
                    exported = $true
                }
            }
            exit 0
        }

        'twincat_create_io' {
            # NATIVE EtherCAT IO creator (tc_ethercat). For each requested module the
            # box is created by the GUI's own "Add Box" route, exposed through the
            # Automation Interface:
            #
            #   ITcSmTreeItem.CreateChild(<name>, 9099, <before>, "<productString>")
            #
            # The 4th arg (vInfo / createInfo) is the PLAIN PRODUCT STRING -- the
            # bare type ("EL1008", which selects the latest ESI revision) or a
            # revision-pinned form ("EL1008-0000-0017"). TwinCAT then expands the
            # box FROM ITS OWN ESI, producing a fully populated, non-hollow box
            # (correct identity, SyncManagers with TwinCAT-computed blobs, FMMUs,
            # the full <EtherCAT> mailbox/CoE/FoE element, and complete PDOs with
            # all entries) for ANY device class -- digital, analog, IO-Link,
            # mailbox, DC, couplers. (The old dead-end was passing identity XML /
            # VendorId+ProductCode numbers as vInfo; that yields a blank-named
            # ghost. The product string is the GUI's own input.)
            #
            # Revision pin format (confirmed live against EL1008): the product
            # string suffix is "<Type>-<pppp>-<rrrr>" where both groups are DECIMAL
            #   pppp = product-code variant (the EtherCAT "0000" variant)
            #   rrrr = the decimal revision number; TwinCAT renders it into the high
            #          16 bits of RevisionNo, e.g. "0016" -> RevisionNo #x00100000,
            #          "0017" -> #x00110000. A bare type (no suffix) = latest.
            # The caller supplies the full pinned string verbatim via `revision`.
            #
            # There is NO fallback: if CreateChild throws (or Assert-WellFormedChild
            # rejects a ghost) for a module, that ONE module is a clean per-entry
            # ok:false and the loop continues. Assert-WellFormedChild does best-effort
            # cleanup of any stray blank child.
            #
            # ONE unified shape -- a single box and a full multi-coupler design are
            # the SAME operation:
            #   racks:[ { parent, modules:[ { type, name?, revision?, before? } ] } ]
            # Modules are created in array order under their parent (left-to-right
            # terminal order); `before` inserts ahead of a named sibling. A single
            # box is just racks:[{parent, modules:[{type}]}]. One global save:true
            # saves the solution once after everything. Sequential, continue-on-error;
            # returns a flat roll-up across all racks.
            $racks = $payload.racks
            if ($null -eq $racks -or @($racks).Count -eq 0) {
                throw 'racks (non-empty array of {parent, modules:[...]}) is required'
            }
            $save = ($null -ne $payload.save) -and [bool]$payload.save

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value

            $results = @()
            $succeeded = 0
            $failed = 0

            foreach ($rack in @($racks)) {
                $parentPath = [string]$rack.parent
                $modules = $rack.modules

                # Resolve the parent once per rack. A bad parent path turns every
                # module under it into a clean per-entry failure (loop never throws).
                $parent = $null
                $parentError = $null
                if ([string]::IsNullOrWhiteSpace($parentPath)) {
                    $parentError = 'rack.parent is required'
                } else {
                    try { $parent = (Get-TreeItem -SysManager $sysManager -TreePath $parentPath).Value }
                    catch { $parentError = 'parent lookup failed: ' + [string]$_.Exception.Message }
                }

                foreach ($m in @($modules)) {
                    $type = [string]$m.type
                    $revision = if ($m.PSObject.Properties.Name -contains 'revision' -and -not [string]::IsNullOrWhiteSpace([string]$m.revision)) { [string]$m.revision } else { $null }
                    $wantName = if ($m.PSObject.Properties.Name -contains 'name' -and -not [string]::IsNullOrWhiteSpace([string]$m.name)) { [string]$m.name } else { $null }
                    $before = if ($m.PSObject.Properties.Name -contains 'before' -and -not [string]::IsNullOrWhiteSpace([string]$m.before)) { [string]$m.before } else { '' }
                    # Default the box name to the type when name is omitted.
                    $boxName = if ($wantName) { $wantName } else { $type }
                    $entry = @{ parent = $parentPath; type = $type; name = $boxName; ok = $false }

                    if ($null -ne $parentError) {
                        $entry.error = $parentError
                        $failed++
                        $results += $entry
                        continue
                    }
                    if ([string]::IsNullOrWhiteSpace($type)) {
                        $entry.error = 'module.type is required'
                        $failed++
                        $results += $entry
                        continue
                    }

                    # createInfo = the plain product string. Bare type => latest
                    # revision; with a revision suffix it is the full pinned product
                    # string (appended verbatim if the caller passed only the suffix).
                    $createInfo = if ($revision) {
                        if ($revision.StartsWith($type)) { $revision } else { "$type-$revision" }
                    } else { $type }

                    try {
                        $child = $parent.CreateChild($boxName, 9099, $before, $createInfo)
                        # Throws (with best-effort ghost cleanup) on a blank /
                        # mismatched / misplaced child -- a bad/unknown product string.
                        Assert-WellFormedChild -Parent $parent -Child $child -RequestedName $boxName -SubType 9099 -ParentPath $parentPath
                        $entry.name = Get-SafeValue { [string]$child.Name }
                        $entry.path = Get-SafeValue { [string]$child.PathName }
                        $entry.createInfo = $createInfo
                        $entry.ok = $true
                        $succeeded++
                    } catch {
                        $entry.createInfo = $createInfo
                        $entry.error = [string]$_.Exception.Message
                        $failed++
                    }
                    $results += $entry
                }
            }

            $saved = $null
            if ($save) {
                try { Save-Solution -Dte $dte; $saved = $true } catch { $saved = $false }
            }

            Write-JsonResult @{
                ok = $true
                data = @{
                    count = @($results).Count
                    succeeded = $succeeded
                    failed = $failed
                    saved = $saved
                    results = $results
                }
            }
            exit 0
        }

        'twincat_get_target_netid' {
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value

            Write-JsonResult @{
                ok = $true
                data = @{
                    targetNetId = [string]$sysManager.GetTargetNetId()
                }
            }
            exit 0
        }

        'twincat_set_target_netid' {
            $targetNetId = [string]$payload.targetNetId
            if ([string]::IsNullOrWhiteSpace($targetNetId)) {
                throw 'targetNetId is required'
            }

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $sysManager.SetTargetNetId($targetNetId)

            Write-JsonResult @{
                ok = $true
                data = @{
                    targetNetId = [string]$sysManager.GetTargetNetId()
                }
            }
            exit 0
        }

        'twincat_get_system_manager_errors' {
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $messages = Get-SafeValue { [string]$sysManager.GetLastErrorMessages() }

            Write-JsonResult @{
                ok = $true
                data = @{
                    messages = $messages
                }
            }
            exit 0
        }

        'twincat_rescan_plc_project' {
            $treePath = if ($payload.treePath) { [string]$payload.treePath } else { 'TIPC' }
            $xml = '<TreeItem><PlcDef><ReScan>1</ReScan></PlcDef></TreeItem>'

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $item = (Get-TreeItem -SysManager $sysManager -TreePath $treePath).Value
            $item.ConsumeXml($xml)

            Write-JsonResult @{
                ok = $true
                data = @{
                    treePath = $treePath
                    rescanned = $true
                }
            }
            exit 0
        }

        'twincat_scan_io_boxes' {
            $treePath = [string]$payload.treePath
            if ([string]::IsNullOrWhiteSpace($treePath)) {
                throw 'treePath is required'
            }
            $xml = '<TreeItem><DeviceDef><ScanBoxes>1</ScanBoxes></DeviceDef></TreeItem>'

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $item = (Get-TreeItem -SysManager $sysManager -TreePath $treePath).Value
            $item.ConsumeXml($xml)

            Write-JsonResult @{
                ok = $true
                data = @{
                    treePath = $treePath
                    scanTriggered = $true
                }
            }
            exit 0
        }

        'xae_save_all' {
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            Save-Solution -Dte $dte

            Write-JsonResult @{
                ok = $true
                data = @{
                    saved = $true
                    solution = Get-SolutionInfo -Dte $dte
                }
            }
            exit 0
        }

        'nc_list_tasks' {
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $motionRoot = (Get-TreeItem -SysManager $sysManager -TreePath 'TINC').Value
            $tasks = @()
            $count = Normalize-ScalarValue (Get-SafeValue { $motionRoot.ChildCount })
            if ($null -eq $count) {
                $count = 0
            }
            for ($i = 1; $i -le [int]$count; $i++) {
                $child = $motionRoot.Child($i)
                $tasks += @{
                    name = Normalize-ScalarValue (Get-SafeValue { [string]$child.Name })
                    pathName = Normalize-ScalarValue (Get-SafeValue { [string]$child.PathName })
                    childCount = Normalize-ScalarValue (Get-SafeValue { [int]$child.ChildCount })
                    itemType = Normalize-ScalarValue (Get-SafeValue { [int]$child.ItemType })
                }
            }

            Write-JsonResult @{
                ok = $true
                data = @{
                    rootPath = 'TINC'
                    count = @($tasks).Count
                    tasks = $tasks
                }
            }
            exit 0
        }

        'nc_list_axes' {
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $requestedTaskPath = $null
            if ($payload.taskPath) {
                $requestedTaskPath = [string]$payload.taskPath
            }
            $taskPath = Resolve-NcTaskPath -SysManager $sysManager -RequestedTaskPath $requestedTaskPath
            $task = (Get-TreeItem -SysManager $sysManager -TreePath $taskPath).Value
            $axesRoot = $task.LookupChild('Axes')
            if ($null -eq $axesRoot) {
                throw "Axes node was not found under task: $taskPath"
            }
            $axesPath = Normalize-ScalarValue (Get-SafeValue { [string]$axesRoot.PathName })
            $axes = @()
            $count = Normalize-ScalarValue (Get-SafeValue { $axesRoot.ChildCount })
            if ($null -eq $count) {
                $count = 0
            }
            for ($i = 1; $i -le [int]$count; $i++) {
                $child = $axesRoot.Child($i)
                $axes += @{
                    name = Normalize-ScalarValue (Get-SafeValue { [string]$child.Name })
                    pathName = Normalize-ScalarValue (Get-SafeValue { [string]$child.PathName })
                    childCount = Normalize-ScalarValue (Get-SafeValue { [int]$child.ChildCount })
                    itemType = Normalize-ScalarValue (Get-SafeValue { [int]$child.ItemType })
                    itemSubType = Normalize-ScalarValue (Get-SafeValue { [int]$child.ItemSubType })
                    itemSubTypeName = Normalize-ScalarValue (Get-SafeValue { [string]$child.ItemSubTypeName })
                }
            }

            Write-JsonResult @{
                ok = $true
                data = @{
                    taskPath = $taskPath
                    axesPath = $axesPath
                    count = @($axes).Count
                    axes = $axes
                }
            }
            exit 0
        }

        'nc_get_axis_info' {
            $axisPath = [string]$payload.axisPath
            if ([string]::IsNullOrWhiteSpace($axisPath)) {
                throw 'axisPath is required'
            }

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $axesSep = $axisPath.LastIndexOf('^Axes^')
            if ($axesSep -lt 0) {
                throw 'axisPath must include ^Axes^ before the axis name'
            }
            $taskPath = $axisPath.Substring(0, $axesSep)
            $axisName = $axisPath.Substring($axesSep + 6)
            $task = (Get-TreeItem -SysManager $sysManager -TreePath $taskPath).Value
            $axesRoot = $task.LookupChild('Axes')
            if ($null -eq $axesRoot) {
                throw "Axes node was not found under task: $taskPath"
            }
            $axis = (Get-ChildTreeItemByName -ParentItem $axesRoot -ChildName $axisName).Value
            $children = @()
            $count = Normalize-ScalarValue (Get-SafeValue { $axis.ChildCount })
            if ($null -eq $count) {
                $count = 0
            }
            for ($i = 1; $i -le [int]$count; $i++) {
                $children += Convert-TreeItem -TreeItem $axis.Child($i)
            }

            Write-JsonResult @{
                ok = $true
                data = @{
                    axis = Convert-TreeItem -TreeItem $axis
                    itemSubType = Get-SafeValue { [int]$axis.ItemSubType }
                    itemSubTypeName = Get-SafeValue { [string]$axis.ItemSubTypeName }
                    moduleTypeName = Get-SafeValue { [string]$axis.ModuleTypeName }
                    moduleInstanceName = Get-SafeValue { [string]$axis.ModuleInstanceName }
                    children = $children
                }
            }
            exit 0
        }

        'xae_solution_build' {
            $actionName = [string]$payload.action
            if ([string]::IsNullOrWhiteSpace($actionName)) {
                throw 'action is required'
            }

            $waitForFinish = $true
            if ($null -ne $payload.waitForFinish) {
                $waitForFinish = [bool]$payload.waitForFinish
            }

            $timeoutMs = 1800000
            if ($null -ne $payload.timeoutMs) {
                $timeoutMs = [int]$payload.timeoutMs
            }

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $solution = Get-SolutionInfo -Dte $dte
            if (-not $solution.isOpen) {
                throw 'No solution is open in XAE'
            }

            $solutionBuild = $dte.Solution.SolutionBuild

            switch ($actionName) {
                'clean' {
                    $solutionBuild.Clean($waitForFinish)
                }
                'build' {
                    $solutionBuild.Build($waitForFinish)
                }
                'rebuild' {
                    $solutionBuild.Clean($waitForFinish)
                    if ($waitForFinish) {
                        $null = Wait-ForBuildFinish -SolutionBuild $solutionBuild -TimeoutMs $timeoutMs
                    }
                    $solutionBuild.Build($waitForFinish)
                }
                default {
                    throw "Unsupported build action: $actionName"
                }
            }

            $buildResult = @{
                buildState = [int]$solutionBuild.BuildState
                lastBuildInfo = $null
            }

            if ($waitForFinish) {
                $buildResult = Wait-ForBuildFinish -SolutionBuild $solutionBuild -TimeoutMs $timeoutMs
            } else {
                try {
                    $buildResult.lastBuildInfo = [int]$solutionBuild.LastBuildInfo
                } catch {
                }
            }

            Write-JsonResult @{
                ok = $true
                data = @{
                    action = $actionName
                    waited = $waitForFinish
                    solution = $solution
                    build = $buildResult
                }
            }
            exit 0
        }

        'twincat_activate_configuration' {
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $sysManager.ActivateConfiguration()

            Write-JsonResult @{
                ok = $true
                data = @{
                    activated = $true
                }
            }
            exit 0
        }

        'plc_login' {
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $candidates = @()
            if ($payload.commandName) { $candidates += [string]$payload.commandName }
            $candidates += 'OtherContextMenus.PlcProject.Login'
            $result = Invoke-PlcProjectCommand -Dte $dte -CandidateCommands $candidates -FallbackPattern '^PLC\.Loginto' -PlcItemName ([string]$payload.itemName)

            Write-JsonResult @{
                ok = $true
                data = $result
            }
            exit 0
        }

        'plc_download' {
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $method = if ($payload.method) { [string]$payload.method } else { 'bootproject' }

            if ($method -eq 'command') {
                # Legacy route via the IDE command surface. Requires a shell whose DTE
                # exposes window automation so the PLC project node can be selected
                # (the 64-bit TcXaeShell 17.0 DTE reports Windows.Count = 0 and cannot).
                $candidates = @()
                if ($payload.commandName) { $candidates += [string]$payload.commandName }
                $candidates += 'PLC.Downloadnone'
                $result = Invoke-PlcProjectCommand -Dte $dte -CandidateCommands $candidates -FallbackPattern '^PLC\.Download' -PlcItemName ([string]$payload.itemName)

                Write-JsonResult @{
                    ok = $true
                    data = $result
                }
                exit 0
            }

            # Default: headless deployment via ITcPlcProject (Beckhoff CI path).
            # GenerateBootProject($true) writes the boot project to the target's boot
            # directory; the runtime loads it on the next TwinCAT restart.
            $sysManager = (Get-SysManager -Dte $dte).Value

            # ITcPlcProject is implemented by the PLC root node (TIPC^<name>), NOT the
            # nested "<name> Project" node (that one only carries ITcPlcIECProject*).
            $treePath = [string]$payload.treePath
            if ([string]::IsNullOrWhiteSpace($treePath)) {
                $tipc = $sysManager.LookupTreeItem('TIPC')
                if ([int]$tipc.ChildCount -lt 1) {
                    throw 'No PLC project found under TIPC'
                }
                $plcName = [string]$tipc.Child(1).Name
                $treePath = "TIPC^$plcName"
            }

            $plcProject = $sysManager.LookupTreeItem($treePath)
            $autostart = $true
            if ($null -ne $payload.autostart) {
                $autostart = [bool]$payload.autostart
            }
            if (-not (Ensure-TcPlcProjectHelper)) {
                throw 'TCatSysManagerLib.dll could not be loaded; the typed ITcPlcProject cast is required for boot project deployment on this shell'
            }
            [Te1000PlcProjectHelper]::Deploy($plcProject, $autostart, $true)

            Write-JsonResult @{
                ok = $true
                data = @{
                    method = 'bootproject'
                    treePath = $treePath
                    bootProjectGenerated = $true
                    bootProjectAutostart = $autostart
                    targetNetId = (Get-SafeValue { [string]$sysManager.GetTargetNetId() })
                    note = 'Boot project deployed to the target boot directory. Restart the TwinCAT runtime (twincat_restart_runtime) to load and run it.'
                }
            }
            exit 0
        }

        'plc_logout' {
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $candidates = @()
            if ($payload.commandName) { $candidates += [string]$payload.commandName }
            $candidates += 'OtherContextMenus.PlcProject.Logout'
            $result = Invoke-PlcProjectCommand -Dte $dte -CandidateCommands $candidates -FallbackPattern '^PLC\.Logout' -PlcItemName ([string]$payload.itemName)

            Write-JsonResult @{
                ok = $true
                data = $result
            }
            exit 0
        }

        'twincat_restart_runtime' {
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $wasStarted = $null
            try {
                $wasStarted = [bool]$sysManager.IsTwinCATStarted()
            } catch {
            }

            $sysManager.StartRestartTwinCAT()

            Write-JsonResult @{
                ok = $true
                data = @{
                    restarted = $true
                    wasStarted = $wasStarted
                }
            }
            exit 0
        }

        'plc_project_create' {
            $name = [string]$payload.name
            if ([string]::IsNullOrWhiteSpace($name)) {
                throw 'name is required'
            }
            $template = if ($payload.template) { [string]$payload.template } else { 'Standard PLC Template' }
            $before = if ($payload.before) { [string]$payload.before } else { '' }

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $tipc = (Get-TreeItem -SysManager $sysManager -TreePath 'TIPC').Value
            # subType 0 = copy-to-solution; vInfo carries the stock template NAME (infosys 242730891).
            $child = $tipc.CreateChild($name, 0, $before, $template)
            Assert-WellFormedChild -Parent $tipc -Child $child -RequestedName $name -SubType 0 -ParentPath 'TIPC'

            if ($payload.PSObject.Properties.Name -contains 'save' -and [bool]$payload.save) {
                Save-Solution -Dte $dte
            }

            Write-JsonResult @{
                ok = $true
                data = @{
                    parentPath = 'TIPC'
                    pathName = "TIPC^$name"
                    child = Convert-TreeItem -TreeItem $child
                }
            }
            exit 0
        }

        'plc_project_open' {
            $name = [string]$payload.name
            $file = [string]$payload.file
            if ([string]::IsNullOrWhiteSpace($name)) {
                throw 'name is required'
            }
            if ([string]::IsNullOrWhiteSpace($file)) {
                throw 'file is required'
            }
            if (-not (Test-Path -LiteralPath $file)) {
                throw "PLC project file not found: $file"
            }
            $subType = 0
            if ($null -ne $payload.subType) {
                $subType = [int]$payload.subType
            }
            $before = if ($payload.before) { [string]$payload.before } else { '' }

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $tipc = (Get-TreeItem -SysManager $sysManager -TreePath 'TIPC').Value
            # Same CreateChild route as create; vInfo = file path, subType selects
            # copy(0)/move(1)/use-in-place(2) (infosys 242730891).
            $child = $tipc.CreateChild($name, $subType, $before, $file)
            Assert-WellFormedChild -Parent $tipc -Child $child -RequestedName $name -SubType $subType -ParentPath 'TIPC'

            if ($payload.PSObject.Properties.Name -contains 'save' -and [bool]$payload.save) {
                Save-Solution -Dte $dte
            }

            Write-JsonResult @{
                ok = $true
                data = @{
                    parentPath = 'TIPC'
                    pathName = "TIPC^$name"
                    subType = $subType
                    child = Convert-TreeItem -TreeItem $child
                }
            }
            exit 0
        }

        'plc_project_info' {
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $treePath = [string]$payload.treePath
            if ([string]::IsNullOrWhiteSpace($treePath)) {
                $tipc = $sysManager.LookupTreeItem('TIPC')
                if ([int]$tipc.ChildCount -lt 1) {
                    throw 'No PLC project found under TIPC'
                }
                $treePath = "TIPC^$([string]$tipc.Child(1).Name)"
            }
            $plc = (Get-TreeItem -SysManager $sysManager -TreePath $treePath).Value
            if (-not (Ensure-TcPlcProjectHelper)) {
                throw 'TCatSysManagerLib.dll could not be loaded; the typed casts required for plc_project_info are unavailable on this shell'
            }
            $nestedName = [Te1000PlcProjectHelper]::GetNestedProjectName($plc)
            $instanceName = [Te1000PlcProjectHelper]::GetInstanceName($plc)

            Write-JsonResult @{
                ok = $true
                data = @{
                    treePath = $treePath
                    name = Normalize-ScalarValue (Get-SafeValue { [string]$plc.Name })
                    nestedProjectName = $nestedName
                    instanceName = $instanceName
                    childCount = Get-TreeItemChildCount -TreeItem $plc
                }
            }
            exit 0
        }

        'plc_project_boot_flags' {
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $treePath = [string]$payload.treePath
            if ([string]::IsNullOrWhiteSpace($treePath)) {
                $tipc = $sysManager.LookupTreeItem('TIPC')
                if ([int]$tipc.ChildCount -lt 1) {
                    throw 'No PLC project found under TIPC'
                }
                $treePath = "TIPC^$([string]$tipc.Child(1).Name)"
            }
            $item = (Get-TreeItem -SysManager $sysManager -TreePath $treePath).Value
            if (-not (Ensure-TcPlcProjectHelper)) {
                throw 'TCatSysManagerLib.dll could not be loaded; the typed ITcPlcProject cast is required for plc_project_boot_flags on this shell'
            }
            $hasAutostart = $null -ne $payload.autostart
            $autostart = if ($hasAutostart) { [bool]$payload.autostart } else { $false }
            $hasTmc = $null -ne $payload.tmcFileCopy
            $tmc = if ($hasTmc) { [bool]$payload.tmcFileCopy } else { $false }
            $current = $null
            try {
                $current = [Te1000PlcProjectHelper]::SetBootFlags($item, $hasAutostart, $autostart, $hasTmc, $tmc)
            } catch {
                throw "node '$treePath' does not implement ITcPlcProject (use the PLC root node TIPC^<name>): $($_.Exception.Message)"
            }

            Write-JsonResult @{
                ok = $true
                data = @{
                    treePath = $treePath
                    bootProjectAutostart = [bool]$current[0]
                    tmcFileCopy = [bool]$current[1]
                }
            }
            exit 0
        }

        'plc_project_generate_boot' {
            # GUARD enforced in index.js (confirm===ALLOW_PLC_DOWNLOAD). This is the
            # only verb in this tool that writes toward the live target.
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $treePath = [string]$payload.treePath
            if ([string]::IsNullOrWhiteSpace($treePath)) {
                $tipc = $sysManager.LookupTreeItem('TIPC')
                if ([int]$tipc.ChildCount -lt 1) {
                    throw 'No PLC project found under TIPC'
                }
                $treePath = "TIPC^$([string]$tipc.Child(1).Name)"
            }
            $plcProject = (Get-TreeItem -SysManager $sysManager -TreePath $treePath).Value
            $autostart = $true
            if ($null -ne $payload.autostart) {
                $autostart = [bool]$payload.autostart
            }
            if (-not (Ensure-TcPlcProjectHelper)) {
                throw 'TCatSysManagerLib.dll could not be loaded; the typed ITcPlcProject cast is required for boot project generation on this shell'
            }
            [Te1000PlcProjectHelper]::Deploy($plcProject, $autostart, $true)

            Write-JsonResult @{
                ok = $true
                data = @{
                    treePath = $treePath
                    bootProjectGenerated = $true
                    bootProjectAutostart = $autostart
                    targetNetId = (Get-SafeValue { [string]$sysManager.GetTargetNetId() })
                    note = 'Boot project generated to the target boot directory. Restart the TwinCAT runtime (twincat_restart_runtime) to load and run it.'
                }
            }
            exit 0
        }

        'plc_project_online' {
            # GUARD enforced in index.js (confirm===ALLOW_PLC_DOWNLOAD for every command).
            # NOTE: the literal ConsumeXml envelope below is UNVERIFIED against a live
            # build>=4010 — confirm before relying on it; GetLastXmlError is surfaced verbatim.
            $command = [string]$payload.command
            if ([string]::IsNullOrWhiteSpace($command)) {
                throw 'command is required'
            }
            $elementMap = @{
                'login' = 'LoginCmd'
                'logout' = 'LogoutCmd'
                'start' = 'StartCmd'
                'stop' = 'StopCmd'
                'reset_cold' = 'ResetColdCmd'
                'reset_origin' = 'ResetOriginCmd'
            }
            if (-not $elementMap.ContainsKey($command)) {
                throw "Unsupported online command: $command"
            }
            $el = $elementMap[$command]

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $treePath = [string]$payload.treePath
            if ([string]::IsNullOrWhiteSpace($treePath)) {
                $tipc = $sysManager.LookupTreeItem('TIPC')
                if ([int]$tipc.ChildCount -lt 1) {
                    throw 'No PLC project found under TIPC'
                }
                $treePath = "TIPC^$([string]$tipc.Child(1).Name)"
            }
            $item = (Get-TreeItem -SysManager $sysManager -TreePath $treePath).Value
            $xml = "<TreeItem><PlcProjectDef><$el></$el></PlcProjectDef></TreeItem>"
            try {
                $item.ConsumeXml($xml)
            } catch {
                $xmlError = $null
                try {
                    $xmlError = $item.GetLastXmlError()
                } catch {
                }
                if ($xmlError) {
                    throw "ConsumeXml failed for online command '$command': $xmlError"
                }
                throw
            }

            Write-JsonResult @{
                ok = $true
                data = @{
                    treePath = $treePath
                    command = $command
                    executed = $true
                }
            }
            exit 0
        }

        'plc_project_plcopen_export' {
            $file = [string]$payload.file
            if ([string]::IsNullOrWhiteSpace($file)) {
                throw 'file is required'
            }
            $selection = if ($payload.selection) { [string]$payload.selection } else { '' }
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $treePath = [string]$payload.treePath
            if ([string]::IsNullOrWhiteSpace($treePath)) {
                $tipc = $sysManager.LookupTreeItem('TIPC')
                if ([int]$tipc.ChildCount -lt 1) {
                    throw 'No PLC project found under TIPC'
                }
                $treePath = "TIPC^$([string]$tipc.Child(1).Name)"
            }
            $item = (Get-TreeItem -SysManager $sysManager -TreePath $treePath).Value
            if (-not (Ensure-TcPlcProjectHelper)) {
                throw 'TCatSysManagerLib.dll could not be loaded; the typed ITcPlcIECProject cast is required for plc_project_plcopen_export on this shell'
            }
            try {
                [Te1000PlcProjectHelper]::PlcOpenExport($item, $file, $selection)
            } catch {
                throw "node '$treePath' does not implement ITcPlcIECProject (use the nested project instance node): $($_.Exception.Message)"
            }

            Write-JsonResult @{
                ok = $true
                data = @{
                    treePath = $treePath
                    file = $file
                    selection = $selection
                    exported = $true
                }
            }
            exit 0
        }

        'plc_project_plcopen_import' {
            $file = [string]$payload.file
            if ([string]::IsNullOrWhiteSpace($file)) {
                throw 'file is required'
            }
            if (-not (Test-Path -LiteralPath $file)) {
                throw "PLCopen XML file not found: $file"
            }
            $options = 0
            if ($null -ne $payload.options) {
                $options = [int]$payload.options
            }
            $selection = if ($payload.selection) { [string]$payload.selection } else { '' }
            $folderStructure = $true
            if ($null -ne $payload.folderStructure) {
                $folderStructure = [bool]$payload.folderStructure
            }
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $treePath = [string]$payload.treePath
            if ([string]::IsNullOrWhiteSpace($treePath)) {
                $tipc = $sysManager.LookupTreeItem('TIPC')
                if ([int]$tipc.ChildCount -lt 1) {
                    throw 'No PLC project found under TIPC'
                }
                $treePath = "TIPC^$([string]$tipc.Child(1).Name)"
            }
            $item = (Get-TreeItem -SysManager $sysManager -TreePath $treePath).Value
            if (-not (Ensure-TcPlcProjectHelper)) {
                throw 'TCatSysManagerLib.dll could not be loaded; the typed ITcPlcIECProject cast is required for plc_project_plcopen_import on this shell'
            }
            try {
                [Te1000PlcProjectHelper]::PlcOpenImport($item, $file, $options, $selection, $folderStructure)
            } catch {
                throw "node '$treePath' does not implement ITcPlcIECProject (use the nested project instance node): $($_.Exception.Message)"
            }
            if ($payload.PSObject.Properties.Name -contains 'save' -and [bool]$payload.save) {
                Save-Solution -Dte $dte
            }

            Write-JsonResult @{
                ok = $true
                data = @{
                    treePath = $treePath
                    file = $file
                    options = $options
                    imported = $true
                }
            }
            exit 0
        }

        'plc_project_save_as_library' {
            $file = [string]$payload.file
            if ([string]::IsNullOrWhiteSpace($file)) {
                throw 'file is required'
            }
            $install = $false
            if ($null -ne $payload.install) {
                $install = [bool]$payload.install
            }
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $treePath = [string]$payload.treePath
            if ([string]::IsNullOrWhiteSpace($treePath)) {
                $tipc = $sysManager.LookupTreeItem('TIPC')
                if ([int]$tipc.ChildCount -lt 1) {
                    throw 'No PLC project found under TIPC'
                }
                $treePath = "TIPC^$([string]$tipc.Child(1).Name)"
            }
            $item = (Get-TreeItem -SysManager $sysManager -TreePath $treePath).Value
            if (-not (Ensure-TcPlcProjectHelper)) {
                throw 'TCatSysManagerLib.dll could not be loaded; the typed ITcPlcIECProject cast is required for plc_project_save_as_library on this shell'
            }
            try {
                [Te1000PlcProjectHelper]::SaveAsLibrary($item, $file, $install)
            } catch {
                throw "node '$treePath' does not implement ITcPlcIECProject (use the nested project instance node): $($_.Exception.Message)"
            }

            Write-JsonResult @{
                ok = $true
                data = @{
                    treePath = $treePath
                    file = $file
                    installed = $install
                }
            }
            exit 0
        }

        'plc_pou_create' {
            # Offline engineering edit: CreateChild a PLC object (POU/DUT/GVL/etc).
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $child = Invoke-PlcPouCreate -SysManager $sysManager -Entry $payload

            Write-JsonResult @{
                ok = $true
                data = @{
                    parentPath = [string]$payload.parent
                    child = Convert-TreeItem -TreeItem $child
                }
            }
            exit 0
        }

        'plc_pou_create_batch' {
            $creates = $payload.creates
            if ($null -eq $creates -or @($creates).Count -lt 1) {
                throw 'creates must be a non-empty array'
            }
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value

            $results = @()
            $succeeded = 0
            $failed = 0
            foreach ($entry in @($creates)) {
                $p = if ($entry.parent) { [string]$entry.parent } else { '' }
                $n = if ($entry.name) { [string]$entry.name } else { '' }
                try {
                    $child = Invoke-PlcPouCreate -SysManager $sysManager -Entry $entry
                    $results += @{ parent = $p; name = $n; ok = $true; child = Convert-TreeItem -TreeItem $child }
                    $succeeded++
                } catch {
                    $results += @{ parent = $p; name = $n; ok = $false; error = $_.Exception.Message }
                    $failed++
                }
            }

            if ($payload.PSObject.Properties.Name -contains 'save' -and [bool]$payload.save) {
                Save-Solution -Dte $dte
            }

            Write-JsonResult @{
                ok = $true
                data = @{
                    count = @($creates).Count
                    succeeded = $succeeded
                    failed = $failed
                    results = $results
                }
            }
            exit 0
        }

        'plc_pou_import_template' {
            $parent = [string]$payload.parent
            if ([string]::IsNullOrWhiteSpace($parent)) {
                throw 'parent is required'
            }
            Assert-NotSafetyPath -Path $parent
            $paths = @($payload.paths) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ }
            if ($null -eq $paths -or @($paths).Count -lt 1) {
                throw 'paths must be a non-empty array of POU-template file paths'
            }
            foreach ($pth in $paths) {
                if (-not (Test-Path -LiteralPath $pth)) {
                    throw "POU template file not found: $pth"
                }
            }

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $parentItem = (Get-TreeItem -SysManager $sysManager -TreePath $parent).Value

            # Snapshot existing child names so we can report only the newly imported objects.
            $before = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
            $countBefore = Get-TreeItemChildCount -TreeItem $parentItem
            for ($i = 1; $i -le $countBefore; $i++) {
                $c = (Get-TreeItemChild -TreeItem $parentItem -Index $i).Value
                $cn = Normalize-ScalarValue (Get-SafeValue { [string]$c.Name })
                if (-not [string]::IsNullOrWhiteSpace($cn)) { [void]$before.Add($cn) }
            }

            # subType 58 = POU template import; vInfo = single path string or [string[]].
            $vInfo = if (@($paths).Count -eq 1) { [string]$paths[0] } else { [string[]]$paths }
            $null = $parentItem.CreateChild($null, 58, '', $vInfo)

            $imported = @()
            $countAfter = Get-TreeItemChildCount -TreeItem $parentItem
            for ($i = 1; $i -le $countAfter; $i++) {
                $c = (Get-TreeItemChild -TreeItem $parentItem -Index $i).Value
                $cn = Normalize-ScalarValue (Get-SafeValue { [string]$c.Name })
                if (-not [string]::IsNullOrWhiteSpace($cn) -and -not $before.Contains($cn)) {
                    $imported += $cn
                }
            }

            if ($payload.PSObject.Properties.Name -contains 'save' -and [bool]$payload.save) {
                Save-Solution -Dte $dte
            }

            Write-JsonResult @{
                ok = $true
                data = @{
                    parent = $parent
                    imported = @($imported)
                }
            }
            exit 0
        }

        'plc_pou_get_decl' {
            $path = [string]$payload.path
            if ([string]::IsNullOrWhiteSpace($path)) { throw 'path is required' }
            Assert-NotSafetyPath -Path $path
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $item = (Get-TreeItem -SysManager $sysManager -TreePath $path).Value
            if (-not (Ensure-TcPlcPouHelper)) {
                throw 'typed PLC cast unavailable on this shell (TCatSysManagerLib.dll / Te1000PlcPouHelper could not be loaded)'
            }
            $declText = [Te1000PlcPouHelper]::GetDeclaration($item)

            $data = Get-PlcTextReadResult -Text $declText -Payload $payload -Path $path
            Write-JsonResult @{ ok = $true; data = $data }
            exit 0
        }

        'plc_pou_get_impl' {
            $path = [string]$payload.path
            if ([string]::IsNullOrWhiteSpace($path)) { throw 'path is required' }
            Assert-NotSafetyPath -Path $path
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $item = (Get-TreeItem -SysManager $sysManager -TreePath $path).Value
            if (-not (Ensure-TcPlcPouHelper)) {
                throw 'typed PLC cast unavailable on this shell (TCatSysManagerLib.dll / Te1000PlcPouHelper could not be loaded)'
            }
            $language = $null
            try { $language = [Te1000PlcPouHelper]::GetImplementationLanguage($item) } catch { }

            if (Test-PlcGraphicalLanguage -Language $language) {
                # Graphical: ImplementationText is empty/meaningless. Report it and
                # treat range/grep as harmless no-ops.
                Write-JsonResult @{
                    ok = $true
                    data = @{
                        path = $path
                        language = $language
                        lineCount = 0
                        graphical = $true
                        hint = 'use get_document for implXml'
                    }
                }
                exit 0
            }

            $implText = [Te1000PlcPouHelper]::GetImplementation($item)
            $data = Get-PlcTextReadResult -Text $implText -Payload $payload -Path $path
            $data.language = $language
            Write-JsonResult @{ ok = $true; data = $data }
            exit 0
        }

        'plc_pou_outline' {
            $path = [string]$payload.path
            if ([string]::IsNullOrWhiteSpace($path)) { throw 'path is required' }
            Assert-NotSafetyPath -Path $path
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $item = (Get-TreeItem -SysManager $sysManager -TreePath $path).Value
            if (-not (Ensure-TcPlcPouHelper)) {
                throw 'typed PLC cast unavailable on this shell (TCatSysManagerLib.dll / Te1000PlcPouHelper could not be loaded)'
            }
            $declText = [Te1000PlcPouHelper]::GetDeclaration($item)
            $declSplit = Split-PlcLines -Text $declText
            $declLines = @($declSplit.lines)
            $outline = Get-DeclOutline -Lines $declLines

            $implLineCount = $null
            $language = $null
            try { $language = [Te1000PlcPouHelper]::GetImplementationLanguage($item) } catch { }
            if (-not (Test-PlcGraphicalLanguage -Language $language)) {
                try {
                    $implText = [Te1000PlcPouHelper]::GetImplementation($item)
                    $implSplit = Split-PlcLines -Text $implText
                    $implLineCount = @($implSplit.lines).Count
                } catch { $implLineCount = $null }
            } else {
                $implLineCount = 0
            }

            # objectKind from tree ItemType (code objects: FB 604 / Program 602 / Interface 618 etc.)
            $objectKind = Normalize-ScalarValue (Get-SafeValue { [int]$item.ItemType })

            # Enumerate child code items (methods/properties/actions/transitions).
            $children = @()
            $childCount = Get-TreeItemChildCount -TreeItem $item
            for ($ci = 1; $ci -le $childCount; $ci++) {
                $childNode = (Get-SafeValue { (Get-TreeItemChild -TreeItem $item -Index $ci).Value })
                if ($null -eq $childNode) { continue }
                $cn = Normalize-ScalarValue (Get-SafeValue { [string]$childNode.Name })
                if ([string]::IsNullOrWhiteSpace($cn)) { continue }
                $cSub = $null
                try { $cSub = $childNode.SubType } catch { try { $cSub = $childNode.ItemSubType } catch { $cSub = $null } }
                $kind = switch ([int]$cSub) {
                    608 { 'action' }
                    609 { 'method' }
                    611 { 'property' }
                    616 { 'transition' }
                    default { 'child' }
                }
                $cLang = $null
                try { $cLang = [Te1000PlcPouHelper]::GetImplementationLanguage($childNode) } catch { }
                $children += @{ name = $cn; kind = $kind; subType = $cSub; language = $cLang }
            }

            Write-JsonResult @{
                ok = $true
                data = @{
                    path = $path
                    objectKind = $objectKind
                    header = $outline.header
                    declLineCount = @($declLines).Count
                    implLineCount = $implLineCount
                    varBlocks = $outline.varBlocks
                    children = @($children)
                }
            }
            exit 0
        }

        'plc_pou_replace' {
            $path = [string]$payload.path
            if ([string]::IsNullOrWhiteSpace($path)) { throw 'path is required' }
            if ($null -eq $payload.find) { throw 'find is required' }
            if ($null -eq $payload.replaceWith) { throw 'replaceWith is required' }
            $target = Get-PlcTargetParam -Payload $payload -Default 'decl'
            $find = [string]$payload.find
            $replaceWith = [string]$payload.replaceWith
            $expectCount = if ($null -ne $payload.expectCount) { [int]$payload.expectCount } else { 1 }
            $resultRef = @{}
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $rmw = Invoke-PlcTextRMW -SysManager $sysManager -Path $path -Target $target -Mutator {
                param($text, $eol, $lines)
                $ar = Apply-Replace -Text $text -Find $find -ReplaceWith $replaceWith -ExpectCount $expectCount
                if (-not $ar.ok) { throw $ar.error }
                $resultRef.replaced = $ar.count
                # Compute changed region for the snippet: locate the first replacement.
                $oldSplit = Split-PlcLines -Text $text
                $newSplit = Split-PlcLines -Text $ar.newText
                $resultRef.firstChanged = Get-FirstDivergentLine -OldLines @($oldSplit.lines) -NewLines @($newSplit.lines)
                $resultRef.lastChanged = Get-LastDivergentLine -OldLines @($oldSplit.lines) -NewLines @($newSplit.lines)
                return $ar.newText
            }
            $startL = if ($null -ne $resultRef.firstChanged) { [int]$resultRef.firstChanged } else { 1 }
            $endL = if ($null -ne $resultRef.lastChanged) { [int]$resultRef.lastChanged } else { $startL }
            $snip = Get-ChangedSnippet -NewLines @($rmw.newLines) -Start $startL -End $endL
            Save-IfRequested -Payload $payload -Dte $dte
            $data = @{
                path = $path
                target = $target
                replaced = $resultRef.replaced
                lineCount = $rmw.newLineCount
                eol = $rmw.eolName
                changedRange = $snip.changedRange
                snippet = $snip.snippet
            }
            Add-ValidateResult -Payload $payload -SysManager $sysManager -Data $data
            Write-JsonResult @{ ok = $true; data = $data }
            exit 0
        }

        'plc_pou_replace_lines' {
            $path = [string]$payload.path
            if ([string]::IsNullOrWhiteSpace($path)) { throw 'path is required' }
            if ($null -eq $payload.start) { throw 'start is required' }
            if ($null -eq $payload.end) { throw 'end is required' }
            if ($null -eq $payload.text) { throw 'text is required' }
            $target = Get-PlcTargetParam -Payload $payload -Default 'decl'
            $startReq = [int]$payload.start
            $endReq = [int]$payload.end
            $newText = [string]$payload.text
            $newEndRef = @{}
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $rmw = Invoke-PlcTextRMW -SysManager $sysManager -Path $path -Target $target -Mutator {
                param($text, $eol, $lines)
                $count = @($lines).Count
                if ($startReq -lt 1 -or $endReq -gt $count -or $startReq -gt $endReq) {
                    throw "replace_lines range [$startReq..$endReq] is out of bounds for lineCount $count (no change written)"
                }
                $repSplit = Split-PlcLines -Text $newText
                $repLines = @($repSplit.lines)
                $before = if ($startReq -gt 1) { @($lines[0..($startReq - 2)]) } else { @() }
                $after = if ($endReq -lt $count) { @($lines[$endReq..($count - 1)]) } else { @() }
                $merged = @($before) + @($repLines) + @($after)
                $newEndRef.start = $startReq
                $newEndRef.newEnd = $startReq + @($repLines).Count - 1
                if ($newEndRef.newEnd -lt $startReq) { $newEndRef.newEnd = $startReq }
                return Join-PlcLines -Lines $merged -Eol $eol -TrailingEol $true
            }
            $snip = Get-ChangedSnippet -NewLines @($rmw.newLines) -Start ([int]$newEndRef.start) -End ([int]$newEndRef.newEnd)
            Save-IfRequested -Payload $payload -Dte $dte
            $data = @{
                path = $path
                target = $target
                lineCount = $rmw.newLineCount
                eol = $rmw.eolName
                changedRange = $snip.changedRange
                snippet = $snip.snippet
            }
            Add-ValidateResult -Payload $payload -SysManager $sysManager -Data $data
            Write-JsonResult @{ ok = $true; data = $data }
            exit 0
        }

        'plc_pou_insert' {
            $path = [string]$payload.path
            if ([string]::IsNullOrWhiteSpace($path)) { throw 'path is required' }
            if ($null -eq $payload.text) { throw 'text is required' }
            $target = Get-PlcTargetParam -Payload $payload -Default 'decl'
            $hasAt = ($payload.PSObject.Properties.Name -contains 'at') -and ($null -ne $payload.at)
            $hasAfter = ($payload.PSObject.Properties.Name -contains 'after') -and ($null -ne $payload.after)
            $hasBefore = ($payload.PSObject.Properties.Name -contains 'before') -and ($null -ne $payload.before)
            $supplied = @($hasAt, $hasAfter, $hasBefore) | Where-Object { $_ } | Measure-Object
            if ($supplied.Count -ne 1) {
                throw 'insert requires exactly one of at / after / before'
            }
            $insText = [string]$payload.text
            $regionRef = @{}
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $rmw = Invoke-PlcTextRMW -SysManager $sysManager -Path $path -Target $target -Mutator {
                param($text, $eol, $lines)
                $count = @($lines).Count
                # Compute 1-based "insert before this index" position.
                if ($hasAfter) { $pos = [int]$payload.after + 1 }
                elseif ($hasBefore) { $pos = [int]$payload.before }
                else { $pos = [int]$payload.at }
                if ($pos -lt 1 -or $pos -gt ($count + 1)) {
                    throw "insert position $pos is out of bounds for lineCount $count (valid 1..$($count + 1)) (no change written)"
                }
                $insSplit = Split-PlcLines -Text $insText
                $insLines = @($insSplit.lines)
                $before = if ($pos -gt 1) { @($lines[0..($pos - 2)]) } else { @() }
                $after = if ($pos -le $count) { @($lines[($pos - 1)..($count - 1)]) } else { @() }
                $merged = @($before) + @($insLines) + @($after)
                $regionRef.start = $pos
                $regionRef.end = $pos + @($insLines).Count - 1
                if ($regionRef.end -lt $pos) { $regionRef.end = $pos }
                return Join-PlcLines -Lines $merged -Eol $eol -TrailingEol $true
            }
            $snip = Get-ChangedSnippet -NewLines @($rmw.newLines) -Start ([int]$regionRef.start) -End ([int]$regionRef.end)
            Save-IfRequested -Payload $payload -Dte $dte
            $data = @{
                path = $path
                target = $target
                lineCount = $rmw.newLineCount
                eol = $rmw.eolName
                changedRange = $snip.changedRange
                snippet = $snip.snippet
            }
            Add-ValidateResult -Payload $payload -SysManager $sysManager -Data $data
            Write-JsonResult @{ ok = $true; data = $data }
            exit 0
        }

        'plc_pou_insert_in_var_block' {
            $path = [string]$payload.path
            if ([string]::IsNullOrWhiteSpace($path)) { throw 'path is required' }
            if ([string]::IsNullOrWhiteSpace([string]$payload.block)) { throw 'block is required' }
            if ($null -eq $payload.text) { throw 'text is required' }
            $target = Get-PlcTargetParam -Payload $payload -Default 'decl'
            $block = [string]$payload.block
            $insText = [string]$payload.text
            $occurrence = if ($null -ne $payload.occurrence) { [int]$payload.occurrence } else { 1 }
            $regionRef = @{}
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $rmw = Invoke-PlcTextRMW -SysManager $sysManager -Path $path -Target $target -Mutator {
                param($text, $eol, $lines)
                $count = @($lines).Count
                $vb = Find-VarBlock -Lines $lines -BlockKeyword $block -Occurrence $occurrence
                if (-not $vb.found) {
                    throw "no $block block found in $path (occurrence $occurrence)"
                }
                $endVarLine = [int]$vb.endVarLine
                # Indentation-match: one indent step deeper than the block opener (best-effort).
                $indent = [string]$vb.indent + '    '
                $insSplit = Split-PlcLines -Text $insText
                $insLines = @($insSplit.lines | ForEach-Object {
                    if ([string]::IsNullOrWhiteSpace($_)) { $_ } else { $indent + $_.TrimStart() }
                })
                $insertPos = $endVarLine  # insert BEFORE END_VAR (1-based "before this index")
                $before = if ($insertPos -gt 1) { @($lines[0..($insertPos - 2)]) } else { @() }
                $after = @($lines[($insertPos - 1)..($count - 1)])
                $merged = @($before) + @($insLines) + @($after)
                $regionRef.start = $insertPos
                $regionRef.end = $insertPos + @($insLines).Count - 1
                if ($regionRef.end -lt $insertPos) { $regionRef.end = $insertPos }
                return Join-PlcLines -Lines $merged -Eol $eol -TrailingEol $true
            }
            $snip = Get-ChangedSnippet -NewLines @($rmw.newLines) -Start ([int]$regionRef.start) -End ([int]$regionRef.end)
            Save-IfRequested -Payload $payload -Dte $dte
            $data = @{
                path = $path
                target = 'decl'
                block = $block
                lineCount = $rmw.newLineCount
                eol = $rmw.eolName
                changedRange = $snip.changedRange
                snippet = $snip.snippet
            }
            Add-ValidateResult -Payload $payload -SysManager $sysManager -Data $data
            Write-JsonResult @{ ok = $true; data = $data }
            exit 0
        }

        'plc_pou_append' {
            $path = [string]$payload.path
            if ([string]::IsNullOrWhiteSpace($path)) { throw 'path is required' }
            if ($null -eq $payload.text) { throw 'text is required' }
            $target = Get-PlcTargetParam -Payload $payload -Default 'impl'
            $appText = [string]$payload.text
            $regionRef = @{}
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $rmw = Invoke-PlcTextRMW -SysManager $sysManager -Path $path -Target $target -Mutator {
                param($text, $eol, $lines)
                $oldCount = @($lines).Count
                $appSplit = Split-PlcLines -Text $appText
                $appLines = @($appSplit.lines)
                if ($oldCount -eq 0) {
                    $regionRef.start = 1
                    $regionRef.end = [Math]::Max(1, @($appLines).Count)
                    return Join-PlcLines -Lines $appLines -Eol $eol -TrailingEol $appSplit.trailingEol
                }
                $merged = @($lines) + @($appLines)
                $regionRef.start = $oldCount + 1
                $regionRef.end = @($merged).Count
                return Join-PlcLines -Lines $merged -Eol $eol -TrailingEol $appSplit.trailingEol
            }
            $snip = Get-ChangedSnippet -NewLines @($rmw.newLines) -Start ([int]$regionRef.start) -End ([int]$regionRef.end)
            Save-IfRequested -Payload $payload -Dte $dte
            $data = @{
                path = $path
                target = $target
                lineCount = $rmw.newLineCount
                eol = $rmw.eolName
                changedRange = $snip.changedRange
                snippet = $snip.snippet
            }
            Add-ValidateResult -Payload $payload -SysManager $sysManager -Data $data
            Write-JsonResult @{ ok = $true; data = $data }
            exit 0
        }

        'plc_pou_get_document' {
            $path = [string]$payload.path
            if ([string]::IsNullOrWhiteSpace($path)) { throw 'path is required' }
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $item = (Get-TreeItem -SysManager $sysManager -TreePath $path).Value
            if (-not (Ensure-TcPlcPouHelper)) {
                throw 'typed PLC cast unavailable on this shell (TCatSysManagerLib.dll / Te1000PlcPouHelper could not be loaded)'
            }
            $documentXml = [Te1000PlcPouHelper]::GetDocumentXml($item)

            Write-JsonResult @{
                ok = $true
                data = @{
                    path = $path
                    xml = $documentXml
                }
            }
            exit 0
        }

        'plc_pou_set_decl' {
            $path = [string]$payload.path
            if ([string]::IsNullOrWhiteSpace($path)) { throw 'path is required' }
            if ($null -eq $payload.declText) { throw 'declText is required' }
            Assert-NotSafetyPath -Path $path
            $declText = [string]$payload.declText
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $item = (Get-TreeItem -SysManager $sysManager -TreePath $path).Value
            if (-not (Ensure-TcPlcPouHelper)) {
                throw 'typed PLC cast unavailable on this shell (TCatSysManagerLib.dll / Te1000PlcPouHelper could not be loaded)'
            }
            [Te1000PlcPouHelper]::SetDeclaration($item, $declText)

            Write-JsonResult @{
                ok = $true
                data = @{
                    path = $path
                    set = $true
                }
            }
            exit 0
        }

        'plc_pou_set_decl_batch' {
            $items = $payload.items
            if ($null -eq $items -or @($items).Count -lt 1) {
                throw 'items must be a non-empty array'
            }
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            if (-not (Ensure-TcPlcPouHelper)) {
                throw 'typed PLC cast unavailable on this shell (TCatSysManagerLib.dll / Te1000PlcPouHelper could not be loaded)'
            }

            $results = @()
            $succeeded = 0
            $failed = 0
            foreach ($entry in @($items)) {
                $p = if ($entry.path) { [string]$entry.path } else { '' }
                try {
                    if ([string]::IsNullOrWhiteSpace($p)) { throw 'path is required' }
                    if ($null -eq $entry.declText) { throw 'declText is required' }
                    Assert-NotSafetyPath -Path $p
                    $item = (Get-TreeItem -SysManager $sysManager -TreePath $p).Value
                    [Te1000PlcPouHelper]::SetDeclaration($item, [string]$entry.declText)
                    $results += @{ path = $p; ok = $true }
                    $succeeded++
                } catch {
                    $results += @{ path = $p; ok = $false; error = $_.Exception.Message }
                    $failed++
                }
            }

            if ($payload.PSObject.Properties.Name -contains 'save' -and [bool]$payload.save) {
                Save-Solution -Dte $dte
            }

            Write-JsonResult @{
                ok = $true
                data = @{
                    count = @($items).Count
                    succeeded = $succeeded
                    failed = $failed
                    results = $results
                }
            }
            exit 0
        }

        'plc_pou_set_impl' {
            $path = [string]$payload.path
            if ([string]::IsNullOrWhiteSpace($path)) { throw 'path is required' }
            Assert-NotSafetyPath -Path $path
            $hasText = $null -ne $payload.implText
            $hasXml = $null -ne $payload.implXml
            if (($hasText -and $hasXml) -or (-not $hasText -and -not $hasXml)) {
                throw 'exactly one of implText / implXml is required'
            }
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $item = (Get-TreeItem -SysManager $sysManager -TreePath $path).Value
            if (-not (Ensure-TcPlcPouHelper)) {
                throw 'typed PLC cast unavailable on this shell (TCatSysManagerLib.dll / Te1000PlcPouHelper could not be loaded)'
            }
            $via = if ($hasText) { 'text' } else { 'xml' }
            if ($hasText) {
                [Te1000PlcPouHelper]::SetImplementationText($item, [string]$payload.implText)
            } else {
                [Te1000PlcPouHelper]::SetImplementationXml($item, [string]$payload.implXml)
            }

            Write-JsonResult @{
                ok = $true
                data = @{
                    path = $path
                    set = $true
                    via = $via
                }
            }
            exit 0
        }

        'plc_pou_set_impl_batch' {
            $items = $payload.items
            if ($null -eq $items -or @($items).Count -lt 1) {
                throw 'items must be a non-empty array'
            }
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            if (-not (Ensure-TcPlcPouHelper)) {
                throw 'typed PLC cast unavailable on this shell (TCatSysManagerLib.dll / Te1000PlcPouHelper could not be loaded)'
            }

            $results = @()
            $succeeded = 0
            $failed = 0
            foreach ($entry in @($items)) {
                $p = if ($entry.path) { [string]$entry.path } else { '' }
                try {
                    if ([string]::IsNullOrWhiteSpace($p)) { throw 'path is required' }
                    $hasText = $null -ne $entry.implText
                    $hasXml = $null -ne $entry.implXml
                    if (($hasText -and $hasXml) -or (-not $hasText -and -not $hasXml)) {
                        throw 'exactly one of implText / implXml is required'
                    }
                    Assert-NotSafetyPath -Path $p
                    $item = (Get-TreeItem -SysManager $sysManager -TreePath $p).Value
                    if ($hasText) {
                        [Te1000PlcPouHelper]::SetImplementationText($item, [string]$entry.implText)
                        $results += @{ path = $p; ok = $true; via = 'text' }
                    } else {
                        [Te1000PlcPouHelper]::SetImplementationXml($item, [string]$entry.implXml)
                        $results += @{ path = $p; ok = $true; via = 'xml' }
                    }
                    $succeeded++
                } catch {
                    $results += @{ path = $p; ok = $false; error = $_.Exception.Message }
                    $failed++
                }
            }

            if ($payload.PSObject.Properties.Name -contains 'save' -and [bool]$payload.save) {
                Save-Solution -Dte $dte
            }

            Write-JsonResult @{
                ok = $true
                data = @{
                    count = @($items).Count
                    succeeded = $succeeded
                    failed = $failed
                    results = $results
                }
            }
            exit 0
        }

        'plc_pou_set_document' {
            $path = [string]$payload.path
            if ([string]::IsNullOrWhiteSpace($path)) { throw 'path is required' }
            if ($null -eq $payload.documentXml) { throw 'documentXml is required' }
            Assert-NotSafetyPath -Path $path
            $documentXml = [string]$payload.documentXml
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $item = (Get-TreeItem -SysManager $sysManager -TreePath $path).Value
            if (-not (Ensure-TcPlcPouHelper)) {
                throw 'typed PLC cast unavailable on this shell (TCatSysManagerLib.dll / Te1000PlcPouHelper could not be loaded)'
            }
            [Te1000PlcPouHelper]::SetDocumentXml($item, $documentXml)

            Write-JsonResult @{
                ok = $true
                data = @{
                    path = $path
                    set = $true
                }
            }
            exit 0
        }

        'plc_pou_check_objects' {
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $plcPath = [string]$payload.plcPath
            if ([string]::IsNullOrWhiteSpace($plcPath)) {
                $tipc = $sysManager.LookupTreeItem('TIPC')
                if ([int]$tipc.ChildCount -lt 1) {
                    throw 'No PLC project found under TIPC'
                }
                $plcPath = "TIPC^$([string]$tipc.Child(1).Name)"
            }
            $root = (Get-TreeItem -SysManager $sysManager -TreePath $plcPath).Value
            # CheckAllObjects lives on ITcPlcIECProject2, which is implemented by the
            # nested IEC PROJECT node (e.g. '<plcName> Project') -- NOT the TcCOM
            # project INSTANCE node ('<plcName> Instance'). The instance node is what
            # tree-child enumeration surfaces under the PLC root, but it does NOT QI to
            # ITcPlcIECProject2 (E_NOINTERFACE). The IEC project node is reachable by
            # name via LookupTreeItem at '<plcPath>^<rootName> Project'. Resolve it via
            # a direct LookupTreeItem + a single
            # Te1000PlcProjectHelper::CheckAll on the freshly resolved RCW (looping over
            # cached RCWs stored in a collection was observed to QI-fail E_NOINTERFACE).
            if (-not (Ensure-TcPlcProjectHelper)) {
                throw 'typed PLC cast unavailable on this shell (TCatSysManagerLib.dll / Te1000PlcProjectHelper could not be loaded)'
            }
            $rootName = Normalize-ScalarValue (Get-SafeValue { [string]$root.Name })

            # Build the ordered list of candidate tree PATHS (strings, not cached RCWs).
            $candidatePaths = New-Object System.Collections.ArrayList
            if (-not [string]::IsNullOrWhiteSpace($rootName)) {
                [void]$candidatePaths.Add("$plcPath^$rootName Project")
            }
            $childCount = Get-TreeItemChildCount -TreeItem $root
            for ($ci = 1; $ci -le $childCount; $ci++) {
                $childNode = (Get-SafeValue { (Get-TreeItemChild -TreeItem $root -Index $ci).Value })
                if ($null -ne $childNode) {
                    $cn = Normalize-ScalarValue (Get-SafeValue { [string]$childNode.Name })
                    if (-not [string]::IsNullOrWhiteSpace($cn)) {
                        $cp = "$plcPath^$cn"
                        if (-not $candidatePaths.Contains($cp)) { [void]$candidatePaths.Add($cp) }
                    }
                }
            }
            if (-not $candidatePaths.Contains($plcPath)) { [void]$candidatePaths.Add($plcPath) }

            $valid = $null
            $instancePath = $plcPath
            $lastErr = $null
            $resolved = $false
            foreach ($candPath in $candidatePaths) {
                try {
                    # Resolve a FRESH RCW per attempt.
                    $node = (Get-TreeItem -SysManager $sysManager -TreePath $candPath).Value
                    $valid = [Te1000PlcProjectHelper]::CheckAll($node)
                    $instancePath = $candPath
                    $resolved = $true
                    break
                } catch {
                    $lastErr = $_.Exception.Message
                }
            }
            if (-not $resolved) {
                throw "could not find a node implementing ITcPlcIECProject2 (CheckAllObjects) under '$plcPath'. Tried the '<name> Project' instance node and the PLC root's children. Last error: $lastErr"
            }

            Write-JsonResult @{
                ok = $true
                data = @{
                    plcPath = $plcPath
                    instancePath = $instancePath
                    allObjectsValid = [bool]$valid
                }
            }
            exit 0
        }

        'plc_pou_tree' {
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $resolved = Get-PlcProjectNodePath -SysManager $sysManager -PlcPath ([string]$payload.plcPath)
            $plcPath = $resolved.plcPath
            $projectPath = $resolved.projectPath

            # Optional subtree root: must be inside the resolved PLC project; TISC rejected.
            $startPath = if (-not [string]::IsNullOrWhiteSpace([string]$payload.path)) { [string]$payload.path } else { $projectPath }
            Assert-NotSafetyPath -Path $startPath

            $maxDepth = 0
            if ($payload.PSObject.Properties.Name -contains 'depth' -and $null -ne $payload.depth) {
                $maxDepth = [int]$payload.depth
                if ($maxDepth -lt 1) { $maxDepth = 1 }
            }

            $startNode = (Get-TreeItem -SysManager $sysManager -TreePath $startPath).Value
            $root = Invoke-PlcTreeWalk -SysManager $sysManager -Node $startNode -BasePath $startPath -Depth 1 -MaxDepth $maxDepth

            $typeSet = ConvertTo-NormalizedTypeSet -TypeFilter ([string]$payload.typeFilter)
            if ($null -ne $typeSet) {
                $root = Select-PrunedTree -Node $root -TypeSet $typeSet
            }

            $treeArr = if ($null -eq $root) { @() } else { @($root) }
            $count = 0
            foreach ($t in $treeArr) { $count += Measure-TreeNodeCount -Node $t }

            Write-JsonResult @{
                ok = $true
                data = @{
                    plcPath = $plcPath
                    projectPath = $projectPath
                    rootPath = $startPath
                    count = $count
                    tree = @($treeArr)
                }
            }
            exit 0
        }

        'plc_pou_find' {
            $namePattern = [string]$payload.name
            $typeFilter = [string]$payload.typeFilter
            if ([string]::IsNullOrWhiteSpace($namePattern) -and [string]::IsNullOrWhiteSpace($typeFilter)) {
                throw 'find requires at least one of name / typeFilter'
            }
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $resolved = Get-PlcProjectNodePath -SysManager $sysManager -PlcPath ([string]$payload.plcPath)
            $plcPath = $resolved.plcPath
            $projectPath = $resolved.projectPath

            $startPath = if (-not [string]::IsNullOrWhiteSpace([string]$payload.path)) { [string]$payload.path } else { $projectPath }
            Assert-NotSafetyPath -Path $startPath

            $startNode = (Get-TreeItem -SysManager $sysManager -TreePath $startPath).Value
            $root = Invoke-PlcTreeWalk -SysManager $sysManager -Node $startNode -BasePath $startPath -Depth 1 -MaxDepth 0

            $typeSet = ConvertTo-NormalizedTypeSet -TypeFilter $typeFilter
            $matches = Select-FlatTreeMatches -NestedRoot $root -NamePattern $namePattern -TypeSet $typeSet

            Write-JsonResult @{
                ok = $true
                data = @{
                    plcPath = $plcPath
                    projectPath = $projectPath
                    count = @($matches).Count
                    matches = @($matches)
                }
            }
            exit 0
        }

        'plc_pou_search' {
            # Project-wide find-in-code. Walk every code-bearing object under the
            # resolved IEC project node, read decl/(ST) impl via the typed helper,
            # and grep line-by-line. Read-only, OFFLINE, one DTE attach.
            $pattern = [string]$payload.pattern
            if ([string]::IsNullOrEmpty($pattern)) { throw 'pattern is required' }
            $ignoreCase = $false
            if ($payload.PSObject.Properties.Name -contains 'ignoreCase') { $ignoreCase = [bool]$payload.ignoreCase }
            $declOnly = $false
            if ($payload.PSObject.Properties.Name -contains 'declOnly') { $declOnly = [bool]$payload.declOnly }
            $implOnly = $false
            if ($payload.PSObject.Properties.Name -contains 'implOnly') { $implOnly = [bool]$payload.implOnly }
            if ($declOnly -and $implOnly) { throw 'declOnly and implOnly are mutually exclusive' }

            $maxResults = 500
            if ($payload.PSObject.Properties.Name -contains 'maxResults' -and $null -ne $payload.maxResults) {
                $maxResults = [int]$payload.maxResults
                if ($maxResults -lt 1) { $maxResults = 1 }
                if ($maxResults -gt 5000) { $maxResults = 5000 }
            }

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $resolved = Get-PlcProjectNodePath -SysManager $sysManager -PlcPath ([string]$payload.plcPath)
            $plcPath = $resolved.plcPath
            $projectPath = $resolved.projectPath

            # Optional subtree root: must be inside the resolved PLC project; TISC rejected.
            $startPath = if (-not [string]::IsNullOrWhiteSpace([string]$payload.path)) { [string]$payload.path } else { $projectPath }
            Assert-NotSafetyPath -Path $startPath

            if (-not (Ensure-TcPlcPouHelper)) {
                throw 'typed PLC cast unavailable on this shell (TCatSysManagerLib.dll / Te1000PlcPouHelper could not be loaded)'
            }

            # Validate the regex once up front so a bad pattern fails fast.
            [void](Find-MatchesInText -Text 'x' -Pattern $pattern -Section 'decl' -Path '' -IgnoreCase $ignoreCase)

            $startNode = (Get-TreeItem -SysManager $sysManager -TreePath $startPath).Value
            $objects = Get-PlcCodeObjects -SysManager $sysManager -RootPath $startPath -RootItem $startNode

            $scanned = 0
            $searched = 0
            $matches = @()
            $truncated = $false
            foreach ($obj in $objects) {
                $scanned++
                $txt = Select-PlcObjectText -Item $obj.item -DeclOnly $declOnly -ImplOnly $implOnly
                $didSearch = $false
                if ($txt.hasDecl -and -not $implOnly) {
                    $didSearch = $true
                    foreach ($m in (Find-MatchesInText -Text $txt.decl -Pattern $pattern -Section 'decl' -Path $obj.path -IgnoreCase $ignoreCase)) {
                        $matches += $m
                        if (@($matches).Count -ge $maxResults) { $truncated = $true; break }
                    }
                }
                if ((-not $truncated) -and $txt.hasImpl -and -not $declOnly) {
                    $didSearch = $true
                    foreach ($m in (Find-MatchesInText -Text $txt.impl -Pattern $pattern -Section 'impl' -Path $obj.path -IgnoreCase $ignoreCase)) {
                        $matches += $m
                        if (@($matches).Count -ge $maxResults) { $truncated = $true; break }
                    }
                }
                if ($didSearch) { $searched++ }
                if ($truncated) { break }
            }

            Write-JsonResult @{
                ok = $true
                data = @{
                    pattern = $pattern
                    plcPath = $plcPath
                    scanned = $scanned
                    searched = $searched
                    count = @($matches).Count
                    truncated = $truncated
                    matches = @($matches)
                }
            }
            exit 0
        }

        'plc_pou_delete' {
            # Resolve parent + child name from either 'path' or 'parent'+'name'.
            $parentPath = [string]$payload.parent
            $childName = [string]$payload.name
            if (-not [string]::IsNullOrWhiteSpace([string]$payload.path) -and ([string]::IsNullOrWhiteSpace($parentPath) -or [string]::IsNullOrWhiteSpace($childName))) {
                $full = [string]$payload.path
                $idx = $full.LastIndexOf('^')
                if ($idx -lt 1) { throw "path '$full' has no parent segment (expected a '^'-separated path)" }
                $parentPath = $full.Substring(0, $idx)
                $childName = $full.Substring($idx + 1)
            }
            if ([string]::IsNullOrWhiteSpace($parentPath) -or [string]::IsNullOrWhiteSpace($childName)) {
                throw 'delete requires either path, or parent and name'
            }
            Assert-NotSafetyPath -Path $parentPath

            $dryRun = $false
            if ($payload.PSObject.Properties.Name -contains 'dryRun') { $dryRun = [bool]$payload.dryRun }

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $parent = (Get-TreeItem -SysManager $sysManager -TreePath $parentPath).Value

            # Verify the child exists before deleting (scan parent children by name).
            $childItem = $null
            $childCount = Get-TreeItemChildCount -TreeItem $parent
            for ($i = 1; $i -le $childCount; $i++) {
                $c = (Get-SafeValue { (Get-TreeItemChild -TreeItem $parent -Index $i).Value })
                if ($null -eq $c) { continue }
                $cn = Normalize-ScalarValue (Get-SafeValue { [string]$c.Name })
                if ($cn -eq $childName) { $childItem = $c; break }
            }
            if ($null -eq $childItem) {
                throw "child '$childName' not found under '$parentPath' (nothing deleted)"
            }

            $cInfo = Convert-TreeItem -TreeItem $childItem
            $cSubTypeName = Normalize-ScalarValue (Get-SafeValue { [string]$childItem.ItemSubTypeName })
            $cType = Get-PlcObjectTypeName -ItemType $cInfo.itemType -ItemSubType $cInfo.subType `
                -ItemSubTypeName $cSubTypeName -Name $cInfo.name -ChildCount ([int]$cInfo.childCount)

            if ($dryRun) {
                Write-JsonResult @{
                    ok = $true
                    data = @{
                        wouldDelete = $true
                        target = @{
                            path = "$parentPath^$childName"
                            name = $childName
                            type = $cType
                            childCount = [int]$cInfo.childCount
                        }
                    }
                }
                exit 0
            }

            $parent.DeleteChild($childName)

            Write-JsonResult @{
                ok = $true
                data = @{
                    parent = $parentPath
                    name = $childName
                    deleted = $true
                    type = $cType
                }
            }
            exit 0
        }

        'plc_library_list_references' {
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $resolved = Get-PlcLibraryReferencesItem -SysManager $sysManager -ReferencesPath ([string]$payload.referencesPath)
            $rows = [Te1000PlcLibraryHelper]::ListReferences($resolved.item)
            $refs = @()
            foreach ($r in $rows) {
                $refs += @{
                    name = $r[0]
                    kind = $r[1]
                    displayName = $r[2]
                    distributor = $r[3]
                    version = $r[4]
                }
            }
            Write-JsonResult @{
                ok = $true
                data = @{
                    referencesPath = $resolved.path
                    count = $refs.Count
                    references = $refs
                }
            }
            exit 0
        }

        'plc_library_scan' {
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $resolved = Get-PlcLibraryReferencesItem -SysManager $sysManager -ReferencesPath ([string]$payload.referencesPath)
            $rows = [Te1000PlcLibraryHelper]::ScanLibraries($resolved.item)
            $libs = @()
            foreach ($r in $rows) {
                $libs += @{
                    name = $r[0]
                    version = $r[1]
                    distributor = $r[2]
                    displayName = $r[3]
                }
            }
            Write-JsonResult @{
                ok = $true
                data = @{
                    count = $libs.Count
                    libraries = $libs
                }
            }
            exit 0
        }

        'plc_library_list_repositories' {
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $resolved = Get-PlcLibraryReferencesItem -SysManager $sysManager -ReferencesPath ([string]$payload.referencesPath)
            $rows = [Te1000PlcLibraryHelper]::ListRepositories($resolved.item)
            $repos = @()
            foreach ($r in $rows) {
                $repos += @{ name = $r[0]; folder = $r[1] }
            }
            Write-JsonResult @{
                ok = $true
                data = @{
                    count = $repos.Count
                    repositories = $repos
                }
            }
            exit 0
        }

        'plc_library_add_library' {
            $name = [string]$payload.name
            if ([string]::IsNullOrWhiteSpace($name)) { throw 'name is required' }
            $version = if ($null -ne $payload.version) { [string]$payload.version } else { '' }
            $company = if ($null -ne $payload.company) { [string]$payload.company } else { '' }
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $resolved = Get-PlcLibraryReferencesItem -SysManager $sysManager -ReferencesPath ([string]$payload.referencesPath)
            [Te1000PlcLibraryHelper]::AddLibrary($resolved.item, $name, $version, $company)
            $saved = $false
            if ($payload.PSObject.Properties.Name -contains 'save' -and [bool]$payload.save) {
                try { Save-Solution -Dte $dte; $saved = $true } catch { $saved = $false }
            }
            Write-JsonResult @{
                ok = $true
                data = @{
                    action = 'add_library'
                    name = $name
                    version = $version
                    company = $company
                    referencesPath = $resolved.path
                    saved = $saved
                    note = $script:PlcLibraryRefNote
                }
            }
            exit 0
        }

        'plc_library_add_placeholder' {
            $name = [string]$payload.name
            if ([string]::IsNullOrWhiteSpace($name)) { throw 'name is required' }
            $defLib = if ($null -ne $payload.defLib) { [string]$payload.defLib } else { '' }
            $defVer = if ($null -ne $payload.defVer) { [string]$payload.defVer } else { '' }
            $defDist = if ($null -ne $payload.defDist) { [string]$payload.defDist } else { '' }
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $resolved = Get-PlcLibraryReferencesItem -SysManager $sysManager -ReferencesPath ([string]$payload.referencesPath)
            if (-not [string]::IsNullOrWhiteSpace($defLib)) {
                [Te1000PlcLibraryHelper]::AddPlaceholder($resolved.item, $name, $defLib, $defVer, $defDist)
            } else {
                [Te1000PlcLibraryHelper]::AddPlaceholderNameOnly($resolved.item, $name)
            }
            $saved = $false
            if ($payload.PSObject.Properties.Name -contains 'save' -and [bool]$payload.save) {
                try { Save-Solution -Dte $dte; $saved = $true } catch { $saved = $false }
            }
            Write-JsonResult @{
                ok = $true
                data = @{
                    action = 'add_placeholder'
                    name = $name
                    defLib = $defLib
                    defVer = $defVer
                    defDist = $defDist
                    referencesPath = $resolved.path
                    saved = $saved
                    note = $script:PlcLibraryRefNote
                }
            }
            exit 0
        }

        'plc_library_set_resolution' {
            $placeholder = [string]$payload.placeholder
            $lib = [string]$payload.lib
            if ([string]::IsNullOrWhiteSpace($placeholder)) { throw 'placeholder is required' }
            if ([string]::IsNullOrWhiteSpace($lib)) { throw 'lib is required' }
            $version = if ($null -ne $payload.version) { [string]$payload.version } else { '' }
            $dist = if ($null -ne $payload.dist) { [string]$payload.dist } else { '' }
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $resolved = Get-PlcLibraryReferencesItem -SysManager $sysManager -ReferencesPath ([string]$payload.referencesPath)
            [Te1000PlcLibraryHelper]::SetEffectiveResolution($resolved.item, $placeholder, $lib, $version, $dist)
            $saved = $false
            if ($payload.PSObject.Properties.Name -contains 'save' -and [bool]$payload.save) {
                try { Save-Solution -Dte $dte; $saved = $true } catch { $saved = $false }
            }
            Write-JsonResult @{
                ok = $true
                data = @{
                    action = 'set_resolution'
                    placeholder = $placeholder
                    lib = $lib
                    version = $version
                    dist = $dist
                    referencesPath = $resolved.path
                    saved = $saved
                    note = $script:PlcLibraryRefNote
                }
            }
            exit 0
        }

        'plc_library_freeze_placeholder' {
            $name = if ($null -ne $payload.name) { [string]$payload.name } else { '' }
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $resolved = Get-PlcLibraryReferencesItem -SysManager $sysManager -ReferencesPath ([string]$payload.referencesPath)
            if (-not [string]::IsNullOrWhiteSpace($name)) {
                [Te1000PlcLibraryHelper]::FreezePlaceholder($resolved.item, $name)
            } else {
                [Te1000PlcLibraryHelper]::FreezePlaceholderAll($resolved.item)
            }
            $saved = $false
            if ($payload.PSObject.Properties.Name -contains 'save' -and [bool]$payload.save) {
                try { Save-Solution -Dte $dte; $saved = $true } catch { $saved = $false }
            }
            Write-JsonResult @{
                ok = $true
                data = @{
                    action = 'freeze'
                    name = if ([string]::IsNullOrWhiteSpace($name)) { '(all)' } else { $name }
                    referencesPath = $resolved.path
                    saved = $saved
                    note = $script:PlcLibraryRefNote
                }
            }
            exit 0
        }

        'plc_library_remove_reference' {
            $name = [string]$payload.name
            if ([string]::IsNullOrWhiteSpace($name)) { throw 'name is required' }
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $resolved = Get-PlcLibraryReferencesItem -SysManager $sysManager -ReferencesPath ([string]$payload.referencesPath)
            [Te1000PlcLibraryHelper]::RemoveReference($resolved.item, $name)
            $saved = $false
            if ($payload.PSObject.Properties.Name -contains 'save' -and [bool]$payload.save) {
                try { Save-Solution -Dte $dte; $saved = $true } catch { $saved = $false }
            }
            Write-JsonResult @{
                ok = $true
                data = @{
                    action = 'remove_reference'
                    name = $name
                    referencesPath = $resolved.path
                    saved = $saved
                    note = ($script:PlcLibraryRefNote + ' (Project-local edit only; does NOT uninstall from the repository.)')
                }
            }
            exit 0
        }

        'plc_library_install_library' {
            Assert-PlcLibraryRepoConfirm -Confirm ([string]$payload.confirm)
            $repo = [string]$payload.repo
            $libPath = [string]$payload.libPath
            if ([string]::IsNullOrWhiteSpace($repo)) { throw 'repo is required' }
            if ([string]::IsNullOrWhiteSpace($libPath)) { throw 'libPath is required' }
            $overwrite = $false
            if ($null -ne $payload.overwrite) { $overwrite = [bool]$payload.overwrite }
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $resolved = Get-PlcLibraryReferencesItem -SysManager $sysManager -ReferencesPath ([string]$payload.referencesPath)
            [Te1000PlcLibraryHelper]::InstallLibrary($resolved.item, $repo, $libPath, $overwrite)
            Write-JsonResult @{
                ok = $true
                data = @{
                    action = 'install_library'
                    repo = $repo
                    libPath = $libPath
                    overwrite = $overwrite
                }
            }
            exit 0
        }

        'plc_library_uninstall_library' {
            Assert-PlcLibraryRepoConfirm -Confirm ([string]$payload.confirm)
            $repo = [string]$payload.repo
            $lib = [string]$payload.lib
            if ([string]::IsNullOrWhiteSpace($repo)) { throw 'repo is required' }
            if ([string]::IsNullOrWhiteSpace($lib)) { throw 'lib is required' }
            $version = if ($null -ne $payload.version) { [string]$payload.version } else { '' }
            $dist = if ($null -ne $payload.dist) { [string]$payload.dist } else { '' }
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $resolved = Get-PlcLibraryReferencesItem -SysManager $sysManager -ReferencesPath ([string]$payload.referencesPath)
            [Te1000PlcLibraryHelper]::UninstallLibrary($resolved.item, $repo, $lib, $version, $dist)
            Write-JsonResult @{
                ok = $true
                data = @{
                    action = 'uninstall_library'
                    repo = $repo
                    lib = $lib
                    version = $version
                    dist = $dist
                }
            }
            exit 0
        }

        'plc_library_insert_repository' {
            Assert-PlcLibraryRepoConfirm -Confirm ([string]$payload.confirm)
            $name = [string]$payload.name
            $folder = [string]$payload.folder
            if ([string]::IsNullOrWhiteSpace($name)) { throw 'name is required' }
            if ([string]::IsNullOrWhiteSpace($folder)) { throw 'folder is required' }
            $index = 0
            if ($null -ne $payload.index) { $index = [int]$payload.index }
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $resolved = Get-PlcLibraryReferencesItem -SysManager $sysManager -ReferencesPath ([string]$payload.referencesPath)
            [Te1000PlcLibraryHelper]::InsertRepository($resolved.item, $name, $folder, $index)
            Write-JsonResult @{
                ok = $true
                data = @{
                    action = 'insert_repository'
                    name = $name
                    folder = $folder
                    index = $index
                }
            }
            exit 0
        }

        'plc_library_remove_repository' {
            Assert-PlcLibraryRepoConfirm -Confirm ([string]$payload.confirm)
            $name = [string]$payload.name
            if ([string]::IsNullOrWhiteSpace($name)) { throw 'name is required' }
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $resolved = Get-PlcLibraryReferencesItem -SysManager $sysManager -ReferencesPath ([string]$payload.referencesPath)
            [Te1000PlcLibraryHelper]::RemoveRepository($resolved.item, $name)
            Write-JsonResult @{
                ok = $true
                data = @{
                    action = 'remove_repository'
                    name = $name
                }
            }
            exit 0
        }

        'plc_library_move_repository' {
            Assert-PlcLibraryRepoConfirm -Confirm ([string]$payload.confirm)
            $name = [string]$payload.name
            if ([string]::IsNullOrWhiteSpace($name)) { throw 'name is required' }
            if ($null -eq $payload.index) { throw 'index is required' }
            $index = [int]$payload.index
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $resolved = Get-PlcLibraryReferencesItem -SysManager $sysManager -ReferencesPath ([string]$payload.referencesPath)
            [Te1000PlcLibraryHelper]::MoveRepository($resolved.item, $name, $index)
            Write-JsonResult @{
                ok = $true
                data = @{
                    action = 'move_repository'
                    name = $name
                    index = $index
                }
            }
            exit 0
        }

        'tc_task_list' {
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $tirt = (Get-TreeItem -SysManager $sysManager -TreePath 'TIRT').Value
            $count = Get-TreeItemChildCount -TreeItem $tirt
            $tasks = @()
            for ($i = 1; $i -le $count; $i++) {
                $child = (Get-TreeItemChild -TreeItem $tirt -Index $i).Value
                if ($null -eq $child) { continue }
                $tasks += Convert-TreeItem -TreeItem $child
            }
            Write-JsonResult @{
                ok = $true
                data = @{
                    count = $count
                    tasks = $tasks
                }
            }
            exit 0
        }

        'tc_task_get' {
            $treePath = [string]$payload.path
            if ([string]::IsNullOrWhiteSpace($treePath)) {
                throw 'path is required'
            }
            $summary = $false
            if ($payload.PSObject.Properties.Name -contains 'summary') {
                $summary = [bool]$payload.summary
            }
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $item = (Get-TreeItem -SysManager $sysManager -TreePath $treePath).Value
            $xml = Strip-TreeImage $item.ProduceXml($false)

            if (-not $summary) {
                Write-JsonResult @{
                    ok = $true
                    data = @{
                        treePath = $treePath
                        xml = $xml
                    }
                }
                exit 0
            }

            # Compact summary: identity + parsed TaskDef child tags. The exact
            # TaskDef tag names for cycle/priority/affinity are not in the cited AI
            # docs, so emit the full <TaskDef> as a name->text map (best-effort) plus
            # a couple of well-known reads; the caller uses this to confirm tag names.
            $identity = Convert-TreeItem -TreeItem $item
            $taskDef = @{}
            if (-not [string]::IsNullOrEmpty($xml)) {
                try {
                    [xml]$doc = $xml
                    $node = $doc.SelectSingleNode('//TaskDef')
                    if ($null -ne $node) {
                        foreach ($childNode in $node.ChildNodes) {
                            if ($childNode.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
                            if ($childNode.HasChildNodes -and $childNode.ChildNodes.Count -gt 1) { continue }
                            $taskDef[[string]$childNode.Name] = [string]$childNode.InnerText
                        }
                    }
                } catch {
                    $taskDef = @{}
                }
            }
            Write-JsonResult @{
                ok = $true
                data = @{
                    treePath = $treePath
                    identity = $identity
                    taskDef = $taskDef
                }
            }
            exit 0
        }

        'tc_task_create' {
            $name = [string]$payload.name
            if ([string]::IsNullOrWhiteSpace($name)) {
                throw 'name is required'
            }
            $subType = 0
            if ($payload.PSObject.Properties.Name -contains 'withImage' -and $payload.withImage -eq $false) {
                $subType = 1
            }
            $before = if ($payload.before) { [string]$payload.before } else { '' }
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $tirt = (Get-TreeItem -SysManager $sysManager -TreePath 'TIRT').Value
            $child = $tirt.CreateChild($name, $subType, $before, $null)
            Assert-WellFormedChild -Parent $tirt -Child $child -RequestedName $name -SubType $subType -ParentPath 'TIRT'

            $paramsApplied = $false
            $hasCycle = ($payload.PSObject.Properties.Name -contains 'cycleTimeUs') -and ($null -ne $payload.cycleTimeUs)
            $hasPriority = ($payload.PSObject.Properties.Name -contains 'priority') -and ($null -ne $payload.priority)
            if ($hasCycle -or $hasPriority) {
                $frag = ''
                if ($hasCycle) {
                    $ticks = [int64]([double]$payload.cycleTimeUs * 10)
                    $frag += "<CycleTime>$ticks</CycleTime>"
                }
                if ($hasPriority) {
                    $frag += "<Priority>$([int]$payload.priority)</Priority>"
                }
                $x = "<TreeItem><TaskDef>$frag</TaskDef></TreeItem>"
                try {
                    $child.ConsumeXml($x)
                } catch {
                    $xmlError = $null
                    try { $xmlError = $child.GetLastXmlError() } catch {}
                    if ($xmlError) { throw "ConsumeXml failed applying task params: $xmlError" }
                    throw
                }
                $paramsApplied = $true
            }

            if ($payload.save -eq $true) {
                Save-Solution -Dte $dte
            }

            Write-JsonResult @{
                ok = $true
                data = @{
                    parentPath = 'TIRT'
                    child = Convert-TreeItem -TreeItem $child
                    paramsApplied = $paramsApplied
                }
            }
            exit 0
        }

        'tc_task_set_params' {
            $treePath = [string]$payload.path
            if ([string]::IsNullOrWhiteSpace($treePath)) {
                throw 'path is required'
            }
            $hasXml = ($payload.PSObject.Properties.Name -contains 'xml') -and (-not [string]::IsNullOrWhiteSpace([string]$payload.xml))
            if ($hasXml) {
                $x = [string]$payload.xml
            } else {
                $frag = ''
                if (($payload.PSObject.Properties.Name -contains 'cycleTimeUs') -and ($null -ne $payload.cycleTimeUs)) {
                    $ticks = [int64]([double]$payload.cycleTimeUs * 10)
                    $frag += "<CycleTime>$ticks</CycleTime>"
                }
                if (($payload.PSObject.Properties.Name -contains 'priority') -and ($null -ne $payload.priority)) {
                    $frag += "<Priority>$([int]$payload.priority)</Priority>"
                }
                if (($payload.PSObject.Properties.Name -contains 'autoStart') -and ($null -ne $payload.autoStart)) {
                    $frag += "<AutoStart>$(([bool]$payload.autoStart).ToString().ToLowerInvariant())</AutoStart>"
                }
                if ([string]::IsNullOrEmpty($frag)) {
                    throw 'set_params requires xml, or at least one of cycleTimeUs / priority / autoStart'
                }
                $x = "<TreeItem><TaskDef>$frag</TaskDef></TreeItem>"
            }
            $returnXml = $false
            if ($payload.PSObject.Properties.Name -contains 'returnXml') {
                $returnXml = [bool]$payload.returnXml
            }
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $item = Set-TreeItemXml -SysManager $sysManager -TargetPath $treePath -Xml $x
            $data = @{ treePath = $treePath }
            if ($returnXml) {
                $data.xml = Strip-TreeImage $item.ProduceXml($false)
            }
            if ($payload.save -eq $true) {
                Save-Solution -Dte $dte
            }
            Write-JsonResult @{
                ok = $true
                data = $data
            }
            exit 0
        }

        'tc_task_add_image_var' {
            $treePath = [string]$payload.path
            $varName = [string]$payload.varName
            $dataType = [string]$payload.dataType
            if ([string]::IsNullOrWhiteSpace($treePath)) { throw 'path is required' }
            if ([string]::IsNullOrWhiteSpace($varName)) { throw 'varName is required' }
            if ([string]::IsNullOrWhiteSpace($dataType)) { throw 'dataType is required' }
            $start = -1
            if (($payload.PSObject.Properties.Name -contains 'startAddress') -and ($null -ne $payload.startAddress)) {
                $start = [int]$payload.startAddress
            }
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $node = (Get-TreeItem -SysManager $sysManager -TreePath $treePath).Value
            $child = $node.CreateChild($varName, $start, '', $dataType)
            Assert-WellFormedChild -Parent $node -Child $child -RequestedName $varName -SubType $start -ParentPath $treePath
            if ($payload.save -eq $true) {
                Save-Solution -Dte $dte
            }
            Write-JsonResult @{
                ok = $true
                data = @{
                    parentPath = $treePath
                    child = Convert-TreeItem -TreeItem $child
                }
            }
            exit 0
        }

        'tc_task_get_rt_settings' {
            $summary = $false
            if ($payload.PSObject.Properties.Name -contains 'summary') {
                $summary = [bool]$payload.summary
            }
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $tirs = (Get-TreeItem -SysManager $sysManager -TreePath 'TIRS').Value
            $xml = Strip-TreeImage $tirs.ProduceXml($false)
            if (-not $summary) {
                Write-JsonResult @{
                    ok = $true
                    data = @{
                        treePath = 'TIRS'
                        xml = $xml
                    }
                }
                exit 0
            }
            $maxCPUs = $null
            $affinity = $null
            $cpus = @()
            if (-not [string]::IsNullOrEmpty($xml)) {
                try {
                    [xml]$doc = $xml
                    $def = $doc.SelectSingleNode('//RTimeSetDef')
                    if ($null -ne $def) {
                        $mc = $def.SelectSingleNode('MaxCPUs')
                        if ($null -ne $mc) { $maxCPUs = [string]$mc.InnerText }
                        $af = $def.SelectSingleNode('Affinity')
                        if ($null -ne $af) { $affinity = [string]$af.InnerText }
                        foreach ($cpuNode in $def.SelectNodes('.//CPU')) {
                            $entry = @{}
                            $idAttr = $cpuNode.Attributes['id']
                            if ($null -ne $idAttr) { $entry['id'] = [string]$idAttr.Value }
                            foreach ($cn in $cpuNode.ChildNodes) {
                                if ($cn.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
                                $entry[[string]$cn.Name] = [string]$cn.InnerText
                            }
                            $cpus += $entry
                        }
                    }
                } catch {
                    $maxCPUs = $null; $affinity = $null; $cpus = @()
                }
            }
            Write-JsonResult @{
                ok = $true
                data = @{
                    treePath = 'TIRS'
                    maxCPUs = $maxCPUs
                    affinity = $affinity
                    cpus = $cpus
                }
            }
            exit 0
        }

        'tc_task_set_rt_settings' {
            # CONFIG-ONLY: edits the project RT settings, not the running target.
            $hasXml = ($payload.PSObject.Properties.Name -contains 'xml') -and (-not [string]::IsNullOrWhiteSpace([string]$payload.xml))
            if ($hasXml) {
                $x = [string]$payload.xml
            } else {
                $frag = ''
                if (($payload.PSObject.Properties.Name -contains 'maxCPUs') -and ($null -ne $payload.maxCPUs)) {
                    $frag += "<MaxCPUs>$([int]$payload.maxCPUs)</MaxCPUs>"
                }
                if (($payload.PSObject.Properties.Name -contains 'affinity') -and (-not [string]::IsNullOrWhiteSpace([string]$payload.affinity))) {
                    $frag += "<Affinity>$(ConvertTo-XmlText ([string]$payload.affinity))</Affinity>"
                }
                if (($payload.PSObject.Properties.Name -contains 'cpus') -and ($null -ne $payload.cpus)) {
                    $cpuFrag = ''
                    foreach ($cpu in @($payload.cpus)) {
                        if ($null -eq $cpu) { continue }
                        $idVal = if ($null -ne $cpu.id) { [int]$cpu.id } else { throw 'each cpus entry requires id' }
                        $inner = ''
                        if ($null -ne $cpu.loadLimit) { $inner += "<LoadLimit>$([int]$cpu.loadLimit)</LoadLimit>" }
                        if ($null -ne $cpu.baseTimeNs) { $inner += "<BaseTime>$([int64]$cpu.baseTimeNs)</BaseTime>" }
                        if ($null -ne $cpu.latencyWarningUs) { $inner += "<LatencyWarning>$([int]$cpu.latencyWarningUs)</LatencyWarning>" }
                        $cpuFrag += "<CPU id=`"$idVal`">$inner</CPU>"
                    }
                    if (-not [string]::IsNullOrEmpty($cpuFrag)) {
                        $frag += "<CPUs>$cpuFrag</CPUs>"
                    }
                }
                if ([string]::IsNullOrEmpty($frag)) {
                    throw 'set_rt_settings requires xml, or at least one of maxCPUs / affinity / cpus'
                }
                $x = "<TreeItem><RTimeSetDef>$frag</RTimeSetDef></TreeItem>"
            }
            $returnXml = $false
            if ($payload.PSObject.Properties.Name -contains 'returnXml') {
                $returnXml = [bool]$payload.returnXml
            }
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $item = Set-TreeItemXml -SysManager $sysManager -TargetPath 'TIRS' -Xml $x
            $data = @{ treePath = 'TIRS' }
            if ($returnXml) {
                $data.xml = Strip-TreeImage $item.ProduceXml($false)
            }
            if ($payload.save -eq $true) {
                Save-Solution -Dte $dte
            }
            Write-JsonResult @{
                ok = $true
                data = $data
            }
            exit 0
        }

        'tc_task_bind_cpu' {
            $treePath = [string]$payload.path
            if ([string]::IsNullOrWhiteSpace($treePath)) { throw 'path is required' }
            if ([string]::IsNullOrWhiteSpace([string]$payload.affinity)) { throw 'affinity is required' }
            $token = Convert-CpuAffinity -Affinity ([string]$payload.affinity)
            $x = "<TreeItem><TaskDef><CpuAffinity>$token</CpuAffinity></TaskDef></TreeItem>"
            $returnXml = $false
            if ($payload.PSObject.Properties.Name -contains 'returnXml') {
                $returnXml = [bool]$payload.returnXml
            }
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $item = Set-TreeItemXml -SysManager $sysManager -TargetPath $treePath -Xml $x
            $data = @{
                treePath = $treePath
                affinity = $token
            }
            if ($returnXml) {
                $data.xml = Strip-TreeImage $item.ProduceXml($false)
            }
            if ($payload.save -eq $true) {
                Save-Solution -Dte $dte
            }
            Write-JsonResult @{
                ok = $true
                data = $data
            }
            exit 0
        }

        'tc_task_get_linked_task' {
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            if (-not (Ensure-TcPlcTaskRefHelper)) {
                throw 'TCatSysManagerLib.dll could not be loaded; the typed ITcPlcTaskReference cast is required for tc_task get_linked_task on this shell'
            }
            # ITcPlcTaskReference is NOT on the PLC root -- resolve the task-reference
            # sub-node (e.g. PlcTask). Try each candidate PATH with a FRESH RCW per
            # attempt (cached RCWs QI-fail E_NOINTERFACE); first that reads wins.
            $candidatePaths = Resolve-PlcTaskRefCandidates -SysManager $sysManager -Path ([string]$payload.path)
            $treePath = $null
            $lt = $null
            $resolved = $false
            $lastErr = $null
            foreach ($candPath in $candidatePaths) {
                try {
                    $node = (Get-TreeItem -SysManager $sysManager -TreePath $candPath).Value
                    $lt = [Te1000PlcTaskRefHelper]::GetLinkedTask($node)
                    $treePath = $candPath
                    $resolved = $true
                    break
                } catch {
                    $lastErr = $_.Exception.Message
                }
            }
            if (-not $resolved) {
                throw "could not find a node implementing ITcPlcTaskReference (GetLinkedTask) under the PLC project. Tried: $($candidatePaths -join ', '). Last error: $lastErr"
            }
            Write-JsonResult @{
                ok = $true
                data = @{
                    treePath = $treePath
                    linkedTask = $lt
                }
            }
            exit 0
        }

        'tc_task_set_linked_task' {
            $linkedTask = [string]$payload.linkedTask
            if ([string]::IsNullOrWhiteSpace($linkedTask)) {
                throw 'linkedTask is required'
            }
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            if (-not (Ensure-TcPlcTaskRefHelper)) {
                throw 'TCatSysManagerLib.dll could not be loaded; the typed ITcPlcTaskReference cast is required for tc_task set_linked_task on this shell'
            }
            # Same resolution as get_linked_task: ITcPlcTaskReference is on the
            # task-reference sub-node (e.g. PlcTask), NOT the PLC root. Feature-detect
            # the node with a GetLinkedTask read (proves the QI), then write on a FRESH
            # RCW for the same path (cached RCWs QI-fail E_NOINTERFACE).
            $candidatePaths = Resolve-PlcTaskRefCandidates -SysManager $sysManager -Path ([string]$payload.path)
            $treePath = $null
            $resolved = $false
            $lastErr = $null
            foreach ($candPath in $candidatePaths) {
                try {
                    $probe = (Get-TreeItem -SysManager $sysManager -TreePath $candPath).Value
                    $null = [Te1000PlcTaskRefHelper]::GetLinkedTask($probe)
                    $treePath = $candPath
                    $resolved = $true
                    break
                } catch {
                    $lastErr = $_.Exception.Message
                }
            }
            if (-not $resolved) {
                throw "could not find a node implementing ITcPlcTaskReference (SetLinkedTask) under the PLC project. Tried: $($candidatePaths -join ', '). Last error: $lastErr"
            }
            $node = (Get-TreeItem -SysManager $sysManager -TreePath $treePath).Value
            try {
                [Te1000PlcTaskRefHelper]::SetLinkedTask($node, $linkedTask)
            } catch {
                throw "node '$treePath' does not implement ITcPlcTaskReference: $($_.Exception.Message)"
            }
            if ($payload.save -eq $true) {
                Save-Solution -Dte $dte
            }
            Write-JsonResult @{
                ok = $true
                data = @{
                    treePath = $treePath
                    linkedTask = $linkedTask
                    set = $true
                }
            }
            exit 0
        }

        'twincat_produce_mapping_info' {
            # Read-only: serialize ALL current variable links/mappings of the loaded
            # .tsproj to one XML blob (the IDE's "Export Mapping Information"). Called
            # late-bound on the aggregated project COM object (same surface that answers
            # ActivateConfiguration / LinkVariables / SetTargetNetId), so no QI/cast helper
            # is needed. No tree path: operates on the whole project.
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $xml = $null
            try {
                $xml = $sysManager.ProduceMappingInfo()
            } catch {
                Fail "ProduceMappingInfo failed: $($_.Exception.Message) ($(Get-ErrorCode $_.Exception))"
            }
            Write-JsonResult @{
                ok = $true
                data = @{
                    xml = ([string]$xml)
                }
            }
            exit 0
        }

        'twincat_consume_mapping_info' {
            # Re-apply/merge a previously produced mapping-info XML blob into the current
            # project. MUTATES the offline config (adds links); no effect on the live cell
            # until a later twincat_activate_configuration. ConsumeMappingInfo is on the
            # aggregated project COM object; no GetLastXmlError here (that is an
            # ITcSmTreeItem member) so just surface the COM message on failure.
            $xml = [string]$payload.xml
            if ([string]::IsNullOrWhiteSpace($xml)) {
                throw 'xml is required'
            }
            $save = $false
            if ($payload.PSObject.Properties.Name -contains 'save') {
                $save = [bool]$payload.save
            }
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            try {
                $sysManager.ConsumeMappingInfo($xml)
            } catch {
                Fail "ConsumeMappingInfo failed: $($_.Exception.Message) ($(Get-ErrorCode $_.Exception))"
            }
            if ($save) {
                Save-Solution -Dte $dte
            }
            Write-JsonResult @{
                ok = $true
                data = @{
                    consumed = $true
                    saved = $save
                }
            }
            exit 0
        }

        'twincat_clear_mapping_info' {
            # Destructive: removes ALL variable links project-wide. MUTATES the offline
            # config; no effect on the live cell until a later twincat_activate_configuration.
            # The confirm token (ALLOW_TWINCAT_DELETE) is enforced in index.js, mirroring
            # twincat_activate_configuration / plc_download which gate in JS.
            $save = $false
            if ($payload.PSObject.Properties.Name -contains 'save') {
                $save = [bool]$payload.save
            }
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            try {
                $sysManager.ClearMappingInfo()
            } catch {
                Fail "ClearMappingInfo failed: $($_.Exception.Message) ($(Get-ErrorCode $_.Exception))"
            }
            if ($save) {
                Save-Solution -Dte $dte
            }
            Write-JsonResult @{
                ok = $true
                data = @{
                    cleared = $true
                    saved = $save
                }
            }
            exit 0
        }

        'twincat_list_routes' {
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $item = (Get-TreeItem -SysManager $sysManager -TreePath 'TIRR').Value

            $routes = @()
            $xml = Get-SafeValue { $item.ProduceXml() }
            if (-not [string]::IsNullOrEmpty($xml)) {
                try {
                    [xml]$doc = $xml
                    foreach ($n in $doc.SelectNodes('//TreeItem/RoutePrj/RemoteConnections/*')) {
                        $rName = Get-SafeValue { [string]$n.Name }
                        $rNetId = Get-SafeValue { [string]$n.NetId }
                        if ([string]::IsNullOrWhiteSpace($rNetId)) { $rNetId = Get-SafeValue { [string]$n.AmsNetId } }
                        $rAddr = Get-SafeValue { [string]$n.Address }
                        if ([string]::IsNullOrWhiteSpace($rAddr)) { $rAddr = Get-SafeValue { [string]$n.IpAddr } }
                        $routes += @{
                            name = $rName
                            netId = $rNetId
                            address = $rAddr
                            type = [string]$n.LocalName
                        }
                    }
                } catch {
                    $routes = @()
                }
            }

            Write-JsonResult @{
                ok = $true
                data = @{
                    count = $routes.Count
                    routes = $routes
                }
            }
            exit 0
        }

        'twincat_route_broadcast_search' {
            $timeoutMs = if ($payload.timeoutMs) { [int]$payload.timeoutMs } else { 4000 }

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $item = (Get-TreeItem -SysManager $sysManager -TreePath 'TIRR').Value

            $trigger = '<TreeItem><RoutePrj><TargetList><BroadcastSearch>true</BroadcastSearch></TargetList></RoutePrj></TreeItem>'
            try {
                $item.ConsumeXml($trigger)
            } catch {
                $e = Get-SafeValue { $item.GetLastXmlError() }
                if ($e) { throw "ConsumeXml failed: $e" } else { throw }
            }
            Start-Sleep -Milliseconds $timeoutMs

            $targets = @()
            $res = Get-SafeValue { $item.ProduceXml() }
            if (-not [string]::IsNullOrEmpty($res)) {
                try {
                    [xml]$doc = $res
                    foreach ($t in $doc.SelectNodes('//TreeItem/RoutePrj/TargetList/Target')) {
                        $targets += @{
                            name = [string]$t.Name
                            netId = [string]$t.NetId
                            ipAddr = [string]$t.IpAddr
                        }
                    }
                } catch {
                    $targets = @()
                }
            }

            Write-JsonResult @{
                ok = $true
                data = @{
                    count = $targets.Count
                    targets = $targets
                }
            }
            exit 0
        }

        'twincat_route_search_host' {
            $searchHost = [string]$payload.host
            if ([string]::IsNullOrWhiteSpace($searchHost)) {
                throw 'host is required'
            }
            $timeoutMs = if ($payload.timeoutMs) { [int]$payload.timeoutMs } else { 4000 }

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $item = (Get-TreeItem -SysManager $sysManager -TreePath 'TIRR').Value

            $h = ConvertTo-XmlText $searchHost
            $trigger = "<TreeItem><RoutePrj><TargetList><Search>$h</Search></TargetList></RoutePrj></TreeItem>"
            try {
                $item.ConsumeXml($trigger)
            } catch {
                $e = Get-SafeValue { $item.GetLastXmlError() }
                if ($e) { throw "ConsumeXml failed: $e" } else { throw }
            }
            Start-Sleep -Milliseconds $timeoutMs

            $target = $null
            $found = $false
            $res = Get-SafeValue { $item.ProduceXml() }
            if (-not [string]::IsNullOrEmpty($res)) {
                try {
                    [xml]$doc = $res
                    $t = $doc.SelectSingleNode('//TreeItem/RoutePrj/TargetList/Target')
                    if ($t) {
                        $target = @{
                            name = [string]$t.Name
                            netId = [string]$t.NetId
                            ipAddr = [string]$t.IpAddr
                            version = [string]$t.Version
                            os = [string]$t.OS
                        }
                        $found = $true
                    }
                } catch {
                    $target = $null
                    $found = $false
                }
            }

            Write-JsonResult @{
                ok = $true
                data = @{
                    host = $searchHost
                    found = $found
                    target = $target
                }
            }
            exit 0
        }

        'twincat_add_route' {
            if ([string]$payload.confirm -ne 'ALLOW_TWINCAT_ROUTE_WRITE') {
                throw 'Blocked: confirm=ALLOW_TWINCAT_ROUTE_WRITE required to write an ADS route.'
            }
            $remoteName = [string]$payload.remoteName
            $remoteNetId = [string]$payload.remoteNetId
            $remoteIpAddr = [string]$payload.remoteIpAddr
            $remoteHostName = [string]$payload.remoteHostName
            if ([string]::IsNullOrWhiteSpace($remoteName)) { throw 'remoteName is required' }
            if ([string]::IsNullOrWhiteSpace($remoteNetId)) { throw 'remoteNetId is required' }
            if ([string]::IsNullOrWhiteSpace($remoteIpAddr) -and [string]::IsNullOrWhiteSpace($remoteHostName)) {
                throw 'one of remoteIpAddr / remoteHostName is required'
            }

            $sb = '<AddRoute>'
            $sb += "<RemoteName>$(ConvertTo-XmlText $remoteName)</RemoteName>"
            $sb += "<RemoteNetId>$(ConvertTo-XmlText $remoteNetId)</RemoteNetId>"
            if (-not [string]::IsNullOrWhiteSpace($remoteIpAddr)) {
                $sb += "<RemoteIpAddr>$(ConvertTo-XmlText $remoteIpAddr)</RemoteIpAddr>"
            } elseif (-not [string]::IsNullOrWhiteSpace($remoteHostName)) {
                $sb += "<RemoteHostName>$(ConvertTo-XmlText $remoteHostName)</RemoteHostName>"
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$payload.userName)) {
                $sb += "<UserName>$(ConvertTo-XmlText ([string]$payload.userName))</UserName>"
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$payload.password)) {
                $sb += "<Password>$(ConvertTo-XmlText ([string]$payload.password))</Password>"
            }
            if (($payload.PSObject.Properties.Name -contains 'noEncryption') -and [bool]$payload.noEncryption) {
                $sb += '<NoEncryption>1</NoEncryption>'
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$payload.localName)) {
                $sb += "<LocalName>$(ConvertTo-XmlText ([string]$payload.localName))</LocalName>"
            }
            $sb += '</AddRoute>'
            $xml = "<TreeItem><RoutePrj><RemoteConnections>$sb</RemoteConnections></RoutePrj></TreeItem>"

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $null = Set-TreeItemXml -SysManager $sysManager -TargetPath 'TIRR' -Xml $xml

            Write-JsonResult @{
                ok = $true
                data = @{
                    added = $true
                    remoteName = $remoteName
                    remoteNetId = $remoteNetId
                }
            }
            exit 0
        }

        'twincat_add_project_route' {
            if ([string]$payload.confirm -ne 'ALLOW_TWINCAT_ROUTE_WRITE') {
                throw 'Blocked: confirm=ALLOW_TWINCAT_ROUTE_WRITE required to write an ADS route.'
            }
            $rName = [string]$payload.name
            $rNetId = [string]$payload.netId
            $rIpAddr = [string]$payload.ipAddr
            $rHostName = [string]$payload.hostName
            if ([string]::IsNullOrWhiteSpace($rName)) { throw 'name is required' }
            if ([string]::IsNullOrWhiteSpace($rNetId)) { throw 'netId is required' }
            if ([string]::IsNullOrWhiteSpace($rIpAddr) -and [string]::IsNullOrWhiteSpace($rHostName)) {
                throw 'one of ipAddr / hostName is required'
            }

            $sb = '<AddProjectRoute>'
            $sb += "<Name>$(ConvertTo-XmlText $rName)</Name>"
            $sb += "<NetId>$(ConvertTo-XmlText $rNetId)</NetId>"
            if (-not [string]::IsNullOrWhiteSpace($rIpAddr)) {
                $sb += "<IpAddr>$(ConvertTo-XmlText $rIpAddr)</IpAddr>"
            } elseif (-not [string]::IsNullOrWhiteSpace($rHostName)) {
                $sb += "<HostName>$(ConvertTo-XmlText $rHostName)</HostName>"
            }
            $sb += '</AddProjectRoute>'
            $xml = "<TreeItem><RoutePrj><RemoteConnections>$sb</RemoteConnections></RoutePrj></TreeItem>"

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $null = Set-TreeItemXml -SysManager $sysManager -TargetPath 'TIRR' -Xml $xml

            Write-JsonResult @{
                ok = $true
                data = @{
                    added = $true
                    name = $rName
                    netId = $rNetId
                }
            }
            exit 0
        }

        'twincat_get_silent_mode' {
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $settings = Get-AutomationSettings -Dte $dte
            $silent = [bool](Get-SafeValue { [bool]$settings.SilentMode })

            Write-JsonResult @{
                ok = $true
                data = @{
                    silentMode = $silent
                }
            }
            exit 0
        }

        'twincat_set_silent_mode' {
            if (-not ($payload.PSObject.Properties.Name -contains 'enabled')) {
                throw "'enabled' is required (boolean)"
            }
            $enabled = [bool]$payload.enabled

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $settings = Get-AutomationSettings -Dte $dte
            $prev = [bool]$settings.SilentMode
            $settings.SilentMode = $enabled

            Write-JsonResult @{
                ok = $true
                data = @{
                    silentMode = $enabled
                    previous = $prev
                }
            }
            exit 0
        }

        'twincat_get_target_platform' {
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $platform = $null
            try {
                $cfg = $sysManager.ConfigurationManager
                $platform = [string]$cfg.ActiveTargetPlatform
            } catch {
                if (-not (Ensure-TcSettingsHelper)) { throw }
                $platform = [Te1000SettingsHelper]::GetActiveTargetPlatform($sysManager)
            }

            Write-JsonResult @{
                ok = $true
                data = @{
                    activeTargetPlatform = $platform
                }
            }
            exit 0
        }

        'twincat_set_target_platform' {
            $platform = [string]$payload.platform
            $allowed = @('TwinCAT RT (x86)', 'TwinCAT RT (x64)')
            if ($allowed -notcontains $platform) {
                throw "platform must be exactly one of: '$($allowed -join "', '")'"
            }

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $prev = $null
            try {
                $cfg = $sysManager.ConfigurationManager
                $prev = [string]$cfg.ActiveTargetPlatform
                $cfg.ActiveTargetPlatform = $platform
            } catch {
                if (-not (Ensure-TcSettingsHelper)) { throw }
                $prev = [Te1000SettingsHelper]::GetActiveTargetPlatform($sysManager)
                [Te1000SettingsHelper]::SetActiveTargetPlatform($sysManager, $platform)
            }

            Write-JsonResult @{
                ok = $true
                data = @{
                    activeTargetPlatform = $platform
                    previous = $prev
                }
            }
            exit 0
        }

        'twincat_save_solution_archive' {
            $file = [string]$payload.file
            if ([string]::IsNullOrWhiteSpace($file)) {
                throw 'file is required (absolute path ending in .tszip)'
            }
            if (-not $file.ToLowerInvariant().EndsWith('.tszip')) {
                throw "file must end in .tszip: $file"
            }
            $parent = Split-Path -Parent $file
            if ([string]::IsNullOrWhiteSpace($parent) -or -not (Test-Path -LiteralPath $parent)) {
                throw "parent directory does not exist (not created automatically): $parent"
            }

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            try {
                $sysManager.SaveAsArchive($file)
            } catch {
                if (-not (Ensure-TcSettingsHelper)) { throw }
                [Te1000SettingsHelper]::SaveAsArchive($sysManager, $file)
            }

            Write-JsonResult @{
                ok = $true
                data = @{
                    file = $file
                    saved = $true
                }
            }
            exit 0
        }

        'twincat_save_plc_archive' {
            $file = [string]$payload.file
            if ([string]::IsNullOrWhiteSpace($file)) {
                throw 'file is required (absolute path ending in .tpzip)'
            }
            if (-not $file.ToLowerInvariant().EndsWith('.tpzip')) {
                throw "file must end in .tpzip: $file"
            }
            $parent = Split-Path -Parent $file
            if ([string]::IsNullOrWhiteSpace($parent) -or -not (Test-Path -LiteralPath $parent)) {
                throw "parent directory does not exist (not created automatically): $parent"
            }

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $plc = (Get-TreeItem -SysManager $sysManager -TreePath 'TIPC').Value

            $childName = if ($payload.name) { [string]$payload.name } else { $null }
            if ([string]::IsNullOrWhiteSpace($childName)) {
                if ([int]$plc.ChildCount -lt 1) {
                    throw 'No PLC project found under TIPC'
                }
                $childName = [string]$plc.Child(1).Name
            }

            $plc.ExportChild($childName, $file)

            Write-JsonResult @{
                ok = $true
                data = @{
                    parentPath = 'TIPC'
                    childName = $childName
                    file = $file
                    saved = $true
                }
            }
            exit 0
        }

        'twincat_get_independent_file' {
            $path = [string]$payload.path
            if ([string]::IsNullOrWhiteSpace($path)) {
                throw 'path is required'
            }

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $item = (Get-TreeItem -SysManager $sysManager -TreePath $path).Value
            $value = $null
            $raw = Get-SafeValue { [bool]$item.SaveInOwnFile }
            if ($null -ne $raw) {
                $value = [bool]$raw
            } else {
                if (-not (Ensure-TcSettingsHelper)) { throw 'SaveInOwnFile is not accessible (late-bound) and the typed helper could not be loaded' }
                $value = [Te1000SettingsHelper]::GetSaveInOwnFile($item)
            }

            Write-JsonResult @{
                ok = $true
                data = @{
                    path = $path
                    saveInOwnFile = $value
                }
            }
            exit 0
        }

        'twincat_set_independent_file' {
            $path = [string]$payload.path
            if ([string]::IsNullOrWhiteSpace($path)) {
                throw 'path is required'
            }
            Assert-NotSafetyPath -Path $path
            if (-not ($payload.PSObject.Properties.Name -contains 'enabled')) {
                throw "'enabled' is required (boolean)"
            }
            $enabled = [bool]$payload.enabled

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $item = (Get-TreeItem -SysManager $sysManager -TreePath $path).Value

            $prev = $null
            $raw = Get-SafeValue { [bool]$item.SaveInOwnFile }
            if ($null -ne $raw) {
                $prev = [bool]$raw
                $item.SaveInOwnFile = $enabled
            } else {
                if (-not (Ensure-TcSettingsHelper)) { throw 'SaveInOwnFile is not accessible (late-bound) and the typed helper could not be loaded' }
                $prev = [Te1000SettingsHelper]::GetSaveInOwnFile($item)
                [Te1000SettingsHelper]::SetSaveInOwnFile($item, $enabled)
            }

            Write-JsonResult @{
                ok = $true
                data = @{
                    path = $path
                    saveInOwnFile = $enabled
                    previous = $prev
                }
            }
            exit 0
        }

        'twincat_get_node_disabled' {
            $path = [string]$payload.path
            if ([string]::IsNullOrWhiteSpace($path)) {
                throw 'path is required'
            }
            $DISABLED_STATE = @{ 0 = 'SMDS_NOT_DISABLED'; 1 = 'SMDS_DISABLED'; 2 = 'SMDS_PARENT_DISABLED' }

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $item = (Get-TreeItem -SysManager $sysManager -TreePath $path).Value
            $raw = [int](Get-SafeValue { [int]$item.Disabled })
            $state = if ($DISABLED_STATE.ContainsKey($raw)) { $DISABLED_STATE[$raw] } else { "UNKNOWN($raw)" }

            Write-JsonResult @{
                ok = $true
                data = @{
                    path = $path
                    disabled = $raw
                    state = $state
                }
            }
            exit 0
        }

        'twincat_set_node_disabled' {
            $path = [string]$payload.path
            if ([string]::IsNullOrWhiteSpace($path)) {
                throw 'path is required'
            }
            Assert-NotSafetyPath -Path $path
            if (-not ($payload.PSObject.Properties.Name -contains 'disabled')) {
                throw "'disabled' is required (boolean)"
            }
            $disabled = [bool]$payload.disabled
            $DISABLED_STATE = @{ 0 = 'SMDS_NOT_DISABLED'; 1 = 'SMDS_DISABLED'; 2 = 'SMDS_PARENT_DISABLED' }

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $item = (Get-TreeItem -SysManager $sysManager -TreePath $path).Value
            $prev = [int](Get-SafeValue { [int]$item.Disabled })
            $newVal = if ($disabled) { 1 } else { 0 }
            $item.Disabled = $newVal

            Write-JsonResult @{
                ok = $true
                data = @{
                    path = $path
                    disabled = $newVal
                    state = $DISABLED_STATE[$newVal]
                    previous = $prev
                }
            }
            exit 0
        }

        # --- tc_fieldbus: NON-EtherCAT fieldbus config (OFFLINE only) ----------
        # PROFINET / PROFIBUS / CANopen / DeviceNet / EAP masters, slaves, boxes.
        # Every verb edits the in-memory project (CreateChild / ClaimResources /
        # ConsumeXml) — NONE push to the live cell, so no confirm token. Safety
        # (TISC) paths are rejected by Assert-NotSafetyPath.
        'fieldbus_create_device' {
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value

            $created = Invoke-FieldbusCreateDevice -SysManager $sysManager -Entry $payload

            $saved = $null
            if ($payload.PSObject.Properties.Name -contains 'save' -and [bool]$payload.save) {
                $saved = $false
                try { Save-Solution -Dte $dte; $saved = $true } catch { $saved = $false }
            }

            Write-JsonResult @{
                ok = $true
                data = @{
                    parentPath = $created.parentPath
                    child = $created.child
                    claimed = $created.claimed
                    saved = $saved
                }
            }
            exit 0
        }

        'fieldbus_create_devices' {
            $creates = $payload.creates
            if ($null -eq $creates -or @($creates).Count -eq 0) {
                throw 'creates is required'
            }
            $save = $false
            if ($payload.PSObject.Properties.Name -contains 'save') {
                $save = [bool]$payload.save
            }

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value

            $results = @()
            $succeeded = 0
            $failed = 0

            foreach ($entry in $creates) {
                $entryParent = if ($entry.PSObject.Properties.Name -contains 'parent' -and -not [string]::IsNullOrWhiteSpace([string]$entry.parent)) { [string]$entry.parent } else { 'TIID' }
                $entryName = if ($entry.PSObject.Properties.Name -contains 'name') { [string]$entry.name } else { $null }
                try {
                    $created = Invoke-FieldbusCreateDevice -SysManager $sysManager -Entry $entry
                    $succeeded++
                    $results += @{
                        parent = $created.parentPath
                        name = $entryName
                        ok = $true
                        child = $created.child
                        claimed = $created.claimed
                    }
                } catch {
                    $failed++
                    $results += @{
                        parent = $entryParent
                        name = $entryName
                        ok = $false
                        error = [string]$_.Exception.Message
                    }
                }
            }

            $data = @{
                count = @($creates).Count
                succeeded = $succeeded
                failed = $failed
                results = $results
            }
            if ($save) {
                $saved = $false
                try { Save-Solution -Dte $dte; $saved = $true } catch { $saved = $false }
                $data.saved = $saved
            }

            Write-JsonResult @{
                ok = $true
                data = $data
            }
            exit 0
        }

        'fieldbus_list_resources' {
            $path = [string]$payload.path
            if ([string]::IsNullOrWhiteSpace($path)) {
                throw 'path is required'
            }

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $item = (Get-TreeItem -SysManager $sysManager -TreePath $path).Value

            # Beckhoff pages disagree on the property name (PROFIBUS page cites
            # ResourcesCount returning a string; CANopen page cites ResourceCount).
            # Probe both via Get-SafeValue and report which one answered.
            $count = Normalize-ScalarValue (Get-SafeValue { $item.ResourcesCount })
            $prop = 'ResourcesCount'
            if ($null -eq $count) {
                $count = Normalize-ScalarValue (Get-SafeValue { $item.ResourceCount })
                $prop = 'ResourceCount'
            }
            if ($null -eq $count) {
                $prop = $null
            } else {
                # Coerce to int when parseable; otherwise keep the raw value.
                $parsed = 0
                if ([int]::TryParse([string]$count, [ref]$parsed)) {
                    $count = $parsed
                }
            }

            Write-JsonResult @{
                ok = $true
                data = @{
                    path = $path
                    resourcesCount = $count
                    property = $prop
                }
            }
            exit 0
        }

        'fieldbus_claim_resources' {
            $path = [string]$payload.path
            if ([string]::IsNullOrWhiteSpace($path)) {
                throw 'path is required'
            }
            if ($null -eq $payload.index) {
                throw 'index is required'
            }
            $index = [int]$payload.index
            Assert-NotSafetyPath -Path $path

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $item = (Get-TreeItem -SysManager $sysManager -TreePath $path).Value

            try {
                $item.ClaimResources($index)
            } catch {
                $xmlError = Get-SafeValue { [string]$item.GetLastXmlError() }
                if (-not [string]::IsNullOrWhiteSpace($xmlError)) {
                    throw "ClaimResources failed: $xmlError"
                }
                throw
            }

            $saved = $null
            if ($payload.PSObject.Properties.Name -contains 'save' -and [bool]$payload.save) {
                $saved = $false
                try { Save-Solution -Dte $dte; $saved = $true } catch { $saved = $false }
            }

            Write-JsonResult @{
                ok = $true
                data = @{
                    path = $path
                    index = $index
                    claimed = $true
                    saved = $saved
                }
            }
            exit 0
        }

        'fieldbus_create_gsd_box' {
            $controllerPath = [string]$payload.controllerPath
            $name = [string]$payload.name
            $gsdPath = [string]$payload.gsdPath
            $moduleIdentNumber = [string]$payload.moduleIdentNumber
            if ([string]::IsNullOrWhiteSpace($controllerPath)) { throw 'controllerPath is required' }
            if ([string]::IsNullOrWhiteSpace($name)) { throw 'name is required' }
            if ([string]::IsNullOrWhiteSpace($gsdPath)) { throw 'gsdPath is required' }
            if ([string]::IsNullOrWhiteSpace($moduleIdentNumber)) { throw 'moduleIdentNumber is required' }
            # GSD box SubType depends on the PROFINET controller variant (PN device
            # 115/118/142/143) and is NOT auto-defaulted — caller must pass it.
            if ($null -eq $payload.subType) {
                throw 'subType is required for create_gsd_box (PROFINET device subType, e.g. 115/118/142/143; depends on the controller variant). Confirm against the GSD how-to before use.'
            }
            $subType = [int]$payload.subType
            Assert-NotSafetyPath -Path $controllerPath

            $flags = if ($payload.PSObject.Properties.Name -contains 'boxFlags' -and $null -ne $payload.boxFlags) { [int]$payload.boxFlags } else { 0 }
            $dap = if ($payload.PSObject.Properties.Name -contains 'dapNumber' -and -not [string]::IsNullOrWhiteSpace([string]$payload.dapNumber)) { [string]$payload.dapNumber } else { '' }
            $before = if ($payload.PSObject.Properties.Name -contains 'before' -and $payload.before) { [string]$payload.before } else { '' }

            # Beckhoff GSD vInfo syntax: PathToGSDfile#ModuleIdentNumber#BoxFlags#DAPNumber
            $vInfo = "$gsdPath#$moduleIdentNumber#$flags#$dap"

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $controller = (Get-TreeItem -SysManager $sysManager -TreePath $controllerPath).Value
            $box = $controller.CreateChild($name, $subType, $before, $vInfo)
            Assert-WellFormedChild -Parent $controller -Child $box -RequestedName $name -SubType $subType -ParentPath $controllerPath

            $saved = $null
            if ($payload.PSObject.Properties.Name -contains 'save' -and [bool]$payload.save) {
                $saved = $false
                try { Save-Solution -Dte $dte; $saved = $true } catch { $saved = $false }
            }

            Write-JsonResult @{
                ok = $true
                data = @{
                    controllerPath = $controllerPath
                    box = Convert-TreeItem -TreeItem $box
                    vInfo = $vInfo
                    saved = $saved
                }
            }
            exit 0
        }

        'fieldbus_add_netvar' {
            $boxPath = [string]$payload.boxPath
            $name = [string]$payload.name
            $dataType = [string]$payload.dataType
            if ([string]::IsNullOrWhiteSpace($boxPath)) { throw 'boxPath is required' }
            if ([string]::IsNullOrWhiteSpace($name)) { throw 'name is required' }
            if ([string]::IsNullOrWhiteSpace($dataType)) { throw 'dataType is required' }
            Assert-NotSafetyPath -Path $boxPath
            $before = if ($payload.PSObject.Properties.Name -contains 'before' -and $payload.before) { [string]$payload.before } else { '' }

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $box = (Get-TreeItem -SysManager $sysManager -TreePath $boxPath).Value
            # EAP pub/sub variable: SubType 0, dataType passed as vInfo. Resulting
            # ItemType is 35 (publisher) / 36 (subscriber) — informational read-back.
            $var = $box.CreateChild($name, 0, $before, $dataType)
            Assert-WellFormedChild -Parent $box -Child $var -RequestedName $name -SubType 0 -ParentPath $boxPath

            $saved = $null
            if ($payload.PSObject.Properties.Name -contains 'save' -and [bool]$payload.save) {
                $saved = $false
                try { Save-Solution -Dte $dte; $saved = $true } catch { $saved = $false }
            }

            Write-JsonResult @{
                ok = $true
                data = @{
                    boxPath = $boxPath
                    var = Convert-TreeItem -TreeItem $var
                    saved = $saved
                }
            }
            exit 0
        }

        'fieldbus_set_station_address' {
            $path = [string]$payload.path
            if ([string]::IsNullOrWhiteSpace($path)) {
                throw 'path is required'
            }
            if ($null -eq $payload.address) {
                throw 'address is required'
            }
            $address = [int]$payload.address
            Assert-NotSafetyPath -Path $path

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $item = (Get-TreeItem -SysManager $sysManager -TreePath $path).Value

            # The exact station-address XML element is not pinned in the docs (the
            # summarized bare ConsumeXml("44") form is suspect), so discover it first:
            # ProduceXml(false), locate an element whose name contains "Station" and an
            # "Address"/"No"/"Number" sibling, then ConsumeXml a minimal envelope.
            $current = Get-SafeValue { [string]$item.ProduceXml($false) }
            $element = $null
            if (-not [string]::IsNullOrWhiteSpace($current)) {
                $m = [regex]::Match($current, '<(?<el>\w*Station(Address|No|Number)\w*)>')
                if ($m.Success) {
                    $element = $m.Groups['el'].Value
                }
            }
            if ([string]::IsNullOrWhiteSpace($element)) {
                throw "Could not discover the station-address XML element from ProduceXml for '$path'. Use tc_fieldbus get_xml to inspect the node and set_xml to apply the correct element (the bare ConsumeXml(number) form is unverified and is not shipped)."
            }

            $xml = "<TreeItem><$element>$address</$element></TreeItem>"
            try {
                $item.ConsumeXml($xml)
            } catch {
                $xmlError = Get-SafeValue { [string]$item.GetLastXmlError() }
                if (-not [string]::IsNullOrWhiteSpace($xmlError)) {
                    throw "ConsumeXml failed: $xmlError"
                }
                throw
            }

            $saved = $null
            if ($payload.PSObject.Properties.Name -contains 'save' -and [bool]$payload.save) {
                $saved = $false
                try { Save-Solution -Dte $dte; $saved = $true } catch { $saved = $false }
            }

            Write-JsonResult @{
                ok = $true
                data = @{
                    path = $path
                    address = $address
                    element = $element
                    saved = $saved
                }
            }
            exit 0
        }

        'fieldbus_import_dbc' {
            $masterPath = [string]$payload.masterPath
            $fileName = [string]$payload.fileName
            if ([string]::IsNullOrWhiteSpace($masterPath)) { throw 'masterPath is required' }
            if ([string]::IsNullOrWhiteSpace($fileName)) { throw 'fileName is required' }
            Assert-NotSafetyPath -Path $masterPath

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $item = (Get-TreeItem -SysManager $sysManager -TreePath $masterPath).Value

            # CanOpenMaster/ImportDbcFile config import (topic 1095735435, needs
            # TC3.1 build >= 4018 — cannot easily detect, documented). OFFLINE.
            $sb = New-Object System.Text.StringBuilder
            [void]$sb.Append('<TreeItem><CanOpenMaster><ImportDbcFile>')
            [void]$sb.Append("<FileName>$(ConvertTo-XmlText $fileName)</FileName>")
            foreach ($flag in @('importExtendedMessages', 'importMultiplexedDataMessages', 'keepUnchangedMessages', 'communicateWithSlavesFromDbcFile')) {
                if ($payload.PSObject.Properties.Name -contains $flag -and $null -ne $payload.$flag) {
                    $tag = switch ($flag) {
                        'importExtendedMessages' { 'ImportExtendedMessages' }
                        'importMultiplexedDataMessages' { 'ImportMultiplexedDataMessages' }
                        'keepUnchangedMessages' { 'KeepUnchangedMessages' }
                        'communicateWithSlavesFromDbcFile' { 'CommunicateWithSlavesFromDbcFile' }
                    }
                    $val = if ([bool]$payload.$flag) { 'true' } else { 'false' }
                    [void]$sb.Append("<$tag>$val</$tag>")
                }
            }
            [void]$sb.Append('</ImportDbcFile></CanOpenMaster></TreeItem>')
            $xml = $sb.ToString()

            try {
                $item.ConsumeXml($xml)
            } catch {
                $xmlError = Get-SafeValue { [string]$item.GetLastXmlError() }
                if (-not [string]::IsNullOrWhiteSpace($xmlError)) {
                    throw "ImportDbcFile ConsumeXml failed: $xmlError (requires TC3.1 build >= 4018)"
                }
                throw
            }

            $saved = $null
            if ($payload.PSObject.Properties.Name -contains 'save' -and [bool]$payload.save) {
                $saved = $false
                try { Save-Solution -Dte $dte; $saved = $true } catch { $saved = $false }
            }

            Write-JsonResult @{
                ok = $true
                data = @{
                    masterPath = $masterPath
                    fileName = $fileName
                    imported = $true
                    saved = $saved
                }
            }
            exit 0
        }

        'fieldbus_get_xml' {
            $path = [string]$payload.path
            if ([string]::IsNullOrWhiteSpace($path)) {
                throw 'path is required'
            }
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $item = (Get-TreeItem -SysManager $sysManager -TreePath $path).Value
            $xml = [string]$item.ProduceXml($false)

            Write-JsonResult @{
                ok = $true
                data = @{ path = $path; xml = $xml }
            }
            exit 0
        }

        'fieldbus_set_xml' {
            $path = [string]$payload.path
            $xml = [string]$payload.xml
            if ([string]::IsNullOrWhiteSpace($path)) { throw 'path is required' }
            if ([string]::IsNullOrWhiteSpace($xml)) { throw 'xml is required' }
            Assert-NotSafetyPath -Path $path
            $returnXml = $payload.PSObject.Properties.Name -contains 'returnXml' -and [bool]$payload.returnXml

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $item = Set-TreeItemXml -SysManager $sysManager -TargetPath $path -Xml $xml

            $echo = $null
            if ($returnXml) {
                $echo = Normalize-ScalarValue (Get-SafeValue { [string]$item.ProduceXml($false) })
            }

            $saved = $null
            if ($payload.PSObject.Properties.Name -contains 'save' -and [bool]$payload.save) {
                $saved = $false
                try { Save-Solution -Dte $dte; $saved = $true } catch { $saved = $false }
            }

            Write-JsonResult @{
                ok = $true
                data = @{
                    path = $path
                    applied = $true
                    xml = $echo
                    saved = $saved
                }
            }
            exit 0
        }

        'twincat_module_list' {
            if (-not (Ensure-Te1000ModuleHelper)) {
                Fail('TCatSysManagerLib.dll could not be loaded; the typed ITcModuleManager3 enumeration is required to list TcCOM modules on this shell')
            }
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value

            $tuples = [Te1000ModuleHelper]::List($sysManager)
            $modules = @()
            foreach ($t in $tuples) {
                $modules += @{
                    moduleTypeName = Normalize-ScalarValue $t[0]
                    moduleInstanceName = Normalize-ScalarValue $t[1]
                    classId = Normalize-ScalarValue $t[2]
                    oid = Normalize-ScalarValue $t[3]
                    objectId = Normalize-ScalarValue $t[4]
                    parentOid = Normalize-ScalarValue $t[5]
                }
            }

            Write-JsonResult @{
                ok = $true
                data = @{
                    count = @($modules).Count
                    modules = $modules
                }
            }
            exit 0
        }

        'twincat_module_create' {
            $parentPath = 'TIRC^TcCOM Objects'
            $name = [string]$payload.name
            if ([string]::IsNullOrWhiteSpace($name)) { throw 'name is required' }
            $by = [string]$payload.by
            if ($by -ne 'classid' -and $by -ne 'name') { throw "by must be 'classid' or 'name'" }
            $id = [string]$payload.id
            if ([string]::IsNullOrWhiteSpace($id)) { throw 'id is required' }
            $subType = if ($by -eq 'classid') { 0 } else { 1 }
            $before = if ($payload.PSObject.Properties.Name -contains 'before' -and $payload.before) { [string]$payload.before } else { '' }

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $parent = (Get-TreeItem -SysManager $sysManager -TreePath $parentPath).Value
            $child = $parent.CreateChild($name, $subType, $before, $id)
            Assert-WellFormedChild -Parent $parent -Child $child -RequestedName $name -SubType $subType -ParentPath $parentPath

            Write-JsonResult @{
                ok = $true
                data = @{
                    parentPath = $parentPath
                    child = Convert-TreeItem -TreeItem $child
                }
            }
            exit 0
        }

        'twincat_module_get_xml' {
            $path = [string]$payload.path
            if ([string]::IsNullOrWhiteSpace($path)) { throw 'path is required' }

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $item = (Get-TreeItem -SysManager $sysManager -TreePath $path).Value
            $xml = Strip-TreeImage $item.ProduceXml()

            Write-JsonResult @{
                ok = $true
                data = @{ treePath = $path; xml = $xml }
            }
            exit 0
        }

        'twincat_module_set_xml' {
            $path = [string]$payload.path
            $xml = [string]$payload.xml
            if ([string]::IsNullOrWhiteSpace($path)) { throw 'path is required' }
            if ([string]::IsNullOrWhiteSpace($xml)) { throw 'xml is required' }
            $returnXml = $payload.PSObject.Properties.Name -contains 'returnXml' -and [bool]$payload.returnXml

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $item = Set-TreeItemXml -SysManager $sysManager -TargetPath $path -Xml $xml

            $data = @{ treePath = $path }
            if ($returnXml) {
                $data.xml = Strip-TreeImage $item.ProduceXml()
            }

            Write-JsonResult @{
                ok = $true
                data = $data
            }
            exit 0
        }

        'twincat_module_enable_symbols' {
            $path = [string]$payload.path
            if ([string]::IsNullOrWhiteSpace($path)) { throw 'path is required' }
            $doParams = $payload.PSObject.Properties.Name -contains 'parameters' -and [bool]$payload.parameters
            $doAreas = $payload.PSObject.Properties.Name -contains 'dataAreas' -and [bool]$payload.dataAreas
            $returnXml = $payload.PSObject.Properties.Name -contains 'returnXml' -and [bool]$payload.returnXml

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $item = (Get-TreeItem -SysManager $sysManager -TreePath $path).Value

            [xml]$doc = $item.ProduceXml()
            $changed = $false
            if ($doParams) {
                foreach ($n in $doc.SelectNodes('//Parameters//Parameter')) {
                    $n.SetAttribute('CreateSymbol', 'true')
                    $changed = $true
                }
            }
            if ($doAreas) {
                foreach ($n in $doc.SelectNodes('//DataAreas//DataArea/AreaNo')) {
                    $n.SetAttribute('CreateSymbols', 'true')
                    $changed = $true
                }
            }
            if ($changed) {
                try {
                    $item.ConsumeXml($doc.OuterXml)
                } catch {
                    $xmlError = $null
                    try { $xmlError = $item.GetLastXmlError() } catch { }
                    if ($xmlError) { throw "ConsumeXml failed: $xmlError" }
                    throw
                }
            }

            $data = @{
                treePath = $path
                parameters = $doParams
                dataAreas = $doAreas
                changed = $changed
            }
            if ($returnXml) {
                $data.xml = Strip-TreeImage $item.ProduceXml()
            }

            Write-JsonResult @{
                ok = $true
                data = $data
            }
            exit 0
        }

        'twincat_module_set_context' {
            if (-not (Ensure-Te1000ModuleHelper)) {
                Fail('TCatSysManagerLib.dll could not be loaded; the typed ITcModuleInstance2.SetModuleContext call is required to set a module context on this shell')
            }
            $path = [string]$payload.path
            if ([string]::IsNullOrWhiteSpace($path)) { throw 'path is required' }
            if ($null -eq $payload.taskObjectId) { throw 'taskObjectId is required' }
            $taskObjectId = [int]$payload.taskObjectId
            $contextId = if ($payload.PSObject.Properties.Name -contains 'contextId' -and $null -ne $payload.contextId) { [int]$payload.contextId } else { 0 }

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $item = (Get-TreeItem -SysManager $sysManager -TreePath $path).Value

            [Te1000ModuleHelper]::SetContext($item, $contextId, $taskObjectId)

            Write-JsonResult @{
                ok = $true
                data = @{
                    treePath = $path
                    contextId = $contextId
                    taskObjectId = $taskObjectId
                    contextSet = $true
                }
            }
            exit 0
        }

        'twincat_cpp_create_project' {
            $parentPath = 'TIXC'
            $name = [string]$payload.name
            $template = [string]$payload.template
            if ([string]::IsNullOrWhiteSpace($name)) { throw 'name is required' }
            if ([string]::IsNullOrWhiteSpace($template)) { throw 'template is required' }
            $before = if ($payload.PSObject.Properties.Name -contains 'before' -and $payload.before) { [string]$payload.before } else { '' }

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $cpp = (Get-TreeItem -SysManager $sysManager -TreePath $parentPath).Value
            $child = $cpp.CreateChild($name, 0, $before, $template)
            Assert-WellFormedChild -Parent $cpp -Child $child -RequestedName $name -SubType 0 -ParentPath $parentPath

            Write-JsonResult @{
                ok = $true
                data = @{
                    parentPath = $parentPath
                    child = Convert-TreeItem -TreeItem $child
                }
            }
            exit 0
        }

        'twincat_cpp_create_module' {
            $parentPath = [string]$payload.projectPath
            $name = [string]$payload.name
            if ([string]::IsNullOrWhiteSpace($parentPath)) { throw 'projectPath is required' }
            if ([string]::IsNullOrWhiteSpace($name)) { throw 'name is required' }
            Assert-NotSafetyPath -Path $parentPath
            $template = if ($payload.PSObject.Properties.Name -contains 'template' -and -not [string]::IsNullOrWhiteSpace([string]$payload.template)) { [string]$payload.template } else { 'TwinCAT Class Wizard' }
            $before = if ($payload.PSObject.Properties.Name -contains 'before' -and $payload.before) { [string]$payload.before } else { '' }

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $proj = (Get-TreeItem -SysManager $sysManager -TreePath $parentPath).Value
            $child = $proj.CreateChild($name, 0, $before, $template)
            Assert-WellFormedChild -Parent $proj -Child $child -RequestedName $name -SubType 0 -ParentPath $parentPath

            Write-JsonResult @{
                ok = $true
                data = @{
                    parentPath = $parentPath
                    child = Convert-TreeItem -TreeItem $child
                }
            }
            exit 0
        }

        'twincat_cpp_open' {
            $file = [string]$payload.file
            if ([string]::IsNullOrWhiteSpace($file)) { throw 'file is required' }
            if (-not (Test-Path -LiteralPath $file)) { throw "C++ project file not found: $file" }
            $subType = if ($null -ne $payload.subType) { [int]$payload.subType } else { 0 }
            if ($subType -notin 0, 1, 2) { throw 'subType must be 0, 1, or 2' }
            $before = if ($payload.PSObject.Properties.Name -contains 'before' -and $payload.before) { [string]$payload.before } else { '' }

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $cpp = (Get-TreeItem -SysManager $sysManager -TreePath 'TIXC').Value
            # NOTE: name MUST be '' — C++ projects cannot be renamed on open, so
            # Assert-WellFormedChild (which requires a matching requested name) is
            # intentionally bypassed; a manual non-null/non-blank check replaces it.
            $child = $cpp.CreateChild('', $subType, $before, $file)
            if ($null -eq $child) { throw 'CreateChild returned null opening C++ project' }
            $actualName = Get-SafeValue { [string]$child.Name }
            if ([string]::IsNullOrWhiteSpace([string]$actualName)) {
                throw "open produced a ghost (blank name) - check the .vcxproj/.tczip path and subType ($file, subType=$subType)"
            }

            Write-JsonResult @{
                ok = $true
                data = @{
                    parentPath = 'TIXC'
                    file = $file
                    subType = $subType
                    child = Convert-TreeItem -TreeItem $child
                }
            }
            exit 0
        }

        'twincat_cpp_consume_xml' {
            $projectPath = [string]$payload.projectPath
            if ([string]::IsNullOrWhiteSpace($projectPath)) { throw 'projectPath is required' }
            Assert-NotSafetyPath -Path $projectPath

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $xml = '<TreeItem><CppProjectDef><StartTmcCodeGenerator><Active>true</Active></StartTmcCodeGenerator></CppProjectDef></TreeItem>'
            $null = Set-TreeItemXml -SysManager $sysManager -TargetPath $projectPath -Xml $xml

            Write-JsonResult @{
                ok = $true
                data = @{
                    projectPath = $projectPath
                    tmcCodeGenerated = $true
                }
            }
            exit 0
        }

        'twincat_cpp_set_props' {
            $projectPath = [string]$payload.projectPath
            if ([string]::IsNullOrWhiteSpace($projectPath)) { throw 'projectPath is required' }
            Assert-NotSafetyPath -Path $projectPath

            $inner = ''
            if ($payload.PSObject.Properties.Name -contains 'bootProjectEncryption' -and -not [string]::IsNullOrWhiteSpace([string]$payload.bootProjectEncryption)) {
                $v = [string]$payload.bootProjectEncryption
                if ($v -notin 'None', 'Target') { throw 'bootProjectEncryption must be None or Target' }
                $inner += "<BootProjectEncryption>$v</BootProjectEncryption>"
            }
            if ($payload.PSObject.Properties.Name -contains 'saveProjectSources' -and $null -ne $payload.saveProjectSources) {
                $b = ([bool]$payload.saveProjectSources).ToString().ToLower()
                $inner += "<TargetArchiveSettings><SaveProjectSources>$b</SaveProjectSources></TargetArchiveSettings><FileArchiveSettings><SaveProjectSources>$b</SaveProjectSources></FileArchiveSettings>"
            }
            if ([string]::IsNullOrEmpty($inner)) {
                throw 'set_props needs at least one of bootProjectEncryption / saveProjectSources'
            }

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $xml = "<TreeItem><CppProjectDef>$inner</CppProjectDef></TreeItem>"
            $null = Set-TreeItemXml -SysManager $sysManager -TargetPath $projectPath -Xml $xml

            Write-JsonResult @{
                ok = $true
                data = @{
                    projectPath = $projectPath
                    propsApplied = $true
                }
            }
            exit 0
        }

        'twincat_cpp_build_project' {
            $projectName = [string]$payload.projectName
            if ([string]::IsNullOrWhiteSpace($projectName)) { throw 'projectName is required' }
            $config = if ($payload.PSObject.Properties.Name -contains 'config' -and -not [string]::IsNullOrWhiteSpace([string]$payload.config)) { [string]$payload.config } else { 'Release|TwinCAT RT (x64)' }
            $wait = if ($null -ne $payload.waitForFinish) { [bool]$payload.waitForFinish } else { $true }
            $timeoutMs = if ($null -ne $payload.timeoutMs) { [int]$payload.timeoutMs } else { 1800000 }

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $solution = Get-SolutionInfo -Dte $dte
            if (-not $solution.isOpen) { throw 'No solution is open in XAE' }

            # BuildProject wants the project UniqueName, not the display name; resolve
            # it by scanning Solution.Projects.
            $unique = $null
            $projects = $dte.Solution.Projects
            for ($i = 1; $i -le $projects.Count; $i++) {
                $proj = $projects.Item($i)
                if ($null -eq $proj) { continue }
                $pName = Get-SafeValue { [string]$proj.Name }
                $pUnique = Get-SafeValue { [string]$proj.UniqueName }
                if ($pName -eq $projectName -or $pUnique -eq $projectName) {
                    $unique = if (-not [string]::IsNullOrWhiteSpace([string]$pUnique)) { [string]$pUnique } else { [string]$pName }
                    break
                }
            }
            if ([string]::IsNullOrWhiteSpace($unique)) { throw "C++ project not found in solution: $projectName" }

            $solutionBuild = $dte.Solution.SolutionBuild
            $solutionBuild.BuildProject($config, $unique, $wait)

            if ($wait) {
                $build = Wait-ForBuildFinish -SolutionBuild $solutionBuild -TimeoutMs $timeoutMs
            } else {
                $build = @{
                    buildState = [int]$solutionBuild.BuildState
                    lastBuildInfo = Get-SafeValue { [int]$solutionBuild.LastBuildInfo }
                }
            }

            Write-JsonResult @{
                ok = $true
                data = @{
                    projectName = $projectName
                    uniqueName = $unique
                    config = $config
                    waited = $wait
                    build = $build
                }
            }
            exit 0
        }

        'twincat_cpp_publish' {
            # Confirm token is enforced in index.js before bridgeCall (matching
            # twincat_activate_configuration, which receives confirm but does not
            # re-verify here).
            $projectPath = [string]$payload.projectPath
            if ([string]::IsNullOrWhiteSpace($projectPath)) { throw 'projectPath is required' }
            Assert-NotSafetyPath -Path $projectPath

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $xml = '<TreeItem><CppProjectDef><PublishModules><Active>true</Active></PublishModules></CppProjectDef></TreeItem>'
            $null = Set-TreeItemXml -SysManager $sysManager -TargetPath $projectPath -Xml $xml

            Write-JsonResult @{
                ok = $true
                data = @{
                    projectPath = $projectPath
                    published = $true
                    note = 'Modules built for all platforms and exported. Does not activate/restart the runtime.'
                }
            }
            exit 0
        }

        'measurement_scope_create' {
            $name = [string]$payload.name
            if ([string]::IsNullOrWhiteSpace($name)) { throw 'name is required' }
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $solution = $dte.Solution
            if ($null -eq $solution -or -not [bool]$solution.IsOpen) { throw 'No solution is open' }

            $destination = if ($payload.destination) { [string]$payload.destination } else { [System.IO.Path]::GetDirectoryName([string]$solution.FullName) }

            $template = if ($payload.template) { [string]$payload.template } else { Get-ScopeTemplatePath }
            if ([string]::IsNullOrWhiteSpace($template)) {
                throw 'Scope project template not found — TE130X Scope View tooling may not be installed. Pass template explicitly (a full .tcmproj path).'
            }
            if (-not (Test-Path -LiteralPath $template)) { throw "Scope template not found: $template" }

            $proj = $solution.AddFromTemplate($template, $destination, $name)
            Write-JsonResult @{
                ok = $true
                data = @{
                    created = $true
                    name = $name
                    kind = 'scope'
                    projectFullName = (Get-SafeValue { [string]$proj.FullName })
                }
            }
            exit 0
        }

        'measurement_scope_add_child' {
            $project = [string]$payload.project
            if ([string]::IsNullOrWhiteSpace($project)) { throw 'project is required' }
            $name = if ($payload.PSObject.Properties.Name -contains 'name' -and $null -ne $payload.name) { [string]$payload.name } else { '' }
            $elementType = if ($null -ne $payload.elementType) { [int]$payload.elementType } else { 0 }
            $parentPath = if ($payload.parentPath) { [string]$payload.parentPath } else { '' }

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            if (-not (Ensure-MeasurementScopeHelper)) {
                throw 'TE130X Scope automation assembly not found (TwinCAT.Measurement.AutomationInterface.dll). Scope tooling is not installed.'
            }
            $obj = Get-ScopeProjectObject -Dte $dte -ProjectName $project
            if (-not [Te1000MeasurementHelper]::Is($obj)) {
                throw "Project '$project' is not a Measurement/Scope project (object is not IMeasurementScope)."
            }
            $parent = Resolve-ScopeElement -Root $obj -ElementPath $parentPath
            $child = $null
            $rc = [Te1000MeasurementHelper]::CreateChild($parent, [ref]$child, $name, $elementType)

            Write-JsonResult @{
                ok = $true
                data = @{
                    project = $project
                    parentPath = $parentPath
                    created = $true
                    name = $name
                    elementType = $elementType
                    rc = $rc
                }
            }
            exit 0
        }

        'measurement_scope_rename' {
            $project = [string]$payload.project
            $path = [string]$payload.path
            $newName = [string]$payload.newName
            if ([string]::IsNullOrWhiteSpace($project)) { throw 'project is required' }
            if ([string]::IsNullOrWhiteSpace($path)) { throw 'path is required' }
            if ([string]::IsNullOrWhiteSpace($newName)) { throw 'newName is required' }

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            if (-not (Ensure-MeasurementScopeHelper)) {
                throw 'TE130X Scope automation assembly not found (TwinCAT.Measurement.AutomationInterface.dll). Scope tooling is not installed.'
            }
            $obj = Get-ScopeProjectObject -Dte $dte -ProjectName $project
            if (-not [Te1000MeasurementHelper]::Is($obj)) {
                throw "Project '$project' is not a Measurement/Scope project (object is not IMeasurementScope)."
            }
            $element = Resolve-ScopeElement -Root $obj -ElementPath $path
            $rc = [Te1000MeasurementHelper]::ChangeName($element, $newName)

            Write-JsonResult @{
                ok = $true
                data = @{ project = $project; path = $path; newName = $newName; rc = $rc }
            }
            exit 0
        }

        'measurement_scope_record' {
            $project = [string]$payload.project
            $state = [string]$payload.state
            if ([string]::IsNullOrWhiteSpace($project)) { throw 'project is required' }
            if ($state -ne 'start' -and $state -ne 'stop') { throw "state must be 'start' or 'stop'" }

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            if (-not (Ensure-MeasurementScopeHelper)) {
                throw 'TE130X Scope automation assembly not found (TwinCAT.Measurement.AutomationInterface.dll). Scope tooling is not installed.'
            }
            $obj = Get-ScopeProjectObject -Dte $dte -ProjectName $project
            if (-not [Te1000MeasurementHelper]::Is($obj)) {
                throw "Project '$project' is not a Measurement/Scope project (object is not IMeasurementScope)."
            }
            $rc = if ($state -eq 'start') { [Te1000MeasurementHelper]::StartRecord($obj) } else { [Te1000MeasurementHelper]::StopRecord($obj) }

            Write-JsonResult @{
                ok = $true
                data = @{ project = $project; state = $state; rc = $rc }
            }
            exit 0
        }

        'measurement_analytics_create' {
            $name = [string]$payload.name
            if ([string]::IsNullOrWhiteSpace($name)) { throw 'name is required' }
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $solution = $dte.Solution
            if ($null -eq $solution -or -not [bool]$solution.IsOpen) { throw 'No solution is open' }

            $destination = if ($payload.destination) { [string]$payload.destination } else { [System.IO.Path]::GetDirectoryName([string]$solution.FullName) }

            $template = if ($payload.template) { [string]$payload.template } else { Get-AnalyticsTemplatePath }
            if ([string]::IsNullOrWhiteSpace($template)) {
                throw 'Analytics project template not found — pass template explicitly (TwinCAT Analytics tooling may not be installed).'
            }
            if (-not (Test-Path -LiteralPath $template)) { throw "Analytics template not found: $template" }

            $proj = $solution.AddFromTemplate($template, $destination, $name)
            Write-JsonResult @{
                ok = $true
                data = @{
                    created = $true
                    name = $name
                    kind = 'analytics'
                    projectFullName = (Get-SafeValue { [string]$proj.FullName })
                }
            }
            exit 0
        }

        'analytics_logger_create' {
            $name = [string]$payload.name
            if ([string]::IsNullOrWhiteSpace($name)) { throw 'name is required' }
            $before = if ($payload.before) { [string]$payload.before } else { '' }

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $tian = (Get-TreeItem -SysManager $sysManager -TreePath 'TIAN').Value
            # subType 1 = DataLogger (infosys 12562942987).
            $child = $tian.CreateChild($name, 1, $before, $null)
            Assert-WellFormedChild -Parent $tian -Child $child -RequestedName $name -SubType 1 -ParentPath 'TIAN'

            Write-JsonResult @{
                ok = $true
                data = @{ parentPath = 'TIAN'; child = Convert-TreeItem -TreeItem $child }
            }
            exit 0
        }

        'analytics_stream_create' {
            $name = [string]$payload.name
            if ([string]::IsNullOrWhiteSpace($name)) { throw 'name is required' }
            $before = if ($payload.before) { [string]$payload.before } else { '' }

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $tian = (Get-TreeItem -SysManager $sysManager -TreePath 'TIAN').Value
            # subType 0 = StreamHelper (infosys 12563004555).
            $child = $tian.CreateChild($name, 0, $before, $null)
            Assert-WellFormedChild -Parent $tian -Child $child -RequestedName $name -SubType 0 -ParentPath 'TIAN'

            Write-JsonResult @{
                ok = $true
                data = @{ parentPath = 'TIAN'; child = Convert-TreeItem -TreeItem $child }
            }
            exit 0
        }

        'analytics_logger_delete' {
            $name = [string]$payload.name
            if ([string]::IsNullOrWhiteSpace($name)) { throw 'name is required' }
            $dryRun = [bool]$payload.dryRun

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $tian = (Get-TreeItem -SysManager $sysManager -TreePath 'TIAN').Value

            if ($dryRun) {
                $exists = $false
                $count = Get-TreeItemChildCount -TreeItem $tian
                for ($i = 1; $i -le $count; $i++) {
                    $c = (Get-TreeItemChild -TreeItem $tian -Index $i).Value
                    if ($null -eq $c) { continue }
                    $cn = Get-SafeValue { [string]$c.Name }
                    if ($cn -eq $name) { $exists = $true; break }
                }
                Write-JsonResult @{ ok = $true; data = @{ parentPath = 'TIAN'; name = $name; exists = $exists; deleted = $false } }
                exit 0
            }

            $tian.DeleteChild($name)
            Write-JsonResult @{ ok = $true; data = @{ parentPath = 'TIAN'; name = $name; deleted = $true } }
            exit 0
        }

        'analytics_stream_delete' {
            $name = [string]$payload.name
            if ([string]::IsNullOrWhiteSpace($name)) { throw 'name is required' }
            $deleteName = $name + '_Obj1 (StreamHelper)'
            $dryRun = [bool]$payload.dryRun

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $tian = (Get-TreeItem -SysManager $sysManager -TreePath 'TIAN').Value

            if ($dryRun) {
                $exists = $false
                $count = Get-TreeItemChildCount -TreeItem $tian
                for ($i = 1; $i -le $count; $i++) {
                    $c = (Get-TreeItemChild -TreeItem $tian -Index $i).Value
                    if ($null -eq $c) { continue }
                    $cn = Get-SafeValue { [string]$c.Name }
                    if ($cn -eq $deleteName) { $exists = $true; break }
                }
                Write-JsonResult @{ ok = $true; data = @{ parentPath = 'TIAN'; name = $name; deleteName = $deleteName; exists = $exists; deleted = $false } }
                exit 0
            }

            $tian.DeleteChild($deleteName)
            Write-JsonResult @{ ok = $true; data = @{ parentPath = 'TIAN'; name = $name; deleteName = $deleteName; deleted = $true } }
            exit 0
        }

        'twincat_license_list_devices' {
            # Read-only: discover available dongle license devices under TIRC^License
            # via ProduceXml. No ConsumeXml. Requires TC3.1 >= 4022.4; on older
            # targets the License node has no device support and the blob is empty.
            $rawFlag = ($payload.PSObject.Properties.Name -contains 'raw') -and [bool]$payload.raw

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $license = (Get-TreeItem -SysManager $sysManager -TreePath 'TIRC^License').Value
            $xmlText = $license.ProduceXml()

            $devices = @()
            try {
                [xml]$doc = $xmlText
                foreach ($d in $doc.SelectNodes('//LicenseDevice')) {
                    $devices += @{
                        name = [string]$d.Name
                        pathName = [string]$d.PathName
                        typeName = [string]$d.TypeName
                        objectId = [string]$d.ObjectID
                    }
                }
            } catch {
                $devices = @()
            }

            $data = @{ treePath = 'TIRC^License'; devices = $devices }
            if ($rawFlag) { $data.xml = Strip-TreeImage $xmlText }

            Write-JsonResult @{ ok = $true; data = $data }
            exit 0
        }

        'twincat_license_add_device' {
            # Offline config edit: CreateChild a license-device node under
            # TIRC^License bound to a dongle that already exists in the I/O tree.
            # vInfo = the device display-name OR ObjectID string from the list
            # action. Not a runtime write -> not confirm-gated (mirrors create).
            $name = [string]$payload.name
            $device = [string]$payload.device
            if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($device)) {
                throw 'name and device are required'
            }

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $license = (Get-TreeItem -SysManager $sysManager -TreePath 'TIRC^License').Value
            $child = $license.CreateChild($name, 0, '', $device)

            # Validate the created child; a ghost (blank/mismatched name, wrong
            # parent) throws with best-effort cleanup instead of a false success.
            Assert-WellFormedChild -Parent $license -Child $child -RequestedName $name -SubType 0 -ParentPath 'TIRC^License'

            Write-JsonResult @{
                ok = $true
                data = @{
                    parentPath = 'TIRC^License'
                    child = Convert-TreeItem -TreeItem $child
                }
            }
            exit 0
        }

        'twincat_license_activate_response' {
            # License-activation state change (GUARDED in index.js before the
            # bridge spawns). ConsumeXml the ActivateResponseFile command on the
            # TIRC^License node. Set-TreeItemXml surfaces GetLastXmlError; the
            # outer try/catch reports the HRESULT (e.g. NTE_BAD_SIGNATURE).
            $path = [string]$payload.path
            if ([string]::IsNullOrWhiteSpace($path)) {
                throw 'path is required'
            }
            $oemGuid = if ($payload.PSObject.Properties.Name -contains 'oemGuid' -and -not [string]::IsNullOrWhiteSpace([string]$payload.oemGuid)) { [string]$payload.oemGuid } else { '0' }

            # Defense-in-depth: re-check the confirm token even though index.js gates it.
            if (([string]$payload.confirm) -ne 'ALLOW_LICENSE_ACTIVATE') {
                throw 'Blocked. license activate_response requires confirm="ALLOW_LICENSE_ACTIVATE".'
            }

            $escPath = $path.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
            $escGuid = $oemGuid.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
            $xml = "<TreeItem><ItemName>License</ItemName><PathName>TIRC^License</PathName><ItemType>59</ItemType><LicenseDef><Commands><ActivateResponseFile><Path>$escPath</Path><OemGuid>$escGuid</OemGuid></ActivateResponseFile></Commands></LicenseDef></TreeItem>"

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $item = Set-TreeItemXml -SysManager $sysManager -TargetPath 'TIRC^License' -Xml $xml

            Write-JsonResult @{
                ok = $true
                data = @{
                    treePath = 'TIRC^License'
                    path = $path
                    activated = $true
                }
            }
            exit 0
        }

        # --- tc_variant: project variant management (OFFLINE config only) ------
        # ProjectVariantConfig / CurrentProjectVariant live on iTcSysManager14
        # (TCatSysManagerLib >= 3.3.0.0); PvDisable / Disabled-for-variants on
        # ITcSmTreeItem9. All accessed late-bound on the __ComObject (no CLR QI).
        # Every verb edits the open solution's variant definition / active variant
        # / per-item disable flag — NONE activate/download/touch the runtime, so no
        # confirm token. The per-item disable verb refuses TISC (safety) paths.
        'twincat_get_variant_config' {
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $xml = Get-SafeValue { [string]$sysManager.ProjectVariantConfig }
            Write-JsonResult @{
                ok = $true
                data = @{ xml = $xml }
            }
            exit 0
        }

        'twincat_get_current_variant' {
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $cur = Get-SafeValue { [string]$sysManager.CurrentProjectVariant }
            Write-JsonResult @{
                ok = $true
                data = @{ current = $cur }
            }
            exit 0
        }

        'twincat_set_variant_config' {
            $xml = [string]$payload.xml
            if ([string]::IsNullOrWhiteSpace($xml)) {
                throw 'xml is required'
            }
            $save = ($payload.PSObject.Properties.Name -contains 'save') -and [bool]$payload.save

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            try {
                $sysManager.ProjectVariantConfig = $xml
            } catch {
                throw "Setting ProjectVariantConfig failed: $($_.Exception.Message)"
            }
            if ($save) { Save-Solution -Dte $dte }
            $readback = Get-SafeValue { [string]$sysManager.ProjectVariantConfig }

            Write-JsonResult @{
                ok = $true
                data = @{
                    defined = $true
                    xml = $readback
                    saved = $save
                }
            }
            exit 0
        }

        'twincat_set_current_variant' {
            $variant = [string]$payload.variant
            if ([string]::IsNullOrWhiteSpace($variant)) {
                throw 'variant is required'
            }
            $save = ($payload.PSObject.Properties.Name -contains 'save') -and [bool]$payload.save

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $sysManager.CurrentProjectVariant = $variant
            if ($save) { Save-Solution -Dte $dte }
            $cur = [string]$sysManager.CurrentProjectVariant
            if ($cur -ne $variant) {
                throw "CurrentProjectVariant is '$cur' after setting '$variant' - variant/group may not exist in the variant config"
            }

            Write-JsonResult @{
                ok = $true
                data = @{
                    current = $cur
                    saved = $save
                }
            }
            exit 0
        }

        'twincat_set_item_variant_disable' {
            $treePath = [string]$payload.treePath
            if ([string]::IsNullOrWhiteSpace($treePath)) {
                throw 'treePath is required'
            }
            # Safety policy: never address the TISC safety project.
            if ($treePath -match '^\s*TISC(\^|$)') {
                throw "Refused: variant operations on the safety project (TISC) are disallowed by policy."
            }
            # Default true; index.js sends disable:false for the enable action.
            $disable = -not (($payload.PSObject.Properties.Name -contains 'disable') -and ($payload.disable -eq $false))
            $save = ($payload.PSObject.Properties.Name -contains 'save') -and [bool]$payload.save

            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $item = (Get-TreeItem -SysManager $sysManager -TreePath $treePath).Value
            $item.PvDisable = $disable
            $item.Disabled = if ($disable) { 1 } else { 0 }
            if ($save) { Save-Solution -Dte $dte }
            $state = [int](Get-SafeValue { [int]$item.Disabled })
            $pv = [bool](Get-SafeValue { [bool]$item.PvDisable })

            Write-JsonResult @{
                ok = $true
                data = @{
                    path = $treePath
                    pvDisable = $pv
                    disabled = $state
                    saved = $save
                }
            }
            exit 0
        }

        default {
            throw "Unsupported action: $Action"
        }
    }
} catch {
    $message = $_.Exception.Message
    $code = Get-ErrorCode $_.Exception
    $location = ''
    try {
        $location = [string]$_.InvocationInfo.PositionMessage
    } catch {
    }
    if (-not [string]::IsNullOrWhiteSpace($location)) {
        Fail("$message [$code]`n$location")
    }
    Fail("$message [$code]")
}
