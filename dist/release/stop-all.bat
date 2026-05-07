@echo off
setlocal EnableExtensions

set "SCRIPT_DIR=%~dp0"
if "%SCRIPT_DIR:~-1%"=="\" set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"

set "ENV_FILE=%SCRIPT_DIR%\.env"
if exist "%ENV_FILE%" call :load_env "%ENV_FILE%"

if not defined CONTAINER_NAME set "CONTAINER_NAME=oscar-postgis-container"

echo Requesting monitor shutdown...
if exist "%SCRIPT_DIR%\monitor-oscar.bat" call "%SCRIPT_DIR%\monitor-oscar.bat" stop >nul 2>nul

echo Stopping SensorHubWrapper Java Process...
for /f "usebackq delims=" %%P in (`
  powershell -NoProfile -ExecutionPolicy Bypass -Command "$procs = Get-CimInstance Win32_Process; foreach ($proc in $procs) { if ($proc.Name -match '^(java|javaw)(\.exe)?$' -and $null -ne $proc.CommandLine -and $proc.CommandLine -like '*com.botts.impl.security.SensorHubWrapper*') { $proc.ProcessId } }" 2^>nul
`) do (
  powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Stop-Process -Id %%P -Force -ErrorAction Stop } catch {}" >nul 2>nul
)

docker ps -a --format "{{.Names}}" | findstr /I /X "%CONTAINER_NAME%" >nul
if not errorlevel 1 (
    echo Stopping container: %CONTAINER_NAME%...
    docker rm -f "%CONTAINER_NAME%" >nul 2>nul
) else (
    echo Container not found: %CONTAINER_NAME%
)

echo.
echo Done.
exit /b 0

:load_env
for /f "usebackq tokens=1,* delims==" %%A in ("%~1") do (
    set "ENV_NAME=%%A"
    set "ENV_VALUE=%%B"
    call :set_env_var
)
exit /b 0

:set_env_var
if not defined ENV_NAME exit /b 0
if "%ENV_NAME:~0,1%"=="#" exit /b 0
if /I "%ENV_NAME:~0,7%"=="export " set "ENV_NAME=%ENV_NAME:~7%"
set "%ENV_NAME%=%ENV_VALUE%"
exit /b 0