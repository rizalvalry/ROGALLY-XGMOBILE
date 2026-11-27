# ROG Ally + XG Mobile: auto `net stop` Armoury Crate SE

Mencegah pop-up bug **"Activate / Deactivate the ROG XG Mobile"** dari Armoury Crate SE dengan cara
yang terbukti berhasil secara manual — menjalankan:

```
net stop "ARMOURY CRATE SE Service"
```

secara otomatis **10 detik setelah login**.

## Pasang (juga setelah instal ulang Windows)

1. Unduh / clone repo ini.
2. Klik kanan **`install.cmd`** → **Run as administrator**.

Selesai. Task `\ROGAlly\XGMobile-NetStop` terdaftar di Task Scheduler.

## Hapus

Klik kanan **`uninstall.cmd`** → **Run as administrator**.

## Cara kerja

| | |
|---|---|
| Pemicu | Login user, tunda 10 detik |
| Berjalan sebagai | SYSTEM (tanpa jendela, tanpa skrip tambahan) |
| Perintah | `net stop "ARMOURY CRATE SE Service"`; bila ditolak karena service belum selesai start, tunggu 20 detik lalu coba sekali lagi |
| Beban | Selesai dalam 1–2 detik (maks. ~22 detik bila perlu mengulang). Tidak ada pemantauan, tidak ada proses yang tertinggal |

Definisi task ada di [`XGMobile-NetStop.xml`](XGMobile-NetStop.xml).

## Catatan

- Selama service berhenti, fitur Armoury Crate SE (profil performa, Command Center) tidak aktif sampai
  reboot berikutnya — sama seperti saat `net stop` dijalankan manual. Driver NVIDIA / eGPU tidak terpengaruh.
- Dengan Fast Startup aktif, *Shut down* menyimpan status service; *Restart* selalu boot penuh.
- "Last Run Result" `0x2` berarti service memang sudah tidak berjalan (misalnya sudah dihentikan manual) — normal.
- Versi lama (guard pendeteksi pop-up) dihapus karena pop-up bisa muncul beberapa menit setelah boot,
  di luar jendela pantauannya. Kodenya tetap tersedia di riwayat git (commit `6148ec9`).

## Folder `XG MOBILE SETUP/`

Arsip pendukung setup eGPU (driver XG Mobile, nvidia-error43-fixer). Lihat README di folder tersebut.
