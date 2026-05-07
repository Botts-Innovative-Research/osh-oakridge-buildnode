@echo off
setlocal EnableExtensions EnableDelayedExpansion

echo Building Java trust store...

set "STOREPASS=changeit"
set "SCRIPTDIR=%~dp0"
set "NEWTRUSTSTORE=%SCRIPTDIR%truststore.jks"
set "CERTDIR=%SCRIPTDIR%trusted_certificates"
set "CACERTS="
set "JAVA_HOME_DETECTED="

rem First try JAVA_HOME if already set
if defined JAVA_HOME (
    if exist "%JAVA_HOME%\conf\security\cacerts" set "CACERTS=%JAVA_HOME%\conf\security\cacerts"
    if not defined CACERTS if exist "%JAVA_HOME%\lib\security\cacerts" set "CACERTS=%JAVA_HOME%\lib\security\cacerts"
)

rem If that did not work, ask Java itself for java.home
if not defined CACERTS (
    for /f "tokens=1,* delims==" %%A in ('java -XshowSettings:properties -version 2^>^&1 ^| findstr /c:"java.home ="') do (
        set "JAVA_HOME_DETECTED=%%B"
    )
)

rem Trim leading spaces
if defined JAVA_HOME_DETECTED (
    for /f "tokens=* delims= " %%H in ("!JAVA_HOME_DETECTED!") do set "JAVA_HOME_DETECTED=%%H"
)

rem Try common cacerts locations under detected java.home
if not defined CACERTS if defined JAVA_HOME_DETECTED (
    if exist "!JAVA_HOME_DETECTED!\conf\security\cacerts" set "CACERTS=!JAVA_HOME_DETECTED!\conf\security\cacerts"
    if not defined CACERTS if exist "!JAVA_HOME_DETECTED!\lib\security\cacerts" set "CACERTS=!JAVA_HOME_DETECTED!\lib\security\cacerts"
)

if not defined CACERTS (
    echo Error: could not locate Java cacerts.
    if defined JAVA_HOME echo JAVA_HOME="%JAVA_HOME%"
    if defined JAVA_HOME_DETECTED echo java.home="!JAVA_HOME_DETECTED!"
    endlocal & exit /b 1
)

if not exist "%CACERTS%" (
    echo Error: Java cacerts path does not exist: "%CACERTS%"
    endlocal & exit /b 1
)

echo Using Java cacerts: "%CACERTS%"

copy /y "%CACERTS%" "%NEWTRUSTSTORE%" >nul
if errorlevel 1 (
    echo Error: failed to create "%NEWTRUSTSTORE%"
    endlocal & exit /b 1
)

if not exist "%CERTDIR%" (
    echo Trusted certificates directory not found: "%CERTDIR%"
    echo Using copied default trust store only.
    echo Done.
    endlocal & exit /b 0
)

set "FOUND_CERT=0"
for %%c in ("%CERTDIR%\*.cer" "%CERTDIR%\*.pem" "%CERTDIR%\*.crt") do (
    if exist "%%~fc" (
        set "FOUND_CERT=1"
        call :check_certificate "%%~fc"
        if errorlevel 1 (
            endlocal & exit /b 1
        )
    )
)

if "%FOUND_CERT%"=="0" (
    echo No certificate files found in "%CERTDIR%".
)

echo Done.
endlocal & exit /b 0

:check_certificate
setlocal
set "CERTFILE=%~1"
set "ALIAS=%~n1"

keytool -list -keystore "%NEWTRUSTSTORE%" -storepass "%STOREPASS%" -alias "%ALIAS%" >nul 2>nul
if not "%ERRORLEVEL%"=="0" (
    echo Importing "%ALIAS%" from "%CERTFILE%"
    keytool -importcert -keystore "%NEWTRUSTSTORE%" -noprompt -storepass "%STOREPASS%" -alias "%ALIAS%" -file "%CERTFILE%" >nul
    if errorlevel 1 (
        echo Error: failed to import "%ALIAS%" from "%CERTFILE%"
        endlocal & exit /b 1
    )
) else (
    echo Certificate with alias "%ALIAS%" already exists. Skipping.
)

endlocal & exit /b 0