@echo off
setlocal enabledelayedexpansion

set HOST=localhost
set PORT=5432
set DB_NAME=gis
set USER=postgres
set RETRY_MAX=20
set RETRY_INTERVAL=5
set PROJECT_DIR=%cd%
set CONTAINER_NAME=oscar-postgis-container

rem Create pgdata directory if needed
if not exist "%PROJECT_DIR%\pgdata" (
    echo Creating pgdata folder...
    mkdir "%PROJECT_DIR%\pgdata"
)

rem Check Docker
docker --version >nul 2>&1
if errorlevel 1 (
    echo Error: Docker is not installed. Please install Docker first.
    exit /b 1
)

echo Building PostGIS (ARM) Docker image...

if not exist "postgis" (
    echo Error: postgis directory not found
    exit /b 1
)

cd postgis

rem Build PostGIS image
docker build . --file=Dockerfile --tag=oscar-postgis

cd "%PROJECT_DIR%"

rem Check if container exists
docker ps -a --format "{{.Names}}" | findstr /i "^%CONTAINER_NAME%$" >nul
if errorlevel 1 (
    rem Container does not exist, create it
    echo Starting new PostGIS container...
    docker run --name "%CONTAINER_NAME%" -e POSTGRES_DB=%DB_NAME% -e POSTGRES_USER=%USER% -e POSTGRES_PASSWORD=postgres -p %PORT%:5432 -v "%PROJECT_DIR%/pgdata:/var/lib/postgresql/data" -d oscar-postgis
) else (
    rem Container exists, start it if not running
    docker inspect -f "{{.State.Running}}" "%CONTAINER_NAME%" | findstr true >nul
    if errorlevel 1 (
        echo Starting existing PostGIS container...
        docker start "%CONTAINER_NAME%"
    ) else (
        echo PostGIS container already running.
    )
)

rem Wait for PostgreSQL/PostGIS to become ready
echo Waiting for PostGIS (PostgreSQL) to be ready...
set RETRY_COUNT=0
set PGPASSWORD=postgres

:wait_loop
docker exec "%CONTAINER_NAME%" pg_isready -U "%USER%" -d "%DB_NAME%" >nul 2>&1
if errorlevel 1 (
    echo PostGIS not ready yet, retrying...
    timeout /t %RETRY_INTERVAL% /nobreak >nul
    set /a RETRY_COUNT+=1
    if !RETRY_COUNT! lss %RETRY_MAX% goto wait_loop
    echo Error: PostGIS failed to become ready after %RETRY_MAX% retries
    exit /b 1
)

echo PostGIS (PostgreSQL) is ready!

rem Launch osh-node-oscar
cd "%PROJECT_DIR%\osh-node-oscar"
if not exist "launch.bat" (
    if not exist "launch.sh" (
        echo Error: launch script not found in osh-node-oscar
        exit /b 1
    )
    echo Warning: launch.sh found but launch.bat not found. You may need to convert launch.sh to launch.bat
    exit /b 1
)

call launch.bat

endlocal
