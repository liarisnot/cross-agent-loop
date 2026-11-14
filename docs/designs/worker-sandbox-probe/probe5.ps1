# AppContainer feasibility probe (throwaway). Run with pwsh, not elevated.
param([switch]$SkipCursorRun)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$work = 'D:\xagent-ac-probe'
Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $work | Out-Null

Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class AC {
  [DllImport("userenv.dll", CharSet=CharSet.Unicode)] public static extern int CreateAppContainerProfile(string n, string d, string desc, IntPtr caps, int cnt, out IntPtr sid);
  [DllImport("userenv.dll", CharSet=CharSet.Unicode)] public static extern int DeriveAppContainerSidFromAppContainerName(string n, out IntPtr sid);
  [DllImport("userenv.dll", CharSet=CharSet.Unicode)] public static extern int DeleteAppContainerProfile(string n);
  [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern bool ConvertSidToStringSid(IntPtr sid, out string s);
  [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern bool ConvertStringSidToSid(string s, out IntPtr sid);
  [StructLayout(LayoutKind.Sequential)] public struct SID_AND_ATTRIBUTES { public IntPtr Sid; public uint Attributes; }
  [StructLayout(LayoutKind.Sequential)] public struct SECURITY_CAPABILITIES { public IntPtr AppContainerSid; public IntPtr Capabilities; public uint CapabilityCount; public uint Reserved; }
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct STARTUPINFO { public int cb; public string lpReserved; public string lpDesktop; public string lpTitle; public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags; public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError; }
  [StructLayout(LayoutKind.Sequential)] public struct STARTUPINFOEX { public STARTUPINFO StartupInfo; public IntPtr lpAttributeList; }
  [StructLayout(LayoutKind.Sequential)] public struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool InitializeProcThreadAttributeList(IntPtr l, int c, int f, ref IntPtr s);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool UpdateProcThreadAttribute(IntPtr l, uint f, IntPtr a, IntPtr v, IntPtr s, IntPtr p, IntPtr r);
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)] static extern bool CreateProcessW(string app, System.Text.StringBuilder cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string cwd, ref STARTUPINFOEX si, out PROCESS_INFORMATION pi);
  [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr h, uint ms);
  [DllImport("kernel32.dll")] static extern bool GetExitCodeProcess(IntPtr h, out uint c);
  [DllImport("kernel32.dll")] static extern bool TerminateProcess(IntPtr h, uint c);

  public static string GetSid(string name) {
    IntPtr sid; int hr = CreateAppContainerProfile(name, name, "xagent probe", IntPtr.Zero, 0, out sid);
    if (hr != 0) { hr = DeriveAppContainerSidFromAppContainerName(name, out sid); if (hr != 0) throw new Exception("derive sid hr=" + hr); }
    string s; ConvertSidToStringSid(sid, out s); return s;
  }
  public static int Run(string containerSid, string[] capSids, string cmdline, string cwd, uint timeoutMs) {
    IntPtr acSid; ConvertStringSidToSid(containerSid, out acSid);
    int n = capSids.Length; int sz = Marshal.SizeOf(typeof(SID_AND_ATTRIBUTES));
    IntPtr caps = Marshal.AllocHGlobal(Math.Max(1, n) * sz);
    for (int i = 0; i < n; i++) { IntPtr cs; ConvertStringSidToSid(capSids[i], out cs); var sa = new SID_AND_ATTRIBUTES { Sid = cs, Attributes = 4 }; Marshal.StructureToPtr(sa, caps + i * sz, false); }
    var sc = new SECURITY_CAPABILITIES { AppContainerSid = acSid, Capabilities = n > 0 ? caps : IntPtr.Zero, CapabilityCount = (uint)n };
    IntPtr scPtr = Marshal.AllocHGlobal(Marshal.SizeOf(sc)); Marshal.StructureToPtr(sc, scPtr, false);
    IntPtr size = IntPtr.Zero; InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref size);
    IntPtr list = Marshal.AllocHGlobal(size);
    if (!InitializeProcThreadAttributeList(list, 1, 0, ref size)) throw new Exception("init attr " + Marshal.GetLastWin32Error());
    if (!UpdateProcThreadAttribute(list, 0, (IntPtr)0x00020009, scPtr, (IntPtr)Marshal.SizeOf(sc), IntPtr.Zero, IntPtr.Zero)) throw new Exception("update attr " + Marshal.GetLastWin32Error());
    var si = new STARTUPINFOEX(); si.StartupInfo.cb = Marshal.SizeOf(typeof(STARTUPINFOEX)); si.lpAttributeList = list;
    PROCESS_INFORMATION pi;
    if (!CreateProcessW(null, new System.Text.StringBuilder(cmdline), IntPtr.Zero, IntPtr.Zero, false, 0x00080000 | 0x08000000, IntPtr.Zero, cwd, ref si, out pi)) throw new Exception("CreateProcess " + Marshal.GetLastWin32Error());
    if (WaitForSingleObject(pi.hProcess, timeoutMs) != 0) { TerminateProcess(pi.hProcess, 99); return -2; }
    uint code; GetExitCodeProcess(pi.hProcess, out code); return (int)code;
  }
}
'@

$name = 'xagent.probe'
$sid = [AC]::GetSid($name)
"container sid: $sid"

# canaries
$secret = 'CANARY-' + [guid]::NewGuid().ToString('N')
$profCanary = Join-Path $env:USERPROFILE 'xagent-probe-canary.txt'
$dDir = 'D:\xagent-probe-canary'; New-Item -ItemType Directory -Force $dDir | Out-Null
$dCanary = Join-Path $dDir 'canary.txt'
Set-Content $profCanary $secret; Set-Content $dCanary $secret

# fake profile inside the granted folder, with copies of Cursor config and login
$fakeHome = Join-Path $work 'home'; $fakeApp = Join-Path $fakeHome 'AppData\Roaming'; $fakeLocal = Join-Path $fakeHome 'AppData\Local'
New-Item -ItemType Directory -Force (Join-Path $fakeHome '.cursor'), (Join-Path $fakeApp 'Cursor'), $fakeLocal, (Join-Path $work 'tmp') | Out-Null
Copy-Item "$env:USERPROFILE\.cursor\cli-config.json" (Join-Path $fakeHome '.cursor\')
Copy-Item "$env:APPDATA\Cursor\auth.json" (Join-Path $fakeApp 'Cursor\')

$pester = (Get-Module Pester -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1).ModuleBase
$cursorDir = Join-Path $env:LOCALAPPDATA 'cursor-agent'
$grants = @($pester, $cursorDir)
icacls $work /grant "*${sid}:(OI)(CI)F" /T /Q | Out-Null
foreach ($g in $grants) { icacls $g /grant "*${sid}:(OI)(CI)RX" /T /Q | Out-Null }

subst T: $cursorDir
@{ secret = $secret; profCanary = $profCanary; dCanary = $dCanary; pester = $pester; cursorDir = 'T:\'
   realProfile = $env:USERPROFILE; realTemp = $env:TEMP; fakeHome = $fakeHome; fakeApp = $fakeApp; fakeLocal = $fakeLocal
   skipCursorRun = [bool]$SkipCursorRun } | ConvertTo-Json | Set-Content (Join-Path $work 'probe-input.json')
Copy-Item (Join-Path $here 'inner5.ps1') (Join-Path $work 'inner.ps1')
Copy-Item -Recurse (Join-Path $here 'nodelocal') $work
subst W: $work

try {
    $pwsh = 'C:\Program Files\PowerShell\7\pwsh.exe'
    $cmd = "`"$pwsh`" -NoProfile -ExecutionPolicy Bypass -File D:\xagent-ac-probe\inner.ps1"
    $code = [AC]::Run($sid, @('S-1-15-3-1'), $cmd, $work, 600000)
    "inner exit code: $code"
    $res = Join-Path $work 'results.txt'
    if (Test-Path $res) { Get-Content $res } else { 'NO RESULTS FILE (inner script never wrote)' }
    $all = Get-ChildItem $work -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'probe-input.json' } | Select-String -SimpleMatch $secret -List
    "canary found in container output files: $(@($all).Count)"
} finally {
    subst T: /D; subst W: /D
    foreach ($g in $grants) { icacls $g /remove "*$sid" /T /Q | Out-Null }
    Remove-Item -Force $profCanary -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $dDir -ErrorAction SilentlyContinue
    [AC]::DeleteAppContainerProfile($name) | Out-Null
    Copy-Item (Join-Path $work 'results.txt') (Join-Path $here 'results5.txt') -ErrorAction SilentlyContinue
    Copy-Item (Join-Path $work 'cursor-run.txt') (Join-Path $here 'cursor-run5.txt') -ErrorAction SilentlyContinue
    Copy-Item (Join-Path $work 'trace-*.log') $here -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
    'cleanup done'
}
