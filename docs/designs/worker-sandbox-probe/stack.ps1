# Dump native stacks of every thread of a process (export-level symbols via dbghelp).
param([int]$ProcessId, [int]$MaxFrames = 30)
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices; using System.Text; using System.Collections.Generic;
public static class SW {
  [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint a, bool i, int pid);
  [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenThread(uint a, bool i, int tid);
  [DllImport("kernel32.dll", SetLastError=true)] static extern uint SuspendThread(IntPtr h);
  [DllImport("kernel32.dll", SetLastError=true)] static extern uint ResumeThread(IntPtr h);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetThreadContext(IntPtr h, IntPtr ctx);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool CloseHandle(IntPtr h);
  [DllImport("kernel32.dll", CharSet=CharSet.Ansi)] static extern IntPtr GetProcAddress(IntPtr m, string n);
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] static extern IntPtr LoadLibraryW(string n);
  [DllImport("dbghelp.dll", SetLastError=true)] static extern bool SymInitialize(IntPtr p, string path, bool invade);
  [DllImport("dbghelp.dll")] static extern uint SymSetOptions(uint o);
  [DllImport("dbghelp.dll")] static extern bool SymCleanup(IntPtr p);
  [DllImport("dbghelp.dll", SetLastError=true)] static extern bool SymFromAddr(IntPtr p, ulong addr, out ulong disp, IntPtr sym);
  [DllImport("dbghelp.dll", SetLastError=true)] static extern bool StackWalk64(uint machine, IntPtr p, IntPtr t, IntPtr frame, IntPtr ctx, IntPtr rd, IntPtr fta, IntPtr gmb, IntPtr tr);
  public static string Dump(int pid, int[] tids, string[] modNames, long[] modBases, long[] modSizes, int maxFrames) {
    var sb = new StringBuilder();
    IntPtr hp = OpenProcess(0x1F0FFF, false, pid); if (hp == IntPtr.Zero) return "OpenProcess failed " + Marshal.GetLastWin32Error();
    SymSetOptions(0x2 | 0x4);
    if (!SymInitialize(hp, null, true)) sb.AppendLine("SymInitialize failed " + Marshal.GetLastWin32Error());
    IntPtr dbg = LoadLibraryW("dbghelp.dll");
    IntPtr fta = GetProcAddress(dbg, "SymFunctionTableAccess64"), gmb = GetProcAddress(dbg, "SymGetModuleBase64");
    IntPtr raw = Marshal.AllocHGlobal(1232 + 16); IntPtr ctx = new IntPtr((raw.ToInt64() + 15) & ~15L);
    IntPtr frame = Marshal.AllocHGlobal(264); IntPtr sym = Marshal.AllocHGlobal(88 + 1024);
    foreach (int tid in tids) {
      IntPtr ht = OpenThread(0x1FFFFF, false, tid); if (ht == IntPtr.Zero) { sb.AppendLine("thread " + tid + ": OpenThread failed"); continue; }
      SuspendThread(ht);
      for (int i = 0; i < 1232; i++) Marshal.WriteByte(ctx, i, 0);
      Marshal.WriteInt32(ctx, 0x30, 0x10000B);
      if (!GetThreadContext(ht, ctx)) { sb.AppendLine("thread " + tid + ": GetThreadContext failed " + Marshal.GetLastWin32Error()); ResumeThread(ht); CloseHandle(ht); continue; }
      for (int i = 0; i < 264; i++) Marshal.WriteByte(frame, i, 0);
      Marshal.WriteInt64(frame, 0, Marshal.ReadInt64(ctx, 0xF8)); Marshal.WriteInt32(frame, 12, 3);
      Marshal.WriteInt64(frame, 32, Marshal.ReadInt64(ctx, 0xA0)); Marshal.WriteInt32(frame, 44, 3);
      Marshal.WriteInt64(frame, 48, Marshal.ReadInt64(ctx, 0x98)); Marshal.WriteInt32(frame, 60, 3);
      sb.AppendLine("--- thread " + tid);
      for (int f = 0; f < maxFrames; f++) {
        if (!StackWalk64(0x8664, hp, ht, frame, ctx, IntPtr.Zero, fta, gmb, IntPtr.Zero)) break;
        ulong pc = (ulong)Marshal.ReadInt64(frame, 0); if (pc == 0) break;
        string mod = "?"; for (int m = 0; m < modNames.Length; m++) if ((long)pc >= modBases[m] && (long)pc < modBases[m] + modSizes[m]) { mod = modNames[m]; break; }
        for (int i = 0; i < 88; i++) Marshal.WriteByte(sym, i, 0);
        Marshal.WriteInt32(sym, 0, 88); Marshal.WriteInt32(sym, 80, 1000);
        ulong disp; string name = SymFromAddr(hp, pc, out disp, sym) ? Marshal.PtrToStringAnsi(sym + 84) + "+0x" + disp.ToString("x") : "0x" + pc.ToString("x");
        sb.AppendLine("  " + mod + "!" + name);
      }
      ResumeThread(ht); CloseHandle(ht);
    }
    SymCleanup(hp); CloseHandle(hp);
    return sb.ToString();
  }
}
'@
$p = Get-Process -Id $ProcessId
$mods = @($p.Modules)
$tids = @($p.Threads | ForEach-Object { $_.Id })
"pid $ProcessId threads: " + (($p.Threads | ForEach-Object { "$($_.Id):$($_.ThreadState)/$(if ($_.ThreadState -eq 'Wait') { $_.WaitReason })" }) -join ' ')
[SW]::Dump($ProcessId, $tids, [string[]]($mods.ModuleName), [long[]]($mods | ForEach-Object { $_.BaseAddress.ToInt64() }), [long[]]($mods | ForEach-Object { [long]$_.ModuleMemorySize }), $MaxFrames)
