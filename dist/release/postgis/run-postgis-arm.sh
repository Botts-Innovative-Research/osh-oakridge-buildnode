#!/bin/bash

if [ ! -d "$(pwd)/pgdata" ]; then
  echo "Creating pgdata folder..."
  mkdir -p "$(pwd)/pgdata"
fi

# Set up DB password secret
PROJECT_DIR="$(pwd)"
if [ -z "$POSTGRES_PASSWORD_FILE" ]; then
    export POSTGRES_PASSWORD_FILE="${PROJECT_DIR}/.db_password"
fi

if [ ! -f "$POSTGRES_PASSWORD_FILE" ]; then
    echo "Generating new database password..."
    openssl rand -base64 32 > "$POSTGRES_PASSWORD_FILE"
fi

docker build . --file=Dockerfile-arm64 --tag=oscar-postgis-arm
docker run \
  -e PG_MAX_CONNECTIONS=500 \
  -e POSTGRES_DB=gis \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_PASS=$(cat "$POSTGRES_PASSWORD_FILE") \
  -e DATADIR=/var/lib/postgresql/data \
  -p 5432:5432 \
  -v "$(pwd)/pgdata:/var/lib/postgresql/data" \
  -v "$POSTGRES_PASSWORD_FILE:/run/secrets/db_password" \
  -d \
  oscar-postgis-arm