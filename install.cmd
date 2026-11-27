@echo off
setlocal
title XG Mobile - pasang auto net stop
net session >nul 2>&1
if errorlevel 1 (
  echo [GAGAL] Jalankan file ini sebagai Administrator: klik kanan ^> Run as administrator.
  pause & exit /b 1
)
schtasks /create /tn "\ROGAlly\XGMobile-NetStop" /xml "%~dp0XGMobile-NetStop.xml" /ru SYSTEM /f
if errorlevel 1 (
  echo [GAGAL] Task tidak bisa didaftarkan.
  pause & exit /b 1
)
echo.
echo [OK] Task \ROGAlly\XGMobile-NetStop terpasang.
echo      10 detik setelah login, Windows menjalankan: net stop "ARMOURY CRATE SE Service"
pause