#!/usr/bin/env bash
set -euo pipefail

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
ENV_FILE="$PROJECT_DIR/.env"
MATCH_EXPR='com.botts.impl.security.SensorHubWrapper'
FORCE_RESTART="${FORCE_RESTART:-0}"
RETRY_MAX="${RETRY_MAX:-120}"
RETRY_INTERVAL="${RETRY_INTERVAL:-2}"
POSTGIS_READY_DELAY="${POSTGIS_READY_DELAY:-5}"
IMAGE_NAME="${POSTGIS_IMAGE_NAME:-${IMAGE_NAME:-oscar-postgis-arm}}"
POSTGIS_DOCKERFILE="${POSTGIS_DOCKERFILE:-Dockerfile-arm64}"
POSTGIS_PLATFORM="${POSTGIS_PLATFORM:-linux/arm64}"

load_env() {
    local env_file="$1"
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ""|"#"*) continue ;;
            export\ *) line="${line#export }" ;;
        esac
        local name="${line%%=*}"
        local value="${line#*=}"
        value="${value%$'\r'}"
        export "${name}=${value}"
    done < "$env_file"
}

require_cmd() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: required command not found: $cmd"
        exit 1
    fi
}

find_existing_oscar_pids() {
    pgrep -f "$MATCH_EXPR" || true
}

stop_existing_oscar() {
    local pids="$1"
    if [ -z "$pids" ]; then
        return 0
    fi

    echo "Stopping existing OSCAR instance(s): $pids"
    kill $pids 2>/dev/null || true

    local waited=0
    while [ "$waited" -lt 15 ]; do
        sleep 1
        waited=$((waited + 1))
        if [ -z "$(find_existing_oscar_pids)" ]; then
            return 0
        fi
    done

    echo "Existing OSCAR instance still running after graceful stop. Forcing stop."
    kill -9 $pids 2>/dev/null || true
    sleep 1

    if [ -n "$(find_existing_oscar_pids)" ]; then
        echo "Error: unable to stop the existing OSCAR instance."
        exit 1
    fi
}

check_existing_oscar() {
    local pids
    pids="$(find_existing_oscar_pids)"

    if [ -z "$pids" ]; then
        return 0
    fi

    if [ "$FORCE_RESTART" = "1" ]; then
        echo "Existing OSCAR instance found with PID(s): $pids. Replacing because FORCE_RESTART=1."
        stop_existing_oscar "$pids"
        return 0
    fi

    echo "OSCAR is already running with PID(s): $pids."
    echo "Stop the running instance first, or set FORCE_RESTART=1 to replace it."
    exit 1
}

require_number() {
    local name="$1"
    local value="${!name:-}"
    case "$value" in
        ''|*[!0-9]*)
            echo "Error: ${name} must be a number, got '${value}'."
            exit 1
            ;;
    esac
}

ensure_project_layout() {
    if [ ! -d "$PROJECT_DIR/postgis" ]; then
        echo "Error: postgis directory not found in $PROJECT_DIR"
        exit 1
    fi

    if [ ! -f "$PROJECT_DIR/postgis/$POSTGIS_DOCKERFILE" ]; then
        echo "Error: $POSTGIS_DOCKERFILE not found in $PROJECT_DIR/postgis"
        exit 1
    fi

    if [ ! -d "$PROJECT_DIR/osh-node-oscar" ]; then
        echo "Error: osh-node-oscar directory not found in $PROJECT_DIR"
        exit 1
    fi

    if [ ! -f "$PROJECT_DIR/osh-node-oscar/launch.sh" ]; then
        echo "Error: launch.sh not found in $PROJECT_DIR/osh-node-oscar"
        exit 1
    fi

    mkdir -p "$PROJECT_DIR/pgdata"
}

if [ -f "$ENV_FILE" ]; then
    load_env "$ENV_FILE"
else
    echo "Warning: .env file not found in $PROJECT_DIR"
    if [ -f "$PROJECT_DIR/env.template" ]; then
        echo "Warning: using built-in defaults. Copy env.template to .env to customize settings."
    else
        echo "Warning: using built-in defaults."
    fi
fi

SYSTEM_PROFILE="${SYSTEM_PROFILE:-8GB}"
CONTAINER_NAME="${CONTAINER_NAME:-oscar-postgis-container}"
DB_NAME="${DB_NAME:-gis}"
DB_USER="${DB_USER:-postgres}"
DB_PASSWORD="${DB_PASSWORD:-postgres}"
DB_PORT="${DB_PORT:-5432}"
DB_HOST="${DB_HOST:-localhost}"
export SYSTEM_PROFILE CONTAINER_NAME DB_NAME DB_USER DB_PASSWORD DB_PORT DB_HOST
export RETRY_MAX RETRY_INTERVAL POSTGIS_READY_DELAY IMAGE_NAME POSTGIS_DOCKERFILE POSTGIS_PLATFORM

require_cmd docker
if ! docker info >/dev/null 2>&1; then
    echo "Error: Docker is installed, but the Docker daemon is not running."
    exit 1
fi

check_existing_oscar
ensure_project_layout
require_number DB_PORT
require_number RETRY_MAX
require_number RETRY_INTERVAL
require_number POSTGIS_READY_DELAY

case "${SYSTEM_PROFILE^^}" in
    RPI4)
        SYSTEM_PROFILE="RPI4"
        PG_SHARED="256MB"
        PG_CACHE="1GB"
        PG_WORK_MEM="2MB"
        PG_MAINT="64MB"
        PG_MAX_CONN="75"
        ;;
    8GB)
        SYSTEM_PROFILE="8GB"
        PG_SHARED="512MB"
        PG_CACHE="2GB"
        PG_WORK_MEM="4MB"
        PG_MAINT="128MB"
        PG_MAX_CONN="125"
        ;;
    16GB)
        SYSTEM_PROFILE="16GB"
        PG_SHARED="1GB"
        PG_CACHE="4GB"
        PG_WORK_MEM="8MB"
        PG_MAINT="256MB"
        PG_MAX_CONN="200"
        ;;
    32GB)
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

echo "Building PostGIS Docker image for Apple Silicon / ARM64..."
(
    cd "$PROJECT_DIR/postgis"
    if [ -n "$POSTGIS_PLATFORM" ]; then
        docker build --platform "$POSTGIS_PLATFORM" . --file="$POSTGIS_DOCKERFILE" --tag="$IMAGE_NAME"
    else
        docker build . --file="$POSTGIS_DOCKERFILE" --tag="$IMAGE_NAME"
    fi
)

echo "Preparing PostGIS container for profile: $SYSTEM_PROFILE"
echo "  Image: $IMAGE_NAME"
echo "  Dockerfile: $POSTGIS_DOCKERFILE"
echo "  Port: ${DB_PORT}:5432"
echo "  Data: $PROJECT_DIR/pgdata"

if docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
    echo "Removing existing container '$CONTAINER_NAME' so updated settings take effect..."
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
    -v "$PROJECT_DIR/pgdata:/var/lib/postgresql/data" \
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
    -c effective_io_concurrency=200

echo "Waiting for PostGIS ARM64 to be ready..."
export PGPASSWORD="$DB_PASSWORD"
retry_count=0
until docker exec "$CONTAINER_NAME" pg_isready -U "$DB_USER" -d "$DB_NAME" >/dev/null 2>&1; do
    retry_count=$((retry_count + 1))
    if [ "$retry_count" -ge "$RETRY_MAX" ]; then
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

cd "$PROJECT_DIR/osh-node-oscar"
if [ ! -x ./launch.sh ]; then
    chmod +x ./launch.sh
fi

exec ./launch.sh
