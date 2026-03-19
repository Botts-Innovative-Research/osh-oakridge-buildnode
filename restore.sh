#!/bin/bash

DB_HOST="${DB_HOST:-localhost}"
DB_NAME="gis"
DB_USER="postgres"

if [ -z "$POSTGRES_PASSWORD_FILE" ]; then
    echo "Error: POSTGRES_PASSWORD_FILE environment variable is not set."
    exit 1
fi

if [ ! -f "$POSTGRES_PASSWORD_FILE" ]; then
    echo "Error: Password file $POSTGRES_PASSWORD_FILE does not exist."
    exit 1
fi

if [ -z "$1" ]; then
    echo "Usage: $0 <backup_file>"
    exit 1
fi

BACKUP_FILE="$1"
export PGPASSWORD=$(cat "$POSTGRES_PASSWORD_FILE")

echo "Restoring database $DB_NAME to $DB_HOST from $BACKUP_FILE..."
pg_restore -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" -v "$BACKUP_FILE"

if [ $? -eq 0 ]; then
    echo "Restore completed successfully."
else
    echo "Restore failed."
    exit 1
fi
