#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${PROJECT_DIR}/.env"

if [ ! -f "$ENV_FILE" ]; then
    echo "Error: .env file not found in $PROJECT_DIR"
    exit 1
fi

set -a
. "$ENV_FILE"
set +a

CONTAINER_NAME="${CONTAINER_NAME:-oscar-postgis-container}"

case "${SYSTEM_PROFILE:-8GB}" in
  "RPI4")
    PG_SHARED="256MB"
    PG_CACHE="1GB"
    PG_WORK_MEM="4MB"
    PG_MAINT="64MB"
    PG_MAX_CONN="50"
    ;;
  "8GB")
    PG_SHARED="512MB"
    PG_CACHE="2GB"
    PG_WORK_MEM="8MB"
    PG_MAINT="128MB"
    PG_MAX_CONN="75"
    ;;
  "16GB")
    PG_SHARED="1GB"
    PG_CACHE="4GB"
    PG_WORK_MEM="16MB"
    PG_MAINT="256MB"
    PG_MAX_CONN="100"
    ;;
  "32GB")
    PG_SHARED="2GB"
    PG_CACHE="8GB"
    PG_WORK_MEM="32MB"
    PG_MAINT="512MB"
    PG_MAX_CONN="150"
    ;;
  *)
    echo "Unknown profile '${SYSTEM_PROFILE}', using 8GB defaults."
    PG_SHARED="512MB"
    PG_CACHE="2GB"
    PG_WORK_MEM="8MB"
    PG_MAINT="128MB"
    PG_MAX_CONN="75"
    ;;
esac

mkdir -p "${PROJECT_DIR}/pgdata"

if ! command -v docker >/dev/null 2>&1; then
    echo "Error: Docker is not installed."
    exit 1
fi

echo "Building PostGIS Docker image..."
cd "${PROJECT_DIR}/postgis" || { echo "Error: postgis directory not found"; exit 1; }
docker build . --file=Dockerfile --tag=oscar-postgis

echo "Preparing PostGIS container for profile: ${SYSTEM_PROFILE}"

# Recreate the container so new tuning always applies.
# Data persists because pgdata is mounted from the host.
if docker ps -a --format '{{.Names}}' | grep -Eq "^${CONTAINER_NAME}$"; then
    echo "Removing existing container '${CONTAINER_NAME}' so updated settings take effect..."
    docker rm -f "${CONTAINER_NAME}" >/dev/null
fi

echo "Creating new container..."
docker run \
  --name "${CONTAINER_NAME}" \
  -e POSTGRES_DB="${DB_NAME}" \
  -e POSTGRES_USER="${DB_USER}" \
  -e POSTGRES_PASSWORD="${DB_PASSWORD}" \
  -p "${DB_PORT}:5432" \
  -v "${PROJECT_DIR}/pgdata:/var/lib/postgresql/data" \
  -d \
  oscar-postgis \
  -c shared_buffers="${PG_SHARED}" \
  -c effective_cache_size="${PG_CACHE}" \
  -c work_mem="${PG_WORK_MEM}" \
  -c maintenance_work_mem="${PG_MAINT}" \
  -c max_connections="${PG_MAX_CONN}" \
  -c wal_buffers=16MB \
  -c random_page_cost=1.1 \
  -c effective_io_concurrency=200 \
  || { echo "Failed to start PostGIS container"; exit 1; }

echo "Waiting for PostGIS to be ready..."
export PGPASSWORD="${DB_PASSWORD}"
until docker exec "${CONTAINER_NAME}" pg_isready -U "${DB_USER}" -d "${DB_NAME}" >/dev/null 2>&1; do
  sleep 2
done

echo "PostGIS is ready."
sleep 5

cd "${PROJECT_DIR}/osh-node-oscar" || { echo "Error: osh-node-oscar not found"; exit 1; }
exec ./launch.sh