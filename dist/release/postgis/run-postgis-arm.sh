#!/bin/bash

if [ ! -d "$(pwd)/pgdata" ]; then
  echo "Creating pgdata folder..."
  mkdir -p "$(pwd)/pgdata"
fi

docker build . --file=Dockerfile-arm64 --tag=oscar-postgis-arm
docker run \
  -e PG_MAX_CONNECTIONS=500 \
  -e POSTGRES_DB=gis \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_PASSWORD=postgres \
  -e DATADIR=/var/lib/postgresql/data \
  -p 5432:5432 \
  -v "$(pwd)/pgdata:/var/lib/postgresql/data" \
  oscar-postgis-arm