@echo off
set CONTAINER_NAME=oscar-postgis-container
set SENSORHUB_NAME=com.botts.impl.security.SensorHubWrapper

echo Stopping container: %CONTAINER_NAME%...

REM Stop docker container if it exists
docker ps -a --format "{{.Names}}" | findstr /R "^%CONTAINER_NAME%$" >nul
if %ERRORLEVEL%==0 (
    docker stop %CONTAINER_NAME%
    echo Container stopped.
) else (
    echo Container not found. Nothing to stop.
)

echo.
echo Stopping SensorHubWrapper Java Process...

FOR /F "tokens=1" %%A IN ('wmic process where "CommandLine like '%%%SENSORHUB_NAME%%%' and name='java.exe'" get ProcessId ^| findstr /R "[0-9]"') DO (
    echo Stopping SensorHubWrapper with PID %%A...
    taskkill /PID %%A /F
    echo SensorHubWrapper stopped.
    goto :DoneJava
)

echo SensorHubWrapper process not found.

:DoneJava
echo.
echo Done.
