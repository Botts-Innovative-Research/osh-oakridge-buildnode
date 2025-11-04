@echo off
docker build . --tag=oscar-postgis

docker run ^
  -e PG_MAX_CONNECTIONS=500 ^
  -e POSTGRES_DB=gis ^
  -e POSTGRES_USER=postgres ^
  -e POSTGRES_PASSWORD=postgres ^
  -p 5432:5432 ^
  oscar-postgis