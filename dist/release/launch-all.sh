#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "${SCRIPT_DIR}"

if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: Docker is not installed or is not available in PATH." >&2
    exit 1
fi

for required_file in \
    secrets/oscar-admin-password.txt \
    secrets/oscar-db-password.txt \
    secrets/postgres-bootstrap-password.txt \
    tls/server.crt \
    tls/server.key; do
    if [ ! -s "${required_file}" ]; then
        echo "ERROR: Required deployment file is missing or empty: ${required_file}" >&2
        echo "Run the OSCAR setup workflow before starting the deployment." >&2
        exit 1
    fi
done

docker compose up --detach --build
