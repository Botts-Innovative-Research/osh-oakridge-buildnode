@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "PROJECT_DIR=%~dp0"
if "%PROJECT_DIR:~-1%"=="\" set "PROJECT_DIR=%PROJECT_DIR:~0,-1%"
set "ENV_FILE=%PROJECT_DIR%\.env"

if not exist "%ENV_FILE%" (
    echo Error: .env file not found in "%PROJECT_DIR%"
    exit /b 1
)

call :load_env "%ENV_FILE%"
if errorlevel 1 exit /b 1

if not defined CONTAINER_NAME set "CONTAINER_NAME=oscar-postgis-container"

call :set_pg_profile "%SYSTEM_PROFILE%"
if errorlevel 1 exit /b 1

if not exist "%PROJECT_DIR%\pgdata" mkdir "%PROJECT_DIR%\pgdata"

where docker >nul 2>nul
if errorlevel 1 (
    echo Error: Docker is not installed or not on PATH.
    exit /b 1
)

echo Building PostGIS Docker image...
pushd "%PROJECT_DIR%\postgis" || (
    echo Error: postgis directory not found.
    exit /b 1
)

docker build . --file Dockerfile --tag oscar-postgis
if errorlevel 1 (
    popd
    echo Error: Docker build failed.
    exit /b 1
)
popd

echo Preparing PostGIS container for profile %SYSTEM_PROFILE%...
for /f %%I in ('docker ps -a --filter "name=^/%CONTAINER_NAME%$" --format "{{.Names}}"') do set "FOUND_CONTAINER=%%I"
if defined FOUND_CONTAINER (
    echo Removing existing container "%CONTAINER_NAME%" so updated settings take effect...
    docker rm -f "%CONTAINER_NAME%" >nul 2>nul
)

echo Creating new container...
docker run --name "%CONTAINER_NAME%" ^
  -e POSTGRES_DB="%DB_NAME%" ^
  -e POSTGRES_USER="%DB_USER%" ^
  -e POSTGRES_PASSWORD="%DB_PASSWORD%" ^
  -p "%DB_PORT%:5432" ^
  -v "%PROJECT_DIR%\pgdata:/var/lib/postgresql/data" ^
  -d oscar-postgis ^
  -c shared_buffers="%PG_SHARED%" ^
  -c effective_cache_size="%PG_CACHE%" ^
  -c work_mem="%PG_WORK_MEM%" ^
  -c maintenance_work_mem="%PG_MAINT%" ^
  -c max_connections="%PG_MAX_CONN%" ^
  -c wal_buffers=16MB ^
  -c random_page_cost=1.1 ^
  -c effective_io_concurrency=200
if errorlevel 1 (
    echo Error: Failed to start PostGIS container.
    exit /b 1
)

echo Waiting for PostGIS to be ready...
:pg_wait
docker exec "%CONTAINER_NAME%" pg_isready -U "%DB_USER%" -d "%DB_NAME%" >nul 2>nul
if errorlevel 1 (
    timeout /t 2 /nobreak >nul
    goto :pg_wait
)

echo PostGIS is ready.
timeout /t 5 /nobreak >nul

pushd "%PROJECT_DIR%\osh-node-oscar" || (
    echo Error: osh-node-oscar directory not found.
    exit /b 1
)
call launch.bat
set "APP_RC=%ERRORLEVEL%"
popd

exit /b %APP_RC%

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

:set_pg_profile
set "PROFILE=%~1"
if /I "%PROFILE%"=="RPI4" (
    set "PG_SHARED=256MB"
    set "PG_CACHE=1GB"
    set "PG_WORK_MEM=4MB"
    set "PG_MAINT=64MB"
    set "PG_MAX_CONN=50"
    exit /b 0
)
if /I "%PROFILE%"=="8GB" (
    set "PG_SHARED=512MB"
    set "PG_CACHE=2GB"
    set "PG_WORK_MEM=8MB"
    set "PG_MAINT=128MB"
    set "PG_MAX_CONN=75"
    exit /b 0
)
if /I "%PROFILE%"=="16GB" (
    set "PG_SHARED=1GB"
    set "PG_CACHE=4GB"
    set "PG_WORK_MEM=16MB"
    set "PG_MAINT=256MB"
    set "PG_MAX_CONN=100"
    exit /b 0
)
if /I "%PROFILE%"=="32GB" (
    set "PG_SHARED=2GB"
    set "PG_CACHE=8GB"
    set "PG_WORK_MEM=32MB"
    set "PG_MAINT=512MB"
    set "PG_MAX_CONN=150"
    exit /b 0
)

echo Unknown profile "%PROFILE%", using 8GB defaults.
set "PG_SHARED=512MB"
set "PG_CACHE=2GB"
set "PG_WORK_MEM=8MB"
set "PG_MAINT=128MB"
set "PG_MAX_CONN=75"
exit /b 0
