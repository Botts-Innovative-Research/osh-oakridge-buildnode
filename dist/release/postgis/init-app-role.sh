#!/bin/sh
set -eu

profile_version="${OSCAR_STORAGE_PROFILE_VERSION:?OSCAR_STORAGE_PROFILE_VERSION is required}"
case "${profile_version}" in
    ''|*[!0-9A-Za-z.-]*) echo 'ERROR: invalid OSCAR storage-profile version' >&2; exit 1 ;;
esac

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

checksum_status="$(psql --set=ON_ERROR_STOP=1 --tuples-only --no-align \
    --username "${POSTGRES_USER}" --dbname "${POSTGRES_DB}" \
    --command 'SHOW data_checksums;')"
if [ "${checksum_status}" != "on" ]; then
    echo "ERROR: OSCAR ${profile_version} requires data checksums on a newly initialized PostgreSQL cluster" >&2
    exit 1
fi

# This marker distinguishes a cluster initialized under the complete release
# storage profile from an older volume that merely started under a newer image.
# SHOW data_checksums remains the authoritative runtime check.
{
    printf 'format=oscar-storage-profile\n'
    printf 'version=%s\n' "${profile_version}"
    printf 'data_checksums=on\n'
    printf 'initialized_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} >"${PGDATA}/.oscar-data-checksum-init"
chmod 0600 "${PGDATA}/.oscar-data-checksum-init"
