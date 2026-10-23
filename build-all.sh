#!/usr/bin/env bash
set -Eeuo pipefail

script_path=${BASH_SOURCE[0]}
case $script_path in */*) script_parent=${script_path%/*} ;; *) script_parent=. ;; esac
repository_root=$(CDPATH= cd -- "$script_parent" && pwd)
cd "$repository_root"

command -v node >/dev/null 2>&1 || { printf 'ERROR: Node.js is required to build OSCAR.\n' >&2; exit 1; }
command -v npm >/dev/null 2>&1 || { printf 'ERROR: npm is required to build OSCAR.\n' >&2; exit 1; }

node tools/validate-release-metadata.js
node --test tools/update-version.test.js

(
    cd web/oscar-viewer
    npm ci
    npm run audit:dependencies
    npm run lint
    npm run test:component
    npm run build
)

./gradlew --no-parallel \
    :sensorhub-datastore-postgis:test \
    --tests org.sensorhub.impl.datastore.postgis.TestTieredArchiveConfiguration \
    --tests org.sensorhub.impl.datastore.postgis.TestParquetArchiveReader \
    --tests org.sensorhub.impl.datastore.postgis.archive.TestDuckDbResourcePolicy \
    --tests org.sensorhub.impl.datastore.postgis.archive.TestArchiveLifecycleInvariants \
    --tests org.sensorhub.impl.datastore.postgis.database.TestOscarTieredModuleProvider \
    --tests org.sensorhub.impl.datastore.postgis.TestParameterizedQueryBuilder

./gradlew --no-parallel \
    :sensorhub-service-oscar:test \
    :sensorhub-service-bucket:test \
    :sensorhub-service-dailyfile-journal:test \
    :sensorhub-system-lane:test

./gradlew --no-parallel \
    :sensorhub-utils-rad:test \
    --tests org.sensorhub.impl.utils.rad.cambio.CambioTempDirectoryTest \
    --tests org.sensorhub.impl.utils.rad.output.OccupancyOutputConcurrencyTest

./gradlew --no-parallel \
    :sensorhub-driver-aspect:test \
    --tests com.botts.impl.sensor.aspect.MessageHandlerJournalTest \
    :sensorhub-driver-ffmpeg:test \
    --tests org.sensorhub.impl.sensor.ffmpeg.controls.FileControlPublicationTest \
    :sensorhub-driver-rapiscan:test \
    --tests com.botts.impl.sensor.rapiscan.MessageHandlerJournalTest \
    :sensorhub-driver-rs350:test \
    --tests com.botts.impl.sensor.rs350.MessageHandlerJournalTest

tools/test-storage-scripts.sh
tools/test-archive-object-helper.sh
tools/test-wal-archive.sh
tools/test-wal-restore-merge.sh

./gradlew build -x test -x osgi

compgen -G 'build/distributions/oscar-*.zip' >/dev/null || {
    printf 'ERROR: The OSCAR connected release ZIP was not produced.\n' >&2
    exit 1
}

printf 'OSCAR connected release created in build/distributions.\n'
