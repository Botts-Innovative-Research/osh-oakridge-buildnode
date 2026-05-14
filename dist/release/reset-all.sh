#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE="${SCRIPT_DIR}/.env"
if [[ -f "${ENV_FILE}" ]]; then
  while IFS='=' read -r key value; do
    [[ -z "${key}" ]] && continue
    [[ "${key:0:1}" == "#" ]] && continue
    if [[ "${key:0:7}" == "export " ]]; then
      key="${key:7}"
    fi
    export "${key}=${value}"
  done < "${ENV_FILE}"
fi

CONTAINER_NAME="${CONTAINER_NAME:-oscar-postgis-container}"

PGDATA_DIR="${SCRIPT_DIR}/pgdata"
NODE_DIR="${SCRIPT_DIR}/osh-node-oscar"
DB_DIR="${NODE_DIR}/db"
FILES_DIR="${NODE_DIR}/files"
CONFIG_JSON="${NODE_DIR}/config.json"
CONFIG_TEMPLATE="${NODE_DIR}/config.template.json"
SECRET_FILE="${NODE_DIR}/.s"

echo "Requesting monitor shutdown..."
if [[ -x "${SCRIPT_DIR}/monitor-oscar.sh" ]]; then
  "${SCRIPT_DIR}/monitor-oscar.sh" stop >/dev/null 2>&1 || true
fi

echo "Stopping OSCAR Java processes..."
pgrep -af 'com\.botts\.impl\.security\.SensorHubWrapper' >/dev/null 2>&1 && \
  pkill -f 'com\.botts\.impl\.security\.SensorHubWrapper' >/dev/null 2>&1 || true

echo "Removing container: ${CONTAINER_NAME}..."
docker rm -f -v "${CONTAINER_NAME}" >/dev/null 2>&1 || true

if [[ -d "${PGDATA_DIR}" ]]; then
  echo "Removing Postgres data directory: ${PGDATA_DIR}"
  rm -rf "${PGDATA_DIR}"
else
  echo "Postgres data directory not found: ${PGDATA_DIR}"
fi

if [[ -d "${DB_DIR}" ]]; then
  echo "Removing OSCAR runtime DB directory: ${DB_DIR}"
  rm -rf "${DB_DIR}"
else
  echo "OSCAR runtime DB directory not found: ${DB_DIR}"
fi

if [[ -d "${FILES_DIR}" ]]; then
  echo "Removing OSCAR files directory: ${FILES_DIR}"
  rm -rf "${FILES_DIR}"
else
  echo "OSCAR files directory not found: ${FILES_DIR}"
fi

if [[ -f "${CONFIG_TEMPLATE}" ]]; then
  echo "Restoring config.json from template: ${CONFIG_TEMPLATE}"
  cp -f "${CONFIG_TEMPLATE}" "${CONFIG_JSON}"
elif [[ -f "${CONFIG_JSON}" ]]; then
  echo "WARNING: config.template.json not found. Resetting admin password placeholder in existing config.json."
  perl -0pi -e 's/("id"\s*:\s*"admin"[\s\S]*?"password"\s*:\s*)"(?:[^"\\]|\\.)*"/$1"__INITIAL_ADMIN_PASSWORD__"/s' "${CONFIG_JSON}"
else
  echo "OSCAR config not found: ${CONFIG_JSON}"
fi

echo "Restoring initial admin secret file: ${SECRET_FILE}"
printf 'oscar\n' > "${SECRET_FILE}"

rm -f "${SCRIPT_DIR}/.monitor-active-dir"

echo
echo "Reset complete."
echo "Next launch should initialize the default login as admin / oscar."