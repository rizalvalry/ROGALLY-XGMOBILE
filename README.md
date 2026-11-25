# XG Mobile Popup Guard (ROG Ally + XG Mobile)

Menghentikan otomatis pop-up bug **"Activate / Deactivate the ROG XG Mobile"** dari Armoury Crate SE
yang muncul berulang setelah boot, login, unlock, atau bangun dari sleep, dengan cara menghentikan
`ARMOURY CRATE SE Service` **hanya ketika pop-up tersebut benar-benar terdeteksi**.
Tidak menyentuh proses atau driver NVIDIA.

## Cara pakai tercepat (setelah instal ulang Windows)

1. Unduh `dist/XGPopupGuard-Setup.exe`.
2. Disarankan: salin ke folder khusus admin, lalu cek hash dari PowerShell **Administrator**:
   ```powershell
   New-Item -ItemType Directory "C:\Program Files\XGPopupGuard-dist" -Force | Out-Null
   Copy-Item .\XGPopupGuard-Setup.exe "C:\Program Files\XGPopupGuard-dist\"
   Get-FileHash "C:\Program Files\XGPopupGuard-dist\XGPopupGuard-Setup.exe"
   ```
   SHA256 v1.1: `CAA774EEC6A6E3C0638E7479380B4CD7332533249DA1B3410A1EF21DAB1370F5`
3. Jalankan exe tersebut → setujui UAC → pilih **[1] Install / Update**.
   (File tidak ditandatangani: SmartScreen akan menampilkan "Unknown publisher" → *More info* → *Run anyway*.)

Mode tanpa menu: `XGPopupGuard-Setup.exe /install /quiet` atau `/uninstall /quiet`.

## Cara kerja

| Komponen | Berjalan sebagai | Tugas |
|---|---|---|
| Task `\ROGAlly\XGPopupGuard` → `XGPopupGuard.ps1` | User, **tanpa elevasi** | Saat logon / unlock / wake (Kernel-Power 507, 107, Power-Troubleshooter 1), memantau 90 dtk (cek tiap 2 dtk) jendela berjudul "XG Mobile" milik proses Armoury Crate SE |
| Task `\ROGAlly\XGPopupGuard-Escalate` → `XGPopupGuard.Escalate.ps1` | **SYSTEM** (dipicu detektor) | **Tahap 1** stop normal (setara `net stop`) · **Tahap 2** bila macet/Error 1053: kill `ArmouryCrateSE.Service.exe` terverifikasi · **Tahap 3** stop ulang bila SCM me-restart service · **Tahap 4** bila service Stopped tapi pop-up masih ada: tutup proses pemilik pop-up (terverifikasi di folder Armoury Crate, sesi user, bukan service) |

- Detektor tidak memegang hak admin; semua tindakan berhak tinggi divalidasi ulang oleh task SYSTEM.
- Akun user hanya boleh **menjalankan** task SYSTEM (SDDL `FRFX`), tidak bisa mengubah/menghapusnya.
- Terpasang di `C:\Program Files\XGPopupGuard` (ACL: Administrators/SYSTEM penuh, Users baca).

## Log

- Detektor: `%LOCALAPPDATA%\XGPopupGuard\guard.log`
- SYSTEM: `C:\Program Files\XGPopupGuard\logs\escalate.log`

"Last Run Result" task detektor selalu `0x0` (dijalankan lewat `conhost --headless` agar tanpa jendela) — status sebenarnya ada di `guard.log`.

## Instalasi manual (tanpa exe)

Dari PowerShell **Administrator**, salin folder repo ke lokasi khusus admin lalu:
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Program Files\XGPopupGuard-setup\Install-XGPopupGuard.ps1"
# uninstall:
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Program Files\XGPopupGuard-setup\Install-XGPopupGuard.ps1" -Uninstall
```

SHA256 file sumber:
```
55E655670D5546D4290A1BE12F0191487066E99F13CA06C508F4431FE9E4EFDB  Install-XGPopupGuard.ps1
D9CABAB19F06C7C1D19249A54A7227DB25A648702C9FFA33ADD9FC64327D8F7B  XGPopupGuard.ps1
8224EB596863AA8BF1F4BB596733AB7581F30952668A54A3CBE4EB0479E892A3  XGPopupGuard.Escalate.ps1
2DED92F131926FF96AD817C7AA8B49F51DC4C35EDA4DAD00F0037E939E89EABE  XGGuard.Common.ps1
BE5EBD72954318EA38697624CC2B1D0EF08FFD98D64C3D58108CA34B3A99FDC1  XGGuard.Win32.cs
```

## Verifikasi setelah instalasi (PowerShell biasa)

```powershell
Get-ScheduledTask -TaskPath '\ROGAlly\' | Select TaskName, State
Start-ScheduledTask -TaskPath '\ROGAlly\' -TaskName 'XGPopupGuard'; Start-Sleep 5
Get-Content "$env:LOCALAPPDATA\XGPopupGuard\guard.log" -Tail 5
```

Uji dry-run saat pop-up sedang tampil (tidak menghentikan apa pun):
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Program Files\XGPopupGuard\XGPopupGuard.ps1" -DryRun -DurationSeconds 60
```

## Build ulang exe

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\build\build.ps1
```
Memakai `csc.exe` bawaan .NET Framework 4.8 (sudah ada di Windows 11); hasil di `dist\XGPopupGuard-Setup.exe`.

## Catatan keamanan

- **UAC:** jika UAC diatur tanpa prompt (`ConsentPromptBehaviorAdmin = 0`), program apa pun di akun user
  bisa memperoleh hak admin diam-diam dan seluruh pengamanan ini menjadi kurang berarti. Gunakan level default
  ("Notify me only when apps try to make changes…").
- Setup exe menolak berjalan bila menemukan variabel pembajak proses .NET (`COR_PROFILER`, `COMPLUS_*`,
  `APPDOMAIN_MANAGER_*`, dll.) atau file `.exe.config` asing, dan memperingatkan bila dijalankan dari folder
  yang bisa diubah tanpa hak admin.
- Risiko yang diterima: program yang berjalan sebagai user bisa memicu task SYSTEM untuk menghentikan service
  Armoury Crate atau menutup proses dari folder Armoury Crate SE (dampak terburuk: fitur ASUS terganggu).

## Persyaratan

Windows 11, ROG Ally dengan Armoury Crate SE, akun administrator lokal, .NET Framework 4.8 (bawaan).
