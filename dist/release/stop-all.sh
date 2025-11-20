#!/bin/bash

CONTAINER_NAME="oscar-postgis-container"
SENSORHUB_NAME="com.botts.impl.security.SensorHubWrapper"

echo "Stopping container: $CONTAINER_NAME..."

# Stop Docker container if it exists
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "Container exists. Stopping..."
    docker stop "$CONTAINER_NAME"
    echo "Container stopped."
else
    echo "Container not found. Nothing to stop."
fi

echo
echo "Stopping SensorHubWrapper Java process..."

PID=""

# --- Option 1: Use jps if available ---
if command -v jps >/dev/null 2>&1; then
    PID=$(jps -l | grep "$SENSORHUB_NAME" | awk '{print $1}')
fi

# --- Option 2: fallback to pgrep if PID not found ---
if [ -z "$PID" ]; then
    if command -v pgrep >/dev/null 2>&1; then
        PID=$(pgrep -f "$SENSORHUB_NAME")
    fi
fi

# --- Kill process if found ---
if [ -n "$PID" ]; then
    echo "Stopping SensorHubWrapper with PID(s): $PID"
    kill -9 $PID
    echo "SensorHubWrapper stopped."
else
    echo "SensorHubWrapper process not found."
fi

echo
echo "Done."
