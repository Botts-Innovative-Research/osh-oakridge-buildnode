#!/bin/bash

CONTAINER_NAME="oscar-postgis-container"

echo "Stopping container: $CONTAINER_NAME..."

# Stop container if running
if sudo docker ps -a --format '{{.Names}}' | grep -Eq "^${CONTAINER_NAME}$"; then
    sudo docker stop "$CONTAINER_NAME"
    echo "Container stopped and removed."
else
    echo "Container not found. Nothing to stop."
fi

echo "Done."
