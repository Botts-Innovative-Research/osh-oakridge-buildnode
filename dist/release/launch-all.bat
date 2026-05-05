@echo off
setlocal EnableExtensions

set "PROJECT_DIR=%~dp0"
set "ENV_FILE=%PROJECT_DIR%.env"
set "MATCH_EXPR=com.botts.impl.security.SensorHubWrapper"
set "FORCE_RESTART=%FORCE_RESTART%"
if not defined FORCE_RESTART set "FORCE_RESTART=0"
set "RETRY_MAX=%RETRY_MAX%"
if not defined RETRY_MAX set "RETRY_MAX=120"
set "RETRY_INTERVAL=%RETRY_INTERVAL%"
if not defined RETRY_INTERVAL set "RETRY_INTERVAL=2"
set "POSTGIS_READY_DELAY=%POSTGIS_READY_DELAY%"
if not defined POSTGIS_READY_DELAY set "POSTGIS_READY_DELAY=5"
set "POSTGIS_DOCKERFILE=%POSTGIS_DOCKERFILE%"
if not defined POSTGIS_DOCKERFILE set "POSTGIS_DOCKERFILE=Dockerfile"

if not exist "%ENV_FILE%" (
    echo Error: .env file not found in "%PROJECT_DIR%".
    echo Create it by copying env.template to .env and editing the values.
    exit /b 1
)

call :load_env "%ENV_FILE%"

if not defined IMAGE_NAME if defined POSTGIS_IMAGE_NAME set "IMAGE_NAME=%POSTGIS_IMAGE_NAME%"
if not defined IMAGE_NAME set "IMAGE_NAME=oscar-postgis"

call :check_dependencies
if errorlevel 1 exit /b %ERRORLEVEL%
call :check_existing_oscar
if errorlevel 1 exit /b %ERRORLEVEL%
call :ensure_project_layout
if errorlevel 1 exit /b %ERRORLEVEL%

if not defined SYSTEM_PROFILE set "SYSTEM_PROFILE=8GB"
if not defined CONTAINER_NAME set "CONTAINER_NAME=oscar-postgis-container"
if not defined DB_HOST set "DB_HOST=localhost"

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

call :require_number DB_PORT
if errorlevel 1 exit /b %ERRORLEVEL%
call :require_number RETRY_MAX
if errorlevel 1 exit /b %ERRORLEVEL%
call :require_number RETRY_INTERVAL
if errorlevel 1 exit /b %ERRORLEVEL%
call :require_number POSTGIS_READY_DELAY
if errorlevel 1 exit /b %ERRORLEVEL%

if /I "%SYSTEM_PROFILE%"=="RPI4" (
    set "SYSTEM_PROFILE=RPI4"
    set "PG_SHARED=256MB"
    set "PG_CACHE=1GB"
    set "PG_WORK_MEM=2MB"
    set "PG_MAINT=64MB"
    set "PG_MAX_CONN=75"
) else if /I "%SYSTEM_PROFILE%"=="8GB" (
    set "SYSTEM_PROFILE=8GB"
    set "PG_SHARED=512MB"
    set "PG_CACHE=2GB"
    set "PG_WORK_MEM=4MB"
    set "PG_MAINT=128MB"
    set "PG_MAX_CONN=125"
) else if /I "%SYSTEM_PROFILE%"=="16GB" (
    set "SYSTEM_PROFILE=16GB"
    set "PG_SHARED=1GB"
    set "PG_CACHE=4GB"
    set "PG_WORK_MEM=8MB"
    set "PG_MAINT=256MB"
    set "PG_MAX_CONN=200"
) else if /I "%SYSTEM_PROFILE%"=="32GB" (
    set "SYSTEM_PROFILE=32GB"
    set "PG_SHARED=2GB"
    set "PG_CACHE=8GB"
    set "PG_WORK_MEM=16MB"
    set "PG_MAINT=512MB"
    set "PG_MAX_CONN=300"
) else (
    echo Unknown profile '%SYSTEM_PROFILE%', using 8GB defaults.
    set "SYSTEM_PROFILE=8GB"
    set "PG_SHARED=512MB"
    set "PG_CACHE=2GB"
    set "PG_WORK_MEM=4MB"
    set "PG_MAINT=128MB"
    set "PG_MAX_CONN=125"
)

set "PATH=%JAVA_HOME_DETECTED%\bin;%PATH%"

if not exist "%PROJECT_DIR%pgdata" mkdir "%PROJECT_DIR%pgdata" >nul 2>nul
if not exist "%PROJECT_DIR%pgdata" (
    echo Error: failed to create pgdata directory.
    exit /b 1
)

echo Building PostGIS Docker image...
pushd "%PROJECT_DIR%postgis"
docker build . --file="%POSTGIS_DOCKERFILE%" --tag="%IMAGE_NAME%"
if errorlevel 1 (
    echo Error: Docker build failed.
    popd
    exit /b 1
)
popd

echo Preparing PostGIS container for profile: %SYSTEM_PROFILE%
echo   Image: %IMAGE_NAME%
echo   Port: %DB_PORT%:5432
echo   Data: %PROJECT_DIR%pgdata

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
    "%IMAGE_NAME%" ^
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
set /a RETRY_COUNT=0

:wait_loop
docker exec "%CONTAINER_NAME%" pg_isready -U "%DB_USER%" -d "%DB_NAME%" >nul 2>&1
if not errorlevel 1 goto after_wait
set /a RETRY_COUNT+=1
if %RETRY_COUNT% GEQ %RETRY_MAX% (
    echo Error: PostGIS did not become ready after %RETRY_MAX% attempts.
    echo Last container logs:
    docker logs --tail 50 "%CONTAINER_NAME%"
    exit /b 1
)
timeout /t %RETRY_INTERVAL% /nobreak >nul
goto wait_loop

:after_wait
echo PostGIS is ready.
timeout /t %POSTGIS_READY_DELAY% /nobreak >nul

cd /d "%PROJECT_DIR%osh-node-oscar"
if errorlevel 1 (
    echo Error: osh-node-oscar directory not found in "%PROJECT_DIR%".
    exit /b 1
)

if not exist "launch.bat" (
    echo Error: launch.bat not found in "%CD%".
    exit /b 1
)

call "launch.bat"
set "LAUNCH_EXIT_CODE=%ERRORLEVEL%"
endlocal & exit /b %LAUNCH_EXIT_CODE%

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

docker info >nul 2>nul
if errorlevel 1 (
    echo Error: Docker is installed, but the Docker daemon is not running.
    exit /b 1
)

set "JAVA_HOME_LINE="
for /f "delims=" %%A in ('java -XshowSettings:properties -version 2^>^&1 ^| findstr /c:"java.home ="') do (
    set "JAVA_HOME_LINE=%%A"
    goto :deps_java_home_line
)

:deps_java_home_line
if not defined JAVA_HOME_LINE (
    echo Error: could not determine java.home from the installed Java runtime.
    exit /b 1
)

for /f "tokens=1,* delims==" %%A in ("%JAVA_HOME_LINE%") do set "JAVA_HOME_DETECTED=%%B"
for /f "tokens=* delims= " %%A in ("%JAVA_HOME_DETECTED%") do set "JAVA_HOME_DETECTED=%%A"

if not exist "%JAVA_HOME_DETECTED%\bin\java.exe" (
    echo Error: Java executable not found under "%JAVA_HOME_DETECTED%\bin\java.exe".
    exit /b 1
)
if not exist "%JAVA_HOME_DETECTED%\bin\keytool.exe" (
    echo Error: keytool.exe not found under "%JAVA_HOME_DETECTED%\bin\keytool.exe".
    exit /b 1
)

set "JAVA_VERSION_LINE="
for /f "delims=" %%A in ('"%JAVA_HOME_DETECTED%\bin\java.exe" -version 2^>^&1 ^| findstr /r /c:"version \""') do (
    set "JAVA_VERSION_LINE=%%A"
    goto :deps_java_version_line
)

:deps_java_version_line
if not defined JAVA_VERSION_LINE (
    echo Error: could not determine Java version. OpenJDK 21 or newer is required.
    exit /b 1
)

for /f "tokens=2 delims=\"" %%A in ("%JAVA_VERSION_LINE%") do set "JAVA_VERSION_RAW=%%A"
for /f "tokens=1 delims=." %%A in ("%JAVA_VERSION_RAW%") do set "JAVA_MAJOR=%%A"
if not defined JAVA_MAJOR (
    echo Error: could not parse Java version from "%JAVA_VERSION_LINE%".
    exit /b 1
)
if %JAVA_MAJOR% LSS 21 (
    echo Error: Java 21 or newer is required. Found Java %JAVA_MAJOR%.
    exit /b 1
)
exit /b 0

:find_existing_oscar
set "OSCAR_PID="
for /f %%P in ('powershell -NoProfile -Command "$p = Get-CimInstance Win32_Process ^| Where-Object { $_.Name -match ''^java(\.exe)?$'' -and $_.CommandLine -like ''*com.botts.impl.security.SensorHubWrapper*'' } ^| Select-Object -ExpandProperty ProcessId -First 1; if ($p) { Write-Output $p }"') do set "OSCAR_PID=%%P"
exit /b 0

:check_existing_oscar
call :find_existing_oscar
if not defined OSCAR_PID exit /b 0

if "%FORCE_RESTART%"=="1" (
    echo Existing OSCAR instance found with PID %OSCAR_PID%. Replacing because FORCE_RESTART=1.
    taskkill /PID %OSCAR_PID% /T /F >nul 2>nul
    timeout /t 2 /nobreak >nul
    call :find_existing_oscar
    if defined OSCAR_PID (
        echo Error: could not stop the existing OSCAR instance.
        exit /b 1
    )
    exit /b 0
)

echo OSCAR is already running with PID %OSCAR_PID%.
echo Stop the running instance first, or set FORCE_RESTART=1 to replace it.
exit /b 1

:ensure_project_layout
if not exist "%PROJECT_DIR%postgis" (
    echo Error: postgis directory not found in "%PROJECT_DIR%".
    exit /b 1
)
if not exist "%PROJECT_DIR%postgis\%POSTGIS_DOCKERFILE%" (
    echo Error: %POSTGIS_DOCKERFILE% not found in "%PROJECT_DIR%postgis".
    exit /b 1
)
if not exist "%PROJECT_DIR%osh-node-oscar" (
    echo Error: osh-node-oscar directory not found in "%PROJECT_DIR%".
    exit /b 1
)
if not exist "%PROJECT_DIR%osh-node-oscar\launch.bat" (
    echo Error: launch.bat not found in "%PROJECT_DIR%osh-node-oscar".
    exit /b 1
)
exit /b 0

:require_number
call set "VALUE=%%%~1%%"
if not defined VALUE (
    echo Error: %~1 must be a number, got ''.
    exit /b 1
)
for /f "delims=0123456789" %%A in ("%VALUE%") do (
    echo Error: %~1 must be a number, got '%VALUE%'.
    exit /b 1
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
