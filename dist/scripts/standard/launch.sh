#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MATCH_EXPR='com.botts.impl.security.SensorHubWrapper'

load_env() {
    local env_file="$1"
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ""|"#"*) continue ;;
            export\ *) line="${line#export }" ;;
        esac
        local name="${line%%=*}"
        local value="${line#*=}"
        value="${value%$'\r'}"
        export "${name}=${value}"
    done < "$env_file"
}

require_cmd() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: required command not found: $cmd"
        exit 1
    fi
}

get_java_major() {
    java -version 2>&1 | awk -F'"' '/version/ { split($2, v, "."); print v[1]; exit }'
}

check_dependencies() {
    require_cmd bash
    require_cmd java
    require_cmd keytool

    local java_major
    java_major="$(get_java_major || true)"
    if [[ -z "$java_major" || ! "$java_major" =~ ^[0-9]+$ ]]; then
        echo "Error: could not determine Java version. Java 21 or newer is required."
        exit 1
    fi
    if [ "$java_major" -lt 21 ]; then
        echo "Error: Java 21 or newer is required. Found Java $java_major."
        exit 1
    fi
}

find_existing_oscar_pids() {
    pgrep -f "$MATCH_EXPR" || true
}

stop_existing_oscar() {
    local pids="$1"
    if [ -z "$pids" ]; then
        return 0
    fi

    echo "Stopping existing OSCAR instance(s): $pids"
    kill $pids 2>/dev/null || true

    local waited=0
    while [ "$waited" -lt 15 ]; do
        sleep 1
        waited=$((waited + 1))
        if [ -z "$(find_existing_oscar_pids)" ]; then
            return 0
        fi
    done

    echo "Existing OSCAR instance still running after graceful stop. Forcing stop."
    kill -9 $pids 2>/dev/null || true
    sleep 1

    if [ -n "$(find_existing_oscar_pids)" ]; then
        echo "Error: unable to stop the existing OSCAR instance."
        exit 1
    fi
}

check_existing_oscar() {
    local pids
    pids="$(find_existing_oscar_pids)"

    if [ -z "$pids" ]; then
        return 0
    fi

    if [ "${FORCE_RESTART:-0}" = "1" ]; then
        echo "Existing OSCAR instance found with PID(s): $pids. Replacing because FORCE_RESTART=1."
        stop_existing_oscar "$pids"
        return 0
    fi

    echo "OSCAR is already running with PID(s): $pids."
    echo "Run stop-all.sh first, or set FORCE_RESTART=1 to replace the existing OSCAR process."
    exit 1
}

ensure_runtime_paths() {
    if [ ! -f "$SCRIPT_DIR/config.json" ]; then
        echo "Error: missing config file: $SCRIPT_DIR/config.json"
        exit 1
    fi

    if [ ! -d "$SCRIPT_DIR/lib" ]; then
        echo "Error: missing library directory: $SCRIPT_DIR/lib"
        exit 1
    fi

    if [ ! -f "$SCRIPT_DIR/load_trusted_certs.sh" ]; then
        echo "Error: load_trusted_certs.sh not found in $SCRIPT_DIR"
        exit 1
    fi

    if [ ! -f "$SCRIPT_DIR/set-initial-admin-password.sh" ]; then
        echo "Error: set-initial-admin-password.sh not found in $SCRIPT_DIR"
        exit 1
    fi

    mkdir -p "$SCRIPT_DIR/db"
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

check_dependencies
check_existing_oscar
ensure_runtime_paths

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

mkdir -p "$(dirname "$JFR_FILENAME")"

export KEYSTORE="${KEYSTORE:-$SCRIPT_DIR/osh-keystore.p12}"
export KEYSTORE_TYPE="${KEYSTORE_TYPE:-PKCS12}"
export KEYSTORE_PASSWORD="${KEYSTORE_PASSWORD:-atakatak}"

export TRUSTSTORE="${TRUSTSTORE:-$SCRIPT_DIR/trustStore.jks}"
export TRUSTSTORE_TYPE="${TRUSTSTORE_TYPE:-JKS}"
export TRUSTSTORE_PASSWORD="${TRUSTSTORE_PASSWORD:-changeit}"

export INITIAL_ADMIN_PASSWORD_FILE="${INITIAL_ADMIN_PASSWORD_FILE:-$SCRIPT_DIR/.s}"
if [ ! -f "$INITIAL_ADMIN_PASSWORD_FILE" ] && [ -z "${INITIAL_ADMIN_PASSWORD:-}" ]; then
    export INITIAL_ADMIN_PASSWORD="oscar"
fi

if [ -z "${HOME:-}" ] && [ -n "${USER:-}" ]; then
    export HOME="/home/${USER}"
fi

JAVA_LIBRARY_PATH_ARG=()
if [ -d "$SCRIPT_DIR/nativelibs" ]; then
    JAVA_LIBRARY_PATH_ARG=("-Djava.library.path=$SCRIPT_DIR/nativelibs")
else
    echo "Warning: optional native library directory not found: $SCRIPT_DIR/nativelibs"
fi

echo "Starting OSH Node with Profile: $SYSTEM_PROFILE"
echo "  Heap: $JAVA_XMS / $JAVA_XMX"
echo "  JavaCPP maxBytes: $JAVACPP_MAX_BYTES"
echo "  JavaCPP maxPhysicalBytes: $JAVACPP_MAX_PHYSICAL_BYTES"
echo "  JFR file: $JFR_FILENAME"

bash "$SCRIPT_DIR/load_trusted_certs.sh"
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
    "${JAVA_LIBRARY_PATH_ARG[@]}" \
    com.botts.impl.security.SensorHubWrapper "$SCRIPT_DIR/config.json" "$SCRIPT_DIR/db"
