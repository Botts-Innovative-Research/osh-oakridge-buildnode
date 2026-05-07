#!/bin/bash
set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER_NAME="${CONTAINER_NAME:-oscar-postgis-container}"
SENSORHUB_NAME='com.botts.impl.security.SensorHubWrapper'
MONITOR_SCRIPT="$SCRIPT_DIR/monitor-oscar.sh"
MONITOR_PID_FILE="$SCRIPT_DIR/monitor.pid"

request_monitor_stop() {
    echo "Requesting monitor shutdown..."
    if [ -f "$MONITOR_SCRIPT" ]; then
        (bash "$MONITOR_SCRIPT" stop >/dev/null 2>&1 || true) &
    elif [ -f "$MONITOR_PID_FILE" ]; then
        monitor_pid="$(tr -d '[:space:]' < "$MONITOR_PID_FILE")"
        if [ -n "$monitor_pid" ] && kill -0 "$monitor_pid" 2>/dev/null; then
            kill "$monitor_pid" 2>/dev/null || true
        fi
    fi
}

stop_sensorhub() {
    local pids=""

    if command -v jps >/dev/null 2>&1; then
        pids="$(jps -l | awk -v name="$SENSORHUB_NAME" '$2==name {print $1}')"
    fi

    if [ -z "$pids" ] && command -v pgrep >/dev/null 2>&1; then
        pids="$(pgrep -f "$SENSORHUB_NAME" || true)"
    fi

    if [ -n "$pids" ]; then
        echo "Stopping SensorHubWrapper with PID(s): $pids"
        kill $pids 2>/dev/null || true
        sleep 2
        if command -v pgrep >/dev/null 2>&1 && pgrep -f "$SENSORHUB_NAME" >/dev/null 2>&1; then
            echo "Force stopping SensorHubWrapper..."
            pkill -9 -f "$SENSORHUB_NAME" 2>/dev/null || true
        fi
        echo "SensorHubWrapper stopped."
    else
        echo "SensorHubWrapper process not found."
    fi
}

stop_container() {
    echo "Stopping container: $CONTAINER_NAME..."
    if command -v docker >/dev/null 2>&1 && docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
        echo "Container stop requested."
    else
        echo "Container not found. Nothing to stop."
    fi
}

request_monitor_stop
sleep 2
stop_sensorhub
stop_container
rm -f "$MONITOR_PID_FILE"

echo
echo "Done."
