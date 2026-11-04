@echo off
rem CATIA Shareable Guard launcher (hidden window, tray icon). Do not run as Administrator.
start "" /min powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0CatiaShareableGuard.ps1" -ConfigPath "%~dp0config.json"
