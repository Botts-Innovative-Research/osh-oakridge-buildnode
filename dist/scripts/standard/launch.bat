@echo off
setlocal enabledelayedexpansion


REM Make sure all the necessary certificates are trusted by the system.
CALL %~dp0load_trusted_certs.bat

set KEYSTORE=.\osh-keystore.p12
set KEYSTORE_TYPE=PKCS12
set KEYSTORE_PASSWORD=atakatak

set TRUSTSTORE=.\truststore.jks
set TRUSTSTORE_TYPE=JKS
set TRUSTSTORE_PASSWORD=changeit

set INITIAL_ADMIN_PASSWORD_FILE=.\.s


REM Check if INITIAL_ADMIN_PASSWORD_FILE and INITIAL_ADMIN_PASSWORD are empty
REM Set default password if neither is provided
if "%INITIAL_ADMIN_PASSWORD_FILE%"=="" if "%INITIAL_ADMIN_PASSWORD%"=="" (
    set INITIAL_ADMIN_PASSWORD=admin
)

REM Call the next batch script to handle setting the initial admin password
CALL "%SCRIPT_DIR%set-initial-admin-password.bat"

REM Start the node
java -Xms6g -Xmx6g -Xss256k -XX:ReservedCodeCacheSize=512m -XX:+UseG1GC -XX:+HeapDumpOnOutOfMemoryError ^
    -Dlogback.configurationFile=./logback.xml ^
    -cp "lib/*" ^
    -Djava.system.class.loader="org.sensorhub.utils.NativeClassLoader" ^
    -Djavax.net.ssl.keyStore="./osh-keystore.p12" ^
    -Djavax.net.ssl.keyStorePassword="atakatak" ^
    -Djavax.net.ssl.trustStore="%~dp0trustStore.jks" ^
    -Djavax.net.ssl.trustStorePassword="changeit" ^
    com.botts.impl.security.SensorHubWrapper config.json db


endlocal
