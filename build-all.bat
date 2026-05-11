@echo off
setlocal EnableExtensions

set "PROJECT_DIR=%~dp0"
set "RELEASE_VERSION=3.5.1"
set "DIST_DIR=%PROJECT_DIR%build\distributions"
set "STANDARD_ZIP=%DIST_DIR%\oscar-%RELEASE_VERSION%.zip"

pushd "%PROJECT_DIR%web\oscar-viewer" || exit /b 1
call npm install || goto :fail
call npm run build || goto :fail
popd

pushd "%PROJECT_DIR%" || exit /b 1
call gradlew.bat build -x test -x osgi || goto :fail
popd

if exist "%DIST_DIR%" (
    powershell -NoProfile -Command ^
      "$dist = '%DIST_DIR%'; $target = '%STANDARD_ZIP%'; $zip = Get-ChildItem -Path $dist -Filter *.zip | Where-Object { $_.FullName -ne $target } | Sort-Object LastWriteTime -Descending | Select-Object -First 1; if ($zip) { Copy-Item -Force $zip.FullName $target; Write-Host ('Standardized release zip: ' + $target) } elseif (Test-Path $target) { Write-Host ('Release zip already available at: ' + $target) } else { Write-Warning ('No distribution zip found under ' + $dist) }"
) else (
    echo Warning: distribution directory not found: "%DIST_DIR%"
)

exit /b 0

:fail
set "EXITCODE=%ERRORLEVEL%"
popd >NUL 2>NUL
exit /b %EXITCODE%
