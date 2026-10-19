@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-loop.ps1" %*
pause
