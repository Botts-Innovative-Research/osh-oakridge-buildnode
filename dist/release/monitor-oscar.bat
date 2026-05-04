@echo off
setlocal EnableExtensions EnableDelayedExpansion

if "%~1"=="stop" goto :stop_mode

set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%.") do set "PROJECT_DIR=%%~fI"
set "OUT_DIR=%PROJECT_DIR%\oscar-monitor-%DATE:~10,4%%DATE:~4,2%%DATE:~7,2%-%TIME:~0,2%%TIME:~3,2%%TIME:~6,2%"
set "OUT_DIR=%OUT_DIR: =0%"
set "ENV_FILE=%PROJECT_DIR%\.env"
set "CONTAINER_NAME=oscar-postgis-container"
set "DB_NAME=gis"
set "DB_USER=postgres"
set "DB_PASSWORD=postgres"
set "MATCH_EXPR=com.botts.impl.security.SensorHubWrapper"
set "INTERVAL=60"
set "JFR_NAME=oscar"
set "JFR_MAX_AGE=4h"
set "JFR_MAX_SIZE=1g"
set "LAUNCH_CMD=%PROJECT_DIR%\launch-all.bat"

if exist "%ENV_FILE%" (
  for /f "usebackq tokens=1,* delims==" %%A in ("%ENV_FILE%") do (
    if not "%%A"=="" if /i not "%%A:~0,1"=="#" set "%%A=%%B"
  )
)

if not exist "%OUT_DIR%" mkdir "%OUT_DIR%"
echo timestamp,total_sessions,active,idle,idle_in_transaction,max_connections,superuser_reserved_connections,failed_psql>"%OUT_DIR%\db-connection-trend.csv"

echo %DATE% %TIME% Monitor output: %OUT_DIR%
echo %DATE% %TIME% Launch command: %LAUNCH_CMD%

where jcmd >nul 2>nul
if errorlevel 1 echo Warning: jcmd not found. JFR and NMT snapshots will be limited.

start "OSCAR_LAUNCH" /b cmd /c ""%LAUNCH_CMD%" 1>"%OUT_DIR%\launch.stdout.log" 2>"%OUT_DIR%\launch.stderr.log""

:wait_for_jvm
timeout /t 2 /nobreak >nul
for /f "tokens=2 delims=," %%P in ('wmic process where "name='java.exe' and commandline like '%%SensorHubWrapper%%'" get processid^,commandline /format:csv ^| findstr /i SensorHubWrapper') do (
  set "JVM_PID=%%P"
  goto :have_jvm
)
goto :wait_for_jvm

:have_jvm
echo %JVM_PID%>"%OUT_DIR%\jvm-pid.txt"
if exist "%PROJECT_DIR%\monitor.pid" del "%PROJECT_DIR%\monitor.pid"
echo %PROCESS_ID%>"%PROJECT_DIR%\monitor.pid"

jcmd %JVM_PID% JFR.start name=%JFR_NAME% settings=profile disk=true maxage=%JFR_MAX_AGE% maxsize=%JFR_MAX_SIZE% filename="%OUT_DIR%\%JFR_NAME%.jfr" >"%OUT_DIR%\jfr-start.txt" 2>&1
jcmd %JVM_PID% VM.native_memory baseline >"%OUT_DIR%\nmt-baseline.txt" 2>&1

:loop
call :snapshot
for /f "tokens=2 delims=," %%P in ('wmic process where "processid=%JVM_PID%" get processid /format:csv ^| findstr /r ",[0-9][0-9]*$"') do set "ALIVE=%%P"
if not defined ALIVE goto :eof_ok
set "ALIVE="
timeout /t %INTERVAL% /nobreak >nul
goto :loop

:snapshot
set "STAMP=%DATE:~10,4%%DATE:~4,2%%DATE:~7,2%-%TIME:~0,2%%TIME:~3,2%%TIME:~6,2%"
set "STAMP=%STAMP: =0%"
set "SNAP=%OUT_DIR%\%STAMP%"
if not exist "%SNAP%" mkdir "%SNAP%"

echo Collecting snapshot at %STAMP% for PID %JVM_PID%
wmic process where processid=%JVM_PID% get Name,ParentProcessId,ProcessId,ThreadCount,WorkingSetSize,VirtualSize /format:list >"%SNAP%\wmic-process.txt" 2>&1
powershell -NoProfile -Command "$p=Get-Process -Id %JVM_PID% -ErrorAction SilentlyContinue; if($p){$p|Select-Object Id,ProcessName,Threads,VirtualMemorySize64,WorkingSet64,PrivateMemorySize64,CPU,StartTime|Format-List|Out-String}" >"%SNAP%\powershell-process.txt" 2>&1
powershell -NoProfile -Command "Get-CimInstance Win32_OperatingSystem | Select-Object TotalVisibleMemorySize,FreePhysicalMemory,TotalVirtualMemorySize,FreeVirtualMemory | Format-List | Out-String" >"%SNAP%\memory.txt" 2>&1
powershell -NoProfile -Command "Get-Counter '\Memory\Committed Bytes','\Memory\Commit Limit','\Paging File(_Total)\%% Usage' | Out-String" >"%SNAP%\counters.txt" 2>&1
jcmd %JVM_PID% VM.native_memory summary >"%SNAP%\nmt-summary.txt" 2>&1
jcmd %JVM_PID% GC.heap_info >"%SNAP%\gc-heap-info.txt" 2>&1
jcmd %JVM_PID% Thread.print >"%SNAP%\thread-print.txt" 2>&1
jcmd %JVM_PID% JFR.check >"%SNAP%\jfr-check.txt" 2>&1

docker ps --filter name=%CONTAINER_NAME% >"%SNAP%\docker-ps.txt" 2>&1
docker logs --tail 100 %CONTAINER_NAME% >"%SNAP%\docker-logs-tail.txt" 2>&1
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

docker ps --format {{.Names}} | findstr /i /x "%CONTAINER_NAME%" >nul 2>&1
if errorlevel 1 (
  >"%DB_ERR%" echo Container %CONTAINER_NAME% not running
  >>"%OUT_DIR%\db-connection-trend.csv" echo %DATE%T%TIME%,,,,,,,1
  exit /b 0
)

docker exec -e PGPASSWORD=%DB_PASSWORD% %CONTAINER_NAME% psql -U %DB_USER% -d %DB_NAME% -At -c "show max_connections;" >"%SNAP%\db-max-connections.txt" 2>"%DB_ERR%"
if errorlevel 1 set "FAILED=1"
docker exec -e PGPASSWORD=%DB_PASSWORD% %CONTAINER_NAME% psql -U %DB_USER% -d %DB_NAME% -At -c "show superuser_reserved_connections;" >"%SNAP%\db-superuser-reserved-connections.txt" 2>>"%DB_ERR%"
docker exec -e PGPASSWORD=%DB_PASSWORD% %CONTAINER_NAME% psql -U %DB_USER% -d %DB_NAME% -At -c "select count(*) from pg_stat_activity;" >"%SNAP%\db-total-sessions.txt" 2>>"%DB_ERR%"
docker exec -e PGPASSWORD=%DB_PASSWORD% %CONTAINER_NAME% psql -U %DB_USER% -d %DB_NAME% -At -c "select coalesce(state,'<null>'), count(*) from pg_stat_activity group by state order by count(*) desc;" >"%SNAP%\db-by-state.txt" 2>>"%DB_ERR%"
docker exec -e PGPASSWORD=%DB_PASSWORD% %CONTAINER_NAME% psql -U %DB_USER% -d %DB_NAME% -At -c "select coalesce(application_name,'<null>'), coalesce(usename,'<null>'), coalesce(client_addr::text,'<null>'), coalesce(state,'<null>'), count(*) from pg_stat_activity group by application_name, usename, client_addr, state order by count(*) desc limit 20;" >"%SNAP%\db-by-app.txt" 2>>"%DB_ERR%"

for /f %%A in (%SNAP%\db-max-connections.txt) do set "MAX_CONN=%%A"
for /f %%A in (%SNAP%\db-superuser-reserved-connections.txt) do set "SUPER_RESERVED=%%A"
for /f %%A in (%SNAP%\db-total-sessions.txt) do set "TOTAL_SESSIONS=%%A"
for /f "tokens=1,2 delims=|" %%A in (%SNAP%\db-by-state.txt) do (
  if /i "%%A"=="active" set "ACTIVE_COUNT=%%B"
  if /i "%%A"=="idle" set "IDLE_COUNT=%%B"
  if /i "%%A"=="idle in transaction" set "IDLE_TX_COUNT=%%B"
)
>>"%OUT_DIR%\db-connection-trend.csv" echo %DATE%T%TIME%,%TOTAL_SESSIONS%,%ACTIVE_COUNT%,%IDLE_COUNT%,%IDLE_TX_COUNT%,%MAX_CONN%,%SUPER_RESERVED%,%FAILED%
exit /b 0

:stop_mode
for /f %%P in (%~dp0monitor.pid) do set "MONPID=%%P"
if defined MONPID taskkill /PID %MONPID% /T /F >nul 2>&1
for /f "tokens=2 delims=," %%P in ('wmic process where "name='java.exe' and commandline like '%%SensorHubWrapper%%'" get processid^,commandline /format:csv ^| findstr /i SensorHubWrapper') do taskkill /PID %%P /T /F >nul 2>&1
for /f %%C in ('docker ps --filter name=oscar-postgis-container --format {{.Names}}') do docker stop %%C >nul 2>&1
echo OSCAR stack stop requested.
exit /b 0

:eof_ok
exit /b 0
