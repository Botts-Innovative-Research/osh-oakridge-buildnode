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

set /p PGPASSWORD=<"%POSTGRES_PASSWORD_FILE%"

set TIMESTAMP=%date:~10,4%%date:~4,2%%date:~7,2%_%time:~0,2%%time:~3,2%%time:~6,2%
set TIMESTAMP=%TIMESTAMP: =0%
set BACKUP_FILE=backup_%TIMESTAMP%.dump

echo Backing up database %DB_NAME% from %DB_HOST%...
pg_dump -h %DB_HOST% -U %DB_USER% -d %DB_NAME% -F c -f "%BACKUP_FILE%"

if %errorlevel% equ 0 (
    echo Backup completed successfully: %BACKUP_FILE%
) else (
    echo Backup failed.
    exit /b 1
)
