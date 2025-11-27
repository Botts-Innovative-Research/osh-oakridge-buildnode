#!/bin/bash

HOST="localhost"
PORT="5432"
DB_NAME="gis"
DB_USER="postgres"
RETRY_MAX=20
RETRY_INTERVAL=5
PROJECT_DIR="$(pwd)"   # Store the original directory
CONTAINER_NAME="oscar-postgis-container"

#docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

# Create pgdata directory if needed
if [ ! -d "${PROJECT_DIR}/pgdata" ]; then
  echo "Creating pgdata folder..."
  mkdir -p "${PROJECT_DIR}/pgdata"
fi

# Check Docker
if ! command -v docker >/dev/null 2>&1; then
    echo "Error: Docker is not installed. Please install Docker first."
    exit 1
fi

echo "Building PostGIS Docker image..."

cd postgis || { echo "Error: postgis directory not found"; exit 1; }

# Build PostGIS
docker build . \
  --file=Dockerfile \
  --tag=oscar-postgis

echo "Starting PostGIS container..."


echo "PROJECT_DIR is set to: ${PROJECT_DIR}"

if docker ps -a --format '{{.Names}}' | grep -Eq "^${CONTAINER_NAME}$"; then
    # The container exists
    if docker ps --format '{{.Names}}' | grep -Eq "^${CONTAINER_NAME}$"; then
        echo "Container already running: ${CONTAINER_NAME}"
    else
        echo "Starting existing container: ${CONTAINER_NAME}"
        docker start "${CONTAINER_NAME}"
    fi
else
    echo "Creating new container: ${CONTAINER_NAME}"
    docker run \
      --name "$CONTAINER_NAME" \
      -e POSTGRES_DB="$DB_NAME" \
      -e POSTGRES_USER="$DB_USER" \
      -e POSTGRES_PASSWORD="postgres" \
      -p $PORT:5432 \
      -v "${PROJECT_DIR}/pgdata:/var/lib/postgresql/data" \
      -d \
      oscar-postgis || { echo "Failed to start PostGIS container"; exit 1; }
fi

# Wait for PostgreSQL/PostGIS to become ready
echo "Waiting for PostGIS (PostgreSQL) to be ready..."

RETRY_COUNT=0
export PGPASSWORD=postgres  # Needed for pg_isready with password

until docker exec "$CONTAINER_NAME" pg_isready -U "$DB_USER" -d "$DB_NAME" > /dev/null 2>&1; do
  echo "PostGIS not ready yet, retrying..."
  sleep "${RETRY_INTERVAL}"
done

echo "PostGIS (PostgreSQL) is ready! Please wait for OpenSensorHub to start..."

sleep 10

# Launch osh-node-oscar
cd "$PROJECT_DIR/osh-node-oscar" || { echo "Error: osh-node-oscar not found"; exit 1; }
./launch.sh