#!/bin/bash

echo "Building Java trust store..."

# Default password for the system trust store is "changeit". Edit this next
# line if it's something different in your Java installation.
STOREPASS="changeit"

# Get the path of this script.
SCRIPTDIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# Get the path where we'll build the new trust store.
NEWTRUSTSTORE="$SCRIPTDIR/trustStore.jks"

# To find the location of the system trust store, we have to look for a few
# different possibilities, depending on our system type (MacOS vs. Linux).
if [ -x /usr/libexec/java_home ]; then
    # MacOS
    JAVA_HOME="$(/usr/libexec/java_home)"
    if [ -f "$JAVA_HOME/jre/lib/security/cacerts" ]; then
        CACERTS="$JAVA_HOME/jre/lib/security/cacerts"
    elif [ -f "$JAVA_HOME/lib/security/cacerts" ]; then
        CACERTS="$JAVA_HOME/lib/security/cacerts"
    else
        echo "Unable to find system-wide cacerts!"
        exit 1
    fi
else
    # Linux
    JAVA="$( readlink -f $( which java ) )"
    CACERTS="$( dirname $( dirname "$JAVA" ) )"/lib/security/cacerts
fi

# Now make a copy of that default system trust store into this directory,
# where we'll add our stuff to it.
cp "$CACERTS" "$NEWTRUSTSTORE"

# Calculate the certificate directory relative to this shell script.
CERTDIR="$SCRIPTDIR/trusted_certificates"

# Now for each .cer, .pem, and .crt file in this dir, check to see if we need
# to add it to the system trust store.
shopt -s nullglob
for file in "$CERTDIR"/*.cer "$CERTDIR"/*.pem "$CERTDIR"/*.crt ; do
    ALIAS="${file##*/}"
    ALIAS="${ALIAS%.*}"
    keytool -list -keystore "$NEWTRUSTSTORE" -storepass "$STOREPASS" -alias "$ALIAS" > /dev/null 2>&1
    if [ "$?" == "0" ]; then
        echo Certificate with alias "\"$ALIAS\"" already exists. Skipping.
    else
        keytool -importcert -keystore "$NEWTRUSTSTORE" -noprompt -storepass "$STOREPASS" -alias "$ALIAS" -file "$file"
    fi
done

echo Done.
