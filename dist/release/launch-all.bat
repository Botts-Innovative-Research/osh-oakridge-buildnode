@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "SCRIPT_DIR=%~dp0"
if "%SCRIPT_DIR:~-1%"=="\" set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"

set "NODE_DIR=%SCRIPT_DIR%\osh-node-oscar"
set "POSTGIS_DIR=%SCRIPT_DIR%\postgis"
set "ENV_FILE=%SCRIPT_DIR%\.env"

if exist "%ENV_FILE%" call :load_env "%ENV_FILE%"

if not defined SYSTEM_PROFILE set "SYSTEM_PROFILE=8GB"
if not defined DB_NAME set "DB_NAME=gis"
if not defined DB_USER set "DB_USER=postgres"
if not defined DB_PASSWORD set "DB_PASSWORD=postgres"
if not defined DB_PORT set "DB_PORT=5432"
if not defined CONTAINER_NAME set "CONTAINER_NAME=oscar-postgis-container"
if not defined POSTGIS_IMAGE_NAME set "POSTGIS_IMAGE_NAME=oscar-postgis"
if not defined POSTGIS_DOCKERFILE set "POSTGIS_DOCKERFILE=Dockerfile"
if not defined FORCE_RESTART set "FORCE_RESTART=0"
if not defined RETRY_MAX set "RETRY_MAX=120"
if not defined RETRY_INTERVAL set "RETRY_INTERVAL=2"
if not defined POSTGIS_READY_DELAY set "POSTGIS_READY_DELAY=5"

set "PGDATA_DIR=%SCRIPT_DIR%\pgdata"

if not exist "%POSTGIS_DIR%" (
    echo ERROR: Missing PostGIS directory: "%POSTGIS_DIR%"
    exit /b 1
)

if not exist "%POSTGIS_DIR%\%POSTGIS_DOCKERFILE%" (
    echo ERROR: Missing PostGIS Dockerfile: "%POSTGIS_DIR%\%POSTGIS_DOCKERFILE%"
    exit /b 1
)

if not exist "%POSTGIS_DIR%\init-extensions.sql" (
    echo ERROR: Missing PostGIS init script: "%POSTGIS_DIR%\init-extensions.sql"
    exit /b 1
)

if not exist "%NODE_DIR%\launch.bat" (
    echo ERROR: Missing node launcher: "%NODE_DIR%\launch.bat"
    exit /b 1
)

where docker >nul 2>nul
if errorlevel 1 (
    echo ERROR: Docker was not found in PATH.
    exit /b 1
)

docker version >nul 2>nul
if errorlevel 1 (
    echo ERROR: Docker is installed but not responding.
    exit /b 1
)

where java >nul 2>nul
if errorlevel 1 (
    echo ERROR: Java was not found in PATH.
    exit /b 1
)

call :check_existing_oscar
if defined OSCAR_PID (
    if /I "%FORCE_RESTART%"=="1" (
        echo OSCAR is already running with PID !OSCAR_PID!. FORCE_RESTART=1, stopping it first...
        call :stop_existing_oscar
        call :wait_for_oscar_stop 60
        call :check_existing_oscar
        if defined OSCAR_PID (
            echo ERROR: OSCAR is still running with PID !OSCAR_PID! after stop attempt.
            exit /b 1
        )
    ) else (
        echo ERROR: OSCAR is already running with PID !OSCAR_PID!.
        echo Set FORCE_RESTART=1 in .env to replace the running instance.
        exit /b 1
    )
)

if /I "%SYSTEM_PROFILE%"=="RPI4" (
    set "PG_MAX_CONNECTIONS=75"
    set "PG_SHARED_BUFFERS=256MB"
    set "PG_EFFECTIVE_CACHE_SIZE=1024MB"
    set "PG_WORK_MEM=2MB"
    set "PG_MAINTENANCE_WORK_MEM=64MB"
) else if /I "%SYSTEM_PROFILE%"=="8GB" (
    set "PG_MAX_CONNECTIONS=125"
    set "PG_SHARED_BUFFERS=1024MB"
    set "PG_EFFECTIVE_CACHE_SIZE=3072MB"
    set "PG_WORK_MEM=4MB"
    set "PG_MAINTENANCE_WORK_MEM=128MB"
) else if /I "%SYSTEM_PROFILE%"=="16GB" (
    set "PG_MAX_CONNECTIONS=200"
    set "PG_SHARED_BUFFERS=2048MB"
    set "PG_EFFECTIVE_CACHE_SIZE=6144MB"
    set "PG_WORK_MEM=4MB"
    set "PG_MAINTENANCE_WORK_MEM=256MB"
) else if /I "%SYSTEM_PROFILE%"=="32GB" (
    set "PG_MAX_CONNECTIONS=300"
    set "PG_SHARED_BUFFERS=4096MB"
    set "PG_EFFECTIVE_CACHE_SIZE=12288MB"
    set "PG_WORK_MEM=8MB"
    set "PG_MAINTENANCE_WORK_MEM=512MB"
) else (
    echo WARNING: Unknown SYSTEM_PROFILE "%SYSTEM_PROFILE%". Using 8GB defaults.
    set "PG_MAX_CONNECTIONS=125"
    set "PG_SHARED_BUFFERS=1024MB"
    set "PG_EFFECTIVE_CACHE_SIZE=3072MB"
    set "PG_WORK_MEM=4MB"
    set "PG_MAINTENANCE_WORK_MEM=128MB"
)

if not exist "%PGDATA_DIR%" mkdir "%PGDATA_DIR%"

echo Building PostGIS Docker image...
docker build -t "%POSTGIS_IMAGE_NAME%" -f "%POSTGIS_DIR%\%POSTGIS_DOCKERFILE%" "%POSTGIS_DIR%"
if errorlevel 1 (
    echo ERROR: Failed to build PostGIS Docker image.
    exit /b 1
)

echo Preparing PostGIS container for profile: %SYSTEM_PROFILE%
echo   Image: %POSTGIS_IMAGE_NAME%
echo   Port: %DB_PORT%:5432
echo   Data: %PGDATA_DIR%

docker ps -a --format "{{.Names}}" | findstr /I /X "%CONTAINER_NAME%" >nul
if not errorlevel 1 (
    echo Removing existing container "%CONTAINER_NAME%" so updated settings take effect...
    docker rm -f "%CONTAINER_NAME%" >nul 2>nul
)

echo Creating new container...
docker run -d ^
  --name "%CONTAINER_NAME%" ^
  -p %DB_PORT%:5432 ^
  -e POSTGRES_DB=%DB_NAME% ^
  -e POSTGRES_USER=%DB_USER% ^
  -e POSTGRES_PASSWORD=%DB_PASSWORD% ^
  -v "%PGDATA_DIR%:/var/lib/postgresql/data" ^
  "%POSTGIS_IMAGE_NAME%" ^
  -c max_connections=%PG_MAX_CONNECTIONS% ^
  -c superuser_reserved_connections=10 ^
  -c shared_buffers=%PG_SHARED_BUFFERS% ^
  -c effective_cache_size=%PG_EFFECTIVE_CACHE_SIZE% ^
  -c work_mem=%PG_WORK_MEM% ^
  -c maintenance_work_mem=%PG_MAINTENANCE_WORK_MEM% ^
  -c idle_session_timeout=600000 ^
  -c log_connections=on ^
  -c log_disconnections=on
if errorlevel 1 (
    echo ERROR: Failed to start PostGIS container.
    exit /b 1
)

echo Waiting for PostGIS to be ready...
set /a WAIT_COUNT=0

:wait_for_postgis
docker exec "%CONTAINER_NAME%" pg_isready -U "%DB_USER%" -d "%DB_NAME%" >nul 2>nul
if not errorlevel 1 goto postgis_ready

set /a WAIT_COUNT+=1
if !WAIT_COUNT! GEQ %RETRY_MAX% (
    echo ERROR: PostGIS did not become ready in time.
    docker logs "%CONTAINER_NAME%"
    exit /b 1
)

timeout /t %RETRY_INTERVAL% /nobreak >nul
goto wait_for_postgis

:postgis_ready
echo PostGIS is ready.
if %POSTGIS_READY_DELAY% GTR 0 timeout /t %POSTGIS_READY_DELAY% /nobreak >nul

pushd "%NODE_DIR%"
call launch.bat
set "NODE_EXIT=%ERRORLEVEL%"
popd

endlocal & exit /b %NODE_EXIT%

:check_existing_oscar
set "OSCAR_PID="
for /f "usebackq delims=" %%P in (`
  powershell -NoProfile -ExecutionPolicy Bypass -Command "$procs = Get-CimInstance Win32_Process; foreach ($proc in $procs) { if ($proc.Name -match '^(java|javaw)(\.exe)?$' -and $null -ne $proc.CommandLine -and $proc.CommandLine -like '*com.botts.impl.security.SensorHubWrapper*') { [Console]::Write($proc.ProcessId); break } }" 2^>nul
`) do set "OSCAR_PID=%%P"
exit /b 0

:stop_existing_oscar
if not defined OSCAR_PID exit /b 0
powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Stop-Process -Id %OSCAR_PID% -Force -ErrorAction Stop; exit 0 } catch { exit 1 }" >nul 2>nul
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