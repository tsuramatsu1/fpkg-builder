@echo off
setlocal
start "fPKG Builder" powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0fpkg-builder-gui.ps1"
