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
node --test tools\update-version.test.js || exit /b 1

pushd "web\oscar-viewer" || exit /b 1
call npm ci || goto viewer_build_failed
call npm run audit:dependencies || goto viewer_build_failed
call npm run lint || goto viewer_build_failed
call npm run test:component || goto viewer_build_failed
call npm run build || goto viewer_build_failed
popd

call gradlew.bat --no-parallel :sensorhub-datastore-postgis:test --tests org.sensorhub.impl.datastore.postgis.TestTieredArchiveConfiguration --tests org.sensorhub.impl.datastore.postgis.TestParquetArchiveReader --tests org.sensorhub.impl.datastore.postgis.archive.TestDuckDbResourcePolicy --tests org.sensorhub.impl.datastore.postgis.archive.TestArchiveLifecycleInvariants --tests org.sensorhub.impl.datastore.postgis.database.TestOscarTieredModuleProvider --tests org.sensorhub.impl.datastore.postgis.TestParameterizedQueryBuilder || exit /b 1

call gradlew.bat --no-parallel :sensorhub-service-oscar:test :sensorhub-service-bucket:test :sensorhub-service-dailyfile-journal:test :sensorhub-system-lane:test || exit /b 1

call gradlew.bat --no-parallel :sensorhub-utils-rad:test --tests org.sensorhub.impl.utils.rad.cambio.CambioTempDirectoryTest --tests org.sensorhub.impl.utils.rad.output.OccupancyOutputConcurrencyTest || exit /b 1

call gradlew.bat --no-parallel :sensorhub-driver-aspect:test --tests com.botts.impl.sensor.aspect.MessageHandlerJournalTest :sensorhub-driver-ffmpeg:test --tests org.sensorhub.impl.sensor.ffmpeg.controls.FileControlPublicationTest :sensorhub-driver-rapiscan:test --tests com.botts.impl.sensor.rapiscan.MessageHandlerJournalTest :sensorhub-driver-rs350:test --tests com.botts.impl.sensor.rs350.MessageHandlerJournalTest || exit /b 1

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
