@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "SCRIPT_DIR=%~dp0"
if "%SCRIPT_DIR:~-1%"=="\" set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"

set "ENV_FILE=%SCRIPT_DIR%\.env"
set "LAUNCH_CMD=%SCRIPT_DIR%\launch-all.bat"
set "ACTIVE_MONITOR_FILE=%SCRIPT_DIR%\.monitor-active-dir"

if /I "%~1"=="stop" goto stop_monitor

if exist "%ENV_FILE%" call :load_env "%ENV_FILE%"

if not defined ATTACH_TO_EXISTING set "ATTACH_TO_EXISTING=0"
if not defined FORCE_RESTART set "FORCE_RESTART=0"
if not defined MAX_WAIT_SECONDS set "MAX_WAIT_SECONDS=300"
if not defined SNAPSHOT_INTERVAL_SECONDS set "SNAPSHOT_INTERVAL_SECONDS=60"

if not exist "%LAUNCH_CMD%" (
    echo ERROR: Missing launch command: "%LAUNCH_CMD%"
    exit /b 1
)

for /f %%T in ('powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-Date -Format yyyyMMdd-HHmmss"') do set "TS=%%T"
set "OUT_DIR=%SCRIPT_DIR%\oscar-monitor-%TS%"

mkdir "%OUT_DIR%" >nul 2>nul
if errorlevel 1 (
    echo ERROR: Could not create monitor output directory: "%OUT_DIR%"
    exit /b 1
)

> "%ACTIVE_MONITOR_FILE%" echo %OUT_DIR%
> "%OUT_DIR%\launch.stdout.log" type nul
> "%OUT_DIR%\launch.stderr.log" type nul

echo %date% %time% Monitor output: %OUT_DIR%
echo %date% %time% Launch command: %LAUNCH_CMD%

call :check_existing_oscar
if defined OSCAR_PID (
    if /I "%ATTACH_TO_EXISTING%"=="1" (
        echo Attaching to existing OSCAR PID %OSCAR_PID%...
        goto found_oscar
    )
    if /I "%FORCE_RESTART%"=="1" (
        echo Existing OSCAR detected with PID %OSCAR_PID%. FORCE_RESTART=1, replacing it...
        call :stop_existing_oscar
        call :wait_for_oscar_stop 60
        call :start_launch
        goto wait_for_oscar
    )
    echo ERROR: OSCAR is already running with PID %OSCAR_PID%.
    echo Set ATTACH_TO_EXISTING=1 to monitor it, or FORCE_RESTART=1 to replace it.
    del "%ACTIVE_MONITOR_FILE%" >nul 2>nul
    exit /b 1
)

call :start_launch

:wait_for_oscar
echo Waiting for OSCAR Java process...
set /a WAITED=0

:wait_loop
if exist "%OUT_DIR%\stop.request" goto cleanup
call :check_existing_oscar
if defined OSCAR_PID goto found_oscar

if %WAITED% GEQ %MAX_WAIT_SECONDS% (
    echo ERROR: Could not find OSCAR Java PID after waiting.
    del "%ACTIVE_MONITOR_FILE%" >nul 2>nul
    exit /b 1
)

timeout /t 2 /nobreak >nul
set /a WAITED+=2
goto wait_loop

:found_oscar
echo Found OSCAR Java PID: %OSCAR_PID%
> "%OUT_DIR%\jvm-pid.txt" echo %OSCAR_PID%

:monitor_loop
if exist "%OUT_DIR%\stop.request" goto cleanup

call :check_existing_oscar
if not defined OSCAR_PID (
    echo OSCAR Java process is no longer running.
    goto cleanup
)

> "%OUT_DIR%\jvm-pid.txt" echo %OSCAR_PID%
call :capture_snapshot
timeout /t %SNAPSHOT_INTERVAL_SECONDS% /nobreak >nul
goto monitor_loop

:cleanup
echo Stopping monitor...
del "%OUT_DIR%\stop.request" >nul 2>nul
del "%ACTIVE_MONITOR_FILE%" >nul 2>nul
exit /b 0

:stop_monitor
set "MON_DIR="
if exist "%ACTIVE_MONITOR_FILE%" set /p MON_DIR=<"%ACTIVE_MONITOR_FILE%"
if not defined MON_DIR call :find_latest_monitor_dir

if not defined MON_DIR (
    echo No active monitor directory found.
    exit /b 0
)

if not exist "%MON_DIR%" (
    del "%ACTIVE_MONITOR_FILE%" >nul 2>nul
    exit /b 0
)

> "%MON_DIR%\stop.request" echo stop
echo Requested monitor stop: "%MON_DIR%"
exit /b 0

:start_launch
echo Launching OSCAR via launch-all.bat...
start "" /b cmd /c ""%LAUNCH_CMD%" 1>>"%OUT_DIR%\launch.stdout.log" 2>>"%OUT_DIR%\launch.stderr.log""
exit /b 0

:check_existing_oscar
set "OSCAR_PID="
for /f "usebackq delims=" %%P in (`
  powershell -NoProfile -ExecutionPolicy Bypass -Command "$procs = Get-CimInstance Win32_Process; foreach ($proc in $procs) { if ($proc.Name -match '^(java|javaw)(\.exe)?$' -and $null -ne $proc.CommandLine -and $proc.CommandLine -like '*com.botts.impl.security.SensorHubWrapper*') { [Console]::Write($proc.ProcessId); break } }" 2^>nul
`) do set "OSCAR_PID=%%P"
exit /b 0

:stop_existing_oscar
if not defined OSCAR_PID exit /b 0
powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Stop-Process -Id %OSCAR_PID% -Force -ErrorAction Stop } catch {}" >nul 2>nul
exit /b 0

:wait_for_oscar_stop
set "WAIT_LIMIT=%~1"
if not defined WAIT_LIMIT set "WAIT_LIMIT=60"
set /a WAITED=0

:wait_for_oscar_stop_loop
call :check_existing_oscar
if not defined OSCAR_PID exit /b 0
if !WAITED! GEQ %WAIT_LIMIT% exit /b 0
timeout /t 1 /nobreak >nul
set /a WAITED+=1
goto wait_for_oscar_stop_loop

:find_latest_monitor_dir
set "MON_DIR="
for /f "delims=" %%D in ('
  powershell -NoProfile -ExecutionPolicy Bypass -Command "$d = Get-ChildItem -LiteralPath '%SCRIPT_DIR%' -Directory -Filter 'oscar-monitor-*' ^| Sort-Object Name -Descending ^| Select-Object -First 1 -ExpandProperty FullName; if ($d) { $d }" 2^>nul
') do set "MON_DIR=%%D"
exit /b 0

:capture_snapshot
for /f %%T in ('powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-Date -Format yyyyMMdd-HHmmss"') do set "SNAP_TS=%%T"
set "SNAP_DIR=%OUT_DIR%\%SNAP_TS%"
mkdir "%SNAP_DIR%" >nul 2>nul

(
    echo Timestamp: %date% %time%
    echo OSCAR_PID: !OSCAR_PID!
) > "%SNAP_DIR%\summary.txt"

tasklist /FI "PID eq !OSCAR_PID!" > "%SNAP_DIR%\tasklist.txt" 2>&1

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "try { Get-Process -Id !OSCAR_PID! ^| Select-Object Id, ProcessName, StartTime, Threads, WorkingSet64, VirtualMemorySize64, PagedMemorySize64 ^| Format-List * } catch { Write-Output $_ }" ^
  > "%SNAP_DIR%\process.txt" 2>&1

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "Get-CimInstance Win32_OperatingSystem ^| Select-Object TotalVisibleMemorySize, FreePhysicalMemory, TotalVirtualMemorySize, FreeVirtualMemory ^| Format-List *" ^
  > "%SNAP_DIR%\system-memory.txt" 2>&1

docker ps > "%SNAP_DIR%\docker-ps.txt" 2>&1

where jcmd >nul 2>nul
if not errorlevel 1 (
    jcmd !OSCAR_PID! VM.native_memory summary > "%SNAP_DIR%\nmt-summary.txt" 2>&1
    jcmd !OSCAR_PID! GC.heap_info > "%SNAP_DIR%\gc-heap-info.txt" 2>&1
    jcmd !OSCAR_PID! Thread.print > "%SNAP_DIR%\thread-print.txt" 2>&1
    jcmd !OSCAR_PID! JFR.check > "%SNAP_DIR%\jfr-check.txt" 2>&1
)

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