@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "SCRIPT_DIR=%~dp0"
if "%SCRIPT_DIR:~-1%"=="\" set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"

if exist "%SCRIPT_DIR%\.env" (
    call :load_env "%SCRIPT_DIR%\.env"
) else if exist "%SCRIPT_DIR%\..\.env" (
    call :load_env "%SCRIPT_DIR%\..\.env"
)

if not defined SYSTEM_PROFILE set "SYSTEM_PROFILE=8GB"
call :set_java_profile "%SYSTEM_PROFILE%"

if not defined JAVACPP_MAX_BYTES set "JAVACPP_MAX_BYTES=%JAVACPP_MAX_BYTES_DEFAULT%"
if not defined JAVACPP_MAX_PHYSICAL_BYTES set "JAVACPP_MAX_PHYSICAL_BYTES=%JAVACPP_MAX_PHYSICAL_BYTES_DEFAULT%"
if not defined KEYSTORE_PASSWORD set "KEYSTORE_PASSWORD=CHANGE_ME"
if not defined TRUSTSTORE_PASSWORD set "TRUSTSTORE_PASSWORD=CHANGE_ME"
if not defined INITIAL_ADMIN_PASSWORD set "INITIAL_ADMIN_PASSWORD=admin"

echo Starting OSH Node with Profile: %SYSTEM_PROFILE%
echo   Heap: %JAVA_XMS% / %JAVA_XMX%
echo   JavaCPP maxBytes: %JAVACPP_MAX_BYTES%
echo   JavaCPP maxPhysicalBytes: %JAVACPP_MAX_PHYSICAL_BYTES%

if exist "%SCRIPT_DIR%\load_trusted_certs.bat" (
    call "%SCRIPT_DIR%\load_trusted_certs.bat"
)

if not exist "%SCRIPT_DIR%\.s" (
    > "%SCRIPT_DIR%\.s" echo %INITIAL_ADMIN_PASSWORD%
)

if exist "%SCRIPT_DIR%\set-initial-admin-password.bat" (
    call "%SCRIPT_DIR%\set-initial-admin-password.bat"
)

set "KEYSTORE=%SCRIPT_DIR%\osh-keystore.p12"
set "TRUSTSTORE=%SCRIPT_DIR%\trustStore.jks"

java -Xms%JAVA_XMS% -Xmx%JAVA_XMX% -Xss256k ^
    -XX:ReservedCodeCacheSize=256m -XX:+UseG1GC -XX:+HeapDumpOnOutOfMemoryError ^
    -XX:+UnlockDiagnosticVMOptions -XX:NativeMemoryTracking=summary ^
    -Dorg.bytedeco.javacpp.maxBytes=%JAVACPP_MAX_BYTES% ^
    -Dorg.bytedeco.javacpp.maxPhysicalBytes=%JAVACPP_MAX_PHYSICAL_BYTES% ^
    -Dorg.bytedeco.javacpp.maxRetries=2 ^
    -Dorg.bytedeco.javacpp.mxbean=true ^
    -Dlogback.configurationFile="%SCRIPT_DIR%\logback.xml" ^
    -cp "%SCRIPT_DIR%\lib\*" ^
    -Djava.system.class.loader=org.sensorhub.utils.NativeClassLoader ^
    -Djavax.net.ssl.keyStore="%KEYSTORE%" ^
    -Djavax.net.ssl.keyStorePassword=%KEYSTORE_PASSWORD% ^
    -Djavax.net.ssl.trustStore="%TRUSTSTORE%" ^
    -Djavax.net.ssl.trustStorePassword=%TRUSTSTORE_PASSWORD% ^
    -Djava.library.path="%SCRIPT_DIR%\nativelibs" ^
    com.botts.impl.security.SensorHubWrapper "%SCRIPT_DIR%\config.json" "%SCRIPT_DIR%\db"

exit /b %ERRORLEVEL%

:load_env
set "ENV_PATH=%~1"
for /f "usebackq tokens=* delims=" %%L in ("%ENV_PATH%") do (
    set "LINE=%%L"
    if defined LINE (
        if not "!LINE:~0,1!"=="#" (
            for /f "tokens=1,* delims==" %%A in ("!LINE!") do (
                if not "%%A"=="" set "%%A=%%B"
            )
        )
    )
)
exit /b 0

:set_java_profile
set "PROFILE=%~1"
if /I "%PROFILE%"=="RPI4" (
    set "JAVA_XMS=512m"
    set "JAVA_XMX=1536m"
    set "JAVACPP_MAX_BYTES_DEFAULT=512m"
    set "JAVACPP_MAX_PHYSICAL_BYTES_DEFAULT=2g"
    exit /b 0
)
if /I "%PROFILE%"=="8GB" (
    set "JAVA_XMS=1g"
    set "JAVA_XMX=2g"
    set "JAVACPP_MAX_BYTES_DEFAULT=1g"
    set "JAVACPP_MAX_PHYSICAL_BYTES_DEFAULT=4g"
    exit /b 0
)
if /I "%PROFILE%"=="16GB" (
    set "JAVA_XMS=1g"
    set "JAVA_XMX=3g"
    set "JAVACPP_MAX_BYTES_DEFAULT=2g"
    set "JAVACPP_MAX_PHYSICAL_BYTES_DEFAULT=8g"
    exit /b 0
)
if /I "%PROFILE%"=="32GB" (
    set "JAVA_XMS=2g"
    set "JAVA_XMX=6g"
    set "JAVACPP_MAX_BYTES_DEFAULT=4g"
    set "JAVACPP_MAX_PHYSICAL_BYTES_DEFAULT=16g"
    exit /b 0
)

set "JAVA_XMS=1g"
set "JAVA_XMX=2g"
set "JAVACPP_MAX_BYTES_DEFAULT=1g"
set "JAVACPP_MAX_PHYSICAL_BYTES_DEFAULT=4g"
exit /b 0
