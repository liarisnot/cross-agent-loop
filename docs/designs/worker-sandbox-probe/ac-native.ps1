$ErrorActionPreference = "Stop"
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
