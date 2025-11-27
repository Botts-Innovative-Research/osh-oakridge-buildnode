@echo off
setlocal enabledelayedexpansion

REM ==== CONFIG ====
set HOST=localhost
set PORT=5432
set DB_NAME=gis
set USER=postgres
set RETRY_MAX=20
set RETRY_INTERVAL=5
set PROJECT_DIR=%cd%
set CONTAINER_NAME=oscar-postgis-container
set IMAGE_NAME=oscar-postgis

echo PROJECT_DIR is: %PROJECT_DIR%

where docker >nul 2>&1
if %errorlevel% neq 0 (
    echo ERROR: Docker is not installed or not in PATH.
    exit /b 1
)

if not exist "%PROJECT_DIR%\pgdata" (
    echo Creating pgdata directory...
    mkdir "%PROJECT_DIR%\pgdata"
)

echo Building PostGIS Docker image...
pushd postgis
docker build . -f Dockerfile -t %IMAGE_NAME%
if %errorlevel% neq 0 (
    echo ERROR: Docker build failed.
    exit /b 1
)
popd

echo Starting PostGIS container...

for /f "tokens=*" %%i in ('docker ps -a --format "{{.Names}}"') do (
    if "%%i"=="%CONTAINER_NAME%" (
        set CONTAINER_EXISTS=1
    )
)

for /f "tokens=*" %%i in ('docker ps --format "{{.Names}}"') do (
    if "%%i"=="%CONTAINER_NAME%" (
        set CONTAINER_RUNNING=1
    )
)

if defined CONTAINER_EXISTS (
    if defined CONTAINER_RUNNING (
        echo Container already running: %CONTAINER_NAME%
    ) else (
        echo Starting existing container: %CONTAINER_NAME%
        docker start %CONTAINER_NAME%
    )
) else (
    echo Creating new container: %CONTAINER_NAME%
    docker run ^
        --name %CONTAINER_NAME% ^
        -e POSTGRES_DB=%DB_NAME% ^
        -e POSTGRES_USER=%USER% ^
        -e POSTGRES_PASSWORD=postgres ^
        -p %PORT%:5432 ^
        -v "%PROJECT_DIR%\pgdata:/var/lib/postgresql/data" ^
        -d ^
        %IMAGE_NAME%

    if %errorlevel% neq 0 (
        echo ERROR: Failed to start PostGIS container.
        exit /b 1
    )
)

echo Waiting for PostGIS database to become ready...

set RETRY_COUNT=0

:wait_loop
docker exec %CONTAINER_NAME% pg_isready -U %USER% -d %DB_NAME% >nul 2>&1
if %errorlevel% equ 0 (
    echo Received OK from PostGIS. Please wait for initialization...
    goto after_wait
)

echo PostGIS not ready yet, retrying...
set /a RETRY_COUNT+=1

if %RETRY_COUNT% geq %RETRY_MAX% (
    echo ERROR: PostGIS did not become ready in time.
    exit /b 1
)

timeout /t %RETRY_INTERVAL% >nul
goto wait_loop

:after_wait

timeout /t 10 >nul

echo PostGIS database is ready!

cd "%PROJECT_DIR%\osh-node-oscar"
if %errorlevel% neq 0 (
    echo ERROR: osh-node-oscar directory not found.
    exit /b 1
)

if exist launch.bat (
    call launch.bat
) else (
    echo WARNING: launch.bat not found. Trying launch.sh through Git Bash...
    bash launch.sh
)

endlocal
