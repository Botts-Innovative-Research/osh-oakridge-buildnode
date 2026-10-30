@echo off
setlocal EnableExtensions DisableDelayedExpansion

set "OSCAR_SETUP=%~dp0oscar-setup.ps1"
set "OSCAR_LAUNCHER=%~f0"
set "OSCAR_DIRECTORY=%~dp0"

if /I "%~1"=="--menu" goto menu
if not "%~1"=="" goto command

rem A no-argument launch is the administrator-friendly, double-click path.
rem Relaunch once with UAC elevation so init/start/stop/upgrade work from the menu.
net session >nul 2>&1
if errorlevel 1 (
    echo Requesting administrator permission for OSCAR administration...
    powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command ^
        "Start-Process -FilePath $env:OSCAR_LAUNCHER -ArgumentList '--menu' -WorkingDirectory $env:OSCAR_DIRECTORY -Verb RunAs" ^
        2>nul
    if errorlevel 1 (
        echo OSCAR could not obtain administrator permission.
        pause
        exit /b 1
    )
    exit /b 0
)
goto menu

:command
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%OSCAR_SETUP%" %*
exit /b %errorlevel%

:menu
title OSCAR Administration
cd /d "%~dp0"

:menu_loop
cls
echo OSCAR Administration
echo ====================
echo.
echo Enter a command and any options. Examples:
echo   init
echo   init -Hostname oscar.local -Port 443
echo   init -Hostname oscar.local -TlsSan oscar-site.example.org
echo   start
echo   stop
echo   restart
echo   status
echo   logs -Service oscar -Tail 200
echo   logs -Service postgres -Follow
echo   check
echo   verify
echo   upgrade
echo   backup
echo   backup-verify -BackupId BACKUP_ID
echo   restore -BackupId BACKUP_ID -Confirm BACKUP_ID
echo   archive status
echo   archive verify
echo   archive hold list
echo   archive hold create -StoreKey KEY -IdScope INT -Generation UUID -Reason "legal hold"
echo   archive hold release -HoldId UUID
echo   archive dry-run -StoreKey KEY -IdScope INT -Before 2026-01-01T00:00:00Z
echo   archive purge -StoreKey KEY -IdScope INT -Plan UUID -Token TOKEN
echo   help
echo.
echo Enter exit to close this window.
echo.
set "OSCAR_INPUT="
set /p "OSCAR_INPUT=oscar> "
if not defined OSCAR_INPUT goto menu_loop
if /I "%OSCAR_INPUT%"=="exit" exit /b 0
if /I "%OSCAR_INPUT%"=="quit" exit /b 0

echo.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%OSCAR_SETUP%" %OSCAR_INPUT%
set "OSCAR_RESULT=%errorlevel%"
echo.
if not "%OSCAR_RESULT%"=="0" echo Command failed with exit code %OSCAR_RESULT%.
pause
goto menu_loop
