#Requires -Version 5.1
<#
.SYNOPSIS
    XG Mobile Popup Guard (DETEKTOR) - berjalan TANPA elevasi sebagai user interaktif.

.DESCRIPTION
    Dijalankan oleh task \ROGAlly\XGPopupGuard saat logon, unlock, dan wake.
    Memantau jendela top-level selama -DurationSeconds (default 90 dtk), interval
    -IntervalSeconds (default 2 dtk). Jika jendela berjudul "XG Mobile" milik proses
    Armoury Crate SE terdeteksi, detektor meminta task SYSTEM
    \ROGAlly\XGPopupGuard-Escalate untuk:
        Tahap 1-3 : "stop-service"      - stop normal, force-kill terverifikasi bila
                                           macet (Error 1053), stop ulang bila SCM
                                           me-restart service.
        Tahap 4   : "close-owner:<PID>" - hanya bila service sudah Stopped tetapi
                                           jendela pop-up MASIH terlihat; menutup proses
                                           pemilik jendela (mis. GPUSwitchDialog.exe).
    Detektor sendiri tidak memegang hak admin, sehingga environment user (yang bisa
    diubah malware tanpa admin) tidak pernah berjalan dengan hak tinggi.

    Kode keluar: 0 = selesai / tidak ada pop-up | 1 = eskalasi gagal | 3 = error

.PARAMETER DryRun
    Deteksi dan catat saja, tanpa meminta eskalasi. Semua judul jendela milik Armoury
    Crate juga dicatat untuk memastikan judul pop-up yang sebenarnya.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Program Files\XGPopupGuard\XGPopupGuard.ps1" -DryRun -DurationSeconds 60
#>
[CmdletBinding()]
param(
    [ValidateRange(10, 600)][int]$DurationSeconds = 90,
    [ValidateRange(1, 10)][int]$IntervalSeconds = 2,
    [ValidatePattern('^[A-Za-z0-9_-]{1,32}$')][string]$Trigger = 'manual',
    [string]$LogPath = '',
    [switch]$DryRun
)

# 0. Hanya modul sistem PowerShell (param block di atas sengaja tanpa cmdlet).
$env:PSModulePath = [IO.Path]::Combine($PSHOME, 'Modules')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = $PSScriptRoot
$LogTag    = $Trigger
if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $LogPath = [IO.Path]::Combine([Environment]::GetFolderPath('LocalApplicationData'), 'XGPopupGuard\guard.log')
}
. ([IO.Path]::Combine($ScriptDir, 'XGGuard.Common.ps1'))

$TitlePattern      = 'XG\s*Mobile'
# Dipakai hanya jika path pemilik tidak terbaca (mis. pop-up dijalankan ASUS sebagai SYSTEM
# sehingga detektor tanpa elevasi tidak bisa membuka prosesnya): judul harus persis.
$ExactTitlePattern = '^\s*(Activate|Deactivate) the ROG XG Mobile\s*$'
$EscalateFolder    = '\ROGAlly'
$EscalateTask      = 'XGPopupGuard-Escalate'
$EscalateTimeoutSeconds = 200
$CloseWaitSeconds  = 10

# =====================================================================
# 1. DETEKSI POP-UP
#    Syarat: judul mengandung "XG Mobile" DAN path proses pemilik (dari kernel)
#    berada di folder Armoury Crate SE. Path tak terbaca = tidak valid (fail-safe).
#    Jendela yang diabaikan dicatat sekali saja.
# =====================================================================
$script:SeenHandles = New-Object 'System.Collections.Generic.HashSet[long]'

function Find-XgMobilePopup {
    foreach ($w in [XGGuard.Win32]::GetVisibleTitledWindows()) {
        $isMatch = $w.Title -match $TitlePattern
        if (-not $isMatch -and -not $DryRun) { continue }
        $path  = [XGGuard.Win32]::GetProcessImagePath($w.ProcessId)
        $owned = Test-ArmouryOwner $path $script:Targets
        $unreadableExact = $isMatch -and -not $path -and ($w.Title -match $ExactTitlePattern)

        if ($isMatch -and ($owned -or $unreadableExact)) {
            if ($unreadableExact -and $script:SeenHandles.Add($w.Handle)) {
                Write-GuardLog ("Path pemilik '{0}' (pid {1}) tidak terbaca tanpa elevasi; judul cocok persis - diteruskan, task SYSTEM memverifikasi ulang" -f $w.Title, $w.ProcessId) 'WARN'
            }
            return [pscustomobject]@{ Title = $w.Title; ProcessId = $w.ProcessId; Path = $(if ($path) { $path } else { '<tidak terbaca>' }); Handle = $w.Handle }
        }
        if (-not $script:SeenHandles.Add($w.Handle)) { continue }
        if ($isMatch) {
            Write-GuardLog ("Diabaikan: '{0}' (pid {1}, owner '{2}') bukan proses Armoury Crate" -f $w.Title, $w.ProcessId, $path) 'WARN'
        } elseif ($owned) {
            Write-GuardLog ("DRY-RUN info: jendela Armoury Crate '{0}' ({1})" -f $w.Title, $path)
        }
    }
    return $null
}

# =====================================================================
# 2. EKSEKUSI LEWAT TASK SYSTEM
#    RegisteredTask.Run(arg) mengisi $(Arg0) pada aksi task SYSTEM. Task SYSTEM
#    memvalidasi ulang semuanya (format permintaan, path proses, status service),
#    jadi detektor tidak perlu dipercaya.
# =====================================================================
#    Detektor MENUNGGU instance task SYSTEM selesai (bukan hanya melihat status service),
#    karena setelah force-kill task SYSTEM masih mengawasi restart oleh SCM. Hasil diambil
#    dari LastTaskResult: 0 = berhasil, 1 = gagal, 2 = ditolak validasi, 3 = error.
function Invoke-Escalation([string]$Request) {
    try {
        $sched = New-Object -ComObject Schedule.Service
        $sched.Connect()
        $folder = $sched.GetFolder($EscalateFolder)
        $before = $folder.GetTask($EscalateTask).LastRunTime
        [void]$folder.GetTask($EscalateTask).Run($Request)
        Write-GuardLog "Permintaan '$Request' dikirim ke task SYSTEM; menunggu selesai"

        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($sw.Elapsed.TotalSeconds -lt $EscalateTimeoutSeconds) {
            Start-Sleep -Seconds 1
            $t = $folder.GetTask($EscalateTask)
            # State: 2 = Queued, 4 = Running. Selesai = sudah pernah jalan setelah Run() dan tidak sedang antre/jalan.
            if ($t.LastRunTime -ne $before -and $t.State -ne 2 -and $t.State -ne 4) {
                $result = [int]$t.LastTaskResult
                Write-GuardLog ("Task SYSTEM selesai: '{0}' -> hasil {1}" -f $Request, $result) $(if ($result -eq 0) { 'INFO' } else { 'WARN' })
                return $result
            }
        }
        Write-GuardLog "Task SYSTEM tidak selesai dalam $EscalateTimeoutSeconds dtk" 'ERROR'
        return -1
    } catch {
        Write-GuardLog ("Gagal menjalankan task SYSTEM '{0}\{1}': {2}" -f $EscalateFolder, $EscalateTask, $_.Exception.Message) 'ERROR'
        return -1
    }
}

function Wait-PopupGone([int]$TimeoutSeconds) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if (-not (Find-XgMobilePopup)) { return $true }
        Start-Sleep -Seconds 1
    }
    return (-not (Find-XgMobilePopup))
}

# =====================================================================
# 3. ALUR UTAMA
#    - Satu instance dijamin Task Scheduler (MultipleInstancesPolicy=IgnoreNew).
#    - Service sudah Stopped DAN uptime > 5 menit -> tidak ada sumber pop-up, exit.
#      Di 5 menit pertama setelah boot tetap memantau (service AUTO_START mungkin
#      belum start saat logon).
#    - Tahap 1-3 lewat "stop-service"; Tahap 4 lewat "close-owner:<PID>" hanya jika
#      service Stopped tetapi pop-up masih ada.
# =====================================================================
try {
    Import-GuardInterop
    $script:Targets = Resolve-GuardTargets
    if (-not $script:Targets) { Write-GuardLog "Service '$ServiceName' tidak terpasang; keluar" 'WARN'; exit 0 }

    $uptimeMin = [XGGuard.Win32]::GetUptimeMilliseconds() / 60000
    Write-GuardLog ("Mulai memantau {0} dtk, interval {1} dtk, uptime {2:N1} mnt{3}" -f $DurationSeconds, $IntervalSeconds, $uptimeMin, $(if ($DryRun) { ' [DRY-RUN]' }))

    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $svc) { Write-GuardLog "Service '$ServiceName' tidak terdaftar di SCM; keluar" 'WARN'; exit 0 }
    if ($svc.Status -eq 'Stopped' -and $uptimeMin -gt 5 -and -not $DryRun) {
        Write-GuardLog 'Service sudah Stopped; tidak ada yang perlu dilakukan'
        exit 0
    }

    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $DurationSeconds) {
        $hit = Find-XgMobilePopup
        if (-not $hit) { Start-Sleep -Seconds $IntervalSeconds; continue }

        Write-GuardLog ("TERDETEKSI: '{0}' (pid {1}, {2}) setelah {3:N0} dtk" -f $hit.Title, $hit.ProcessId, $hit.Path, $sw.Elapsed.TotalSeconds)
        if ($DryRun) { Write-GuardLog 'DRY-RUN: tidak ada tindakan'; exit 0 }

        # Tahap 1-3: hentikan service (dikerjakan task SYSTEM).
        $svc.Refresh()
        if ($svc.Status -ne 'Stopped') {
            [void](Invoke-Escalation 'stop-service')
            $svc.Refresh()
            if ($svc.Status -ne 'Stopped') {
                Write-GuardLog "Service masih $($svc.Status) setelah Tahap 1-3 (lihat escalate.log)" 'ERROR'
                exit 1
            }
            Write-GuardLog 'Service berstatus Stopped'
        }

        # Tahap 4: pop-up masih terlihat walau service sudah Stopped.
        Start-Sleep -Seconds 2
        $still = Find-XgMobilePopup
        if (-not $still) { Write-GuardLog 'Pop-up hilang. Selesai.'; exit 0 }

        Write-GuardLog ("Tahap 4: '{0}' masih terlihat (pid {1}, {2}); minta tutup proses pemilik" -f $still.Title, $still.ProcessId, $still.Path) 'WARN'
        $rc = Invoke-Escalation ("close-owner:{0}" -f $still.ProcessId)
        if ($rc -ne 0) { Write-GuardLog "Tahap 4 tidak berhasil (hasil $rc, lihat escalate.log)" 'ERROR'; exit 1 }
        if (Wait-PopupGone $CloseWaitSeconds) { Write-GuardLog 'Tahap 4 berhasil: pop-up hilang. Selesai.'; exit 0 }
        Write-GuardLog "Pop-up masih terlihat setelah Tahap 4 (lihat escalate.log)" 'ERROR'
        exit 1
    }
    Write-GuardLog "Tidak ada pop-up XG Mobile dalam $DurationSeconds dtk; keluar"
    exit 0
} catch {
    Write-GuardLog ("Error: {0}" -f $_.Exception.Message) 'ERROR'
    exit 3
}
