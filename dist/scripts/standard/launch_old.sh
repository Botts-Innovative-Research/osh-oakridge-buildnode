#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

load_env() {
    local env_file="$1"
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ""|"#"*) continue ;;
            export\ *) line="${line#export }" ;;
        esac
        local name="${line%%=*}"
        local value="${line#*=}"
        export "${name}=${value}"
    done < "$env_file"
}

ENV_FILE=""
if [ -f "$SCRIPT_DIR/.env" ]; then
    ENV_FILE="$SCRIPT_DIR/.env"
elif [ -f "$SCRIPT_DIR/../.env" ]; then
    ENV_FILE="$SCRIPT_DIR/../.env"
fi

if [ -n "$ENV_FILE" ]; then
    load_env "$ENV_FILE"
fi

check_existing_oscar() {
    local pids
    pids="$(pgrep -f 'com.botts.impl.security.SensorHubWrapper' || true)"

    if [ -z "$pids" ]; then
        return 0
    fi

    if [ "${FORCE_RESTART:-0}" = "1" ]; then
        echo "Existing OSCAR instance found with PID(s): $pids. Stopping because FORCE_RESTART=1."
        kill $pids || true
        sleep 2
        return 0
    fi

    echo "OSCAR is already running with PID(s): $pids."
    echo "Run stop-all.sh first, or set FORCE_RESTART=1 to replace the existing OSCAR process."
    return 1
}

check_existing_oscar || exit 1

SYSTEM_PROFILE="${SYSTEM_PROFILE:-8GB}"

case "$SYSTEM_PROFILE" in
    RPI4)
        JAVA_XMS="512m"
        JAVA_XMX="1536m"
        JAVACPP_MAX_BYTES_DEFAULT="512m"
        JAVACPP_MAX_PHYSICAL_BYTES_DEFAULT="2g"
        ;;
    8GB)
        JAVA_XMS="1g"
        JAVA_XMX="2g"
        JAVACPP_MAX_BYTES_DEFAULT="1g"
        JAVACPP_MAX_PHYSICAL_BYTES_DEFAULT="4g"
        ;;
    16GB)
        JAVA_XMS="1g"
        JAVA_XMX="3g"
        JAVACPP_MAX_BYTES_DEFAULT="2g"
        JAVACPP_MAX_PHYSICAL_BYTES_DEFAULT="8g"
        ;;
    32GB)
        JAVA_XMS="2g"
        JAVA_XMX="6g"
        JAVACPP_MAX_BYTES_DEFAULT="4g"
        JAVACPP_MAX_PHYSICAL_BYTES_DEFAULT="16g"
        ;;
    *)
        echo "Unknown profile '$SYSTEM_PROFILE', using 8GB defaults."
        JAVA_XMS="1g"
        JAVA_XMX="2g"
        JAVACPP_MAX_BYTES_DEFAULT="1g"
        JAVACPP_MAX_PHYSICAL_BYTES_DEFAULT="4g"
        ;;
esac

: "${JAVACPP_MAX_BYTES:=$JAVACPP_MAX_BYTES_DEFAULT}"
: "${JAVACPP_MAX_PHYSICAL_BYTES:=$JAVACPP_MAX_PHYSICAL_BYTES_DEFAULT}"
: "${JFR_FILENAME:=$SCRIPT_DIR/oscar.jfr}"

echo "Starting OSH Node with Profile: $SYSTEM_PROFILE"
echo "  Heap: $JAVA_XMS / $JAVA_XMX"
echo "  JavaCPP maxBytes: $JAVACPP_MAX_BYTES"
echo "  JavaCPP maxPhysicalBytes: $JAVACPP_MAX_PHYSICAL_BYTES"
echo "  JFR file: $JFR_FILENAME"

if [ ! -f "$SCRIPT_DIR/load_trusted_certs.sh" ]; then
    echo "Error: load_trusted_certs.sh not found in $SCRIPT_DIR."
    exit 1
fi
bash "$SCRIPT_DIR/load_trusted_certs.sh"

export KEYSTORE="${KEYSTORE:-$SCRIPT_DIR/osh-keystore.p12}"
export KEYSTORE_TYPE="${KEYSTORE_TYPE:-PKCS12}"
export KEYSTORE_PASSWORD="${KEYSTORE_PASSWORD:-atakatak}"

export TRUSTSTORE="${TRUSTSTORE:-$SCRIPT_DIR/truststore.jks}"
export TRUSTSTORE_TYPE="${TRUSTSTORE_TYPE:-JKS}"
export TRUSTSTORE_PASSWORD="${TRUSTSTORE_PASSWORD:-changeit}"

export INITIAL_ADMIN_PASSWORD_FILE="${INITIAL_ADMIN_PASSWORD_FILE:-$SCRIPT_DIR/.s}"

if [ ! -f "$INITIAL_ADMIN_PASSWORD_FILE" ] && [ -z "${INITIAL_ADMIN_PASSWORD:-}" ]; then
    export INITIAL_ADMIN_PASSWORD="admin"
fi

if [ ! -f "$SCRIPT_DIR/set-initial-admin-password.sh" ]; then
    echo "Error: set-initial-admin-password.sh not found in $SCRIPT_DIR."
    exit 1
fi
bash "$SCRIPT_DIR/set-initial-admin-password.sh"

exec java \
    -Xms"$JAVA_XMS" \
    -Xmx"$JAVA_XMX" \
    -Xss256k \
    -XX:ReservedCodeCacheSize=256m \
    -XX:+UseG1GC \
    -XX:+HeapDumpOnOutOfMemoryError \
    -XX:+UnlockDiagnosticVMOptions \
    -XX:NativeMemoryTracking=summary \
    "-Dorg.bytedeco.javacpp.maxBytes=$JAVACPP_MAX_BYTES" \
    "-Dorg.bytedeco.javacpp.maxPhysicalBytes=$JAVACPP_MAX_PHYSICAL_BYTES" \
    -Dorg.bytedeco.javacpp.maxRetries=2 \
    -Dorg.bytedeco.javacpp.mxbean=true \
    "-Dlogback.configurationFile=$SCRIPT_DIR/logback.xml" \
    -cp "$SCRIPT_DIR/lib/*" \
    "-Djava.system.class.loader=org.sensorhub.utils.NativeClassLoader" \
    "-Djava.library.path=$SCRIPT_DIR/nativelibs" \
    com.botts.impl.security.SensorHubWrapper "$SCRIPT_DIR/config.json" "$SCRIPT_DIR/db"