@echo off
setlocal
title XG Mobile - hapus auto net stop
net session >nul 2>&1
if errorlevel 1 (
  echo [GAGAL] Jalankan file ini sebagai Administrator: klik kanan ^> Run as administrator.
  pause & exit /b 1
)
schtasks /delete /tn "\ROGAlly\XGMobile-NetStop" /f
if errorlevel 1 ( echo [INFO] Task tidak ditemukan. ) else ( echo [OK] Task dihapus. )
pause