using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public class RunHandle {
    public int ProcessId;
    public IntPtr ProcessHandle;
    public IntPtr JobHandle;
    public bool Closed;
}

public static class XagentSandbox {
    const uint GENERIC_READ = 0x80000000;
    const uint GENERIC_WRITE = 0x40000000;
    const uint FILE_SHARE_READ = 0x00000001;
    const uint FILE_SHARE_WRITE = 0x00000002;
    const uint OPEN_EXISTING = 3;
    const uint OPEN_ALWAYS = 4;
    const uint FILE_ATTRIBUTE_NORMAL = 0x80;
    const uint FILE_END = 2;
    const uint HANDLE_FLAG_INHERIT = 0x00000001;
    const uint STARTF_USESTDHANDLES = 0x00000100;
    const uint CREATE_SUSPENDED = 0x00000004;
    const uint CREATE_UNICODE_ENVIRONMENT = 0x00000400;
    const uint EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
    const uint CREATE_NO_WINDOW = 0x08000000;
    const int PROC_THREAD_ATTRIBUTE_HANDLE_LIST = 0x00020002;
    const int PROC_THREAD_ATTRIBUTE_SECURITY_CAPABILITIES = 0x00020009;
    const uint SE_GROUP_ENABLED = 0x00000004;
    const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000;
    const int JobObjectExtendedLimitInformation = 9;
    const int TokenIsAppContainer = 29;
    const uint TOKEN_QUERY = 0x0008;
    const string InternetClientSid = "S-1-15-3-1";

    [StructLayout(LayoutKind.Sequential)]
    struct SECURITY_ATTRIBUTES {
        public int nLength;
        public IntPtr lpSecurityDescriptor;
        public int bInheritHandle;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct SID_AND_ATTRIBUTES {
        public IntPtr Sid;
        public uint Attributes;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct SECURITY_CAPABILITIES {
        public IntPtr AppContainerSid;
        public IntPtr Capabilities;
        public uint CapabilityCount;
        public uint Reserved;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct STARTUPINFO {
        public int cb;
        public IntPtr lpReserved;
        public IntPtr lpDesktop;
        public IntPtr lpTitle;
        public int dwX;
        public int dwY;
        public int dwXSize;
        public int dwYSize;
        public int dwXCountChars;
        public int dwYCountChars;
        public int dwFillAttribute;
        public int dwFlags;
        public short wShowWindow;
        public short cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput;
        public IntPtr hStdOutput;
        public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct STARTUPINFOEX {
        public STARTUPINFO StartupInfo;
        public IntPtr lpAttributeList;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_INFORMATION {
        public IntPtr hProcess;
        public IntPtr hThread;
        public int dwProcessId;
        public int dwThreadId;
    }

    [StructLayout(LayoutKind.Explicit, Size = 64)]
    struct JOBOBJECT_BASIC_LIMIT_INFORMATION {
        [FieldOffset(0)] public long PerProcessUserTimeLimit;
        [FieldOffset(8)] public long PerJobUserTimeLimit;
        [FieldOffset(16)] public uint LimitFlags;
        [FieldOffset(24)] public UIntPtr MinimumWorkingSetSize;
        [FieldOffset(32)] public UIntPtr MaximumWorkingSetSize;
        [FieldOffset(40)] public uint ActiveProcessLimit;
        [FieldOffset(48)] public UIntPtr Affinity;
        [FieldOffset(56)] public uint PriorityClass;
        [FieldOffset(60)] public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct IO_COUNTERS {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    [DllImport("userenv.dll", CharSet = CharSet.Unicode)]
    static extern int CreateAppContainerProfile(string name, string displayName, string description, IntPtr caps, int count, out IntPtr sid);

    [DllImport("userenv.dll", CharSet = CharSet.Unicode)]
    static extern int DeriveAppContainerSidFromAppContainerName(string name, out IntPtr sid);

    [DllImport("userenv.dll", CharSet = CharSet.Unicode)]
    static extern int DeleteAppContainerProfile(string name);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool ConvertSidToStringSid(IntPtr sid, out string s);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool ConvertStringSidToSid(string s, out IntPtr sid);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr LocalFree(IntPtr hMem);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateJobObject(IntPtr lpJobAttributes, string lpName);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetInformationJobObject(IntPtr hJob, int jobObjectInfoClass, IntPtr lpJobObjectInfo, uint cbJobObjectInfoLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool AssignProcessToJobObject(IntPtr hJob, IntPtr hProcess);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool TerminateJobObject(IntPtr hJob, uint uExitCode);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateFileW(string fileName, uint access, uint share, ref SECURITY_ATTRIBUTES sa, uint creation, uint flags, IntPtr template);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern uint SetFilePointer(IntPtr hFile, int distance, IntPtr high, uint method);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetHandleInformation(IntPtr hObject, uint mask, uint flags);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool InitializeProcThreadAttributeList(IntPtr lpAttributeList, int dwAttributeCount, int dwFlags, ref IntPtr lpSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool UpdateProcThreadAttribute(IntPtr lpAttributeList, uint dwFlags, IntPtr attribute, IntPtr lpValue, IntPtr cbSize, IntPtr lpPreviousValue, IntPtr lpReturnSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern void DeleteProcThreadAttributeList(IntPtr lpAttributeList);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CreateProcessW(string app, StringBuilder cmd, IntPtr processAttributes, IntPtr threadAttributes, bool inherit, uint flags, IntPtr env, string cwd, ref STARTUPINFOEX si, out PROCESS_INFORMATION pi);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern uint ResumeThread(IntPtr hThread);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern uint WaitForSingleObject(IntPtr h, uint ms);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetExitCodeProcess(IntPtr h, out uint code);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool TerminateProcess(IntPtr h, uint code);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CloseHandle(IntPtr h);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    static extern int CompareStringOrdinal(string a, int aLen, string b, int bLen, bool ignoreCase);

    [DllImport("kernel32.dll")]
    static extern IntPtr GetCurrentProcess();

    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);

    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool GetTokenInformation(IntPtr token, int cls, IntPtr buffer, uint length, out uint returnLength);

    static readonly IntPtr InvalidHandle = new IntPtr(-1);

    static void Fail(string what) {
        int err = Marshal.GetLastWin32Error();
        throw new InvalidOperationException(what + " (win32 " + err + ")");
    }

    public static string EnsureProfile(string name) {
        if (string.IsNullOrEmpty(name)) throw new ArgumentException("name");
        IntPtr sid;
        int hr = CreateAppContainerProfile(name, name, "xagent", IntPtr.Zero, 0, out sid);
        if (hr != 0) {
            int derived = DeriveAppContainerSidFromAppContainerName(name, out sid);
            if (derived != 0) {
                throw new InvalidOperationException("EnsureProfile " + name + " create=0x" + hr.ToString("X8") + " derive=0x" + derived.ToString("X8"));
            }
        }
        try {
            string text;
            if (!ConvertSidToStringSid(sid, out text) || string.IsNullOrEmpty(text)) Fail("ConvertSidToStringSid");
            return text;
        } finally {
            LocalFree(sid);
        }
    }

    public static void DeleteProfile(string name) {
        if (string.IsNullOrEmpty(name)) throw new ArgumentException("name");
        int hr = DeleteAppContainerProfile(name);
        if (hr != 0) throw new InvalidOperationException("DeleteProfile " + name + " hr=0x" + hr.ToString("X8"));
    }

    public static RunHandle Start(string containerSid, string exePath, string commandLine, string cwd, string[] environment, string stdoutPath, string stderrPath) {
        if (string.IsNullOrEmpty(containerSid)) throw new ArgumentException("containerSid");
        if (string.IsNullOrEmpty(exePath)) throw new ArgumentException("exePath");
        if (commandLine == null) commandLine = "";
        if (environment == null) environment = new string[0];

        IntPtr job = IntPtr.Zero;
        IntPtr process = IntPtr.Zero;
        IntPtr thread = IntPtr.Zero;
        IntPtr stdin = IntPtr.Zero;
        IntPtr stdout = IntPtr.Zero;
        IntPtr stderr = IntPtr.Zero;
        IntPtr env = IntPtr.Zero;
        IntPtr acSid = IntPtr.Zero;
        IntPtr capSid = IntPtr.Zero;
        IntPtr caps = IntPtr.Zero;
        IntPtr scPtr = IntPtr.Zero;
        IntPtr attrList = IntPtr.Zero;
        IntPtr handleList = IntPtr.Zero;
        bool attrReady = false;
        bool ownJob = false;
        bool ownProcess = false;

        try {
            job = CreateJobObject(IntPtr.Zero, null);
            if (job == IntPtr.Zero) Fail("CreateJobObject");
            ownJob = true;
            SetKillOnJobClose(job);

            SECURITY_ATTRIBUTES sa = new SECURITY_ATTRIBUTES();
            sa.nLength = Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES));
            sa.bInheritHandle = 1;
            stdin = OpenInheritable(@"\\.\NUL", GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, OPEN_EXISTING, ref sa);
            stdout = OpenAppend(stdoutPath, ref sa);
            stderr = OpenAppend(stderrPath, ref sa);

            env = BuildEnvironment(environment);
            if (!ConvertStringSidToSid(containerSid, out acSid)) Fail("ConvertStringSidToSid");
            if (!ConvertStringSidToSid(InternetClientSid, out capSid)) Fail("ConvertStringSidToSid capability");

            int sidSize = Marshal.SizeOf(typeof(SID_AND_ATTRIBUTES));
            caps = Marshal.AllocHGlobal(sidSize);
            SID_AND_ATTRIBUTES cap = new SID_AND_ATTRIBUTES { Sid = capSid, Attributes = SE_GROUP_ENABLED };
            Marshal.StructureToPtr(cap, caps, false);

            SECURITY_CAPABILITIES sc = new SECURITY_CAPABILITIES {
                AppContainerSid = acSid,
                Capabilities = caps,
                CapabilityCount = 1,
                Reserved = 0
            };
            int scSize = Marshal.SizeOf(typeof(SECURITY_CAPABILITIES));
            scPtr = Marshal.AllocHGlobal(scSize);
            Marshal.StructureToPtr(sc, scPtr, false);

            IntPtr attrSize = IntPtr.Zero;
            InitializeProcThreadAttributeList(IntPtr.Zero, 2, 0, ref attrSize);
            if (attrSize == IntPtr.Zero) Fail("InitializeProcThreadAttributeList size");
            attrList = Marshal.AllocHGlobal(attrSize);
            if (!InitializeProcThreadAttributeList(attrList, 2, 0, ref attrSize)) Fail("InitializeProcThreadAttributeList");
            attrReady = true;

            if (!UpdateProcThreadAttribute(attrList, 0, (IntPtr)PROC_THREAD_ATTRIBUTE_SECURITY_CAPABILITIES, scPtr, (IntPtr)scSize, IntPtr.Zero, IntPtr.Zero)) {
                Fail("UpdateProcThreadAttribute security");
            }

            handleList = Marshal.AllocHGlobal(IntPtr.Size * 3);
            Marshal.WriteIntPtr(handleList, 0, stdin);
            Marshal.WriteIntPtr(handleList, IntPtr.Size, stdout);
            Marshal.WriteIntPtr(handleList, IntPtr.Size * 2, stderr);
            if (!UpdateProcThreadAttribute(attrList, 0, (IntPtr)PROC_THREAD_ATTRIBUTE_HANDLE_LIST, handleList, (IntPtr)(IntPtr.Size * 3), IntPtr.Zero, IntPtr.Zero)) {
                Fail("UpdateProcThreadAttribute handles");
            }

            STARTUPINFOEX si = new STARTUPINFOEX();
            si.StartupInfo.cb = Marshal.SizeOf(typeof(STARTUPINFOEX));
            si.StartupInfo.dwFlags = (int)STARTF_USESTDHANDLES;
            si.StartupInfo.hStdInput = stdin;
            si.StartupInfo.hStdOutput = stdout;
            si.StartupInfo.hStdError = stderr;
            si.lpAttributeList = attrList;

            StringBuilder cmd = new StringBuilder(commandLine, Math.Max(commandLine.Length + 1024, 1));
            PROCESS_INFORMATION pi;
            uint flags = CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT | EXTENDED_STARTUPINFO_PRESENT | CREATE_NO_WINDOW;
            if (!CreateProcessW(exePath, cmd, IntPtr.Zero, IntPtr.Zero, true, flags, env, cwd, ref si, out pi)) Fail("CreateProcessW");
            process = pi.hProcess;
            thread = pi.hThread;
            ownProcess = true;

            if (!AssignProcessToJobObject(job, process)) Fail("AssignProcessToJobObject");
            if (ResumeThread(thread) == 0xFFFFFFFF) Fail("ResumeThread");

            RunHandle handle = new RunHandle();
            handle.ProcessId = pi.dwProcessId;
            handle.ProcessHandle = process;
            handle.JobHandle = job;
            handle.Closed = false;
            ownProcess = false;
            ownJob = false;
            process = IntPtr.Zero;
            job = IntPtr.Zero;
            return handle;
        } finally {
            if (thread != IntPtr.Zero) CloseHandle(thread);
            if (stdin != IntPtr.Zero) CloseHandle(stdin);
            if (stdout != IntPtr.Zero) CloseHandle(stdout);
            if (stderr != IntPtr.Zero) CloseHandle(stderr);
            if (env != IntPtr.Zero) Marshal.FreeHGlobal(env);
            if (attrReady) DeleteProcThreadAttributeList(attrList);
            if (attrList != IntPtr.Zero) Marshal.FreeHGlobal(attrList);
            if (handleList != IntPtr.Zero) Marshal.FreeHGlobal(handleList);
            if (scPtr != IntPtr.Zero) Marshal.FreeHGlobal(scPtr);
            if (caps != IntPtr.Zero) Marshal.FreeHGlobal(caps);
            if (acSid != IntPtr.Zero) LocalFree(acSid);
            if (capSid != IntPtr.Zero) LocalFree(capSid);
            if (ownProcess && process != IntPtr.Zero) {
                TerminateProcess(process, 1);
                CloseHandle(process);
            }
            if (ownJob && job != IntPtr.Zero) CloseHandle(job);
        }
    }

    public static bool Wait(RunHandle h, int ms) {
        if (h == null || h.Closed || h.ProcessHandle == IntPtr.Zero) return false;
        uint result = WaitForSingleObject(h.ProcessHandle, unchecked((uint)ms));
        return result == 0;
    }

    public static void Kill(RunHandle h) {
        if (h == null || h.Closed || h.JobHandle == IntPtr.Zero) return;
        if (!TerminateJobObject(h.JobHandle, 1)) Fail("TerminateJobObject");
    }

    public static int Finish(RunHandle h) {
        if (h == null || h.Closed) return -1;
        int code = -1;
        try {
            if (h.ProcessHandle != IntPtr.Zero && WaitForSingleObject(h.ProcessHandle, 0) == 0) {
                uint native;
                if (GetExitCodeProcess(h.ProcessHandle, out native)) code = unchecked((int)native);
            }
            return code;
        } finally {
            if (h.ProcessHandle != IntPtr.Zero) {
                CloseHandle(h.ProcessHandle);
                h.ProcessHandle = IntPtr.Zero;
            }
            if (h.JobHandle != IntPtr.Zero) {
                CloseHandle(h.JobHandle);
                h.JobHandle = IntPtr.Zero;
            }
            h.Closed = true;
        }
    }

    public static bool IsAppContainer() {
        IntPtr token;
        if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, out token)) Fail("OpenProcessToken");
        try {
            IntPtr buf = Marshal.AllocHGlobal(4);
            try {
                uint needed;
                if (!GetTokenInformation(token, TokenIsAppContainer, buf, 4, out needed)) {
                    if (Marshal.GetLastWin32Error() == 87) return false;
                    Fail("GetTokenInformation");
                }
                return Marshal.ReadInt32(buf) != 0;
            } finally {
                Marshal.FreeHGlobal(buf);
            }
        } finally {
            CloseHandle(token);
        }
    }

    public static int[] FindFilePattern(string path, byte[] pattern) {
        if (string.IsNullOrEmpty(path)) throw new ArgumentException("path");
        if (pattern == null || pattern.Length == 0) return new int[0];
        byte[] data = System.IO.File.ReadAllBytes(path);
        List<int> hits = new List<int>();
        int last = data.Length - pattern.Length;
        for (int i = 0; i <= last; i++) {
            if (data[i] != pattern[0]) continue;
            int j = 1;
            for (; j < pattern.Length; j++) {
                if (data[i + j] != pattern[j]) break;
            }
            if (j == pattern.Length) hits.Add(i);
        }
        return hits.ToArray();
    }

    static void SetKillOnJobClose(IntPtr job) {
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
        info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        int size = Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
        IntPtr mem = Marshal.AllocHGlobal(size);
        try {
            Marshal.StructureToPtr(info, mem, false);
            if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, mem, (uint)size)) Fail("SetInformationJobObject");
        } finally {
            Marshal.FreeHGlobal(mem);
        }
    }

    static IntPtr OpenInheritable(string path, uint access, uint share, uint creation, ref SECURITY_ATTRIBUTES sa) {
        IntPtr handle = CreateFileW(path, access, share, ref sa, creation, FILE_ATTRIBUTE_NORMAL, IntPtr.Zero);
        if (handle == IntPtr.Zero || handle == InvalidHandle) Fail("CreateFile " + path);
        if (!SetHandleInformation(handle, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT)) Fail("SetHandleInformation");
        return handle;
    }

    static IntPtr OpenAppend(string path, ref SECURITY_ATTRIBUTES sa) {
        IntPtr handle = OpenInheritable(path, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, OPEN_ALWAYS, ref sa);
        uint pos = SetFilePointer(handle, 0, IntPtr.Zero, FILE_END);
        if (pos == 0xFFFFFFFF && Marshal.GetLastWin32Error() != 0) Fail("SetFilePointer " + path);
        return handle;
    }

    static IntPtr BuildEnvironment(string[] environment) {
        List<string> items = new List<string>();
        foreach (string entry in environment) {
            if (!string.IsNullOrEmpty(entry)) items.Add(entry);
        }
        // AppContainer startup looks variables up with a binary search, so the
        // order has to be Windows' own case-insensitive ordinal order.
        items.Sort((x, y) => CompareStringOrdinal(x, -1, y, -1, true) - 2);
        int chars = 1;
        foreach (string entry in items) chars += entry.Length + 1;
        char[] block = new char[chars];
        int index = 0;
        foreach (string entry in items) {
            entry.CopyTo(0, block, index, entry.Length);
            index += entry.Length;
            block[index++] = '\0';
        }
        block[index] = '\0';
        byte[] bytes = Encoding.Unicode.GetBytes(block);
        IntPtr mem = Marshal.AllocHGlobal(bytes.Length);
        Marshal.Copy(bytes, 0, mem, bytes.Length);
        return mem;
    }
}
