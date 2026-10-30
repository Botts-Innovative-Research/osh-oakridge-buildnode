#!/bin/sh
set -eu

STATE_DIR=/var/lib/oscar
CONFIG_FILE="${STATE_DIR}/config.json"
DEFAULT_CONFIG=/opt/oscar/config.json
ADMIN_PASSWORD_FILE="${INITIAL_ADMIN_PASSWORD_FILE:-/run/secrets/oscar_admin_password}"
DB_PASSWORD_FILE="${OSCAR_DB_PASSWORD_FILE:-/run/secrets/oscar_db_password}"
NATIVE_TMP_DIR=/run/oscar-native
READY_FILE=/tmp/oscar-ready
readonly NATIVE_TMP_DIR
readonly READY_FILE

umask 077

# OpenJDK appends _JAVA_OPTIONS after command-line options. Reject it so an
# ambient environment override cannot undo the managed temp-path separation.
if [ -n "${_JAVA_OPTIONS:-}" ]; then
    echo "ERROR: _JAVA_OPTIONS is not supported; use OSCAR_JAVA_OPTS" >&2
    exit 1
fi

is_tmpfs_mount() {
    awk -v target="$1" '
        $5 == target {
            for (field = 7; field <= NF; field++) {
                if ($field == "-" && $(field + 1) == "tmpfs") found = 1
            }
        }
        END { exit found ? 0 : 1 }
    ' /proc/self/mountinfo
}

mount_has_option() {
    awk -v target="$1" -v required="$2" '
        $5 == target {
            count = split($6, options, ",")
            for (option = 1; option <= count; option++) {
                if (options[option] == required) found = 1
            }
        }
        END { exit found ? 0 : 1 }
    ' /proc/self/mountinfo
}

if ! is_tmpfs_mount /tmp \
    || ! mount_has_option /tmp rw \
    || ! mount_has_option /tmp noexec \
    || ! mount_has_option /tmp nosuid \
    || ! mount_has_option /tmp nodev; then
    echo "ERROR: /tmp must be a dedicated rw,noexec,nosuid,nodev tmpfs" >&2
    exit 1
fi

# Docker can restart the JVM in the same container. Remove any marker left by
# an ungraceful prior process before the HTTP server has a chance to accept
# traffic; the OSCAR service republishes it only after every top-level
# auto-start module is started and its nested members complete their startup
# attempt, including devices that explicitly settle offline.
if ! rm -f -- "${READY_FILE}" "${READY_FILE}.tmp"; then
    echo "ERROR: cannot clear the OSCAR application-readiness marker" >&2
    exit 1
fi
if ! is_tmpfs_mount "${NATIVE_TMP_DIR}" \
    || ! mount_has_option "${NATIVE_TMP_DIR}" rw \
    || ! mount_has_option "${NATIVE_TMP_DIR}" nosuid \
    || ! mount_has_option "${NATIVE_TMP_DIR}" nodev; then
    echo "ERROR: ${NATIVE_TMP_DIR} must be a dedicated rw,nosuid,nodev tmpfs for JVM native libraries" >&2
    exit 1
fi

expected_native_tmp_metadata="$(id -u):$(id -g):700"
actual_native_tmp_metadata="$(stat -c '%u:%g:%a' "${NATIVE_TMP_DIR}")"
if [ "${actual_native_tmp_metadata}" != "${expected_native_tmp_metadata}" ]; then
    echo "ERROR: ${NATIVE_TMP_DIR} must be owned by the OSCAR runtime user with mode 0700" >&2
    exit 1
fi

# A directory can have search permission while its mount still forbids native
# code mappings. Execute a private disposable probe so a bad Compose override
# fails at startup instead of hours later in the archive worker.
native_exec_probe="${NATIVE_TMP_DIR}/.exec-probe.$$"
if ! cp /bin/true "${native_exec_probe}" \
    || ! chmod 0500 "${native_exec_probe}" \
    || ! "${native_exec_probe}"; then
    rm -f -- "${native_exec_probe}"
    echo "ERROR: ${NATIVE_TMP_DIR} must permit execution for JVM native libraries" >&2
    exit 1
fi
if ! rm -f -- "${native_exec_probe}"; then
    echo "ERROR: cannot remove the JVM native-directory startup probe" >&2
    exit 1
fi

for directory in db files hivemq-config hivemq-data .moduledata; do
    mkdir -p "${STATE_DIR}/${directory}"
done

for path in lib web rules documentation trusted_certificates config logback.xml; do
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

# The image copy is deliberately read-only. Combined with the restrictive
# umask, a plain cp seeds the state volume as 0400 even though this runtime
# configuration is expected to be writable by its owner. Normalize new files
# and repair existing affected volumes without granting group/world access.
if ! chmod 0600 "${CONFIG_FILE}"; then
    echo "ERROR: OSCAR configuration is not writable by the runtime user" >&2
    exit 1
fi

if grep -q '__INITIAL_ADMIN_PASSWORD__' "${CONFIG_FILE}"; then
    echo "ERROR: OSCAR configuration still contains an unset administrator password" >&2
    exit 1
fi

# JAVA_OPTS is intentionally word-split so administrators can provide normal JVM options.
# The managed temporary-directory settings follow JAVA_OPTS so native extraction
# cannot be redirected to /tmp and user-controlled data cannot enter the executable mount.
# shellcheck disable=SC2086
exec java ${JAVA_OPTS:-} \
    -Duser.timezone="${TZ:-UTC}" \
    -Djava.io.tmpdir="${NATIVE_TMP_DIR}" \
    -Dorg.bytedeco.javacpp.cachedir="${NATIVE_TMP_DIR}/javacpp" \
    -Doscar.data.tmpdir=/tmp \
    -Dlogback.configurationFile=/opt/oscar/logback.xml \
    -cp '/opt/oscar/lib/*' \
    -Djava.system.class.loader=org.sensorhub.utils.NativeClassLoader \
    -Djava.library.path=/opt/oscar/nativelibs \
    org.sensorhub.impl.SensorHub "${CONFIG_FILE}" "${STATE_DIR}/db"
