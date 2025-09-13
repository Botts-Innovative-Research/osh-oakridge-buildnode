@echo off
setlocal

echo Building Java trust store...

REM Default password for the sytem trust store is "changeit". Edit this next
REM line if it's something different in your Java installation.
set "STOREPASS=changeit"

REM Get the path of this script.
set "SCRIPTDIR=%~dp0"

REM Get the path where we'll build the new trust store.
set "NEWTRUSTSTORE=%SCRIPTDIR%trustStore.jks"

REM To find the location of the system trust store, we start by finding the
REM path to "java.exe".
for /f "tokens=* usebackq" %%j in (`where java`) do (set "JAVA=%%~dpj" & goto :next )
:next
REM Then we back up a directory and look in lib\security.
set "CACERTS=%JAVA%..\lib\security\cacerts"

REM Now make a copy of that default system trust store into this directory,
REM where we'll add our stuff to it.
copy /y "%CACERTS%" "%NEWTRUSTSTORE%" >NUL

REM Get the full path to where our certs are.
set CERTDIR=%SCRIPTDIR%trusted_certificates

REM Now for each .cer, .pem, and .crt file in our cert dir, check to see if we
REM need to add it to the system trust store.
for %%c in ( %CERTDIR%\*.cer %CERTDIR%\*.pem %CERTDIR%\*.crt ) do (
    call :check_certificate %%c
)

goto :end_of_script

REM The next few lines define a function that checks whether a certificate 
REM is already loaded in the system store. If so, it does nothing. If not, it
REM attempts to load it in. Note that the alias of the certificate is
REM calculated as the base file name (without path or extension).
REM NOTE: As currently written, this is performing an unnecessary check, since
REM we're guaranteed that none of the certificates will ever be present in the
REM original file.

:check_certificate
set ALIAS=%~n1
REM Check for existence. ERRORLEVEL is set to 0 if it's found, and something
REM else otherwise.
keytool -list -keystore "%NEWTRUSTSTORE%" -storepass "%STOREPASS%" -alias "%ALIAS%" >NUL 2>NUL
if not "%ERRORLEVEL%" == "0" (
    echo Importing "%ALIAS%" from "%1"
    keytool -importcert -keystore "%NEWTRUSTSTORE%" -noprompt -storepass "%STOREPASS%" -alias "%ALIAS%" -file "%1"
) else (
    echo Certificate with alias "%ALIAS%" already exists. Skipping.
)
REM Return to caller.
exit /b 0

:end_of_script

echo Done.

endlocal
