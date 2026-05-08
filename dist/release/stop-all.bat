@echo off
setlocal EnableExtensions

set "SCRIPT_DIR=%~dp0"
if "%SCRIPT_DIR:~-1%"=="\" set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"
set "CONTAINER_NAME=oscar-postgis-container"
set "SENSORHUB_NAME=com.botts.impl.security.SensorHubWrapper"

if exist "%SCRIPT_DIR%\.env" (
  for /f "usebackq tokens=* delims=" %%L in ("%SCRIPT_DIR%\.env") do (
    set "LINE=%%L"
    call :parse_env_line
  )
)

echo Requesting monitor stop if active...
if exist "%SCRIPT_DIR%\monitor-oscar.bat" (
    call "%SCRIPT_DIR%\monitor-oscar.bat" stop >nul 2>nul
    timeout /t 5 /nobreak >nul
)

echo.
echo Stopping container: %CONTAINER_NAME%...
docker stop %CONTAINER_NAME% >nul 2>nul
if errorlevel 1 (
    echo Container not found or already stopped.
) else (
    echo Container stop requested.
)

echo.
echo Stopping SensorHubWrapper Java process...
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-CimInstance Win32_Process | Where-Object { $_.Name -match '^(java|javaw)(\.exe)?$' -and $null -ne $_.CommandLine -and $_.CommandLine -like '*%SENSORHUB_NAME%*' } | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop; Write-Output ('Stopped PID ' + $_.ProcessId) } catch {} }"

echo.
echo Done.
exit /b 0

:parse_env_line
if not defined LINE exit /b 0
if "%LINE:~0,1%"=="#" exit /b 0
for /f "tokens=1,* delims==" %%A in ("%LINE%") do (
  if /I "%%A"=="CONTAINER_NAME" set "CONTAINER_NAME=%%B"
)
exit /b 0
