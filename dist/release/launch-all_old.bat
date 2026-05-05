@echo off
setlocal EnableExtensions

rem Resolve project root from this script's location instead of the caller's cwd.
set "PROJECT_DIR=%~dp0"
set "ENV_FILE=%PROJECT_DIR%.env"
set "IMAGE_NAME=oscar-postgis"

if not exist "%ENV_FILE%" (
    echo Error: .env file not found in "%PROJECT_DIR%".
    echo Create it by copying env.template to .env and editing the values.
    exit /b 1
)

call :load_env "%ENV_FILE%"

if not defined SYSTEM_PROFILE set "SYSTEM_PROFILE=8GB"
if not defined CONTAINER_NAME set "CONTAINER_NAME=oscar-postgis-container"

if not defined DB_NAME (
    echo Error: DB_NAME is not set in .env.
    exit /b 1
)
if not defined DB_USER (
    echo Error: DB_USER is not set in .env.
    exit /b 1
)
if not defined DB_PASSWORD (
    echo Error: DB_PASSWORD is not set in .env.
    exit /b 1
)
if not defined DB_PORT (
    echo Error: DB_PORT is not set in .env.
    exit /b 1
)

if /I "%SYSTEM_PROFILE%"=="RPI4" (
    set "PG_SHARED=256MB"
    set "PG_CACHE=1GB"
    set "PG_WORK_MEM=2MB"
    set "PG_MAINT=64MB"
    set "PG_MAX_CONN=75"
) else if /I "%SYSTEM_PROFILE%"=="8GB" (
    set "PG_SHARED=512MB"
    set "PG_CACHE=2GB"
    set "PG_WORK_MEM=4MB"
    set "PG_MAINT=128MB"
    set "PG_MAX_CONN=125"
) else if /I "%SYSTEM_PROFILE%"=="16GB" (
    set "PG_SHARED=1GB"
    set "PG_CACHE=4GB"
    set "PG_WORK_MEM=8MB"
    set "PG_MAINT=256MB"
    set "PG_MAX_CONN=200"
) else if /I "%SYSTEM_PROFILE%"=="32GB" (
    set "PG_SHARED=2GB"
    set "PG_CACHE=8GB"
    set "PG_WORK_MEM=16MB"
    set "PG_MAINT=512MB"
    set "PG_MAX_CONN=300"
) else (
    echo Unknown profile '%SYSTEM_PROFILE%', using 8GB defaults.
    set "PG_SHARED=512MB"
    set "PG_CACHE=2GB"
    set "PG_WORK_MEM=4MB"
    set "PG_MAINT=128MB"
    set "PG_MAX_CONN=125"
)

if not exist "%PROJECT_DIR%pgdata" (
    mkdir "%PROJECT_DIR%pgdata"
    if errorlevel 1 (
        echo Error: failed to create pgdata directory.
        exit /b 1
    )
)

where docker >nul 2>&1
if errorlevel 1 (
    echo Error: Docker is not installed or is not in PATH.
    exit /b 1
)

echo Building PostGIS Docker image...
if not exist "%PROJECT_DIR%postgis" (
    echo Error: postgis directory not found in "%PROJECT_DIR%".
    exit /b 1
)
pushd "%PROJECT_DIR%postgis"
docker build . --file=Dockerfile --tag=%IMAGE_NAME%
if errorlevel 1 (
    echo Error: Docker build failed.
    popd
    exit /b 1
)
popd

echo Preparing PostGIS container for profile: %SYSTEM_PROFILE%

rem Recreate the container so profile/tuning changes always take effect.
rem Data persists because pgdata is mounted from the host.
docker container inspect "%CONTAINER_NAME%" >nul 2>&1
if not errorlevel 1 (
    echo Removing existing container '%CONTAINER_NAME%' so updated settings take effect...
    docker rm -f "%CONTAINER_NAME%" >nul
    if errorlevel 1 (
        echo Error: failed to remove existing container '%CONTAINER_NAME%'.
        exit /b 1
    )
)

echo Creating new container...
docker run ^
    --name "%CONTAINER_NAME%" ^
    -e "POSTGRES_DB=%DB_NAME%" ^
    -e "POSTGRES_USER=%DB_USER%" ^
    -e "POSTGRES_PASSWORD=%DB_PASSWORD%" ^
    -p "%DB_PORT%:5432" ^
    -v "%PROJECT_DIR%pgdata:/var/lib/postgresql/data" ^
    -d ^
    %IMAGE_NAME% ^
    -c "shared_buffers=%PG_SHARED%" ^
    -c "effective_cache_size=%PG_CACHE%" ^
    -c "work_mem=%PG_WORK_MEM%" ^
    -c "maintenance_work_mem=%PG_MAINT%" ^
    -c "max_connections=%PG_MAX_CONN%" ^
    -c superuser_reserved_connections=10 ^
    -c idle_session_timeout=600000 ^
    -c log_connections=on ^
    -c log_disconnections=on ^
    -c wal_buffers=16MB ^
    -c random_page_cost=1.1 ^
    -c effective_io_concurrency=200
if errorlevel 1 (
    echo Error: failed to start PostGIS container.
    exit /b 1
)

echo Waiting for PostGIS to be ready...
set "PGPASSWORD=%DB_PASSWORD%"

:wait_loop
docker exec "%CONTAINER_NAME%" pg_isready -U "%DB_USER%" -d "%DB_NAME%" >nul 2>&1
if not errorlevel 1 goto after_wait
timeout /t 2 /nobreak >nul
goto wait_loop

:after_wait
echo PostGIS is ready.
timeout /t 5 /nobreak >nul

cd /d "%PROJECT_DIR%osh-node-oscar"
if errorlevel 1 (
    echo Error: osh-node-oscar directory not found in "%PROJECT_DIR%".
    exit /b 1
)

if exist "launch.bat" goto run_launch_bat
if exist "launch.sh" goto run_launch_sh
echo Error: neither launch.bat nor launch.sh was found in "%CD%".
exit /b 1

:run_launch_bat
call "launch.bat"
set "LAUNCH_EXIT_CODE=%ERRORLEVEL%"
goto launch_done

:run_launch_sh
echo Warning: launch.bat not found. Trying launch.sh through Bash...
bash "launch.sh"
set "LAUNCH_EXIT_CODE=%ERRORLEVEL%"
goto launch_done

:launch_done
endlocal & exit /b %LAUNCH_EXIT_CODE%

:load_env
rem Minimal .env loader for KEY=VALUE lines. Blank lines are ignored by for /f.
rem Lines beginning with # are ignored. Empty values clear the variable.
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
