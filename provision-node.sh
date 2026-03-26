#!/bin/bash
# OSCAR API Key Provisioning Utility (Unix/Linux/macOS)
# Uses Tailscale to securely push an API key to a remote node.

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <tailscale-ip-or-name> <api-key>"
    exit 1
fi

NODE_TARGET=$1
API_KEY=$2
CONFIG_PATH="/opt/sensorhub/config/standard/config.json"

echo "Attempting to push API key to $NODE_TARGET..."

# Create a temporary file with the key
echo "$API_KEY" > .tmp_apikey

# Use Tailscale to push the file
tailscale file cp .tmp_apikey "$NODE_TARGET:"

# Use Tailscale SSH to move the key into the configuration
# This assumes the remote node has tailscale ssh enabled and the user has permissions.
# We append it to a known environment file or update config.json via a script if available.
# For simplicity, we'll assume a standard location for local secrets.
tailscale ssh "$NODE_TARGET" "mkdir -p /opt/sensorhub/secrets && mv .tmp_apikey /opt/sensorhub/secrets/api_key && chmod 600 /opt/sensorhub/secrets/api_key"

rm .tmp_apikey
echo "Provisioning complete for $NODE_TARGET"
