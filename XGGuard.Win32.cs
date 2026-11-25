// Interop Win32 untuk XG Mobile Popup Guard.
// Dikompilasi SEKALI oleh installer menjadi XGGuard.Interop.dll di folder instalasi yang terkunci,
// sehingga proses elevated tidak pernah menjalankan compiler (csc) di %TEMP% milik user.
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace XGGuard {
    public sealed class WindowInfo {
        public long Handle;
        public uint ProcessId;
        public string Title;
    }

    public static class Win32 {
        private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

        [DllImport("user32.dll")]
        private static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);

        [DllImport("user32.dll")]
        private static extern bool IsWindowVisible(IntPtr hWnd);

        [DllImport("user32.dll", EntryPoint = "GetWindowTextLengthW", CharSet = CharSet.Unicode)]
        private static extern int GetWindowTextLength(IntPtr hWnd);

        [DllImport("user32.dll", EntryPoint = "GetWindowTextW", CharSet = CharSet.Unicode)]
        private static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int maxCount);

        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr OpenProcess(uint access, bool inheritHandle, uint processId);

        [DllImport("kernel32.dll", EntryPoint = "QueryFullProcessImageNameW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool QueryFullProcessImageName(IntPtr hProcess, uint flags, StringBuilder exeName, ref uint size);

        [DllImport("kernel32.dll")]
        private static extern bool CloseHandle(IntPtr handle);

        [DllImport("kernel32.dll")]
        private static extern ulong GetTickCount64();

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool TerminateProcess(IntPtr hProcess, uint exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool ProcessIdToSessionId(uint processId, out uint sessionId);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetExitCodeProcess(IntPtr hProcess, out uint exitCode);

        private const uint STILL_ACTIVE = 259;

        private const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
        private const uint PROCESS_TERMINATE = 0x0001;
        private const uint SYNCHRONIZE = 0x00100000;
        private const uint WAIT_OBJECT_0 = 0;

        // Hasil TerminateVerified.
        public const int KillExited = 0;      // dihentikan dan sudah keluar
        public const int KillTimeout = 1;     // dihentikan tetapi belum keluar dalam waktu tunggu
        public const int KillRefused = 2;     // validasi path/sesi gagal - tidak disentuh
        public const int KillNotFound = 3;    // proses tidak ada / tidak bisa dibuka
        public const int KillFailed = 4;      // TerminateProcess gagal

        private static string QueryImagePath(IntPtr h) {
            var sb = new StringBuilder(1024);
            uint size = (uint)sb.Capacity;
            return QueryFullProcessImageName(h, 0, sb, ref size) ? sb.ToString(0, (int)size) : null;
        }

        // Verifikasi lalu hentikan proses melalui SATU handle. Selama handle terbuka, PID
        // tidak bisa dipakai ulang oleh proses lain, sehingga yang diverifikasi = yang dihentikan.
        //   exactPath        : jika diisi, path harus sama persis (case-insensitive).
        //   allowedRoots     : jika diisi, path harus diawali salah satu root.
        //   excludedPath     : path yang tidak boleh dihentikan.
        //   requireUserSession: tolak proses di session 0.
        public static int TerminateVerified(uint processId, string exactPath, string[] allowedRoots,
                                            string excludedPath, bool requireUserSession, uint waitMs,
                                            out string actualPath, out uint sessionId) {
            actualPath = null;
            sessionId = uint.MaxValue;
            if (processId == 0 || processId == 4) return KillRefused;
            IntPtr h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_TERMINATE | SYNCHRONIZE, false, processId);
            if (h == IntPtr.Zero) {
                // 87 = ERROR_INVALID_PARAMETER: PID tidak ada. Selain itu (mis. access denied) = gagal.
                return Marshal.GetLastWin32Error() == 87 ? KillNotFound : KillFailed;
            }
            try {
                uint exitCode;
                if (GetExitCodeProcess(h, out exitCode) && exitCode != STILL_ACTIVE) return KillNotFound;
                actualPath = QueryImagePath(h);
                if (actualPath == null) return KillRefused;
                if (!ProcessIdToSessionId(processId, out sessionId)) return KillRefused;

                if (exactPath != null && !string.Equals(actualPath, exactPath, StringComparison.OrdinalIgnoreCase)) return KillRefused;
                if (allowedRoots != null) {
                    bool ok = false;
                    foreach (var root in allowedRoots) {
                        if (!string.IsNullOrEmpty(root) && actualPath.StartsWith(root, StringComparison.OrdinalIgnoreCase)) { ok = true; break; }
                    }
                    if (!ok) return KillRefused;
                }
                if (excludedPath != null && string.Equals(actualPath, excludedPath, StringComparison.OrdinalIgnoreCase)) return KillRefused;
                if (requireUserSession && sessionId == 0) return KillRefused;

                if (!TerminateProcess(h, 1)) return KillFailed;
                return WaitForSingleObject(h, waitMs) == WAIT_OBJECT_0 ? KillExited : KillTimeout;
            } finally {
                CloseHandle(h);
            }
        }

        // Semua jendela top-level yang terlihat dan punya judul (termasuk dialog sekunder).
        public static List<WindowInfo> GetVisibleTitledWindows() {
            var result = new List<WindowInfo>();
            EnumWindowsProc cb = delegate(IntPtr h, IntPtr l) {
                if (!IsWindowVisible(h)) return true;
                int len = GetWindowTextLength(h);
                if (len <= 0) return true;
                var sb = new StringBuilder(len + 1);
                GetWindowText(h, sb, sb.Capacity);
                uint pid;
                GetWindowThreadProcessId(h, out pid);
                result.Add(new WindowInfo { Handle = h.ToInt64(), ProcessId = pid, Title = sb.ToString() });
                return true;
            };
            EnumWindows(cb, IntPtr.Zero);
            GC.KeepAlive(cb);
            return result;
        }

        // Path executable dari kernel (bukan dari memori proses/PEB yang bisa dipalsukan).
        public static string GetProcessImagePath(uint processId) {
            if (processId == 0) return null;
            IntPtr h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, processId);
            if (h == IntPtr.Zero) return null;
            try {
                return QueryImagePath(h);
            } finally {
                CloseHandle(h);
            }
        }

        public static ulong GetUptimeMilliseconds() {
            return GetTickCount64();
        }
    }
}
