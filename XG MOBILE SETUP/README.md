# XG MOBILE SETUP

Arsip pendukung setup eGPU ROG XG Mobile (RTX 2060) di ROG Ally, disimpan apa adanya
(salinan byte-identik dari `D:\XG MOBILE SETUP`) untuk dipakai lagi setelah instal ulang Windows.

| File | SHA256 | Isi |
|---|---|---|
| `XGMDriverSetup.rar` | `F9B642089D82A39A40CB462FD43548C56F137499D5FEC273D1BA9E1ADA86555A` | `XGMDriverSetup.exe` (148 KB) |
| `nvidia-error43-fixer.zip` | `E59A523B3B7D9AAF7A6C5C05B8E5ABB5127810D3CB893D7E583D545D3DDC0407` | `nvidia-error43-fixer.bat`, `devset.bat`, `devcon.exe`, `devcon64.exe` |

## Catatan asal-usul (hasil pemeriksaan, tanpa menjalankan file)

- **`XGMDriverSetup.exe`** — installer **NSIS 3.10**, **tidak ditandatangani digital**, tanpa info publisher/versi,
  meminta hak Administrator. Isi payload tidak terverifikasi. Sebelum menjalankan: cek hash di VirusTotal dan
  pastikan sumbernya tepercaya.
- **`nvidia-error43-fixer`** — skrip komunitas eGPU oleh nando4 (egpu.io), © 2018–2021, untuk mengatasi
  NVIDIA **Error 43** pada eGPU. `devcon.exe` / `devcon64.exe` adalah tool Microsoft (Windows Setup API,
  10.0.17763.1), tidak membawa tanda tangan Authenticode tertanam. Skrip `.bat` membuka halaman donasi
  PayPal penulisnya di akhir proses.

## Urutan pakai setelah instal ulang Windows (saran)

1. Pasang driver NVIDIA terbaru dan driver/dukungan XG Mobile.
2. Jika eGPU muncul dengan **Error 43** di Device Manager: ekstrak `nvidia-error43-fixer.zip`, jalankan
   `nvidia-error43-fixer.bat` sebagai Administrator, lalu restart.
3. Pasang **XG Mobile Popup Guard** dengan `dist/XGPopupGuard-Setup.exe` (lihat README utama).

File pihak ketiga tetap milik penulis/pemegang hak masing-masing.
