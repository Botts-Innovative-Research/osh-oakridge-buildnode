@echo off

where docker >nul 2>nul
if errorlevel 1 (
    echo [ERROR] Docker is not installed or not in PATH.
    exit /b 1
)

where docker-compose >nul 2>nul
if %errorlevel%==0 (
    set DOCKER_COMPOSE_CMD=docker-compose
) else (
    docker compose version >nul 2>nul
    if %errorlevel%==0 (
        set DOCKER_COMPOSE_CMD=docker compose
    ) else (
        echo [ERROR] Docker Compose is not installed.
        exit /b 1
    )
)

cd /d "%~dp0"

echo.
echo Stopping Docker Compose services...
%DOCKER_COMPOSE_CMD% down
if errorlevel 1 (
    echo [ERROR] Failed to stop containers.
    exit /b 1
)

echo Application stopped successfully.