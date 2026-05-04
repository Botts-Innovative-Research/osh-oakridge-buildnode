@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "SCRIPT_DIR=%~dp0"
if "%SCRIPT_DIR:~-1%"=="\" set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"
set "STATE_DIR=%SCRIPT_DIR%\.monitor-state"
if not exist "%STATE_DIR%" mkdir "%STATE_DIR%"

if exist "%SCRIPT_DIR%\.env" call :load_env "%SCRIPT_DIR%\.env"

if not defined CONTAINER_NAME set "CONTAINER_NAME=oscar-postgis-container"
if not defined MONITOR_INTERVAL set "MONITOR_INTERVAL=60"
if not defined JFR_NAME set "JFR_NAME=oscar"
if not defined JFR_MAX_AGE set "JFR_MAX_AGE=4h"
if not defined JFR_MAX_SIZE set "JFR_MAX_SIZE=1g"

if /I "%~1"=="stop" goto :stop_stack

for /f %%I in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd-HHmmss"') do set "STAMP=%%I"
set "OUT_DIR=%SCRIPT_DIR%\oscar-monitor-%STAMP%"
mkdir "%OUT_DIR%"

echo %OUT_DIR%> "%STATE_DIR%\out_dir.txt"
echo %CONTAINER_NAME%> "%STATE_DIR%\container_name.txt"

echo Monitor output: %OUT_DIR%
echo Launching OSCAR stack...

where jcmd >nul 2>nul
if errorlevel 1 (
    echo Warning: jcmd not found. JFR and NMT snapshots will be skipped.
)

powershell -NoProfile -Command ^
  "$stdout = [System.IO.Path]::Combine('%OUT_DIR%','launch.stdout.log'); $stderr = [System.IO.Path]::Combine('%OUT_DIR%','launch.stderr.log'); $p = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c','call ""%SCRIPT_DIR%\launch-all.bat""') -WorkingDirectory '%SCRIPT_DIR%' -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru; $p.Id" > "%STATE_DIR%\launcher-pid.txt"
if errorlevel 1 (
    echo Error: failed to start launch-all.bat
    exit /b 1
)

set /p LAUNCHER_PID=<"%STATE_DIR%\launcher-pid.txt"
echo Launcher PID: %LAUNCHER_PID%

echo Waiting for JVM to appear...
:wait_for_java
call :find_java_pid
if defined JVM_PID goto :java_found

tasklist /FI "PID eq %LAUNCHER_PID%" | find "%LAUNCHER_PID%" >nul
if errorlevel 1 (
    echo Launch process exited before JVM appeared.
    exit /b 1
)

timeout /t 2 /nobreak >nul
goto :wait_for_java

:java_found
echo Found JVM PID: %JVM_PID%
echo %JVM_PID%> "%STATE_DIR%\jvm-pid.txt"

powershell -NoProfile -Command ^
  "$p = Get-CimInstance Win32_Process -Filter \"ProcessId=%JVM_PID%\"; if ($p) { [System.IO.File]::WriteAllText('%OUT_DIR%\\process-info.txt', ('Timestamp: ' + (Get-Date -Format o) + [Environment]::NewLine + 'Launcher PID: %LAUNCHER_PID%' + [Environment]::NewLine + 'JVM PID: %JVM_PID%' + [Environment]::NewLine + [Environment]::NewLine + 'Command line:' + [Environment]::NewLine + $p.CommandLine)) }"

where jcmd >nul 2>nul
if not errorlevel 1 (
    jcmd %JVM_PID% JFR.start name=%JFR_NAME% settings=profile disk=true maxage=%JFR_MAX_AGE% maxsize=%JFR_MAX_SIZE% filename="%OUT_DIR%\%JFR_NAME%.jfr" > "%OUT_DIR%\jfr-start.txt" 2>&1
    jcmd %JVM_PID% VM.native_memory baseline > "%OUT_DIR%\nmt-baseline.txt" 2>&1
)

call :snapshot

echo Monitor is running. Use monitor-oscar.bat stop to stop the stack and dump final data.
:monitor_loop
tasklist /FI "PID eq %JVM_PID%" | find "%JVM_PID%" >nul
if errorlevel 1 goto :natural_exit

timeout /t %MONITOR_INTERVAL% /nobreak >nul
call :snapshot
goto :monitor_loop

:natural_exit
call :jfr_dump
echo JVM exited.
exit /b 0

:stop_stack
if not exist "%STATE_DIR%\out_dir.txt" (
    echo No active monitor state found.
    exit /b 1
)

set /p OUT_DIR=<"%STATE_DIR%\out_dir.txt"
if exist "%STATE_DIR%\container_name.txt" set /p CONTAINER_NAME=<"%STATE_DIR%\container_name.txt"
if exist "%STATE_DIR%\jvm-pid.txt" set /p JVM_PID=<"%STATE_DIR%\jvm-pid.txt"
if exist "%STATE_DIR%\launcher-pid.txt" set /p LAUNCHER_PID=<"%STATE_DIR%\launcher-pid.txt"

echo Stopping OSCAR stack...
if defined JVM_PID call :snapshot
if defined JVM_PID call :jfr_dump

if defined JVM_PID (
    taskkill /PID %JVM_PID% /T /F > "%OUT_DIR%\taskkill-jvm.txt" 2>&1
)
if defined LAUNCHER_PID (
    taskkill /PID %LAUNCHER_PID% /T /F > "%OUT_DIR%\taskkill-launcher.txt" 2>&1
)

where docker >nul 2>nul
if not errorlevel 1 (
    docker stop "%CONTAINER_NAME%" > "%OUT_DIR%\docker-stop.txt" 2>&1
)

echo Stack stopped.
exit /b 0

:snapshot
if not defined JVM_PID exit /b 0

tasklist /FI "PID eq %JVM_PID%" | find "%JVM_PID%" >nul
if errorlevel 1 exit /b 0

for /f %%I in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd-HHmmss"') do set "SNAPSTAMP=%%I"
set "SNAP_DIR=%OUT_DIR%\%SNAPSTAMP%"
mkdir "%SNAP_DIR%" >nul 2>nul

tasklist /FI "PID eq %JVM_PID%" /V > "%SNAP_DIR%\tasklist.txt" 2>&1
powershell -NoProfile -Command ^
  "$p = Get-Process -Id %JVM_PID% -ErrorAction SilentlyContinue; if ($p) { $p | Select-Object Id,ProcessName,CPU,StartTime,WorkingSet64,PrivateMemorySize64,VirtualMemorySize64,HandleCount,@{Name='ThreadCount';Expression={$_.Threads.Count}} | Format-List * }" > "%SNAP_DIR%\process.txt" 2>&1
powershell -NoProfile -Command ^
  "Get-Counter '\Memory\Committed Bytes','\Memory\Commit Limit','\Paging File(_Total)\%% Usage' | Format-List *" > "%SNAP_DIR%\memory-counters.txt" 2>&1
powershell -NoProfile -Command ^
  "Get-CimInstance Win32_OperatingSystem | Select-Object TotalVisibleMemorySize,FreePhysicalMemory,TotalVirtualMemorySize,FreeVirtualMemory | Format-List *" > "%SNAP_DIR%\os-memory.txt" 2>&1
powershell -NoProfile -Command ^
  "$p = Get-CimInstance Win32_PerfFormattedData_PerfProc_Process | Where-Object { $_.IDProcess -eq %JVM_PID% }; if ($p) { $p | Select-Object Name,IDProcess,WorkingSet,PrivateBytes,PageFileBytes,ThreadCount,HandleCount | Format-List * }" > "%SNAP_DIR%\perfproc.txt" 2>&1

where jcmd >nul 2>nul
if not errorlevel 1 (
    jcmd %JVM_PID% VM.native_memory summary > "%SNAP_DIR%\nmt-summary.txt" 2>&1
    jcmd %JVM_PID% GC.heap_info > "%SNAP_DIR%\gc-heap-info.txt" 2>&1
    jcmd %JVM_PID% Thread.print > "%SNAP_DIR%\thread-print.txt" 2>&1
    jcmd %JVM_PID% JFR.check > "%SNAP_DIR%\jfr-check.txt" 2>&1
)
exit /b 0

:jfr_dump
where jcmd >nul 2>nul
if errorlevel 1 exit /b 0
if not defined JVM_PID exit /b 0
jcmd %JVM_PID% JFR.dump name=%JFR_NAME% filename="%OUT_DIR%\%JFR_NAME%-final.jfr" > "%OUT_DIR%\jfr-dump-final.txt" 2>&1
exit /b 0

:find_java_pid
set "JVM_PID="
for /f %%I in ('powershell -NoProfile -Command "$p = Get-CimInstance Win32_Process -Filter \"Name='java.exe'\" ^| Where-Object { $_.CommandLine -match 'com\.botts\.impl\.security\.SensorHubWrapper' } ^| Select-Object -First 1 -ExpandProperty ProcessId; if ($p) { $p }"') do set "JVM_PID=%%I"
exit /b 0

:load_env
set "ENV_PATH=%~1"
for /f "usebackq tokens=* delims=" %%L in ("%ENV_PATH%") do (
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
