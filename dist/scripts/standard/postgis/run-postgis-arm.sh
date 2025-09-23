sudo docker build . --file=Dockerfile-arm64 --tag=oscar-postgis-arm
docker run -e POSTGRES_DB=gis -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=postgres -p 5432:5432 oscar-postgis-arm