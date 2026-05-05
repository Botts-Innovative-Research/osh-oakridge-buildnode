@echo off
setlocal EnableExtensions

if /I "%~1"=="stop" goto :stop_mode

set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%.") do set "PROJECT_DIR=%%~fI"

call :timestamp OUT_STAMP
set "OUT_DIR=%PROJECT_DIR%\oscar-monitor-%OUT_STAMP%"
set "ENV_FILE=%PROJECT_DIR%\.env"
set "CONTAINER_NAME=oscar-postgis-container"
set "DB_NAME=gis"
set "DB_USER=postgres"
set "DB_PASSWORD=postgres"
set "MATCH_EXPR=com.botts.impl.security.SensorHubWrapper"
set "INTERVAL=%INTERVAL%"
if not defined INTERVAL set "INTERVAL=60"
set "MAX_WAIT_SECONDS=%MAX_WAIT_SECONDS%"
if not defined MAX_WAIT_SECONDS set "MAX_WAIT_SECONDS=300"
set "JFR_NAME=%JFR_NAME%"
if not defined JFR_NAME set "JFR_NAME=oscar"
set "JFR_MAX_AGE=%JFR_MAX_AGE%"
if not defined JFR_MAX_AGE set "JFR_MAX_AGE=4h"
set "JFR_MAX_SIZE=%JFR_MAX_SIZE%"
if not defined JFR_MAX_SIZE set "JFR_MAX_SIZE=1g"
set "LAUNCH_CMD=%PROJECT_DIR%\launch-all.bat"
set "ATTACH_TO_EXISTING=%ATTACH_TO_EXISTING%"
if not defined ATTACH_TO_EXISTING set "ATTACH_TO_EXISTING=0"
set "FORCE_RESTART=%FORCE_RESTART%"
if not defined FORCE_RESTART set "FORCE_RESTART=0"

if exist "%ENV_FILE%" call :load_env "%ENV_FILE%"

call :check_dependencies
if errorlevel 1 exit /b %ERRORLEVEL%

if not exist "%OUT_DIR%" mkdir "%OUT_DIR%"
echo timestamp,total_sessions,active,idle,idle_in_transaction,max_connections,superuser_reserved_connections,failed_psql>"%OUT_DIR%\db-connection-trend.csv"

echo %DATE% %TIME% Monitor output: %OUT_DIR%
echo %DATE% %TIME% Launch command: %LAUNCH_CMD%

call :find_existing_oscar
if defined OSCAR_PID (
    if "%ATTACH_TO_EXISTING%"=="1" (
        set "JVM_PID=%OSCAR_PID%"
        set "USE_EXISTING=1"
        echo %DATE% %TIME% Attaching to existing OSCAR PID %JVM_PID%
    ) else if "%FORCE_RESTART%"=="1" (
        echo %DATE% %TIME% Existing OSCAR instance found with PID %OSCAR_PID%. Replacing because FORCE_RESTART=1.
        taskkill /PID %OSCAR_PID% /T /F >nul 2>nul
        timeout /t 2 /nobreak >nul
        call :find_existing_oscar
        if defined OSCAR_PID (
            echo Error: could not stop the existing OSCAR instance.
            exit /b 1
        )
    ) else (
        echo OSCAR is already running with PID %OSCAR_PID%.
        echo Set ATTACH_TO_EXISTING=1 to monitor the running instance, or FORCE_RESTART=1 to replace it.
        exit /b 1
    )
)

if not defined USE_EXISTING (
    if not exist "%LAUNCH_CMD%" (
        echo Error: launch command not found: "%LAUNCH_CMD%"
        exit /b 1
    )

    powershell -NoProfile -Command "$p = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c ""%LAUNCH_CMD%""' -RedirectStandardOutput '%OUT_DIR%\launch.stdout.log' -RedirectStandardError '%OUT_DIR%\launch.stderr.log' -PassThru; Write-Output $p.Id" > "%OUT_DIR%\launcher-pid.txt"
    for /f "usebackq" %%P in ("%OUT_DIR%\launcher-pid.txt") do set "LAUNCH_PID=%%P"

    echo %DATE% %TIME% Waiting for OSCAR Java process...
    set /a WAITED=0

    :wait_for_jvm
    call :find_existing_oscar
    if defined OSCAR_PID (
        set "JVM_PID=%OSCAR_PID%"
        goto :have_jvm
    )

    if %WAITED% GEQ %MAX_WAIT_SECONDS% (
        echo ERROR: Could not find OSCAR Java PID after waiting.
        exit /b 1
    )

    timeout /t 2 /nobreak >nul
    set /a WAITED+=2
    goto :wait_for_jvm
) else (
    >"%OUT_DIR%\launch.stdout.log" type nul
    >"%OUT_DIR%\launch.stderr.log" type nul
)

:have_jvm
echo %JVM_PID%>"%OUT_DIR%\jvm-pid.txt"

powershell -NoProfile -Command "$p = Get-CimInstance Win32_Process -Filter 'ProcessId=%JVM_PID%'; if($p){ 'Timestamp: ' + (Get-Date -Format o); 'Launcher PID: %LAUNCH_PID%'; 'JVM PID: %JVM_PID%'; ''; 'Command line:'; $p.CommandLine }" > "%OUT_DIR%\process-info.txt"

if defined JCMD_CMD (
    "%JCMD_CMD%" %JVM_PID% JFR.start name=%JFR_NAME% settings=profile disk=true maxage=%JFR_MAX_AGE% maxsize=%JFR_MAX_SIZE% filename="%OUT_DIR%\%JFR_NAME%.jfr" > "%OUT_DIR%\jfr-start.txt" 2>&1
    "%JCMD_CMD%" %JVM_PID% VM.native_memory baseline > "%OUT_DIR%\nmt-baseline.txt" 2>&1
) else (
    echo jcmd not available; skipping JFR start and NMT baseline. > "%OUT_DIR%\jcmd-warning.txt"
)

:loop
call :snapshot
call :process_alive %JVM_PID% JVM_ALIVE
if not defined JVM_ALIVE goto :eof_ok
set "JVM_ALIVE="
timeout /t %INTERVAL% /nobreak >nul
goto :loop

:snapshot
call :timestamp SNAP_STAMP
set "SNAP=%OUT_DIR%\%SNAP_STAMP%"
if not exist "%SNAP%" mkdir "%SNAP%"

echo Collecting snapshot at %SNAP_STAMP% for PID %JVM_PID%
powershell -NoProfile -Command "$p = Get-CimInstance Win32_Process -Filter 'ProcessId=%JVM_PID%'; if($p){$p | Select-Object ProcessId,ParentProcessId,Name,CommandLine | Format-List | Out-String}" > "%SNAP%\process.txt" 2>&1
powershell -NoProfile -Command "$p=Get-Process -Id %JVM_PID% -ErrorAction SilentlyContinue; if($p){$p | Select-Object Id,ProcessName,Threads,VirtualMemorySize64,WorkingSet64,PrivateMemorySize64,CPU,StartTime | Format-List | Out-String}" > "%SNAP%\powershell-process.txt" 2>&1
powershell -NoProfile -Command "Get-CimInstance Win32_OperatingSystem | Select-Object TotalVisibleMemorySize,FreePhysicalMemory,TotalVirtualMemorySize,FreeVirtualMemory | Format-List | Out-String" > "%SNAP%\memory.txt" 2>&1
powershell -NoProfile -Command "Get-Counter '\Memory\Committed Bytes','\Memory\Commit Limit','\Paging File(_Total)\%% Usage' | Out-String" > "%SNAP%\counters.txt" 2>&1
if defined JCMD_CMD (
    "%JCMD_CMD%" %JVM_PID% VM.native_memory summary > "%SNAP%\nmt-summary.txt" 2>&1
    "%JCMD_CMD%" %JVM_PID% GC.heap_info > "%SNAP%\gc-heap-info.txt" 2>&1
    "%JCMD_CMD%" %JVM_PID% Thread.print > "%SNAP%\thread-print.txt" 2>&1
    "%JCMD_CMD%" %JVM_PID% JFR.check > "%SNAP%\jfr-check.txt" 2>&1
)

docker ps --filter name=%CONTAINER_NAME% > "%SNAP%\docker-ps.txt" 2>&1
docker logs --tail 100 %CONTAINER_NAME% > "%SNAP%\docker-logs-tail.txt" 2>&1
call :db_snapshot "%SNAP%"
exit /b 0

:db_snapshot
set "SNAP=%~1"
set "DB_ERR=%SNAP%\db-error.txt"
set "FAILED=0"
set "MAX_CONN="
set "SUPER_RESERVED="
set "TOTAL_SESSIONS="
set "ACTIVE_COUNT=0"
set "IDLE_COUNT=0"
set "IDLE_TX_COUNT=0"

for /f %%T in ('powershell -NoProfile -Command "Get-Date -Format o"') do set "DB_TS=%%T"

docker ps --format {{.Names}} | findstr /i /x "%CONTAINER_NAME%" >nul 2>&1
if errorlevel 1 (
    >"%DB_ERR%" echo Container %CONTAINER_NAME% not running
    >>"%OUT_DIR%\db-connection-trend.csv" echo %DB_TS%,,,,,,,1
    exit /b 0
)

docker exec -e PGPASSWORD=%DB_PASSWORD% %CONTAINER_NAME% psql -U %DB_USER% -d %DB_NAME% -At -c "show max_connections;" > "%SNAP%\db-max-connections.txt" 2> "%DB_ERR%"
if errorlevel 1 set "FAILED=1"
docker exec -e PGPASSWORD=%DB_PASSWORD% %CONTAINER_NAME% psql -U %DB_USER% -d %DB_NAME% -At -c "show superuser_reserved_connections;" > "%SNAP%\db-superuser-reserved-connections.txt" 2>> "%DB_ERR%"
docker exec -e PGPASSWORD=%DB_PASSWORD% %CONTAINER_NAME% psql -U %DB_USER% -d %DB_NAME% -At -c "select count(*) from pg_stat_activity;" > "%SNAP%\db-total-sessions.txt" 2>> "%DB_ERR%"
docker exec -e PGPASSWORD=%DB_PASSWORD% %CONTAINER_NAME% psql -U %DB_USER% -d %DB_NAME% -At -c "select coalesce(state,'<null>'), count(*) from pg_stat_activity group by state order by count(*) desc;" > "%SNAP%\db-by-state.txt" 2>> "%DB_ERR%"
docker exec -e PGPASSWORD=%DB_PASSWORD% %CONTAINER_NAME% psql -U %DB_USER% -d %DB_NAME% -At -c "select coalesce(application_name,'<null>'), coalesce(usename,'<null>'), coalesce(client_addr::text,'<null>'), coalesce(state,'<null>'), count(*) from pg_stat_activity group by application_name, usename, client_addr, state order by count(*) desc limit 20;" > "%SNAP%\db-by-app.txt" 2>> "%DB_ERR%"
docker exec -e PGPASSWORD=%DB_PASSWORD% %CONTAINER_NAME% psql -U %DB_USER% -d %DB_NAME% -At -c "select pid, usename, application_name, client_addr, state, backend_start, xact_start, query_start, wait_event_type, wait_event, left(query,120) from pg_stat_activity order by backend_start;" > "%SNAP%\db-activity-detail.txt" 2>> "%DB_ERR%"

for /f "usebackq" %%A in ("%SNAP%\db-max-connections.txt") do set "MAX_CONN=%%A"
for /f "usebackq" %%A in ("%SNAP%\db-superuser-reserved-connections.txt") do set "SUPER_RESERVED=%%A"
for /f "usebackq" %%A in ("%SNAP%\db-total-sessions.txt") do set "TOTAL_SESSIONS=%%A"
for /f "usebackq tokens=1,2 delims=|" %%A in ("%SNAP%\db-by-state.txt") do (
    if /i "%%A"=="active" set "ACTIVE_COUNT=%%B"
    if /i "%%A"=="idle" set "IDLE_COUNT=%%B"
    if /i "%%A"=="idle in transaction" set "IDLE_TX_COUNT=%%B"
)
>>"%OUT_DIR%\db-connection-trend.csv" echo %DB_TS%,%TOTAL_SESSIONS%,%ACTIVE_COUNT%,%IDLE_COUNT%,%IDLE_TX_COUNT%,%MAX_CONN%,%SUPER_RESERVED%,%FAILED%
exit /b 0

:stop_mode
call :find_existing_oscar
if defined OSCAR_PID taskkill /PID %OSCAR_PID% /T /F >nul 2>&1
for /f %%C in ('docker ps --filter name=oscar-postgis-container --format {{.Names}}') do docker stop %%C >nul 2>&1
echo OSCAR stop requested.
exit /b 0

:check_dependencies
where powershell >nul 2>nul
if errorlevel 1 (
    echo Error: PowerShell is required but was not found on PATH.
    exit /b 1
)

where java >nul 2>nul
if errorlevel 1 (
    echo Error: java was not found on PATH. Install OpenJDK 21 or newer.
    exit /b 1
)

where docker >nul 2>nul
if errorlevel 1 (
    echo Error: docker was not found on PATH. Install Docker Desktop and make sure it is running.
    exit /b 1
)

set "JAVA_HOME_LINE="
for /f "delims=" %%A in ('java -XshowSettings:properties -version 2^>^&1 ^| findstr /c:"java.home ="') do (
    set "JAVA_HOME_LINE=%%A"
    goto :monitor_java_home_line
)

:monitor_java_home_line
if not defined JAVA_HOME_LINE exit /b 0
for /f "tokens=1,* delims==" %%A in ("%JAVA_HOME_LINE%") do set "JAVA_HOME_DETECTED=%%B"
for /f "tokens=* delims= " %%A in ("%JAVA_HOME_DETECTED%") do set "JAVA_HOME_DETECTED=%%A"
if exist "%JAVA_HOME_DETECTED%\bin\jcmd.exe" set "JCMD_CMD=%JAVA_HOME_DETECTED%\bin\jcmd.exe"
exit /b 0

:find_existing_oscar
set "OSCAR_PID="
for /f %%P in ('powershell -NoProfile -Command "$p = Get-CimInstance Win32_Process ^| Where-Object { $_.Name -match ''^java(\.exe)?$'' -and $_.CommandLine -like ''*com.botts.impl.security.SensorHubWrapper*'' } ^| Select-Object -ExpandProperty ProcessId -First 1; if ($p) { Write-Output $p }"') do set "OSCAR_PID=%%P"
exit /b 0

:process_alive
set "%~2="
powershell -NoProfile -Command "if (Get-Process -Id %~1 -ErrorAction SilentlyContinue) { exit 0 } else { exit 1 }" >nul 2>nul
if not errorlevel 1 set "%~2=1"
exit /b 0

:timestamp
for /f %%A in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd-HHmmss"') do set "%~1=%%A"
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

:eof_ok
exit /b 0
