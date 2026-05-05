@echo off
setlocal EnableExtensions

rem Resolve this script's directory. %~dp0 includes the trailing backslash.
set "SCRIPT_DIR=%~dp0"

rem Load .env from this directory, or from the parent directory when this script
rem is launched from osh-node-oscar under the project root.
set "ENV_FILE="
if exist "%SCRIPT_DIR%.env" (
    set "ENV_FILE=%SCRIPT_DIR%.env"
) else if exist "%SCRIPT_DIR%..\.env" (
    set "ENV_FILE=%SCRIPT_DIR%..\.env"
)

if defined ENV_FILE (
    call :load_env "%ENV_FILE%"
    echo AFTER load_env ERR=%ERRORLEVEL%
)

rem Pick Java and JavaCPP defaults from SYSTEM_PROFILE.
if not defined SYSTEM_PROFILE set "SYSTEM_PROFILE=8GB"

if /I "%SYSTEM_PROFILE%"=="RPI4" (
    set "JAVA_XMS=512m"
    set "JAVA_XMX=1536m"
    set "JAVACPP_MAX_BYTES_DEFAULT=512m"
    set "JAVACPP_MAX_PHYSICAL_BYTES_DEFAULT=2g"
) else if /I "%SYSTEM_PROFILE%"=="8GB" (
    set "JAVA_XMS=1g"
    set "JAVA_XMX=2g"
    set "JAVACPP_MAX_BYTES_DEFAULT=1g"
    set "JAVACPP_MAX_PHYSICAL_BYTES_DEFAULT=4g"
) else if /I "%SYSTEM_PROFILE%"=="16GB" (
    set "JAVA_XMS=1g"
    set "JAVA_XMX=3g"
    set "JAVACPP_MAX_BYTES_DEFAULT=2g"
    set "JAVACPP_MAX_PHYSICAL_BYTES_DEFAULT=8g"
) else if /I "%SYSTEM_PROFILE%"=="32GB" (
    set "JAVA_XMS=2g"
    set "JAVA_XMX=6g"
    set "JAVACPP_MAX_BYTES_DEFAULT=4g"
    set "JAVACPP_MAX_PHYSICAL_BYTES_DEFAULT=16g"
) else (
    echo Unknown profile '%SYSTEM_PROFILE%', using 8GB defaults.
    set "JAVA_XMS=1g"
    set "JAVA_XMX=2g"
    set "JAVACPP_MAX_BYTES_DEFAULT=1g"
    set "JAVACPP_MAX_PHYSICAL_BYTES_DEFAULT=4g"
)

if not defined JAVACPP_MAX_BYTES set "JAVACPP_MAX_BYTES=%JAVACPP_MAX_BYTES_DEFAULT%"
if not defined JAVACPP_MAX_PHYSICAL_BYTES set "JAVACPP_MAX_PHYSICAL_BYTES=%JAVACPP_MAX_PHYSICAL_BYTES_DEFAULT%"
if not defined JFR_FILENAME set "JFR_FILENAME=%SCRIPT_DIR%oscar.jfr"

echo Starting OSH Node with Profile: %SYSTEM_PROFILE%
echo   Heap: %JAVA_XMS% / %JAVA_XMX%
echo   JavaCPP maxBytes: %JAVACPP_MAX_BYTES%
echo   JavaCPP maxPhysicalBytes: %JAVACPP_MAX_PHYSICAL_BYTES%
echo   JFR file: %JFR_FILENAME%

rem Make sure all the necessary certificates are trusted by the system.
if not exist "%SCRIPT_DIR%load_trusted_certs.bat" (
    echo Error: load_trusted_certs.bat not found in "%SCRIPT_DIR%".
    exit /b 1
)
call "%SCRIPT_DIR%load_trusted_certs.bat"
echo AFTER load_trusted_certs ERR=%ERRORLEVEL%
if errorlevel 1 exit /b %ERRORLEVEL%

set "KEYSTORE=%SCRIPT_DIR%osh-keystore.p12"
set "KEYSTORE_TYPE=PKCS12"
if not defined KEYSTORE_PASSWORD set "KEYSTORE_PASSWORD=atakatak"

set "TRUSTSTORE=%SCRIPT_DIR%truststore.jks"
set "TRUSTSTORE_TYPE=JKS"
if not defined TRUSTSTORE_PASSWORD set "TRUSTSTORE_PASSWORD=changeit"

set "INITIAL_ADMIN_PASSWORD_FILE=%SCRIPT_DIR%.s"

rem If no secret file exists and no env var was supplied, use the dev default.
if not exist "%INITIAL_ADMIN_PASSWORD_FILE%" if not defined INITIAL_ADMIN_PASSWORD set "INITIAL_ADMIN_PASSWORD=admin"

if not exist "%SCRIPT_DIR%set-initial-admin-password.bat" (
    echo Error: set-initial-admin-password.bat not found in "%SCRIPT_DIR%".
    exit /b 1
)
call "%SCRIPT_DIR%set-initial-admin-password.bat"
echo AFTER set-initial-admin-password ERR=%ERRORLEVEL%
if errorlevel 1 exit /b %ERRORLEVEL%

echo BEFORE JAVA
where java
echo KEYSTORE=%KEYSTORE%
echo TRUSTSTORE=%TRUSTSTORE%
echo INITIAL_ADMIN_PASSWORD_FILE=%INITIAL_ADMIN_PASSWORD_FILE%
echo SCRIPT_DIR=%SCRIPT_DIR%
echo CONFIG=%SCRIPT_DIR%config.json
echo DBDIR=%SCRIPT_DIR%db
echo NATIVELIBS=%SCRIPT_DIR%nativelibs

java ^
    -Xms%JAVA_XMS% ^
    -Xmx%JAVA_XMX% ^
    -Xss256k ^
    -XX:ReservedCodeCacheSize=256m ^
    -XX:+UseG1GC ^
    -XX:+HeapDumpOnOutOfMemoryError ^
    -XX:+UnlockDiagnosticVMOptions ^
    -XX:NativeMemoryTracking=summary ^
    "-Dorg.bytedeco.javacpp.maxBytes=%JAVACPP_MAX_BYTES%" ^
    "-Dorg.bytedeco.javacpp.maxPhysicalBytes=%JAVACPP_MAX_PHYSICAL_BYTES%" ^
    -Dorg.bytedeco.javacpp.maxRetries=2 ^
    -Dorg.bytedeco.javacpp.mxbean=true ^
    "-Dlogback.configurationFile=%SCRIPT_DIR%logback.xml" ^
    -cp "%SCRIPT_DIR%lib\*" ^
    "-Djava.system.class.loader=org.sensorhub.utils.NativeClassLoader" ^
    "-Djavax.net.ssl.keyStore=%KEYSTORE%" ^
    "-Djavax.net.ssl.keyStorePassword=%KEYSTORE_PASSWORD%" ^
    "-Djavax.net.ssl.trustStore=%TRUSTSTORE%" ^
    "-Djavax.net.ssl.trustStorePassword=%TRUSTSTORE_PASSWORD%" ^
    "-Djava.library.path=%SCRIPT_DIR%nativelibs" ^
    com.botts.impl.security.SensorHubWrapper "%SCRIPT_DIR%config.json" "%SCRIPT_DIR%db"

set "JAVA_EXIT_CODE=%ERRORLEVEL%"
echo AFTER JAVA
echo JAVA_EXIT_CODE=%JAVA_EXIT_CODE%
pause
endlocal & exit /b %JAVA_EXIT_CODE%

:load_env
for /f "usebackq tokens=1,* delims==" %%A in ("%~1") do (
    set "ENV_NAME=%%A"
    set "ENV_VALUE=%%B"
    call :set_env_var
)
exit /b 0

:set_env_var
if not defined ENV_NAME exit /b 0
if "%ENV_NAME:~0,1%"=="#" exit /b 0
if /I "%ENV_NAME:~0,7%"=="export " set "ENV_NAME=%ENV_NAME:~7%"
set "%ENV_NAME%=%ENV_VALUE%"
exit /b 0