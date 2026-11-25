#Requires -Version 5.1
<#
.SYNOPSIS
    Memasang / melepas XG Mobile Popup Guard (detektor user + eskalasi SYSTEM).

.DESCRIPTION
    Sebelum menjalankan, cocokkan SHA256 file ini:  Get-FileHash .\Install-XGPopupGuard.ps1
    Lalu jalankan dari PowerShell **Administrator**:
        powershell -NoProfile -ExecutionPolicy Bypass -File D:\XGPopupGuard\Install-XGPopupGuard.ps1

    Langkah:
      1. Membaca file sumber SEKALI ke memori, menampilkan SHA256, meminta konfirmasi.
         Byte yang sama persis yang ditulis ke folder instalasi (tidak dibaca ulang).
      2. Membuat ulang C:\Program Files\XGPopupGuard (user biasa tidak bisa membuat
         folder di sana) dengan DACL terkunci; owner & ACE setiap item diverifikasi.
      3. Mengompilasi XGGuard.Interop.dll dari salinan terkunci.
      4. Task \ROGAlly\XGPopupGuard         : detektor, user interaktif, TANPA elevasi.
         Task \ROGAlly\XGPopupGuard-Escalate: SYSTEM, tanpa pemicu; hanya user target
                                              (plus admin/SYSTEM) yang boleh menjalankannya.

.EXAMPLE
    .\Install-XGPopupGuard.ps1               # pasang
    .\Install-XGPopupGuard.ps1 -Uninstall    # lepas
#>
[CmdletBinding()]
param(
    [switch]$Uninstall,
    [string]$UserName = '',
    [switch]$SkipHashPrompt
)

$env:PSModulePath = [IO.Path]::Combine($PSHOME, 'Modules')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TaskFolder   = '\ROGAlly'
$DetectorTask = 'XGPopupGuard'
$EscalateTask = 'XGPopupGuard-Escalate'
$SourceFiles  = @('XGPopupGuard.ps1', 'XGPopupGuard.Escalate.ps1', 'XGGuard.Common.ps1', 'XGGuard.Win32.cs')

# Path dari API/HKLM, bukan variabel environment.
$SystemDir = [Environment]::SystemDirectory
$hklm = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion')
$ProgramFiles = [string]$hklm.GetValue('ProgramFilesDir'); $hklm.Close()
if ([string]::IsNullOrWhiteSpace($ProgramFiles) -or -not [IO.Directory]::Exists($ProgramFiles)) { throw 'ProgramFilesDir HKLM tidak valid.' }
$InstallDir = [IO.Path]::Combine($ProgramFiles, 'XGPopupGuard')
$LogDir     = [IO.Path]::Combine($InstallDir, 'logs')
$InteropDll = [IO.Path]::Combine($InstallDir, 'XGGuard.Interop.dll')

$AllowedSids = @{ 'S-1-5-32-544' = 'FullControl'; 'S-1-5-18' = 'FullControl'; 'S-1-5-32-545' = 'ReadAndExecute' }
$AllowedOwners = @('S-1-5-32-544', 'S-1-5-18', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw 'Jalankan PowerShell sebagai Administrator.' }

function Write-Step([string]$Msg) { Write-Host ("[{0:HH:mm:ss}] {1}" -f [DateTime]::Now, $Msg) }

function Get-Sha256Hex([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes)) -replace '-', '') } finally { $sha.Dispose() }
}

# Menghapus folder instalasi tanpa pernah mengikuti junction/symlink.
function Remove-InstallDir {
    if (-not ([IO.Directory]::Exists($InstallDir) -or [IO.File]::Exists($InstallDir))) { return }
    $attr = [IO.File]::GetAttributes($InstallDir)
    if ($attr -band [IO.FileAttributes]::ReparsePoint) { [IO.Directory]::Delete($InstallDir); return }
    if (-not ($attr -band [IO.FileAttributes]::Directory)) { [IO.File]::Delete($InstallDir); return }
    & ([IO.Path]::Combine($SystemDir, 'cmd.exe')) /d /c rmdir /s /q $InstallDir
    if ([IO.Directory]::Exists($InstallDir)) { throw "Gagal menghapus $InstallDir" }
}

function New-LockedDirectorySecurity {
    $sec = New-Object System.Security.AccessControl.DirectorySecurity
    $sec.SetAccessRuleProtection($true, $false)
    $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    foreach ($sid in $AllowedSids.Keys) {
        $sec.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
            (New-Object Security.Principal.SecurityIdentifier($sid)),
            [System.Security.AccessControl.FileSystemRights]$AllowedSids[$sid],
            $inherit, [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Allow)))
    }
    $sec.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    return $sec
}

# Setiap item: bukan reparse point, owner = Administrators/SYSTEM/TrustedInstaller,
# dan tidak ada ACE di luar daftar izin.
function Assert-LockedAcl {
    $items = @(Get-Item -LiteralPath $InstallDir -Force) + @(Get-ChildItem -LiteralPath $InstallDir -Recurse -Force)
    foreach ($item in $items) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse point tak terduga: $($item.FullName)" }
        $acl = Get-Acl -LiteralPath $item.FullName
        $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
        if ($AllowedOwners -notcontains $owner) { throw "Owner tak terduga ($owner) pada $($item.FullName)" }
        foreach ($ace in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
            if (-not $AllowedSids.ContainsKey($ace.IdentityReference.Value)) {
                throw "ACE tak terduga ($($ace.IdentityReference.Value)) pada $($item.FullName)"
            }
        }
    }
}

function Resolve-InteractiveUser {
    $sessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
    $explorer = Get-CimInstance Win32_Process -Filter "Name='explorer.exe' AND SessionId=$sessionId" | Select-Object -First 1
    if ($explorer) {
        $owner = Invoke-CimMethod -InputObject $explorer -MethodName GetOwner
        if ($owner.ReturnValue -eq 0) { return "$($owner.Domain)\$($owner.User)" }
    }
    return [Security.Principal.WindowsIdentity]::GetCurrent().Name
}

function Get-TaskService { $s = New-Object -ComObject Schedule.Service; $s.Connect(); return $s }

function Remove-GuardTasks {
    $sched = Get-TaskService
    $folder = $null
    try { $folder = $sched.GetFolder($TaskFolder) } catch { return }
    foreach ($name in $DetectorTask, $EscalateTask) {
        try { $t = $folder.GetTask($name); try { $t.Stop(0) } catch { }; $folder.DeleteTask($name, 0); Write-Step "Task $TaskFolder\$name dihapus" } catch { }
    }
    try {
        if ($folder.GetTasks(1).Count -eq 0 -and $folder.GetFolders(0).Count -eq 0) { $sched.GetFolder('\').DeleteFolder($TaskFolder.TrimStart('\'), 0) }
    } catch { }
}

$esc = { param($s) [Security.SecurityElement]::Escape([string]$s) }

# =====================================================================
# UNINSTALL
# =====================================================================
if ($Uninstall) {
    Remove-GuardTasks
    Remove-InstallDir
    Write-Step "Folder $InstallDir dihapus. Log detektor (per user) di %LOCALAPPDATA%\XGPopupGuard dibiarkan."
    return
}

# =====================================================================
# INSTALL
# =====================================================================
# 1. Baca sumber SEKALI ke memori; hash dan instalasi memakai byte yang sama.
$payload = [ordered]@{}
foreach ($f in $SourceFiles) {
    $src = [IO.Path]::Combine($PSScriptRoot, $f)
    if (-not [IO.File]::Exists($src)) { throw "File sumber hilang: $f" }
    $payload[$f] = [IO.File]::ReadAllBytes($src)
}
Write-Step 'SHA256 file yang akan dipasang:'
foreach ($f in $payload.Keys) { Write-Host ("    {0}  {1}" -f (Get-Sha256Hex $payload[$f]), $f) }
if (-not $SkipHashPrompt) {
    if ((Read-Host 'Cocok dengan hash yang diberikan? Ketik Y untuk lanjut') -ne 'Y') { throw 'Dibatalkan oleh pengguna.' }
}

# 2. User target: pemilik desktop interaktif (bukan akun admin yang dipakai saat UAC).
#    Detektor berjalan tanpa elevasi, jadi tidak perlu keanggotaan Administrators.
if ([string]::IsNullOrWhiteSpace($UserName)) { $UserName = Resolve-InteractiveUser }
$userSid = (New-Object Security.Principal.NTAccount($UserName)).Translate([Security.Principal.SecurityIdentifier]).Value
if ($userSid -notmatch '^S-1-5-21-\d+-\d+-\d+-\d+$') { throw "SID user tidak valid: $userSid" }
Write-Step "User target: $UserName ($userSid)"

# 3. Folder instalasi terkunci.
Remove-GuardTasks
Remove-InstallDir
$sec = New-LockedDirectorySecurity
[void][IO.Directory]::CreateDirectory($InstallDir, $sec)
[IO.Directory]::SetAccessControl($InstallDir, $sec)
if (@(Get-ChildItem -LiteralPath $InstallDir -Force).Count -gt 0) { throw 'Folder instalasi berisi file tak terduga. Dibatalkan.' }
[void][IO.Directory]::CreateDirectory($LogDir)
foreach ($f in $payload.Keys) { [IO.File]::WriteAllBytes([IO.Path]::Combine($InstallDir, $f), $payload[$f]) }
foreach ($f in $payload.Keys) {
    if ((Get-Sha256Hex ([IO.File]::ReadAllBytes([IO.Path]::Combine($InstallDir, $f)))) -ne (Get-Sha256Hex $payload[$f])) { throw "Verifikasi salinan gagal: $f" }
}

# 4. Kompilasi interop dari salinan terkunci; TEMP dialihkan ke folder terkunci.
$tmp = [IO.Path]::Combine($InstallDir, 'tmp')
[void][IO.Directory]::CreateDirectory($tmp)
$oldTmp, $oldTemp = $env:TMP, $env:TEMP
try {
    $env:TMP = $tmp; $env:TEMP = $tmp
    Add-Type -Path ([IO.Path]::Combine($InstallDir, 'XGGuard.Win32.cs')) -OutputAssembly $InteropDll -OutputType Library
} finally {
    $env:TMP, $env:TEMP = $oldTmp, $oldTemp
    & ([IO.Path]::Combine($SystemDir, 'cmd.exe')) /d /c rmdir /s /q $tmp
}
if (-not [IO.File]::Exists($InteropDll)) { throw 'Kompilasi XGGuard.Interop.dll gagal.' }
Assert-LockedAcl
Write-Step "Terpasang & terverifikasi: $InstallDir"

# 5. Task SYSTEM (eskalasi). Tanpa pemicu; dijalankan detektor via Run("<permintaan>").
#    $(Arg0) diletakkan SETELAH -File sehingga hanya menjadi nilai parameter -Request
#    (divalidasi regex), tidak pernah dieksekusi sebagai kode.
$powershellExe = [IO.Path]::Combine($SystemDir, 'WindowsPowerShell\v1.0\powershell.exe')
$conhostExe    = [IO.Path]::Combine($SystemDir, 'conhost.exe')
$escalateArgs  = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Request "$(Arg0)"' -f [IO.Path]::Combine($InstallDir, 'XGPopupGuard.Escalate.ps1')

$escalateXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>$(& $esc "Eskalasi SYSTEM untuk XGPopupGuard: stop ArmouryCrateSEService (Tahap 1-3) dan tutup pemilik pop-up XG Mobile (Tahap 4). Log: $LogDir\escalate.log")</Description>
  </RegistrationInfo>
  <Triggers />
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>Queue</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>false</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings><StopOnIdleEnd>false</StopOnIdleEnd><RestartOnIdle>false</RestartOnIdle></IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT3M</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$(& $esc $powershellExe)</Command>
      <Arguments>$(& $esc $escalateArgs)</Arguments>
    </Exec>
  </Actions>
</Task>
"@

# 6. Task detektor: user interaktif, TANPA elevasi (LeastPrivilege). Pemicu:
#    - Logon (tunda 30 dtk) : menggantikan "At startup" - desktop belum ada sebelum logon;
#                             tunda 30 dtk agar service AUTO_START sudah start (tanpa polling)
#    - Kernel-Power 507     : keluar dari Modern Standby (sleep di ROG Ally)
#    - Kernel-Power 107 / Power-Troubleshooter 1 : resume dari hibernate / S3
$query = @"
<QueryList>
  <Query Id="0" Path="System">
    <Select Path="System">*[System[Provider[@Name='Microsoft-Windows-Kernel-Power'] and (EventID=507 or EventID=107)]]</Select>
    <Select Path="System">*[System[Provider[@Name='Microsoft-Windows-Power-Troubleshooter'] and EventID=1]]</Select>
  </Query>
</QueryList>
"@
$detectorArgs = '--headless "{0}" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{1}" -Trigger task' -f $powershellExe, [IO.Path]::Combine($InstallDir, 'XGPopupGuard.ps1')

$detectorXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>$(& $esc "Detektor pop-up 'Activate/Deactivate the ROG XG Mobile' (tanpa elevasi). Log: %LOCALAPPDATA%\XGPopupGuard\guard.log")</Description>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger><Enabled>true</Enabled><UserId>$userSid</UserId><Delay>PT30S</Delay></LogonTrigger>
    <EventTrigger><Enabled>true</Enabled><Subscription>$(& $esc $query)</Subscription></EventTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$userSid</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>false</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings><StopOnIdleEnd>false</StopOnIdleEnd><RestartOnIdle>false</RestartOnIdle></IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT10M</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$(& $esc $conhostExe)</Command>
      <Arguments>$(& $esc $detectorArgs)</Arguments>
    </Exec>
  </Actions>
</Task>
"@

# 7. Registrasi via COM. Task SYSTEM diberi security descriptor:
#    Administrators & SYSTEM = penuh, user target = baca + jalankan (FRFX, hak spesifik; tidak bisa mengubah).
$sched = Get-TaskService
$root = $sched.GetFolder('\')
try { $folder = $sched.GetFolder($TaskFolder) } catch { $folder = $root.CreateFolder($TaskFolder.TrimStart('\'), $null) }

$TASK_CREATE_OR_UPDATE = 6
$escalateSddl = "D:P(A;;FA;;;BA)(A;;FA;;;SY)(A;;FRFX;;;$userSid)"
[void]$folder.RegisterTask($EscalateTask, $escalateXml, $TASK_CREATE_OR_UPDATE, 'SYSTEM', $null, 5, $escalateSddl)
[void]$folder.RegisterTask($DetectorTask, $detectorXml, $TASK_CREATE_OR_UPDATE, $userSid, $null, 3, $null)

foreach ($name in $EscalateTask, $DetectorTask) {
    $t = $folder.GetTask($name)
    Write-Step ("Task {0}\{1} terdaftar (enabled: {2})" -f $TaskFolder, $name, $t.Enabled)
}
Write-Host  "    Uji detektor : Start-ScheduledTask -TaskPath '$TaskFolder\' -TaskName '$DetectorTask'"
Write-Host  "    Log detektor : %LOCALAPPDATA%\XGPopupGuard\guard.log"
Write-Host  "    Log SYSTEM   : $LogDir\escalate.log"
