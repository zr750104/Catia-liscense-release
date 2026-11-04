@echo off
rem Step 3: request the licenses listed in config.json "Licenses" once.
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0CatiaShareableGuard.ps1" -ConfigPath "%~dp0config.json" -RequestNow
pause
