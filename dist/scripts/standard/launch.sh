#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Load .env from current dir or parent dir
if [ -f "${SCRIPT_DIR}/.env" ]; then
    set -a
    . "${SCRIPT_DIR}/.env"
    set +a
elif [ -f "${SCRIPT_DIR}/../.env" ]; then
    set -a
    . "${SCRIPT_DIR}/../.env"
    set +a
fi

case "${SYSTEM_PROFILE:-8GB}" in
  "RPI4")
    JAVA_XMS="512m"
    JAVA_XMX="1536m"
    JAVACPP_MAX_BYTES_DEFAULT="512m"
    JAVACPP_MAX_PHYSICAL_BYTES_DEFAULT="2g"
    ;;
  "8GB")
    JAVA_XMS="1g"
    JAVA_XMX="2g"
    JAVACPP_MAX_BYTES_DEFAULT="1g"
    JAVACPP_MAX_PHYSICAL_BYTES_DEFAULT="4g"
    ;;
  "16GB")
    JAVA_XMS="1g"
    JAVA_XMX="3g"
    JAVACPP_MAX_BYTES_DEFAULT="2g"
    JAVACPP_MAX_PHYSICAL_BYTES_DEFAULT="8g"
    ;;
  "32GB")
    JAVA_XMS="2g"
    JAVA_XMX="6g"
    JAVACPP_MAX_BYTES_DEFAULT="4g"
    JAVACPP_MAX_PHYSICAL_BYTES_DEFAULT="16g"
    ;;
  *)
    JAVA_XMS="1g"
    JAVA_XMX="2g"
    JAVACPP_MAX_BYTES_DEFAULT="1g"
    JAVACPP_MAX_PHYSICAL_BYTES_DEFAULT="4g"
    ;;
esac

JAVACPP_MAX_BYTES="${JAVACPP_MAX_BYTES:-$JAVACPP_MAX_BYTES_DEFAULT}"
JAVACPP_MAX_PHYSICAL_BYTES="${JAVACPP_MAX_PHYSICAL_BYTES:-$JAVACPP_MAX_PHYSICAL_BYTES_DEFAULT}"
JFR_FILENAME="${JFR_FILENAME:-${SCRIPT_DIR}/oscar.jfr}"

echo "Starting OSH Node with Profile: ${SYSTEM_PROFILE:-DEFAULT}"
echo "  Heap: ${JAVA_XMS} / ${JAVA_XMX}"
echo "  JavaCPP maxBytes: ${JAVACPP_MAX_BYTES}"
echo "  JavaCPP maxPhysicalBytes: ${JAVACPP_MAX_PHYSICAL_BYTES}"
echo "  JFR file: ${JFR_FILENAME}"

"${SCRIPT_DIR}/load_trusted_certs.sh"

export KEYSTORE="${SCRIPT_DIR}/osh-keystore.p12"
export KEYSTORE_TYPE=PKCS12
export KEYSTORE_PASSWORD="${KEYSTORE_PASSWORD:-atakatak}"

# Keep filename casing consistent for Linux
export TRUSTSTORE="${SCRIPT_DIR}/truststore.jks"
export TRUSTSTORE_TYPE=JKS
export TRUSTSTORE_PASSWORD="${TRUSTSTORE_PASSWORD:-changeit}"

export INITIAL_ADMIN_PASSWORD_FILE="${SCRIPT_DIR}/.s"

if [ ! -f "${INITIAL_ADMIN_PASSWORD_FILE}" ] && [ -z "${INITIAL_ADMIN_PASSWORD:-}" ]; then
  export INITIAL_ADMIN_PASSWORD=admin
fi

"${SCRIPT_DIR}/set-initial-admin-password.sh"

exec java \
    -Xms"${JAVA_XMS}" \
    -Xmx"${JAVA_XMX}" \
    -Xss256k \
    -XX:ReservedCodeCacheSize=256m \
    -XX:+UseG1GC \
    -XX:+HeapDumpOnOutOfMemoryError \
    -XX:+UnlockDiagnosticVMOptions \
    -XX:NativeMemoryTracking=summary \
    -Dorg.bytedeco.javacpp.maxBytes="${JAVACPP_MAX_BYTES}" \
    -Dorg.bytedeco.javacpp.maxPhysicalBytes="${JAVACPP_MAX_PHYSICAL_BYTES}" \
    -Dorg.bytedeco.javacpp.maxRetries=2 \
    -Dorg.bytedeco.javacpp.mxbean=true \
    -Dlogback.configurationFile="${SCRIPT_DIR}/logback.xml" \
    -cp "${SCRIPT_DIR}/lib/*" \
    -Djava.system.class.loader="org.sensorhub.utils.NativeClassLoader" \
    -Djavax.net.ssl.keyStore="${KEYSTORE}" \
    -Djavax.net.ssl.keyStorePassword="${KEYSTORE_PASSWORD}" \
    -Djavax.net.ssl.trustStore="${TRUSTSTORE}" \
    -Djavax.net.ssl.trustStorePassword="${TRUSTSTORE_PASSWORD}" \
    -Djava.library.path="${SCRIPT_DIR}/nativelibs" \
    com.botts.impl.security.SensorHubWrapper "${SCRIPT_DIR}/config.json" "${SCRIPT_DIR}/db"