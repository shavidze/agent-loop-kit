@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0stop-loop.ps1" %*
pause
