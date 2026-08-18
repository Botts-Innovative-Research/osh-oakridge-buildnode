@echo off
setlocal
cd /d "%~dp0"

where docker >nul 2>&1
if errorlevel 1 (
    echo ERROR: Docker is not installed or is not available in PATH. 1>&2
    exit /b 1
)

for %%F in (
    "secrets\oscar-admin-password.txt"
    "secrets\oscar-db-password.txt"
    "secrets\postgres-bootstrap-password.txt"
    "tls\server.crt"
    "tls\server.key"
) do (
    if not exist "%%~F" (
        echo ERROR: Required deployment file is missing: %%~F 1>&2
        echo Run the OSCAR setup workflow before starting the deployment. 1>&2
        exit /b 1
    )
)

docker compose up --detach --build
exit /b %errorlevel%
