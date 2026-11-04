@echo off
rem Test launcher: 1 minute idle, 20 second warning, console visible.
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0CatiaShareableGuard.ps1" -ConfigPath "%~dp0config.json" -IdleMinutes 1 -WarningSeconds 20
pause
