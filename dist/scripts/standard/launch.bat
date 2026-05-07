@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "SCRIPT_DIR=%~dp0"
if "%SCRIPT_DIR:~-1%"=="\" set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"

set "ENV_FILE="
if exist "%SCRIPT_DIR%\.env" (
    set "ENV_FILE=%SCRIPT_DIR%\.env"
) else if exist "%SCRIPT_DIR%\..\.env" (
    set "ENV_FILE=%SCRIPT_DIR%\..\.env"
)

if defined ENV_FILE call :load_env "%ENV_FILE%"

if not defined SYSTEM_PROFILE set "SYSTEM_PROFILE=8GB"
if not defined FORCE_RESTART set "FORCE_RESTART=0"

where java >nul 2>nul
if errorlevel 1 (
    echo ERROR: Java was not found in PATH.
    exit /b 1
)

where keytool >nul 2>nul
if errorlevel 1 (
    echo ERROR: keytool was not found in PATH.
    exit /b 1
)

if not exist "%SCRIPT_DIR%\lib" (
    echo ERROR: Missing library directory: "%SCRIPT_DIR%\lib"
    exit /b 1
)

if not exist "%SCRIPT_DIR%\config.json" (
    echo ERROR: Missing config file: "%SCRIPT_DIR%\config.json"
    exit /b 1
)

if not exist "%SCRIPT_DIR%\load_trusted_certs.bat" (
    echo ERROR: Missing trusted-certs helper: "%SCRIPT_DIR%\load_trusted_certs.bat"
    exit /b 1
)

if not exist "%SCRIPT_DIR%\set-initial-admin-password.bat" (
    echo ERROR: Missing admin-password helper: "%SCRIPT_DIR%\set-initial-admin-password.bat"
    exit /b 1
)

call :check_existing_oscar
if defined OSCAR_PID (
    if /I "%FORCE_RESTART%"=="1" (
        echo OSCAR is already running with PID !OSCAR_PID!. FORCE_RESTART=1, stopping it first...
        call :stop_existing_oscar
        call :wait_for_oscar_stop 60
        call :check_existing_oscar
        if defined OSCAR_PID (
            echo ERROR: OSCAR is still running with PID !OSCAR_PID! after stop attempt.
            exit /b 1
        )
    ) else (
        echo OSCAR is already running with PID !OSCAR_PID!.
        echo Run stop-all.bat first, or set FORCE_RESTART=1 to replace the existing OSCAR process.
        exit /b 1
    )
)

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
    echo WARNING: Unknown SYSTEM_PROFILE "%SYSTEM_PROFILE%". Using 8GB defaults.
    set "JAVA_XMS=1g"
    set "JAVA_XMX=2g"
    set "JAVACPP_MAX_BYTES_DEFAULT=1g"
    set "JAVACPP_MAX_PHYSICAL_BYTES_DEFAULT=4g"
)

if not defined JAVACPP_MAX_BYTES set "JAVACPP_MAX_BYTES=%JAVACPP_MAX_BYTES_DEFAULT%"
if not defined JAVACPP_MAX_PHYSICAL_BYTES set "JAVACPP_MAX_PHYSICAL_BYTES=%JAVACPP_MAX_PHYSICAL_BYTES_DEFAULT%"
if not defined JFR_FILENAME set "JFR_FILENAME=%SCRIPT_DIR%\oscar.jfr"

echo Starting OSH Node with Profile: %SYSTEM_PROFILE%
echo   Heap: %JAVA_XMS% / %JAVA_XMX%
echo   JavaCPP maxBytes: %JAVACPP_MAX_BYTES%
echo   JavaCPP maxPhysicalBytes: %JAVACPP_MAX_PHYSICAL_BYTES%
echo   JFR file: %JFR_FILENAME%

call "%SCRIPT_DIR%\load_trusted_certs.bat"
if errorlevel 1 exit /b %ERRORLEVEL%

set "KEYSTORE=%SCRIPT_DIR%\osh-keystore.p12"
set "KEYSTORE_TYPE=PKCS12"
if not defined KEYSTORE_PASSWORD set "KEYSTORE_PASSWORD=atakatak"

set "TRUSTSTORE=%SCRIPT_DIR%\truststore.jks"
set "TRUSTSTORE_TYPE=JKS"
if not defined TRUSTSTORE_PASSWORD set "TRUSTSTORE_PASSWORD=changeit"

set "INITIAL_ADMIN_PASSWORD_FILE=%SCRIPT_DIR%\.s"
if not exist "%INITIAL_ADMIN_PASSWORD_FILE%" if not defined INITIAL_ADMIN_PASSWORD set "INITIAL_ADMIN_PASSWORD=admin"

call "%SCRIPT_DIR%\set-initial-admin-password.bat"
if errorlevel 1 exit /b %ERRORLEVEL%

set "JAVA_LIBRARY_OPT="
if exist "%SCRIPT_DIR%\nativelibs" (
    set "JAVA_LIBRARY_OPT=-Djava.library.path=%SCRIPT_DIR%\nativelibs"
) else (
    echo WARNING: Optional native library directory not found: "%SCRIPT_DIR%\nativelibs"
)

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
    "-Dlogback.configurationFile=%SCRIPT_DIR%\logback.xml" ^
    -cp "%SCRIPT_DIR%\lib\*" ^
    "-Djava.system.class.loader=org.sensorhub.utils.NativeClassLoader" ^
    "-Djavax.net.ssl.keyStore=%KEYSTORE%" ^
    "-Djavax.net.ssl.keyStorePassword=%KEYSTORE_PASSWORD%" ^
    "-Djavax.net.ssl.trustStore=%TRUSTSTORE%" ^
    "-Djavax.net.ssl.trustStorePassword=%TRUSTSTORE_PASSWORD%" ^
    !JAVA_LIBRARY_OPT! ^
    com.botts.impl.security.SensorHubWrapper "%SCRIPT_DIR%\config.json" "%SCRIPT_DIR%\db"

set "JAVA_EXIT_CODE=%ERRORLEVEL%"
endlocal & exit /b %JAVA_EXIT_CODE%

:check_existing_oscar
set "OSCAR_PID="
for /f "usebackq delims=" %%P in (`
  powershell -NoProfile -ExecutionPolicy Bypass -Command "$procs = Get-CimInstance Win32_Process; foreach ($proc in $procs) { if ($proc.Name -match '^(java|javaw)(\.exe)?$' -and $null -ne $proc.CommandLine -and $proc.CommandLine -like '*com.botts.impl.security.SensorHubWrapper*') { [Console]::Write($proc.ProcessId); break } }" 2^>nul
`) do set "OSCAR_PID=%%P"
exit /b 0

:stop_existing_oscar
if not defined OSCAR_PID exit /b 0
powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Stop-Process -Id %OSCAR_PID% -Force -ErrorAction Stop } catch {}" >nul 2>nul
exit /b 0

:wait_for_oscar_stop
set "WAIT_LIMIT=%~1"
if not defined WAIT_LIMIT set "WAIT_LIMIT=60"
set /a WAITED=0

:wait_for_oscar_stop_loop
call :check_existing_oscar
if not defined OSCAR_PID exit /b 0
if !WAITED! GEQ %WAIT_LIMIT% exit /b 0
timeout /t 1 /nobreak >nul
set /a WAITED+=1
goto wait_for_oscar_stop_loop

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