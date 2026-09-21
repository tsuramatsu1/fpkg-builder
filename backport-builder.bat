@echo off
setlocal
start "PS5 Backport Builder" powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0backport-builder-gui.ps1"
