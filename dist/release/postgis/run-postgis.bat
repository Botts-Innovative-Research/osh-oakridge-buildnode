@echo off

if not exist "%cd%\pgdata" (
    echo Creating pgdata folder...
    mkdir "%cd%\pgdata"
)

docker build . --tag=oscar-postgis

docker run ^
  --name oscar-postgis ^
  --restart unless-stopped ^
  -e PG_MAX_CONNECTIONS=500 ^
  -e POSTGRES_DB=gis ^
  -e POSTGRES_USER=postgres ^
  -e POSTGRES_PASSWORD=postgres ^
  -p 5432:5432 ^
  -v "%cd%\pgdata:/var/lib/postgresql/data" ^
  oscar-postgis