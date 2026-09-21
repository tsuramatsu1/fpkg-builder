@echo off
setlocal
start "Backport Update Builder" powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0backport-gui.ps1"
