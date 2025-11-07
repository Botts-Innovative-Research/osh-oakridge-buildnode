@echo off
docker run -d --name test-postgis ^
  -e PG_MAX_CONNECTIONS=1000 ^
  -e POSTGRES_DB=gis ^
  -e POSTGRES_USER=postgres ^
  -e POSTGRES_PASSWORD=postgres ^
  -p 5432:5432 ^
  oscar-postgis:latest

:waitloop
docker exec test-postgis pg_isready -U postgres | findstr /C:"accepting connections" >nul
if %errorlevel%==0 (
  echo Postgres is ready!
  goto continue
) else (
  echo Waiting for Postgres...
  timeout /t 5 >nul
  goto waitloop
)

:continue
echo Database started successfully