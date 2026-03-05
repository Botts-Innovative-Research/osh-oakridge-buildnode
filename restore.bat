@echo off
setlocal enabledelayedexpansion

if "%DB_HOST%"=="" (set DB_HOST=localhost)
set DB_NAME=gis
set DB_USER=postgres

if "%POSTGRES_PASSWORD_FILE%"=="" (
    echo Error: POSTGRES_PASSWORD_FILE environment variable is not set.
    exit /b 1
)

if not exist "%POSTGRES_PASSWORD_FILE%" (
    echo Error: Password file %POSTGRES_PASSWORD_FILE% does not exist.
    exit /b 1
)

if "%~1"=="" (
    echo Usage: %0 ^<backup_file^>
    exit /b 1
)

set BACKUP_FILE=%~1
set /p PGPASSWORD=<"%POSTGRES_PASSWORD_FILE%"

echo Restoring database %DB_NAME% to %DB_HOST% from %BACKUP_FILE%...
pg_restore -h %DB_HOST% -U %DB_USER% -d %DB_NAME% -v "%BACKUP_FILE%"

if %errorlevel% equ 0 (
    echo Restore completed successfully.
) else (
    echo Restore failed.
    exit /b 1
)
