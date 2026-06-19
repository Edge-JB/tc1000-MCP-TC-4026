# plc-session.ps1 — detect/drive the XAE PLC online session via UI Automation.
#
# The TE1000/DTE command surface on the 64-bit TcXaeShell cannot log the PLC out
# (the Logout command never reports IsAvailable=true because Solution-Explorer
# selection context is unreachable, and it has no key binding). But the IDE's
# Login/Logout toolbar buttons ARE reachable through UI Automation:
#   - logged in  => "Logout" button Enabled, "Login" button Disabled
#   - logged out => "Login"  button Enabled, "Logout" button Disabled
# So we read those button states to detect session state, and invoke the Logout
# button to log out. We deliberately NEVER invoke Login (no auto-login).
#
# Modes:
#   status  (default) — report { loggedIn, logoutEnabled, loginEnabled }
#   logout            — invoke Logout if logged in; report before/after state

param(
    [ValidateSet('status', 'logout')]
    [string]$Mode = 'status',
    [string]$ProcessName = 'TcXaeShell'
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

$AE = [System.Windows.Automation.AutomationElement]
$TS = [System.Windows.Automation.TreeScope]
$INV = [System.Windows.Automation.InvokePattern]

function Write-Json($obj) { $obj | ConvertTo-Json -Compress }

function Get-MainWindow {
    $proc = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $proc) { return $null }
    $cond = New-Object System.Windows.Automation.PropertyCondition($AE::ProcessIdProperty, $proc.Id)
    return [System.Windows.Automation.AutomationElement]::RootElement.FindFirst($TS::Children, $cond)
}

function Find-Button($win, [string]$name) {
    if (-not $win) { return $null }
    $cond = New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, $name)
    return $win.FindFirst($TS::Descendants, $cond)
}

function Get-State {
    $win = Get-MainWindow
    if (-not $win) { return [ordered]@{ ok = $false; error = "no $ProcessName window via UIA" } }
    $logout = Find-Button $win 'Logout'
    $login = Find-Button $win 'Login'
    $logoutEn = $false; $loginEn = $false
    if ($logout) { try { $logoutEn = [bool]$logout.Current.IsEnabled } catch {} }
    if ($login) { try { $loginEn = [bool]$login.Current.IsEnabled } catch {} }
    # Logged in is defined by the Logout button being actionable.
    return [ordered]@{
        ok            = $true
        found         = ($null -ne $logout -or $null -ne $login)
        loggedIn      = $logoutEn
        logoutEnabled = $logoutEn
        loginEnabled  = $loginEn
    }
}

if ($Mode -eq 'status') {
    Write-Json (Get-State)
    return
}

# logout
$before = Get-State
if (-not $before.ok) { Write-Json $before; return }
if (-not $before.loggedIn) {
    Write-Json ([ordered]@{ ok = $true; action = 'logout'; changed = $false; loggedIn = $false; note = 'already logged out' })
    return
}

$win = Get-MainWindow
$logout = Find-Button $win 'Logout'
$invoked = $false
if ($logout) {
    try { $logout.GetCurrentPattern($INV::Pattern).Invoke(); $invoked = $true } catch {}
}

# Let the IDE process the logout (it may also load any deferred external edits).
$deadline = (Get-Date).AddSeconds(8)
$after = $null
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
    $after = Get-State
    if ($after.ok -and -not $after.loggedIn) { break }
}
if (-not $after) { $after = Get-State }

Write-Json ([ordered]@{
    ok       = $true
    action   = 'logout'
    invoked  = $invoked
    changed  = ($before.loggedIn -and -not $after.loggedIn)
    loggedIn = $after.loggedIn
})
