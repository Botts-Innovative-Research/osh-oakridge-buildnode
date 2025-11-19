@echo off
setlocal

set CONTAINER_NAME=oscar-postgis-container

rem Stop the container
echo Stopping container "%CONTAINER_NAME%"...
docker stop "%CONTAINER_NAME%"

echo Container stopped successfully.
endlocal
