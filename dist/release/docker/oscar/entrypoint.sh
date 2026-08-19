#!/bin/sh
set -eu

STATE_DIR=/var/lib/oscar
CONFIG_FILE="${STATE_DIR}/config.json"
DEFAULT_CONFIG=/opt/oscar/config.json
ADMIN_PASSWORD_FILE="${INITIAL_ADMIN_PASSWORD_FILE:-/run/secrets/oscar_admin_password}"
DB_PASSWORD_FILE="${OSCAR_DB_PASSWORD_FILE:-/run/secrets/oscar_db_password}"

umask 077

for directory in db files hivemq-config hivemq-data .moduledata; do
    mkdir -p "${STATE_DIR}/${directory}"
done

for path in lib web rules documentation trusted_certificates config logback.xml sentry.properties; do
    if [ -e "/opt/oscar/${path}" ] && [ ! -e "${STATE_DIR}/${path}" ]; then
        ln -s "/opt/oscar/${path}" "${STATE_DIR}/${path}"
    fi
done

if [ ! -f "${CONFIG_FILE}" ]; then
    if [ ! -s "${ADMIN_PASSWORD_FILE}" ]; then
        echo "ERROR: initial OSCAR administrator password secret is missing or empty" >&2
        exit 1
    fi
    if [ ! -s "${DB_PASSWORD_FILE}" ]; then
        echo "ERROR: OSCAR database password secret is missing or empty" >&2
        exit 1
    fi

    cp "${DEFAULT_CONFIG}" "${CONFIG_FILE}"
    sed -i \
        -e 's|"url": "localhost:5432"|"url": "postgres:5432"|' \
        -e 's|"passwordFile": ""|"passwordFile": "/run/secrets/oscar_db_password"|' \
        "${CONFIG_FILE}"

    encoded_password="$(java -classpath '/opt/oscar/lib/*' com.botts.impl.security.PBKDF2CredentialProvider < "${ADMIN_PASSWORD_FILE}" | tail -n 1)"
    if [ -z "${encoded_password}" ]; then
        echo "ERROR: failed to encode the initial OSCAR administrator password" >&2
        exit 1
    fi
    escaped_password="$(printf '%s' "${encoded_password}" | sed 's/[&|\\]/\\&/g')"
    sed -i "s|__INITIAL_ADMIN_PASSWORD__|${escaped_password}|" "${CONFIG_FILE}"
fi

if grep -q '__INITIAL_ADMIN_PASSWORD__' "${CONFIG_FILE}"; then
    echo "ERROR: OSCAR configuration still contains an unset administrator password" >&2
    exit 1
fi

# JAVA_OPTS is intentionally word-split so administrators can provide normal JVM options.
# shellcheck disable=SC2086
exec java ${JAVA_OPTS:-} \
    -Dlogback.configurationFile=/opt/oscar/logback.xml \
    -cp '/opt/oscar/lib/*' \
    -Djava.system.class.loader=org.sensorhub.utils.NativeClassLoader \
    -Djava.library.path=/opt/oscar/nativelibs \
    org.sensorhub.impl.SensorHub "${CONFIG_FILE}" "${STATE_DIR}/db"
