@echo off
docker run -d --name postgres ^
  -e POSTGRES_DB=gis ^
  -e POSTGRES_USER=postgres ^
  -e POSTGRES_PASSWORD=postgres ^
  -p 5432:5432 ^
  my-postgis:latest

:waitloop
docker exec postgres pg_isready -U postgres | findstr /C:"accepting connections" >nul
if %errorlevel%==0 (
  echo Postgres is ready!
  goto continue
) else (
  echo Waiting for Postgres...
  timeout /t 2 >nul
  goto waitloop
)

:continue
echo Database started successfully