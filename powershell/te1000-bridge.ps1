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
        ((ITcPlcIECProject)iecProject).PlcOpenImport(file, (PlcImportOptions)options, selection, folderStructure);
    }
    public static void SaveAsLibrary(object iecProject, string file, bool install) {
        ((ITcPlcIECProject)iecProject).SaveAsLibrary(file, install);
    }
}
'@
    return $null -ne ('Te1000PlcProjectHelper' -as [type])
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
            # NATIVE EtherCAT IO creator (createIO). For each requested module the
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

        'plc_project_check' {
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
                throw 'TCatSysManagerLib.dll could not be loaded; the typed ITcPlcIECProject2 cast is required for plc_project_check on this shell'
            }
            $valid = $null
            try {
                $valid = [Te1000PlcProjectHelper]::CheckAll($item)
            } catch {
                throw "node '$treePath' does not implement ITcPlcIECProject2 (use the nested project instance node, e.g. TIPC^<name>^<name> Project): $($_.Exception.Message)"
            }

            Write-JsonResult @{
                ok = $true
                data = @{
                    treePath = $treePath
                    allObjectsValid = [bool]$valid
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

        'plc_project_link_task' {
            $treePath = [string]$payload.treePath
            $taskPath = [string]$payload.taskPath
            if ([string]::IsNullOrWhiteSpace($treePath)) {
                throw 'treePath is required'
            }
            if ([string]::IsNullOrWhiteSpace($taskPath)) {
                throw 'taskPath is required'
            }
            $dte = Get-Dte -ProgId $progId -Mode $mode -Visible $true
            $sysManager = (Get-SysManager -Dte $dte).Value
            $item = (Get-TreeItem -SysManager $sysManager -TreePath $treePath).Value
            if (-not (Ensure-TcPlcProjectHelper)) {
                throw 'TCatSysManagerLib.dll could not be loaded; the typed ITcPlcTaskReference cast is required for plc_project_link_task on this shell'
            }
            $linked = $null
            try {
                $linked = [Te1000PlcProjectHelper]::SetLinkedTask($item, $taskPath)
            } catch {
                throw "node '$treePath' does not implement ITcPlcTaskReference (treePath must be the PlcTask reference node under the project instance): $($_.Exception.Message)"
            }

            Write-JsonResult @{
                ok = $true
                data = @{
                    treePath = $treePath
                    linkedTask = $linked
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
