#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"
MONITOR_SCRIPT="$SCRIPT_DIR/monitor-oscar.sh"
STATE_DIR="$SCRIPT_DIR/.monitor-state"
LOCK_DIR="$STATE_DIR/lock"
CONTAINER_NAME="oscar-postgis-container"
SENSORHUB_NAME="com.botts.impl.security.SensorHubWrapper"

if [ -f "$ENV_FILE" ]; then
    set -a
    . "$ENV_FILE"
    set +a
    CONTAINER_NAME="${CONTAINER_NAME:-oscar-postgis-container}"
fi

echo "Requesting monitor stop if active..."
if [ -x "$MONITOR_SCRIPT" ]; then
    "$MONITOR_SCRIPT" stop || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if [ ! -d "$LOCK_DIR" ]; then
            break
        fi
        sleep 1
    done
fi

echo
printf 'Stopping container: %s...\n' "$CONTAINER_NAME"
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
    echo "Container stop requested."
else
    echo "Container not found."
fi

echo
echo "Stopping SensorHubWrapper Java process..."
PIDS="$(pgrep -f "$SENSORHUB_NAME" || true)"
if [ -n "$PIDS" ]; then
    echo "Stopping SensorHubWrapper with PID(s): $PIDS"
    kill $PIDS 2>/dev/null || true
    sleep 3
    REMAINING="$(pgrep -f "$SENSORHUB_NAME" || true)"
    if [ -n "$REMAINING" ]; then
        echo "Force killing remaining PID(s): $REMAINING"
        kill -9 $REMAINING 2>/dev/null || true
    fi
else
    echo "SensorHubWrapper process not found."
fi

echo
echo "Done."
