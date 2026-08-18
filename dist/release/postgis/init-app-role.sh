#!/bin/sh
set -eu

password_file="${OSCAR_DB_PASSWORD_FILE:-/run/secrets/oscar_db_password}"

if [ ! -s "${password_file}" ]; then
    echo "ERROR: OSCAR database password secret is missing or empty" >&2
    exit 1
fi

app_password="$(head -n 1 "${password_file}")"
if [ -z "${app_password}" ]; then
    echo "ERROR: OSCAR database password secret is empty" >&2
    exit 1
fi

psql --set=ON_ERROR_STOP=1 \
    --username "${POSTGRES_USER}" \
    --dbname "${POSTGRES_DB}" \
    --set=app_password="${app_password}" \
    --set=database_name="${POSTGRES_DB}" <<'EOSQL'
CREATE ROLE oscar_owner
    NOLOGIN
    NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;

CREATE ROLE oscar_app
    LOGIN PASSWORD :'app_password'
    NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;

REVOKE CONNECT, TEMPORARY ON DATABASE :"database_name" FROM PUBLIC;
GRANT CONNECT, TEMPORARY ON DATABASE :"database_name" TO oscar_app;

REVOKE CREATE ON SCHEMA public FROM PUBLIC;
CREATE SCHEMA oscar AUTHORIZATION oscar_owner;
GRANT USAGE, CREATE ON SCHEMA oscar TO oscar_app;

ALTER ROLE oscar_app IN DATABASE :"database_name" SET search_path = oscar, public;
EOSQL
