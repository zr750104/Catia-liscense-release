@echo off
rem Test launcher: 1 minute idle, 20 second warning, console visible for log output.
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0CatiaIdleGuard.ps1" -IdleMinutes 1 -WarningSeconds 20
pause
