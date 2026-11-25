#Requires -Version 5.1
<#
.SYNOPSIS
    XG Mobile Popup Guard (ESKALASI) - berjalan sebagai SYSTEM lewat task
    \ROGAlly\XGPopupGuard-Escalate, dipicu oleh detektor.

.DESCRIPTION
    SYSTEM memakai environment-nya sendiri (bukan HKCU\Environment user), sehingga
    malware tanpa hak admin tidak bisa menyusupkan kode ke proses ini. Permintaan dari
    detektor dianggap TIDAK tepercaya dan divalidasi ulang di sini:

    stop-service
        Tahap 1: stop via SCM (setara `net stop`), tunggu Running dulu jika StartPending,
                 batas 20 dtk.
        Tahap 2: bila macet/timeout (Error 1053) -> kill proses service, HANYA jika path
                 kernel-nya persis ImagePath service di HKLM.
        Tahap 3: recovery service = RESTART 5 dtk; awasi 15 dtk dan stop ulang bila hidup.

    close-owner:<PID>
        Tahap 4: menutup proses pemilik pop-up, HANYA jika:
          - service ArmouryCrateSEService sudah Stopped,
          - path kernel proses berada di folder Armoury Crate SE (bukan service itu sendiri),
          - proses berada di sesi user (bukan session 0).

    Tidak ada proses/driver NVIDIA atau Windows yang bisa lolos validasi di atas.
    Kode keluar: 0 = berhasil | 1 = gagal | 2 = ditolak (validasi/bukan SYSTEM) | 3 = error
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^(stop-service|close-owner:[1-9][0-9]{0,9})\z')]
    [string]$Request
)

$env:PSModulePath = [IO.Path]::Combine($PSHOME, 'Modules')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = $PSScriptRoot
$LogTag    = 'escalate'
$LogPath   = [IO.Path]::Combine($ScriptDir, 'logs\escalate.log')
. ([IO.Path]::Combine($ScriptDir, 'XGGuard.Common.ps1'))

$GracefulStopTimeout = [TimeSpan]::FromSeconds(20)

# ---------------------------------------------------------------------
# Tahap 1: stop normal via SCM.
# ---------------------------------------------------------------------
function Invoke-GracefulStop([System.ServiceProcess.ServiceController]$Svc) {
    $Svc.Refresh()
    if ($Svc.Status -eq 'StartPending') {
        $Svc.WaitForStatus('Running', [TimeSpan]::FromSeconds(15))
        $Svc.Refresh()
    }
    if ($Svc.Status -eq 'Stopped') { return $true }
    if ($Svc.Status -ne 'StopPending') { $Svc.Stop() }
    $Svc.WaitForStatus('Stopped', $GracefulStopTimeout)
    return $true
}

# ---------------------------------------------------------------------
# Tahap 1-3.
# ---------------------------------------------------------------------
function Stop-ArmouryService {
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $svc) { Write-GuardLog "Service '$ServiceName' tidak ditemukan" 'ERROR'; return $false }

    try {
        if (Invoke-GracefulStop $svc) { Write-GuardLog 'Tahap 1: service dihentikan secara normal (setara net stop)'; return $true }
    } catch {
        Write-GuardLog ("Tahap 1 gagal/timeout (setara Error 1053): {0}" -f $_.Exception.Message) 'WARN'
    }

    $cim = Get-CimInstance -ClassName Win32_Service -Filter "Name='$ServiceName'" -ErrorAction SilentlyContinue
    $svcPid = if ($cim) { [uint32]$cim.ProcessId } else { [uint32]0 }
    if ($svcPid -eq 0) { $svc.Refresh(); return ($svc.Status -eq 'Stopped') }

    # Verifikasi path == ImagePath dan kill lewat satu handle (anti PID-reuse).
    $procPath = $null; $sessionId = [uint32]0
    $rc = [XGGuard.Win32]::TerminateVerified($svcPid, $script:Targets.ServiceExe, $null, $null, $false, 10000, [ref]$procPath, [ref]$sessionId)
    switch ($rc) {
        ([XGGuard.Win32]::KillRefused) {
            Write-GuardLog ("Tahap 2 DIBATALKAN: pid {0} path '{1}' tidak cocok dengan '{2}'" -f $svcPid, $procPath, $script:Targets.ServiceExe) 'ERROR'
            return $false
        }
        ([XGGuard.Win32]::KillNotFound) { Write-GuardLog "Tahap 2: pid $svcPid sudah tidak ada" }
        ([XGGuard.Win32]::KillFailed)   { Write-GuardLog "Tahap 2: TerminateProcess gagal (pid $svcPid)" 'ERROR'; return $false }
        default { Write-GuardLog ("Tahap 2: force-kill proses service terverifikasi (pid {0}, hasil {1})" -f $svcPid, $rc) 'WARN' }
    }

    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt 15) {
        Start-Sleep -Seconds 1
        $svc.Refresh()
        if ($svc.Status -in 'Running', 'StartPending') {
            Write-GuardLog 'Tahap 3: service di-restart oleh SCM recovery; stop normal ulang' 'WARN'
            try { return (Invoke-GracefulStop $svc) }
            catch { Write-GuardLog ("Tahap 3 gagal: {0}" -f $_.Exception.Message) 'ERROR'; return $false }
        }
    }
    $svc.Refresh()
    return ($svc.Status -eq 'Stopped')
}

# ---------------------------------------------------------------------
# Tahap 4.
# ---------------------------------------------------------------------
function Close-PopupOwner([uint32]$ProcessId) {
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Stopped') {
        Write-GuardLog "Tahap 4 DITOLAK: service masih $($svc.Status)" 'WARN'
        return 2
    }

    # Satu handle: path di folder Armoury Crate SE, bukan service, bukan session 0 -> kill.
    $path = $null; $sessionId = [uint32]0
    $rc = [XGGuard.Win32]::TerminateVerified($ProcessId, $null, [string[]]$script:Targets.OwnerRoots, $script:Targets.ServiceExe, $true, 5000, [ref]$path, [ref]$sessionId)
    switch ($rc) {
        ([XGGuard.Win32]::KillExited)   { Write-GuardLog ("Tahap 4: pemilik pop-up ditutup (pid {0}, {1}, sesi {2})" -f $ProcessId, $path, $sessionId) 'WARN'; return 0 }
        ([XGGuard.Win32]::KillNotFound) { Write-GuardLog "Tahap 4: pid $ProcessId sudah tidak ada"; return 0 }
        ([XGGuard.Win32]::KillRefused)  {
            Write-GuardLog ("Tahap 4 DITOLAK: pid {0} path '{1}' sesi {2} - bukan proses Armoury Crate SE di sesi user, atau proses service" -f $ProcessId, $path, $sessionId) 'ERROR'
            return 2
        }
        ([XGGuard.Win32]::KillTimeout)  { Write-GuardLog "Tahap 4: pid $ProcessId dihentikan tetapi belum keluar dalam 5 dtk" 'ERROR'; return 1 }
        default                         { Write-GuardLog "Tahap 4: TerminateProcess gagal (pid $ProcessId)" 'ERROR'; return 1 }
    }
}

# ---------------------------------------------------------------------
# Alur utama.
# ---------------------------------------------------------------------
try {
    # Bukan SYSTEM: tolak tanpa menulis apa pun (log hanya boleh ditulis oleh SYSTEM).
    if ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -ne 'S-1-5-18') { exit 2 }
    Import-GuardInterop
    $script:Targets = Resolve-GuardTargets
    if (-not $script:Targets) { Write-GuardLog "Service '$ServiceName' tidak terpasang" 'WARN'; exit 0 }

    Write-GuardLog "Permintaan diterima: $Request"
    if ($Request -eq 'stop-service') {
        if (Stop-ArmouryService) { exit 0 }
        Write-GuardLog 'Gagal menghentikan service' 'ERROR'
        exit 1
    }
    exit (Close-PopupOwner ([uint32]$Request.Split(':')[1]))
} catch {
    Write-GuardLog ("Error: {0}" -f $_.Exception.Message) 'ERROR'
    exit 3
}
