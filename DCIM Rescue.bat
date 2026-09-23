@echo off
rem Opens the DCIM Rescue window.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0src\iPhoneCopyGUI.ps1"
