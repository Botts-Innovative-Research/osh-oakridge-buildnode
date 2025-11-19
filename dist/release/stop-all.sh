#!/bin/bash

CONTAINER_NAME="oscar-postgis-container"
SENSORHUB_NAME="com.botts.impl.security.SensorHubWrapper"

echo "Stopping container: $CONTAINER_NAME..."

# Stop container if running
if sudo docker ps -a --format '{{.Names}}' | grep -Eq "^${CONTAINER_NAME}$"; then
    sudo docker stop "$CONTAINER_NAME"
    echo "Container stopped and removed."
else
    echo "Container not found. Nothing to stop."
fi

echo "Stopping SensorHubWrapper Java Process"

SENSORHUB_PID=$(jps -l | grep "$SENSORHUB_NAME" | awk '{print $1}')

if [ -n "$SENSORHUB_PID" ]; then
    echo "Stopping SensorHubWrapper Java process with PID $SENSORHUB_PID..."
    kill -9 "$SENSORHUB_PID"
    echo "SensorHubWrapper stopped."
else
    echo "SensorHubWrapper process not found."
fi

echo "Done."
