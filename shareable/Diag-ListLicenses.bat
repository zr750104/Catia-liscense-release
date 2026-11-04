@echo off
rem Step 1: list the shareable licenses CATIA reports (CATIA must be running).
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0CatiaShareableGuard.ps1" -ConfigPath "%~dp0config.json" -ListLicenses
pause
