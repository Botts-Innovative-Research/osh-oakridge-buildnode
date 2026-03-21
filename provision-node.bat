@echo off
rem OSCAR API Key Provisioning Utility (Windows)
rem Uses Tailscale to securely push an API key to a remote node.

if "%~2"=="" (
    echo Usage: %0 ^<tailscale-ip-or-name^> ^<api-key^>
    exit /b 1
)

set NODE_TARGET=%1
set API_KEY=%2

echo Attempting to push API key to %NODE_TARGET%...

rem Create a temporary file with the key
echo %API_KEY% > .tmp_apikey

rem Use Tailscale to push the file
tailscale file cp .tmp_apikey "%NODE_TARGET%:"

rem Use Tailscale SSH to move the key into the configuration
rem Assumes tailscale ssh enabled on target
tailscale ssh %NODE_TARGET% "powershell -Command New-Item -Path 'C:\ProgramData\SensorHub\secrets' -ItemType Directory -Force; Move-Item -Path '.tmp_apikey' -Destination 'C:\ProgramData\SensorHub\secrets\api_key' -Force"

del .tmp_apikey
echo Provisioning complete for %NODE_TARGET%
