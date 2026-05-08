@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "SCRIPT_DIR=%~dp0"
if "%SCRIPT_DIR:~-1%"=="\" set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"
set "STATE_DIR=%SCRIPT_DIR%\.monitor-state"
set "MONITOR_LOCK_DIR=%STATE_DIR%\lock"
set "HEARTBEAT_FILE=%MONITOR_LOCK_DIR%\heartbeat.txt"
set "ACTIVE_MONITOR_FILE=%STATE_DIR%\active-monitor-dir.txt"
set "STATUS_FILE=%SCRIPT_DIR%\monitor.last-status"
set "ERROR_FILE=%SCRIPT_DIR%\monitor.last-error"
set "ENV_FILE=%SCRIPT_DIR%\.env"
set "LAUNCH_CMD=%SCRIPT_DIR%\launch-all.bat"
set "JVM_MATCH=com.botts.impl.security.SensorHubWrapper"
set "OUT_DIR="
set "OSCAR_PID="
set "WAITED=0"
set "STOP_REQUESTED=0"
set "CLEANUP_REASON=STOPPED"

if not exist "%STATE_DIR%" mkdir "%STATE_DIR%" >nul 2>nul

if /I "%~1"=="stop" goto :stop_monitor

if exist "%ENV_FILE%" call :load_env "%ENV_FILE%"

if not defined CONTAINER_NAME set "CONTAINER_NAME=oscar-postgis-container"
if not defined MONITOR_INTERVAL set "MONITOR_INTERVAL=60"
if not defined MAX_WAIT_SECONDS set "MAX_WAIT_SECONDS=300"
if not defined JFR_NAME set "JFR_NAME=oscar"
if not defined JFR_MAX_AGE set "JFR_MAX_AGE=4h"
if not defined JFR_MAX_SIZE set "JFR_MAX_SIZE=1g"
if not defined ATTACH_TO_EXISTING set "ATTACH_TO_EXISTING=0"
if not defined FORCE_RESTART set "FORCE_RESTART=0"

call :write_status STARTING monitor_batch=%~nx0
call :clear_error

if not exist "%LAUNCH_CMD%" (
    echo Error: Missing launch command: "%LAUNCH_CMD%"
    call :write_error Missing launch command: "%LAUNCH_CMD%"
    call :write_status FAILED launch_command_missing path="%LAUNCH_CMD%"
    exit /b 1
)

call :acquire_monitor_lock
if errorlevel 1 exit /b 1

for /f %%I in ('powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-Date -Format yyyyMMdd-HHmmss"') do set "STAMP=%%I"
set "OUT_DIR=%SCRIPT_DIR%\oscar-monitor-%STAMP%"
mkdir "%OUT_DIR%" >nul 2>nul
if errorlevel 1 (
    echo Error: Could not create monitor output directory "%OUT_DIR%"
    call :write_error Could not create monitor output directory "%OUT_DIR%"
    call :write_status FAILED out_dir_create path="%OUT_DIR%"
    call :release_monitor_lock
    exit /b 1
)

echo %OUT_DIR%> "%ACTIVE_MONITOR_FILE%"
call :update_heartbeat
call :write_status RUNNING output="%OUT_DIR%"

echo Monitor output: %OUT_DIR%
echo Launching OSCAR stack...

where jcmd >nul 2>nul
if errorlevel 1 (
    echo Warning: jcmd not found. JFR and NMT snapshots will be skipped.
)

call :check_existing_oscar
if defined OSCAR_PID (
    if /I "%ATTACH_TO_EXISTING%"=="1" (
        echo Attaching to existing OSCAR PID %OSCAR_PID%...
        call :clear_error
        call :write_status RUNNING attached jvm_pid=%OSCAR_PID% output="%OUT_DIR%"
        goto :found_java
    )
    if /I "%FORCE_RESTART%"=="1" (
        echo Existing OSCAR detected with PID %OSCAR_PID%. FORCE_RESTART=1, replacing it...
        call :stop_existing_oscar
        call :wait_for_oscar_stop 60
    ) else (
        echo OSCAR is already running with PID %OSCAR_PID%.
        echo Set ATTACH_TO_EXISTING=1 to monitor it, or FORCE_RESTART=1 to replace it.
        call :write_error OSCAR is already running with PID %OSCAR_PID%.
        call :write_status FAILED oscar_already_running pid=%OSCAR_PID% output="%OUT_DIR%"
        call :release_monitor_lock
        exit /b 1
    )
)

call :start_launch
if errorlevel 1 (
    call :write_error Failed to start launch-all.bat
    call :write_status FAILED launch_start output="%OUT_DIR%"
    call :release_monitor_lock
    exit /b 1
)

call :write_status WAITING_FOR_JVM output="%OUT_DIR%"
echo Waiting for JVM to appear...
set /a WAITED=0

:wait_for_java
call :update_heartbeat
if exist "%OUT_DIR%\stop.request" (
    set "STOP_REQUESTED=1"
    set "CLEANUP_REASON=STOPPED"
    goto :cleanup
)

call :check_existing_oscar
if defined OSCAR_PID goto :found_java

if %WAITED% GEQ %MAX_WAIT_SECONDS% (
    echo Launch timed out before JVM appeared.
    call :write_error Timed out waiting for JVM after %MAX_WAIT_SECONDS%s. Check "%OUT_DIR%\launch.stdout.log" and "%OUT_DIR%\launch.stderr.log"
    call :write_status FAILED wait_for_jvm_timeout output="%OUT_DIR%"
    call :release_monitor_lock
    exit /b 1
)

timeout /t 2 /nobreak >nul
set /a WAITED+=2
goto :wait_for_java

:found_java
echo Found JVM PID: %OSCAR_PID%
> "%OUT_DIR%\jvm-pid.txt" echo %OSCAR_PID%
call :clear_error
call :write_status RUNNING jvm_pid=%OSCAR_PID% output="%OUT_DIR%"

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$p = Get-CimInstance Win32_Process -Filter \"ProcessId=%OSCAR_PID%\"; if ($p) { [System.IO.File]::WriteAllText('%OUT_DIR%\\process-info.txt', ('Timestamp: ' + (Get-Date -Format o) + [Environment]::NewLine + 'JVM PID: %OSCAR_PID%' + [Environment]::NewLine + [Environment]::NewLine + 'Command line:' + [Environment]::NewLine + $p.CommandLine)) }" >nul 2>nul

where jcmd >nul 2>nul
if not errorlevel 1 (
    jcmd %OSCAR_PID% JFR.start name=%JFR_NAME% settings=profile disk=true maxage=%JFR_MAX_AGE% maxsize=%JFR_MAX_SIZE% filename="%OUT_DIR%\%JFR_NAME%.jfr" > "%OUT_DIR%\jfr-start.txt" 2>&1
    jcmd %OSCAR_PID% VM.native_memory baseline > "%OUT_DIR%\nmt-baseline.txt" 2>&1
)

call :snapshot

echo Monitor is running. Use monitor-oscar.bat stop to stop the stack and dump final data.
:monitor_loop
call :update_heartbeat
if exist "%OUT_DIR%\stop.request" (
    set "STOP_REQUESTED=1"
    set "CLEANUP_REASON=STOPPED"
    goto :cleanup
)

call :check_existing_oscar
if not defined OSCAR_PID (
    set "CLEANUP_REASON=EXITED"
    goto :cleanup
)

> "%OUT_DIR%\jvm-pid.txt" echo %OSCAR_PID%
call :snapshot
call :write_status RUNNING jvm_pid=%OSCAR_PID% output="%OUT_DIR%"
timeout /t %MONITOR_INTERVAL% /nobreak >nul
goto :monitor_loop

:cleanup
if defined OSCAR_PID call :jfr_dump
if "%STOP_REQUESTED%"=="1" (
    echo Stop requested.
) else if /I "%CLEANUP_REASON%"=="EXITED" (
    echo JVM exited.
)

del "%OUT_DIR%\stop.request" >nul 2>nul
call :release_monitor_lock
if /I "%CLEANUP_REASON%"=="EXITED" (
    call :write_status EXITED output="%OUT_DIR%"
) else (
    call :write_status STOPPED output="%OUT_DIR%"
)
call :clear_error
exit /b 0

:stop_monitor
set "MON_DIR="
if exist "%ACTIVE_MONITOR_FILE%" set /p MON_DIR=<"%ACTIVE_MONITOR_FILE%"
if not defined MON_DIR call :find_latest_monitor_dir

if not defined MON_DIR (
    echo OSCAR monitor is not running.
    call :write_status STOP_REQUESTED no_active_monitor
    call :clear_error
    call :release_monitor_lock
    exit /b 0
)

if not exist "%MON_DIR%" (
    echo OSCAR monitor is not running.
    call :write_status STOP_REQUESTED no_active_monitor
    call :clear_error
    call :release_monitor_lock
    exit /b 0
)

> "%MON_DIR%\stop.request" echo stop
call :write_status STOP_REQUESTED output="%MON_DIR%"
call :clear_error
echo Requested monitor stop: "%MON_DIR%"
exit /b 0

:start_launch
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$stdout = [System.IO.Path]::Combine('%OUT_DIR%','launch.stdout.log'); $stderr = [System.IO.Path]::Combine('%OUT_DIR%','launch.stderr.log'); Start-Process -WindowStyle Hidden -FilePath 'cmd.exe' -ArgumentList @('/c','call ""%LAUNCH_CMD%""') -WorkingDirectory '%SCRIPT_DIR%' -RedirectStandardOutput $stdout -RedirectStandardError $stderr | Out-Null"
if errorlevel 1 exit /b 1
exit /b 0

:check_existing_oscar
set "OSCAR_PID="
for /f %%I in ('powershell -NoProfile -ExecutionPolicy Bypass -Command "$p = Get-CimInstance Win32_Process ^| Where-Object { $_.Name -match '^(java|javaw)(\\.exe)?$' -and $null -ne $_.CommandLine -and $_.CommandLine -like '*%JVM_MATCH%*' } ^| Select-Object -First 1 -ExpandProperty ProcessId; if ($p) { $p }"') do set "OSCAR_PID=%%I"
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
goto :wait_for_oscar_stop_loop

:snapshot
if not defined OSCAR_PID exit /b 0
for /f %%I in ('powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-Date -Format yyyyMMdd-HHmmss"') do set "SNAPSTAMP=%%I"
set "SNAP_DIR=%OUT_DIR%\%SNAPSTAMP%"
mkdir "%SNAP_DIR%" >nul 2>nul

tasklist /FI "PID eq %OSCAR_PID%" /V > "%SNAP_DIR%\tasklist.txt" 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$p = Get-Process -Id %OSCAR_PID% -ErrorAction SilentlyContinue; if ($p) { $p | Select-Object Id,ProcessName,CPU,StartTime,WorkingSet64,PrivateMemorySize64,VirtualMemorySize64,HandleCount,@{Name='ThreadCount';Expression={$_.Threads.Count}} | Format-List * }" > "%SNAP_DIR%\process.txt" 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "Get-Counter '\Memory\Committed Bytes','\Memory\Commit Limit','\Paging File(_Total)\%% Usage' | Format-List *" > "%SNAP_DIR%\memory-counters.txt" 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "Get-CimInstance Win32_OperatingSystem | Select-Object TotalVisibleMemorySize,FreePhysicalMemory,TotalVirtualMemorySize,FreeVirtualMemory | Format-List *" > "%SNAP_DIR%\os-memory.txt" 2>&1

where jcmd >nul 2>nul
if not errorlevel 1 (
    jcmd %OSCAR_PID% VM.native_memory summary > "%SNAP_DIR%\nmt-summary.txt" 2>&1
    jcmd %OSCAR_PID% GC.heap_info > "%SNAP_DIR%\gc-heap-info.txt" 2>&1
    jcmd %OSCAR_PID% Thread.print > "%SNAP_DIR%\thread-print.txt" 2>&1
    jcmd %OSCAR_PID% JFR.check > "%SNAP_DIR%\jfr-check.txt" 2>&1
)

docker ps > "%SNAP_DIR%\docker-ps.txt" 2>&1
exit /b 0

:jfr_dump
where jcmd >nul 2>nul
if errorlevel 1 exit /b 0
if not defined OSCAR_PID exit /b 0
jcmd %OSCAR_PID% JFR.dump name=%JFR_NAME% filename="%OUT_DIR%\%JFR_NAME%-final.jfr" > "%OUT_DIR%\jfr-dump-final.txt" 2>&1
exit /b 0

:acquire_monitor_lock
if not exist "%STATE_DIR%" mkdir "%STATE_DIR%" >nul 2>nul
mkdir "%MONITOR_LOCK_DIR%" >nul 2>nul
if not errorlevel 1 exit /b 0

call :lock_is_fresh
if "%LOCK_FRESH%"=="1" (
    set "EXISTING_OUT_DIR="
    if exist "%ACTIVE_MONITOR_FILE%" set /p EXISTING_OUT_DIR=<"%ACTIVE_MONITOR_FILE%"
    echo Error: Another monitor-oscar.bat instance is already running.
    if defined EXISTING_OUT_DIR echo Active monitor output: %EXISTING_OUT_DIR%
    echo Run stop-all.bat or monitor-oscar.bat stop before starting another monitor.
    if defined EXISTING_OUT_DIR (
        call :write_error Duplicate monitor start refused. Existing output: %EXISTING_OUT_DIR%
        call :write_status FAILED duplicate_monitor output="%EXISTING_OUT_DIR%"
    ) else (
        call :write_error Duplicate monitor start refused.
        call :write_status FAILED duplicate_monitor
    )
    exit /b 1
)

echo Removing stale OSCAR monitor lock state.
call :release_monitor_lock
mkdir "%MONITOR_LOCK_DIR%" >nul 2>nul
if errorlevel 1 (
    call :write_error Could not acquire OSCAR monitor lock at "%MONITOR_LOCK_DIR%"
    call :write_status FAILED lock_acquire path="%MONITOR_LOCK_DIR%"
    exit /b 1
)
exit /b 0

:lock_is_fresh
set "LOCK_FRESH=0"
if not exist "%HEARTBEAT_FILE%" exit /b 0
for /f %%I in ('powershell -NoProfile -ExecutionPolicy Bypass -Command "$age = (Get-Date) - (Get-Item '%HEARTBEAT_FILE%').LastWriteTime; if ($age.TotalSeconds -lt 180) { 1 } else { 0 }"') do set "LOCK_FRESH=%%I"
exit /b 0

:update_heartbeat
if not exist "%MONITOR_LOCK_DIR%" mkdir "%MONITOR_LOCK_DIR%" >nul 2>nul
break> "%HEARTBEAT_FILE%"
exit /b 0

:release_monitor_lock
if exist "%HEARTBEAT_FILE%" del "%HEARTBEAT_FILE%" >nul 2>nul
if exist "%ACTIVE_MONITOR_FILE%" del "%ACTIVE_MONITOR_FILE%" >nul 2>nul
if exist "%MONITOR_LOCK_DIR%" rmdir "%MONITOR_LOCK_DIR%" >nul 2>nul
exit /b 0

:find_latest_monitor_dir
set "MON_DIR="
for /f "delims=" %%I in ('powershell -NoProfile -ExecutionPolicy Bypass -Command "$d = Get-ChildItem -LiteralPath '%SCRIPT_DIR%' -Directory -Filter 'oscar-monitor-*' ^| Sort-Object Name -Descending ^| Select-Object -First 1 -ExpandProperty FullName; if ($d) { $d }"') do set "MON_DIR=%%I"
exit /b 0

:load_env
for /f "usebackq tokens=* delims=" %%L in ("%~1") do (
    set "LINE=%%L"
    if defined LINE (
        if not "!LINE:~0,1!"=="#" (
            for /f "tokens=1,* delims==" %%A in ("!LINE!") do (
                if not "%%A"=="" set "%%A=%%B"
            )
        )
    )
)
exit /b 0

:write_status
set "STATUS_TEXT=%*"
> "%STATUS_FILE%" echo %date% %time% %STATUS_TEXT%
exit /b 0

:write_error
set "ERROR_TEXT=%*"
> "%ERROR_FILE%" echo %date% %time% %ERROR_TEXT%
exit /b 0

:clear_error
> "%ERROR_FILE%" type nul
exit /b 0
