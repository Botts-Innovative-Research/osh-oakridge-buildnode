@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "SCRIPT_DIR=%~dp0"
if "%SCRIPT_DIR:~-1%"=="\" set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"

set "ENV_FILE=%SCRIPT_DIR%\.env"
if exist "%ENV_FILE%" call :load_env "%ENV_FILE%"

if not defined CONTAINER_NAME set "CONTAINER_NAME=oscar-postgis-container"

set "PGDATA_DIR=%SCRIPT_DIR%\pgdata"
set "NODE_DIR=%SCRIPT_DIR%\osh-node-oscar"
set "DB_DIR=%NODE_DIR%\db"
set "FILES_DIR=%NODE_DIR%\files"
set "CONFIG_JSON=%NODE_DIR%\config.json"
set "CONFIG_TEMPLATE=%NODE_DIR%\config.template.json"
set "SECRET_FILE=%NODE_DIR%\.s"

echo Requesting monitor shutdown...
if exist "%SCRIPT_DIR%\monitor-oscar.bat" (
    call "%SCRIPT_DIR%\monitor-oscar.bat" stop >nul 2>nul
)

echo Stopping OSCAR Java processes...
for /f "usebackq delims=" %%P in (`
  powershell -NoProfile -ExecutionPolicy Bypass -Command "$procs = Get-CimInstance Win32_Process; foreach ($proc in $procs) { if ($proc.Name -match '^(java|javaw)(\.exe)?$' -and $null -ne $proc.CommandLine -and $proc.CommandLine -like '*com.botts.impl.security.SensorHubWrapper*') { $proc.ProcessId } }" 2^>nul
`) do (
  powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Stop-Process -Id %%P -Force -ErrorAction Stop } catch {}" >nul 2>nul
)

echo Removing container: %CONTAINER_NAME%...
docker rm -f -v "%CONTAINER_NAME%" >nul 2>nul

if exist "%PGDATA_DIR%" (
    echo Removing Postgres data directory: %PGDATA_DIR%
    rmdir /s /q "%PGDATA_DIR%"
) else (
    echo Postgres data directory not found: %PGDATA_DIR%
)

if exist "%DB_DIR%" (
    echo Removing OSCAR runtime DB directory: %DB_DIR%
    rmdir /s /q "%DB_DIR%"
) else (
    echo OSCAR runtime DB directory not found: %DB_DIR%
)

if exist "%FILES_DIR%" (
    echo Removing OSCAR files directory: %FILES_DIR%
    rmdir /s /q "%FILES_DIR%"
) else (
    echo OSCAR files directory not found: %FILES_DIR%
)

if exist "%CONFIG_TEMPLATE%" (
    echo Restoring config.json from template: %CONFIG_TEMPLATE%
    copy /y "%CONFIG_TEMPLATE%" "%CONFIG_JSON%" >nul
) else (
    if exist "%CONFIG_JSON%" (
        echo WARNING: config.template.json not found. Resetting admin password placeholder in existing config.json.
        powershell -NoProfile -ExecutionPolicy Bypass -Command ^
          "$path = '%CONFIG_JSON%';" ^
          "$json = Get-Content -LiteralPath $path -Raw;" ^
          "$pattern = '(\"id\"\s*:\s*\"admin\"[\s\S]*?\"password\"\s*:\s*)\"[^\"]*\"';" ^
          "$updated = [regex]::Replace($json, $pattern, '$1\"__INITIAL_ADMIN_PASSWORD__\"', 1);" ^
          "Set-Content -LiteralPath $path -Value $updated -NoNewline"
    ) else (
        echo OSCAR config not found: %CONFIG_JSON%
    )
)

echo Restoring initial admin secret file: %SECRET_FILE%
> "%SECRET_FILE%" echo oscar

del "%SCRIPT_DIR%\.monitor-active-dir" >nul 2>nul

echo.
echo Reset complete.
echo Next launch should initialize the default login as admin / oscar.
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