@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0monitor-oscar.ps1"
exit /b %ERRORLEVEL%