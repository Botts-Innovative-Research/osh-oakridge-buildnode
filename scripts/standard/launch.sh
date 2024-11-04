#!/bin/bash

# Make sure all the necessary certificates are trusted by the system.
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
"$SCRIPT_DIR/load_trusted_certs.sh"

# After copying the default configuration file, also look to see if they
# specified what they want the initial admin user's password to be, either
# as a secret file or by providing it as an environment variable.
if [ -z "$INITIAL_ADMIN_PASSWORD_FILE" ] && [ -z "$INITIAL_ADMIN_PASSWORD" ]; then
  export INITIAL_ADMIN_PASSWORD=admin
fi
"$SCRIPT_DIR/set-initial-admin-password.sh"



# Start the node
java -Xmx2g \
	-Dlogback.configurationFile=./logback.xml \
	-cp "lib/*" \
	-Djava.system.class.loader="org.sensorhub.utils.NativeClassLoader" \
	-Djavax.net.ssl.keyStore="./osh-keystore.p12" \
	-Djavax.net.ssl.keyStorePassword="atakatak" \
	-Djavax.net.ssl.trustStore="$SCRIPT_DIR/trustStore.jks" \
	-Djavax.net.ssl.trustStorePassword="changeit" \
	com.botts.impl.security.SensorHubWrapper ./config.json ./db
