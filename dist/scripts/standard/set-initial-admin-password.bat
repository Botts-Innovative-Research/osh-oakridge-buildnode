@echo off
setlocal enabledelayedexpansion


REM Define the directories
set CONFIG_DIR=.
set LIB_DIR=.\lib


REM Check if INITIAL_ADMIN_PASSWORD_FILE is set and handle accordingly
if not "%INITIAL_ADMIN_PASSWORD_FILE%"=="" (
    REM If INITIAL_ADMIN_PASSWORD_FILE is provided, encode it using the PBKDF2CredentialProvider
    for /f "delims=" %%i in ('type "%INITIAL_ADMIN_PASSWORD_FILE%" ^| java -classpath "%LIB_DIR%\*" com.botts.impl.security.PBKDF2CredentialProvider') do set ENCODED_PASSWORD=%%i
) else (
   REM If INITIAL_ADMIN_PASSWORD_FILE is not provided, use INITIAL_ADMIN_PASSWORD environment variable
    for /f "delims=" %%i in ('echo %INITIAL_ADMIN_PASSWORD% ^| java -classpath "%LIB_DIR%\*" com.botts.impl.security.PBKDF2CredentialProvider') do set ENCODED_PASSWORD=%%i
)

REM Replace "__INITIAL_ADMIN_PASSWORD__" in config.json with the encoded password using PowerShell
powershell -Command "(Get-Content '%CONFIG_DIR%\config.json') -replace '__INITIAL_ADMIN_PASSWORD__', '%ENCODED_PASSWORD%' | Set-Content '%CONFIG_DIR%\config.json'"

endlocal
