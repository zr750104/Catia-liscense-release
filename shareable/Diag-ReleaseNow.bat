@echo off
rem Step 2: release the shareable licenses once. Check Tools > Options > Licensing > Shareable Products afterwards.
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0CatiaShareableGuard.ps1" -ConfigPath "%~dp0config.json" -ReleaseNow
pause
