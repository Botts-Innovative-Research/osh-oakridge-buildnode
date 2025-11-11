@echo off

where docker >nul 2>nul
if errorlevel 1 (
    echo [ERROR] Docker is not installed or not in PATH.
    echo Please install Docker Desktop and try again.
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
        echo Please install Docker Compose or ensure Docker Desktop is up to date.
        exit /b 1
    )
)

cd /d "%~dp0"

echo Starting Docker Compose services...
%DOCKER_COMPOSE_CMD% up
if errorlevel 1 (
    echo [ERROR] Failed to start containers.
    exit /b 1
)