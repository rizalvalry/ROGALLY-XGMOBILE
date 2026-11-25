# =====================================================================
# XGGuard.Common.ps1 - fungsi bersama untuk detektor (user) dan eskalasi (SYSTEM).
# Di-dot-source dari folder instalasi (C:\Program Files\XGPopupGuard, hanya admin
# yang bisa menulis). Pemanggil wajib mengisi $LogPath dan $LogTag sebelum memakai
# Write-GuardLog, serta $ScriptDir sebelum Import-GuardInterop.
# =====================================================================

$ServiceName = 'ArmouryCrateSEService'

# ---------------------------------------------------------------------
# Logging: satu baris per kejadian, karakter kontrol dibuang (anti pemalsuan
# baris log dari judul jendela), dipotong 400 karakter, rotasi di 1 MB.
# ---------------------------------------------------------------------
function Write-GuardLog {
    param([string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO')
    try {
        $clean = ($Message -replace '[\x00-\x1F\x7F]', ' ')
        if ($clean.Length -gt 400) { $clean = $clean.Substring(0, 400) + '...' }
        $dir = [IO.Path]::GetDirectoryName($LogPath)
        if (-not [IO.Directory]::Exists($dir)) { [void][IO.Directory]::CreateDirectory($dir) }
        if ([IO.File]::Exists($LogPath) -and (New-Object IO.FileInfo $LogPath).Length -gt 1MB) {
            [IO.File]::Copy($LogPath, "$LogPath.1", $true)
            [IO.File]::WriteAllText($LogPath, '')
        }
        $line = '{0:yyyy-MM-dd HH:mm:ss} [{1,-5}] [{2}] [pid {3}] {4}{5}' -f [DateTime]::Now, $Level, $LogTag, $PID, $clean, [Environment]::NewLine
        [IO.File]::AppendAllText($LogPath, $line, [Text.Encoding]::UTF8)
    } catch { }
}

# ---------------------------------------------------------------------
# Interop Win32 (EnumWindows, QueryFullProcessImageName, GetTickCount64).
# Terpasang: dimuat dari XGGuard.Interop.dll hasil kompilasi installer.
# Folder sumber (uji DryRun tanpa admin): dikompilasi dari XGGuard.Win32.cs.
# Proses elevated/SYSTEM tidak pernah menjalankan compiler.
# ---------------------------------------------------------------------
function Test-IsPrivileged {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    if ($id.User.Value -eq 'S-1-5-18') { return $true }
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Import-GuardInterop {
    if ('XGGuard.Win32' -as [type]) { return }
    $dll = [IO.Path]::Combine($ScriptDir, 'XGGuard.Interop.dll')
    if ([IO.File]::Exists($dll)) { [void][Reflection.Assembly]::LoadFile($dll); return }
    if (Test-IsPrivileged) { throw "XGGuard.Interop.dll tidak ditemukan di $ScriptDir - jalankan ulang installer" }
    Add-Type -Path ([IO.Path]::Combine($ScriptDir, 'XGGuard.Win32.cs'))
}

# ---------------------------------------------------------------------
# Target & whitelist dari HKLM (bukan variabel environment).
#   ServiceExe : ImagePath service Armoury Crate SE.
#   OwnerRoots : folder service tersebut + paket AppX Armoury Crate SE (publisher ASUS).
# ---------------------------------------------------------------------
function Get-HklmValue([string]$SubKey, [string]$Name) {
    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($SubKey)
    if (-not $key) { return $null }
    try { return $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) }
    finally { $key.Close() }
}

function Resolve-GuardTargets {
    $image = [string](Get-HklmValue "SYSTEM\CurrentControlSet\Services\$ServiceName" 'ImagePath')
    if ([string]::IsNullOrWhiteSpace($image)) { return $null }
    $image = $image.Trim()
    $exe = if ($image.StartsWith('"')) { $image.Substring(1, $image.IndexOf('"', 1) - 1) }
           else { $image.Substring(0, $image.ToLowerInvariant().IndexOf('.exe') + 4) }
    if ($exe.Contains('%') -or -not [IO.Path]::IsPathRooted($exe)) { throw "ImagePath service tidak wajar: $image" }

    $programFiles = [string](Get-HklmValue 'SOFTWARE\Microsoft\Windows\CurrentVersion' 'ProgramFilesDir')
    if ([string]::IsNullOrWhiteSpace($programFiles) -or $programFiles.Contains('%')) { throw 'ProgramFilesDir HKLM tidak valid' }

    return [pscustomobject]@{
        ServiceExe = $exe
        OwnerRoots = @(
            ([IO.Path]::GetDirectoryName($exe).TrimEnd('\') + '\'),
            [IO.Path]::Combine($programFiles, 'WindowsApps\B9ECED6F.ArmouryCrateSE_')
        )
    }
}

function Test-ArmouryOwner([string]$Path, $Targets) {
    if ([string]::IsNullOrEmpty($Path)) { return $false }
    foreach ($root in $Targets.OwnerRoots) {
        if ($Path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}
