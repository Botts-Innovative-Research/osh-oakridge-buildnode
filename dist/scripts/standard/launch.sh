#!/bin/bash

# Make sure all the necessary certificates are trusted by the system.
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
"$SCRIPT_DIR/load_trusted_certs.sh"

export KEYSTORE="./osh-keystore.p12"
export KEYSTORE_TYPE=PKCS12

# Ephemeral CA Generation
if [ ! -f "$KEYSTORE" ]; then
    echo "Generating ephemeral certificates..."
    java -cp "lib/*" com.botts.impl.security.EphemeralCAUtility
fi

if [ -f ".app_secrets" ]; then
    export KEYSTORE_PASSWORD=$(head -n 1 .app_secrets)
else
    export KEYSTORE_PASSWORD="atakatak"
fi

export TRUSTSTORE="./truststore.jks"
  export TRUSTSTORE_TYPE=JKS
  export TRUSTSTORE_PASSWORD="changeit"

  if [ -f "./.initial_admin_password" ]; then
      export INITIAL_ADMIN_PASSWORD_FILE="./.initial_admin_password"
  fi

# Database configuration
export DB_HOST="${DB_HOST:-localhost}"
if [ -z "$POSTGRES_PASSWORD_FILE" ]; then
    # Check for password file in parent directory (standard for release) or current
    if [ -f "../.db_password" ]; then
        export POSTGRES_PASSWORD_FILE="$(cd .. && pwd)/.db_password"
    elif [ -f "./.db_password" ]; then
        export POSTGRES_PASSWORD_FILE="$(pwd)/.db_password"
    fi
fi

# After copying the default configuration file, also look to see if they
# specified what they want the initial admin user's password to be, either
# as a secret file or by providing it as an environment variable.
if [ ! -z "$INITIAL_ADMIN_PASSWORD_FILE" ] || [ ! -z "$INITIAL_ADMIN_PASSWORD" ]; then
  "$SCRIPT_DIR/set-initial-admin-password.sh"
fi



# Start the node
java -Xms6g -Xmx6g -Xss256k -XX:ReservedCodeCacheSize=512m -XX:+UseG1GC -XX:+HeapDumpOnOutOfMemoryError \
	-Dlogback.configurationFile=./logback.xml \
	-cp "lib/*" \
	-Djava.system.class.loader="org.sensorhub.utils.NativeClassLoader" \
	com.botts.impl.security.SensorHubWrapper ./config.json ./db
