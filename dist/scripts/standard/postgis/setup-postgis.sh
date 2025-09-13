sudo docker build . --tag=oscar-postgis
docker run -e POSTGRES_DB=gis -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=postgres -p 5432:5432 oscar-postgis