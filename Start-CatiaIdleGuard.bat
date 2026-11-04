@echo off
rem CATIA Idle Guard launcher (Windows PowerShell 5.1, hidden window, tray icon)
rem Do not run as Administrator: COM connection to CATIA requires the same privilege level.
start "" /min powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0CatiaIdleGuard.ps1" -ConfigPath "%~dp0config.json"
