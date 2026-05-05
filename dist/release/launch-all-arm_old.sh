#!/bin/bash
set -euo pipefail

# Apple Silicon / ARM64 launcher for the full OSH + PostGIS stack.
# Resolves paths from this script's location, not from the caller's cwd.

SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
  SOURCE_DIR="$(CDPATH= cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  case "$SOURCE" in
    /*) ;;
    *) SOURCE="${SOURCE_DIR}/${SOURCE}" ;;
  esac
done
PROJECT_DIR="$(CDPATH= cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"
ENV_FILE="${PROJECT_DIR}/.env"

IMAGE_NAME="${POSTGIS_IMAGE_NAME:-${IMAGE_NAME:-oscar-postgis-arm}}"
POSTGIS_DOCKERFILE="${POSTGIS_DOCKERFILE:-Dockerfile-arm64}"
POSTGIS_PLATFORM="${POSTGIS_PLATFORM:-linux/arm64}"

if [ ! -f "$ENV_FILE" ]; then
  echo "Error: .env file not found in ${PROJECT_DIR}."
  echo "Create it by copying env.template to .env and editing the values."
  exit 1
fi

# Export values from .env so osh-node-oscar/launch.sh can use the same settings.
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

# Remove a possible CR from values if .env was edited on Windows.
strip_cr_var() {
  _name="$1"
  eval "_value=\${${_name}-}"
  _value="${_value%$'\r'}"
  export "${_name}=${_value}"
}

for _var in \
  SYSTEM_PROFILE DB_NAME DB_USER DB_PASSWORD DB_PORT DB_HOST CONTAINER_NAME \
  KEYSTORE_PASSWORD TRUSTSTORE_PASSWORD JAVACPP_MAX_BYTES \
  JAVACPP_MAX_PHYSICAL_BYTES JFR_FILENAME RETRY_MAX RETRY_INTERVAL \
  POSTGIS_READY_DELAY IMAGE_NAME POSTGIS_IMAGE_NAME POSTGIS_DOCKERFILE POSTGIS_PLATFORM
 do
  strip_cr_var "$_var"
done
unset _var

SYSTEM_PROFILE="${SYSTEM_PROFILE:-8GB}"
CONTAINER_NAME="${CONTAINER_NAME:-oscar-postgis-container}"
DB_HOST="${DB_HOST:-localhost}"
RETRY_MAX="${RETRY_MAX:-120}"
RETRY_INTERVAL="${RETRY_INTERVAL:-2}"
POSTGIS_READY_DELAY="${POSTGIS_READY_DELAY:-5}"
IMAGE_NAME="${POSTGIS_IMAGE_NAME:-${IMAGE_NAME:-oscar-postgis-arm}}"
POSTGIS_DOCKERFILE="${POSTGIS_DOCKERFILE:-Dockerfile-arm64}"
POSTGIS_PLATFORM="${POSTGIS_PLATFORM:-linux/arm64}"
export SYSTEM_PROFILE CONTAINER_NAME DB_HOST RETRY_MAX RETRY_INTERVAL POSTGIS_READY_DELAY
export IMAGE_NAME POSTGIS_DOCKERFILE POSTGIS_PLATFORM

require_env() {
  _name="$1"
  eval "_value=\${${_name}:-}"
  if [ -z "$_value" ]; then
    echo "Error: ${_name} is not set in .env."
    exit 1
  fi
}

require_env DB_NAME
require_env DB_USER
require_env DB_PASSWORD
require_env DB_PORT

require_number() {
  _name="$1"
  eval "_value=\${${_name}:-}"
  case "$_value" in
    *[!0-9]*|'')
      echo "Error: ${_name} must be a number, got '${_value}'."
      exit 1
      ;;
  esac
}

require_number DB_PORT
require_number RETRY_MAX
require_number RETRY_INTERVAL
require_number POSTGIS_READY_DELAY

PROFILE_UPPER="$(printf '%s' "$SYSTEM_PROFILE" | tr '[:lower:]' '[:upper:]')"
case "$PROFILE_UPPER" in
  "RPI4")
    SYSTEM_PROFILE="RPI4"
    PG_SHARED="256MB"
    PG_CACHE="1GB"
    PG_WORK_MEM="2MB"
    PG_MAINT="64MB"
    PG_MAX_CONN="75"
    ;;
  "8GB")
    SYSTEM_PROFILE="8GB"
    PG_SHARED="512MB"
    PG_CACHE="2GB"
    PG_WORK_MEM="4MB"
    PG_MAINT="128MB"
    PG_MAX_CONN="125"
    ;;
  "16GB")
    SYSTEM_PROFILE="16GB"
    PG_SHARED="1GB"
    PG_CACHE="4GB"
    PG_WORK_MEM="8MB"
    PG_MAINT="256MB"
    PG_MAX_CONN="200"
    ;;
  "32GB")
    SYSTEM_PROFILE="32GB"
    PG_SHARED="2GB"
    PG_CACHE="8GB"
    PG_WORK_MEM="16MB"
    PG_MAINT="512MB"
    PG_MAX_CONN="300"
    ;;
  *)
    echo "Unknown profile '${SYSTEM_PROFILE}', using 8GB defaults."
    SYSTEM_PROFILE="8GB"
    PG_SHARED="512MB"
    PG_CACHE="2GB"
    PG_WORK_MEM="4MB"
    PG_MAINT="128MB"
    PG_MAX_CONN="125"
    ;;
esac

# Keep sanitized/defaulted values available to the child launch.sh.
export SYSTEM_PROFILE CONTAINER_NAME DB_NAME DB_USER DB_PASSWORD DB_PORT

mkdir -p "${PROJECT_DIR}/pgdata"

if ! command -v docker >/dev/null 2>&1; then
  echo "Error: Docker is not installed or is not in PATH."
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "Error: Docker is installed, but the Docker daemon is not running."
  echo "Start Docker Desktop, then run this script again."
  exit 1
fi

POSTGIS_DIR="${PROJECT_DIR}/postgis"
if [ ! -d "$POSTGIS_DIR" ]; then
  echo "Error: postgis directory not found in ${PROJECT_DIR}."
  exit 1
fi

if [ ! -f "${POSTGIS_DIR}/${POSTGIS_DOCKERFILE}" ]; then
  echo "Error: ${POSTGIS_DOCKERFILE} not found in ${POSTGIS_DIR}."
  exit 1
fi

echo "Building PostGIS Docker image for Apple Silicon / ARM64..."
cd "$POSTGIS_DIR"
if [ -n "${POSTGIS_PLATFORM:-}" ]; then
  docker build --platform "$POSTGIS_PLATFORM" . --file="$POSTGIS_DOCKERFILE" --tag="$IMAGE_NAME"
else
  docker build . --file="$POSTGIS_DOCKERFILE" --tag="$IMAGE_NAME"
fi

echo "Preparing PostGIS container for profile: ${SYSTEM_PROFILE}"
echo "  Image: ${IMAGE_NAME}"
echo "  Dockerfile: ${POSTGIS_DOCKERFILE}"
echo "  Port: ${DB_PORT}:5432"
echo "  Data: ${PROJECT_DIR}/pgdata"

# Recreate the container so profile/tuning changes always take effect.
# Data persists because pgdata is mounted from the host.
if docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
  echo "Removing existing container '${CONTAINER_NAME}' so updated settings take effect..."
  docker rm -f "$CONTAINER_NAME" >/dev/null
fi

echo "Creating new PostGIS container..."
docker run \
  --name "$CONTAINER_NAME" \
  -e POSTGRES_DB="$DB_NAME" \
  -e POSTGRES_USER="$DB_USER" \
  -e POSTGRES_PASSWORD="$DB_PASSWORD" \
  -e DATADIR=/var/lib/postgresql/data \
  -p "${DB_PORT}:5432" \
  -v "${PROJECT_DIR}/pgdata:/var/lib/postgresql/data" \
  -d \
  "$IMAGE_NAME" \
  -c shared_buffers="$PG_SHARED" \
  -c effective_cache_size="$PG_CACHE" \
  -c work_mem="$PG_WORK_MEM" \
  -c maintenance_work_mem="$PG_MAINT" \
  -c max_connections="$PG_MAX_CONN" \
  -c superuser_reserved_connections=10 \
  -c idle_session_timeout=600000 \
  -c log_connections=on \
  -c log_disconnections=on \
  -c wal_buffers=16MB \
  -c random_page_cost=1.1 \
  -c effective_io_concurrency=200 \
  || { echo "Failed to start PostGIS container"; exit 1; }

echo "Waiting for PostGIS ARM64 to be ready..."
export PGPASSWORD="$DB_PASSWORD"
RETRY_COUNT=0
until docker exec "$CONTAINER_NAME" pg_isready -U "$DB_USER" -d "$DB_NAME" >/dev/null 2>&1; do
  RETRY_COUNT=$((RETRY_COUNT + 1))
  if [ "$RETRY_COUNT" -ge "$RETRY_MAX" ]; then
    echo "Error: PostGIS did not become ready after $((RETRY_MAX * RETRY_INTERVAL)) seconds."
    echo "Last container logs:"
    docker logs --tail 50 "$CONTAINER_NAME" || true
    exit 1
  fi
  echo "PostGIS not ready yet, retrying..."
  sleep "$RETRY_INTERVAL"
done

echo "PostGIS is ready. Starting OpenSensorHub..."
sleep "$POSTGIS_READY_DELAY"

OSH_DIR="${PROJECT_DIR}/osh-node-oscar"
if [ ! -d "$OSH_DIR" ]; then
  echo "Error: osh-node-oscar directory not found in ${PROJECT_DIR}."
  exit 1
fi

cd "$OSH_DIR"
if [ ! -f "./launch.sh" ]; then
  echo "Error: launch.sh was not found in ${OSH_DIR}."
  exit 1
fi

if [ ! -x "./launch.sh" ]; then
  chmod +x ./launch.sh
fi

exec ./launch.sh
