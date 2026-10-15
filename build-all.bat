@echo off
setlocal
cd /d "%~dp0" || exit /b 1

where node.exe >nul 2>&1 || (
    echo ERROR: Node.js is required to build OSCAR. 1>&2
    exit /b 1
)
where npm.cmd >nul 2>&1 || (
    echo ERROR: npm is required to build OSCAR. 1>&2
    exit /b 1
)

node tools\validate-release-metadata.js || exit /b 1

pushd "web\oscar-viewer" || exit /b 1
call npm ci || goto viewer_build_failed
call npm run build || goto viewer_build_failed
popd

call gradlew.bat build -x test -x osgi || exit /b 1

dir /b "build\distributions\oscar-*.zip" >nul 2>&1 || (
    echo ERROR: The OSCAR connected release ZIP was not produced. 1>&2
    exit /b 1
)

echo OSCAR connected release created in build\distributions.
exit /b 0

:viewer_build_failed
set "BUILD_EXIT_CODE=%errorlevel%"
popd
exit /b %BUILD_EXIT_CODE%
