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

export PGPASSWORD=$(cat "$POSTGRES_PASSWORD_FILE")

echo "Backing up database $DB_NAME from $DB_HOST..."
pg_dump -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" -F c -f "backup_$(date +%Y%m%d_%H%M%S).dump"

if [ $? -eq 0 ]; then
    echo "Backup completed successfully."
else
    echo "Backup failed."
    exit 1
fi
