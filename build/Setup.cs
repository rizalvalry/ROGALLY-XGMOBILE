// XGPopupGuard-Setup.exe - installer satu file untuk XG Mobile Popup Guard.
// Berisi semua file solusi sebagai embedded resource. Diminta elevated lewat manifest.
// Alur: cek lingkungan -> verifikasi SHA256 -> ekstrak ke folder admin-only di Program Files ->
//       jalankan Install-XGPopupGuard.ps1 dengan environment allowlist -> hapus folder sementara.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Threading;
using Microsoft.Win32;

[assembly: AssemblyTitle("XG Mobile Popup Guard Setup")]
[assembly: AssemblyProduct("XGPopupGuard")]
[assembly: AssemblyVersion("1.1.0.0")]
[assembly: AssemblyFileVersion("1.1.0.0")]

namespace XGGuardSetup {
    internal static class Program {
        // Diisi otomatis oleh build.ps1 (nama resource -> SHA256 saat build).
        private static readonly Dictionary<string, string> ExpectedHashes = new Dictionary<string, string>(StringComparer.Ordinal) {
/*HASHES*/
        };

        private const string InstallerScript = "Install-XGPopupGuard.ps1";
        private const int InstallerTimeoutMs = 10 * 60 * 1000;
        private static volatile bool childRunning;

        private static int Main(string[] args) {
            Console.Title = "XG Mobile Popup Guard - Setup";
            Console.WriteLine("==============================================");
            Console.WriteLine("  XG Mobile Popup Guard - Setup v1.1");
            Console.WriteLine("  ROG Ally + XG Mobile: auto-stop pop-up Armoury Crate");
            Console.WriteLine("==============================================");
            Console.WriteLine();

            // --- Argumen ---
            bool quiet = HasArg(args, "/quiet"), inst = HasArg(args, "/install"), uninst = HasArg(args, "/uninstall");
            foreach (string a in args) {
                string l = a.ToLowerInvariant();
                if (l != "/quiet" && l != "/install" && l != "/uninstall") return Usage("Argumen tidak dikenal: " + a);
            }
            if (inst && uninst) return Usage("/install dan /uninstall tidak boleh dipakai bersamaan.");
            if (quiet && !inst && !uninst) return Usage("/quiet harus disertai /install atau /uninstall.");

            // Ctrl+C diabaikan selama installer berjalan agar instalasi tidak terputus di tengah.
            Console.CancelKeyPress += delegate(object s, ConsoleCancelEventArgs e) {
                if (childRunning) { e.Cancel = true; WriteColor("  Mohon tunggu, instalasi sedang berjalan...", ConsoleColor.Yellow); }
            };

            bool createdNew;
            Mutex created;
            try {
                created = new Mutex(true, @"Global\XGPopupGuard-Setup", out createdNew);
            } catch (Exception ex) {
                Fail("Tidak bisa membuat penanda setup (" + ex.Message + "). Tutup setup lain lalu coba lagi.");
                return Pause(quiet, 3);
            }
            using (Mutex mutex = created) {
                if (!createdNew) { Fail("Setup lain sedang berjalan. Tutup dulu jendela setup yang lain."); return Pause(quiet, 2); }
                try {
                    return Run(quiet, inst ? "install" : uninst ? "uninstall" : null);
                } catch (Exception ex) {
                    Fail(ex.Message);
                    return Pause(quiet, 3);
                } finally {
                    mutex.ReleaseMutex();
                }
            }
        }

        private static int Run(bool quiet, string mode) {
            if (!IsElevated()) {
                Fail("Setup harus dijalankan sebagai Administrator (klik kanan > Run as administrator).");
                return Pause(quiet, 2);
            }

            // --- Pemeriksaan lingkungan (deteksi upaya pembajakan proses elevated) ---
            List<string> hijack = FindHijackIndicators();
            if (hijack.Count > 0) {
                Fail("Ditemukan pengaturan yang bisa dipakai untuk membajak program admin:");
                foreach (string h in hijack) Console.WriteLine("    - " + h);
                Console.WriteLine("  Hapus item di atas (System > About > Advanced system settings > Environment Variables,");
                Console.WriteLine("  atau file .config di samping setup), lalu jalankan ulang. Instalasi dibatalkan.");
                return Pause(quiet, 4);
            }
            string exeDir = AppDomain.CurrentDomain.BaseDirectory;
            if (IsWritableByNonAdmins(exeDir)) {
                WriteColor("[PERINGATAN] Setup dijalankan dari folder yang bisa diubah tanpa hak admin:", ConsoleColor.Yellow);
                WriteColor("             " + exeDir, ConsoleColor.Yellow);
                WriteColor("             Lebih aman: salin setup ke folder khusus admin, cek SHA256, lalu jalankan dari sana.", ConsoleColor.Yellow);
                Console.WriteLine();
            }

            if (mode == null) mode = Menu();
            if (mode == null) { Console.WriteLine("Dibatalkan."); return Pause(quiet, 0); }

            string programFiles = GetProgramFilesDir();
            string workDir = Path.Combine(programFiles, "XGPopupGuard-setup");
            int rc;
            try {
                Extract(workDir);
                rc = RunInstaller(workDir, mode == "uninstall");
            } finally {
                try { SafeDeleteDirectory(workDir); }
                catch (Exception ex) { WriteColor("[PERINGATAN] Folder sementara tidak bisa dihapus (" + ex.Message + "). Akan dibersihkan pada run berikutnya.", ConsoleColor.Yellow); }
            }

            Console.WriteLine();
            if (rc == 0) {
                Ok(mode == "install" ? "Instalasi selesai." : "Uninstall selesai.");
                if (mode == "install") {
                    Console.WriteLine("  Log detektor : %LOCALAPPDATA%\\XGPopupGuard\\guard.log");
                    Console.WriteLine("  Log SYSTEM   : " + Path.Combine(programFiles, @"XGPopupGuard\logs\escalate.log"));
                }
            } else {
                Fail("Proses gagal (kode " + rc + "). Lihat pesan di atas.");
            }
            return Pause(quiet, rc);
        }

        private static string Menu() {
            Console.WriteLine("  [1] Install / Update");
            Console.WriteLine("  [2] Uninstall");
            Console.WriteLine("  [Q] Keluar");
            Console.WriteLine();
            while (true) {
                Console.Write("Pilih (1/2/Q): ");
                string line = Console.ReadLine();
                if (line == null) return null;
                string s = line.Trim().ToUpperInvariant();
                if (s == "1") return "install";
                if (s == "2") return "uninstall";
                if (s == "Q") return null;
            }
        }

        // Variabel environment / file yang bisa menyuntikkan kode ke proses .NET elevated.
        // Catatan: ini deteksi. Profiler yang sudah termuat sebelum Main tidak bisa dicegah dari dalam proses.
        private static List<string> FindHijackIndicators() {
            List<string> found = new List<string>();
            string[] prefixes = { "COR_ENABLE_PROFILING", "COR_PROFILER", "COMPLUS_", "APPDOMAIN_MANAGER_", "DOTNET_", "CORECLR_" };

            foreach (System.Collections.DictionaryEntry de in Environment.GetEnvironmentVariables()) {
                string name = (string)de.Key;
                foreach (string p in prefixes) if (name.StartsWith(p, StringComparison.OrdinalIgnoreCase)) { found.Add("Variabel proses: " + name); break; }
            }
            using (RegistryKey k = Registry.CurrentUser.OpenSubKey("Environment")) {
                if (k != null) {
                    foreach (string name in k.GetValueNames()) {
                        bool bad = name.Equals("windir", StringComparison.OrdinalIgnoreCase) || name.Equals("SystemRoot", StringComparison.OrdinalIgnoreCase);
                        foreach (string p in prefixes) if (name.StartsWith(p, StringComparison.OrdinalIgnoreCase)) bad = true;
                        if (bad) found.Add("Variabel user (HKCU\\Environment): " + name);
                    }
                }
            }
            string cfg = Assembly.GetExecutingAssembly().Location + ".config";
            if (File.Exists(cfg)) found.Add("File konfigurasi asing: " + cfg);
            return found;
        }

        // True jika Users/Authenticated Users/Everyone/Interactive/user saat ini bisa menulis ke folder.
        private static bool IsWritableByNonAdmins(string dir) {
            try {
                HashSet<string> risky = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "S-1-5-32-545", "S-1-5-11", "S-1-1-0", "S-1-5-4" };
                WindowsIdentity me = WindowsIdentity.GetCurrent();
                if (me.User != null) risky.Add(me.User.Value);
                // Bit spesifik saja (FullControl/Modify adalah gabungan yang juga memuat bit baca):
                // WriteData/CreateFiles 0x2, AppendData/CreateDirectories 0x4, WRITE_DAC 0x40000,
                // WRITE_OWNER 0x80000, GENERIC_ALL 0x10000000, GENERIC_WRITE 0x40000000.
                const int writeMask = 0x2 | 0x4 | 0x40000 | 0x80000 | 0x10000000 | 0x40000000;
                DirectorySecurity sec = Directory.GetAccessControl(dir);
                foreach (FileSystemAccessRule r in sec.GetAccessRules(true, true, typeof(SecurityIdentifier))) {
                    if (r.AccessControlType == AccessControlType.Allow && risky.Contains(r.IdentityReference.Value) && ((int)r.FileSystemRights & writeMask) != 0) return true;
                }
                return false;
            } catch { return true; }
        }

        // Ekstrak ke Program Files (hanya admin yang bisa menulis), verifikasi hash setiap file.
        private static void Extract(string workDir) {
            SafeDeleteDirectory(workDir);
            Directory.CreateDirectory(workDir);
            if ((File.GetAttributes(workDir) & FileAttributes.ReparsePoint) != 0) throw new IOException("Folder kerja berupa junction. Dibatalkan.");

            Assembly asm = Assembly.GetExecutingAssembly();
            Console.WriteLine("Memverifikasi & mengekstrak file:");
            foreach (KeyValuePair<string, string> kv in ExpectedHashes) {
                byte[] data;
                using (Stream s = asm.GetManifestResourceStream(kv.Key)) {
                    if (s == null) throw new InvalidDataException("Resource hilang: " + kv.Key);
                    using (MemoryStream ms = new MemoryStream()) { s.CopyTo(ms); data = ms.ToArray(); }
                }
                string hash = Sha256(data);
                if (!string.Equals(hash, kv.Value, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidDataException("Hash tidak cocok untuk " + kv.Key + " - file setup rusak/diubah.");
                File.WriteAllBytes(Path.Combine(workDir, kv.Key), data);
                Console.WriteLine("  OK  " + hash + "  " + kv.Key);
            }
            Console.WriteLine();
        }

        // PowerShell dari System32 (path absolut) dengan environment ALLOWLIST: hanya variabel
        // yang dibutuhkan yang diteruskan; nilai sistem diambil dari API/HKLM, bukan dari user.
        private static int RunInstaller(string workDir, bool uninstall) {
            string sys = Environment.SystemDirectory;
            string win = Path.GetDirectoryName(sys);
            string psHome = Path.Combine(sys, @"WindowsPowerShell\v1.0");
            string script = Path.Combine(workDir, InstallerScript);
            string tmp = Path.Combine(workDir, "tmp");
            Directory.CreateDirectory(tmp);

            ProcessStartInfo psi = new ProcessStartInfo(Path.Combine(psHome, "powershell.exe"));
            psi.Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" + script + "\" -SkipHashPrompt" + (uninstall ? " -Uninstall" : "");
            psi.UseShellExecute = false;
            psi.WorkingDirectory = workDir;
            psi.CreateNoWindow = true;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;

            Dictionary<string, string> keep = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (string name in new[] { "USERNAME", "USERDOMAIN", "COMPUTERNAME", "USERPROFILE", "APPDATA", "LOCALAPPDATA",
                                            "PROCESSOR_ARCHITECTURE", "PROCESSOR_IDENTIFIER", "PROCESSOR_LEVEL", "PROCESSOR_REVISION", "NUMBER_OF_PROCESSORS" }) {
                string v = Environment.GetEnvironmentVariable(name);
                if (!string.IsNullOrEmpty(v)) keep[name] = v;
            }
            psi.EnvironmentVariables.Clear();
            foreach (KeyValuePair<string, string> kv in keep) psi.EnvironmentVariables[kv.Key] = kv.Value;
            psi.EnvironmentVariables["SystemRoot"] = win;
            psi.EnvironmentVariables["windir"] = win;
            psi.EnvironmentVariables["SystemDrive"] = Path.GetPathRoot(win).TrimEnd('\\');
            psi.EnvironmentVariables["ComSpec"] = Path.Combine(sys, "cmd.exe");
            psi.EnvironmentVariables["OS"] = "Windows_NT";
            psi.EnvironmentVariables["PATHEXT"] = ".COM;.EXE;.BAT;.CMD;.VBS;.VBE;.JS;.JSE;.WSF;.WSH;.MSC";
            psi.EnvironmentVariables["ProgramFiles"] = GetProgramFilesDir();
            psi.EnvironmentVariables["ProgramData"] = Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData);
            psi.EnvironmentVariables["PATH"] = sys + ";" + win + ";" + Path.Combine(sys, "Wbem") + ";" + psHome;
            psi.EnvironmentVariables["PSModulePath"] = Path.Combine(psHome, "Modules");
            psi.EnvironmentVariables["TEMP"] = tmp;
            psi.EnvironmentVariables["TMP"] = tmp;

            Console.WriteLine(uninstall ? "Menjalankan uninstall..." : "Menjalankan instalasi...");
            Console.WriteLine("----------------------------------------------");
            using (Process p = new Process()) {
                p.StartInfo = psi;
                p.OutputDataReceived += delegate(object s, DataReceivedEventArgs e) { if (e.Data != null) Console.WriteLine(e.Data); };
                p.ErrorDataReceived += delegate(object s, DataReceivedEventArgs e) { if (e.Data != null) WriteColor(e.Data, ConsoleColor.Red); };
                childRunning = true;
                try {
                    p.Start();
                    p.BeginOutputReadLine();
                    p.BeginErrorReadLine();
                    if (!p.WaitForExit(InstallerTimeoutMs)) {
                        try { p.Kill(); } catch { }
                        Fail("Installer tidak selesai dalam 10 menit dan dihentikan.");
                        return 5;
                    }
                    p.WaitForExit();
                } finally {
                    childRunning = false;
                }
                Console.WriteLine("----------------------------------------------");
                return p.ExitCode;
            }
        }

        private static string GetProgramFilesDir() {
            using (RegistryKey k = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows\CurrentVersion")) {
                string v = k == null ? null : k.GetValue("ProgramFilesDir") as string;
                if (string.IsNullOrEmpty(v) || v.Contains("%") || !Directory.Exists(v)) throw new InvalidOperationException("ProgramFilesDir HKLM tidak valid.");
                return v;
            }
        }

        // Hapus folder tanpa mengikuti junction.
        private static void SafeDeleteDirectory(string dir) {
            if (!Directory.Exists(dir)) return;
            if ((File.GetAttributes(dir) & FileAttributes.ReparsePoint) != 0) { Directory.Delete(dir, false); return; }
            foreach (string sub in Directory.GetDirectories(dir)) SafeDeleteDirectory(sub);
            foreach (string f in Directory.GetFiles(dir)) { File.SetAttributes(f, FileAttributes.Normal); File.Delete(f); }
            Directory.Delete(dir, false);
        }

        private static bool IsElevated() {
            return new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator);
        }

        private static bool HasArg(string[] args, string name) {
            foreach (string a in args) if (string.Equals(a, name, StringComparison.OrdinalIgnoreCase)) return true;
            return false;
        }

        private static string Sha256(byte[] data) {
            using (SHA256 sha = SHA256.Create()) return BitConverter.ToString(sha.ComputeHash(data)).Replace("-", "");
        }

        private static int Usage(string error) {
            Fail(error);
            Console.WriteLine("Pemakaian: XGPopupGuard-Setup.exe [/install | /uninstall] [/quiet]");
            Console.WriteLine("           tanpa argumen = menu interaktif; /quiet wajib disertai /install atau /uninstall.");
            return 2;
        }

        private static int Pause(bool quiet, int rc) {
            if (!quiet) { Console.WriteLine(); Console.Write("Tekan Enter untuk menutup..."); Console.ReadLine(); }
            return rc;
        }

        private static void Ok(string m)   { WriteColor("[OK] " + m, ConsoleColor.Green); }
        private static void Fail(string m) { WriteColor("[GAGAL] " + m, ConsoleColor.Red); }
        private static void WriteColor(string m, ConsoleColor c) {
            lock (typeof(Program)) {
                ConsoleColor old = Console.ForegroundColor; Console.ForegroundColor = c; Console.WriteLine(m); Console.ForegroundColor = old;
            }
        }
    }
}
