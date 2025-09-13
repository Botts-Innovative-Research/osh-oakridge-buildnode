#!/bin/bash

##
##  Gets INITIAL_ADMIN_PASSWORD_FILE or INITIAL_ADMIN_PASSWORD, encodes it, and
##  replaces "__INITIAL_ADMIN_PASSWORD__" in config.json with the encoded version.
##

#if [ -z "$OSH_HOME" ]; then
#  echo "OSH_HOME environment variable is not set."
#  exit 1
#fi

CONFIG_DIR="."
LIB_DIR="./lib"

if [ ! -z "$INITIAL_ADMIN_PASSWORD_FILE" ]; then
  ENCODED_PASSWORD=$( java -classpath "$LIB_DIR/*" com.botts.impl.security.PBKDF2CredentialProvider < "$INITIAL_ADMIN_PASSWORD_FILE" | tail -1 )
else
  ENCODED_PASSWORD=$( echo "$INITIAL_ADMIN_PASSWORD" | java -classpath "$LIB_DIR/*" com.botts.impl.security.PBKDF2CredentialProvider | tail -1 )
fi

# ENCODED_PASSWORD includes base64-encoded values, which may contain a "/".
# To use sed with a replacement string that includes "/", we'll want to use a
# different delimeter.
sed -i"" -e  "s|__INITIAL_ADMIN_PASSWORD__|$ENCODED_PASSWORD|" "$CONFIG_DIR/config.json"
