@echo off
setlocal EnableExtensions

set "SCRIPT_DIR=%~dp0"
set "MATCH_EXPR=com.botts.impl.security.SensorHubWrapper"
set "FORCE_RESTART=%FORCE_RESTART%"
if not defined FORCE_RESTART set "FORCE_RESTART=0"

set "ENV_FILE="
if exist "%SCRIPT_DIR%.env" (
    set "ENV_FILE=%SCRIPT_DIR%.env"
) else if exist "%SCRIPT_DIR%..\.env" (
    set "ENV_FILE=%SCRIPT_DIR%..\.env"
)

if defined ENV_FILE call :load_env "%ENV_FILE%"

call :check_java
if errorlevel 1 exit /b %ERRORLEVEL%

call :check_existing_oscar
if errorlevel 1 exit /b %ERRORLEVEL%

call :ensure_runtime_paths
if errorlevel 1 exit /b %ERRORLEVEL%

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

if not defined HOME if defined USERPROFILE set "HOME=%USERPROFILE%"

set "PATH=%JAVA_HOME_DETECTED%\bin;%PATH%"
set "KEYSTORE=%SCRIPT_DIR%osh-keystore.p12"
set "KEYSTORE_TYPE=PKCS12"
if not defined KEYSTORE_PASSWORD set "KEYSTORE_PASSWORD=atakatak"

set "TRUSTSTORE=%SCRIPT_DIR%truststore.jks"
set "TRUSTSTORE_TYPE=JKS"
if not defined TRUSTSTORE_PASSWORD set "TRUSTSTORE_PASSWORD=changeit"

set "INITIAL_ADMIN_PASSWORD_FILE=%SCRIPT_DIR%.s"
if not exist "%INITIAL_ADMIN_PASSWORD_FILE%" if not defined INITIAL_ADMIN_PASSWORD set "INITIAL_ADMIN_PASSWORD=admin"

echo Starting OSH Node with Profile: %SYSTEM_PROFILE%
echo   Heap: %JAVA_XMS% / %JAVA_XMX%
echo   JavaCPP maxBytes: %JAVACPP_MAX_BYTES%
echo   JavaCPP maxPhysicalBytes: %JAVACPP_MAX_PHYSICAL_BYTES%
echo   JFR file: %JFR_FILENAME%

call "%SCRIPT_DIR%load_trusted_certs.bat"
if errorlevel 1 exit /b %ERRORLEVEL%

call "%SCRIPT_DIR%set-initial-admin-password.bat"
if errorlevel 1 exit /b %ERRORLEVEL%

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
endlocal & exit /b %JAVA_EXIT_CODE%

:check_java
where java >nul 2>nul
if errorlevel 1 (
    echo Error: java was not found on PATH. Install OpenJDK 21 or newer.
    exit /b 1
)

set "JAVA_HOME_LINE="
for /f "delims=" %%A in ('java -XshowSettings:properties -version 2^>^&1 ^| findstr /c:"java.home ="') do (
    set "JAVA_HOME_LINE=%%A"
    goto :check_java_home_line
)

:check_java_home_line
if not defined JAVA_HOME_LINE (
    echo Error: could not determine java.home from the installed Java runtime.
    exit /b 1
)

for /f "tokens=1,* delims==" %%A in ("%JAVA_HOME_LINE%") do set "JAVA_HOME_DETECTED=%%B"
for /f "tokens=* delims= " %%A in ("%JAVA_HOME_DETECTED%") do set "JAVA_HOME_DETECTED=%%A"

if not exist "%JAVA_HOME_DETECTED%\bin\java.exe" (
    echo Error: Java executable not found under "%JAVA_HOME_DETECTED%\bin\java.exe".
    exit /b 1
)

if not exist "%JAVA_HOME_DETECTED%\bin\keytool.exe" (
    echo Error: keytool.exe not found under "%JAVA_HOME_DETECTED%\bin\keytool.exe".
    exit /b 1
)

set "JAVA_VERSION_LINE="
for /f "delims=" %%A in ('"%JAVA_HOME_DETECTED%\bin\java.exe" -version 2^>^&1 ^| findstr /r /c:"version \""') do (
    set "JAVA_VERSION_LINE=%%A"
    goto :check_java_version_line
)

:check_java_version_line
if not defined JAVA_VERSION_LINE (
    echo Error: could not determine Java version. OpenJDK 21 or newer is required.
    exit /b 1
)

for /f "tokens=2 delims=\"" %%A in ("%JAVA_VERSION_LINE%") do set "JAVA_VERSION_RAW=%%A"
for /f "tokens=1 delims=." %%A in ("%JAVA_VERSION_RAW%") do set "JAVA_MAJOR=%%A"

if not defined JAVA_MAJOR (
    echo Error: could not parse Java version from "%JAVA_VERSION_LINE%".
    exit /b 1
)

if %JAVA_MAJOR% LSS 21 (
    echo Error: Java 21 or newer is required. Found Java %JAVA_MAJOR%.
    exit /b 1
)

exit /b 0

:find_existing_oscar
set "OSCAR_PID="
for /f %%P in ('powershell -NoProfile -Command "$p = Get-CimInstance Win32_Process ^| Where-Object { $_.Name -match ''^java(\.exe)?$'' -and $_.CommandLine -like ''*com.botts.impl.security.SensorHubWrapper*'' } ^| Select-Object -ExpandProperty ProcessId -First 1; if ($p) { Write-Output $p }"') do set "OSCAR_PID=%%P"
exit /b 0

:check_existing_oscar
call :find_existing_oscar
if not defined OSCAR_PID exit /b 0

if "%FORCE_RESTART%"=="1" (
    echo Existing OSCAR instance found with PID %OSCAR_PID%. Replacing because FORCE_RESTART=1.
    taskkill /PID %OSCAR_PID% /T /F >nul 2>nul
    timeout /t 2 /nobreak >nul
    call :find_existing_oscar
    if defined OSCAR_PID (
        echo Error: could not stop the existing OSCAR instance.
        exit /b 1
    )
    exit /b 0
)

echo OSCAR is already running with PID %OSCAR_PID%.
echo Close the existing instance first, or set FORCE_RESTART=1 to replace it.
exit /b 1

:ensure_runtime_paths
if not exist "%SCRIPT_DIR%load_trusted_certs.bat" (
    echo Error: load_trusted_certs.bat not found in "%SCRIPT_DIR%".
    exit /b 1
)

if not exist "%SCRIPT_DIR%set-initial-admin-password.bat" (
    echo Error: set-initial-admin-password.bat not found in "%SCRIPT_DIR%".
    exit /b 1
)

if not exist "%SCRIPT_DIR%config.json" (
    echo Error: missing config file: "%SCRIPT_DIR%config.json".
    exit /b 1
)

if not exist "%SCRIPT_DIR%lib" (
    echo Error: missing library directory: "%SCRIPT_DIR%lib".
    exit /b 1
)

if not exist "%SCRIPT_DIR%nativelibs" (
    echo Error: missing native library directory: "%SCRIPT_DIR%nativelibs".
    exit /b 1
)

if not exist "%SCRIPT_DIR%db" mkdir "%SCRIPT_DIR%db" >nul 2>nul
if not exist "%SCRIPT_DIR%db" (
    echo Error: could not create database directory: "%SCRIPT_DIR%db".
    exit /b 1
)

exit /b 0

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
