#!/usr/bin/env node

'use strict';

const fs = require('node:fs');
const path = require('node:path');

const repositoryRoot = path.resolve(__dirname, '..');
let requestedVersion = process.argv[2];
if (process.argv.length === 2) {
    requestedVersion = fs.readFileSync(path.join(repositoryRoot, 'build.gradle'), 'utf8')
        .match(/^\s*version\s*=\s*"([^"]+)"\s*$/m)?.[1];
}
const version = requestedVersion?.replace(/^v/, '');
const semanticVersion = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/;

if (process.argv.length > 3 || !semanticVersion.test(version ?? '')) {
    console.error('Usage: node tools/validate-release-metadata.js [semantic-version]');
    process.exit(2);
}

function escapeRegExp(value) {
    return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

const escapedVersion = escapeRegExp(version);

function read(relativePath) {
    return fs.readFileSync(path.join(repositoryRoot, relativePath), 'utf8');
}

function requireMatch(relativePath, pattern, expected, description) {
    const match = read(relativePath).match(pattern);
    const actual = match?.[1];
    if (actual !== expected) {
        throw new Error(`${relativePath}: expected ${description} ${expected}, found ${actual ?? 'nothing'}.`);
    }
}

function requireOnlyOscarVersion(relativePath) {
    const matches = [...read(relativePath).matchAll(/\bOSCAR (\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)/g)];
    if (matches.length === 0) {
        throw new Error(`${relativePath}: expected at least one OSCAR release label.`);
    }
    const staleVersions = [...new Set(matches.map((match) => match[1]).filter((value) => value !== version))];
    if (staleVersions.length > 0) {
        throw new Error(`${relativePath}: stale OSCAR release label(s): ${staleVersions.join(', ')}.`);
    }
}

function requirePattern(relativePath, pattern, description) {
    if (!pattern.test(read(relativePath))) {
        throw new Error(`${relativePath}: missing ${description}.`);
    }
}

function forbidPattern(relativePath, pattern, description) {
    if (pattern.test(read(relativePath))) {
        throw new Error(`${relativePath}: contains forbidden ${description}.`);
    }
}

function requireLocalizedMediaDefaults(relativePath) {
    const section = read(relativePath).match(/^### 4\.3[^\n]*\n([\s\S]*?)(?=\n### |(?![\s\S]))/m)?.[1];
    if (!section) {
        throw new Error(`${relativePath}: missing localized video-retention section 4.3.`);
    }
    const numericDefaults = section.split(/\r?\n/)
        .filter((line) => line.startsWith('|'))
        .map((line) => line.split('|').slice(1, -1).map((cell) => cell.trim()))
        .filter((cells) => cells.length >= 3 && /^\d+$/.test(cells[1]))
        .map((cells) => Number(cells[1]));
    const expected = [0, 5, 6, 24, 360, 2, 24, 24, 15, 200, 200, 5, 85, 24];
    if (JSON.stringify(numericDefaults) !== JSON.stringify(expected)) {
        throw new Error(`${relativePath}: localized video-retention defaults do not match the production profile.`);
    }
}

requireMatch('build.gradle', /^\s*version\s*=\s*"([^"]+)"\s*$/m, version, 'version');
requireMatch(
    '.github/workflows/release.yml',
    /^\s*RELEASE_VERSION:\s*'([^']+)'\s*$/m,
    version,
    'release workflow version',
);
requireMatch(
    'dist/config/standard/config.json',
    /^\s*"deploymentName"\s*:\s*"OSCAR ([^"]+)"\s*,?\s*$/m,
    version,
    'deployment version',
);
const standardConfig = JSON.parse(read('dist/config/standard/config.json'));
const standardOscar = standardConfig.filter((item) =>
    item?.objClass === 'com.botts.impl.service.oscar.OSCARServiceConfig');
const standardDatabases = standardConfig.filter((item) =>
    item?.objClass === 'org.sensorhub.impl.database.system.SystemDriverDatabaseConfig');
const standardDailyJournals = standardConfig.filter((item) =>
    item?.objClass === 'com.botts.impl.service.dailyfile.DailyFileJournalServiceConfig');
if (standardOscar.length !== 1 || standardDatabases.length !== 1 || standardDailyJournals.length !== 1) {
    throw new Error('dist/config/standard/config.json: expected one OSCAR service, one system database, and one daily-file journal.');
}
const videoRetention = standardOscar[0].videoRetentionConfig;
const archive = standardDatabases[0].dbConfig?.archive;
const dailyJournal = standardDailyJournals[0];
const expectedStorageDefaults = {
    'videoRetentionConfig.timeToRetention': [videoRetention?.timeToRetention, 0],
    'videoRetentionConfig.videoQueryPeriod': [videoRetention?.videoQueryPeriod, 5],
    'videoRetentionConfig.maximumCatchUpHours': [videoRetention?.maximumCatchUpHours, 6],
    'videoRetentionConfig.lateArrivalOverlapHours': [videoRetention?.lateArrivalOverlapHours, 24],
    'videoRetentionConfig.lateArrivalScanPeriodMinutes': [videoRetention?.lateArrivalScanPeriodMinutes, 360],
    'videoRetentionConfig.lateArrivalCatchUpHours': [videoRetention?.lateArrivalCatchUpHours, 2],
    'videoRetentionConfig.reconciliationCatchUpHours': [videoRetention?.reconciliationCatchUpHours, 24],
    'videoRetentionConfig.reconciliationPeriodHours': [videoRetention?.reconciliationPeriodHours, 24],
    'videoRetentionConfig.occupancyStreamRefreshMinutes': [videoRetention?.occupancyStreamRefreshMinutes, 15],
    'videoRetentionConfig.enableFrameRetention': [videoRetention?.enableFrameRetention, true],
    'videoRetentionConfig.frameRetentionCount': [videoRetention?.frameRetentionCount, 5],
    'videoRetentionConfig.jpegQuality': [videoRetention?.jpegQuality, 85],
    'videoRetentionConfig.sourceRollbackGraceHours': [videoRetention?.sourceRollbackGraceHours, 24],
    'videoRetentionConfig.maintenanceWorkLimit': [videoRetention?.maintenanceWorkLimit, 200],
    'videoRetentionConfig.metadataReclamationWorkLimit': [videoRetention?.metadataReclamationWorkLimit, 200],
    'archive.enabled': [archive?.enabled, true],
    'archive.intervalMinutes': [archive?.intervalMinutes, 60],
    'archive.hotRetentionDays': [archive?.hotRetentionDays, 2],
    'archive.rollbackGraceDays': [archive?.rollbackGraceDays, 1],
    'archive.deleteHotAfterArchive': [archive?.deleteHotAfterArchive, true],
    'archive.requireParityReceipt': [archive?.requireParityReceipt, true],
    'dailyJournal.sealedJournalRetentionDays': [dailyJournal?.sealedJournalRetentionDays, 30],
    'dailyJournal.requireBackupBeforeSealedJournalDeletion': [dailyJournal?.requireBackupBeforeSealedJournalDeletion, false],
};
for (const [field, [actual, expected]] of Object.entries(expectedStorageDefaults)) {
    if (actual !== expected) {
        throw new Error(`dist/config/standard/config.json: expected ${field}=${expected}, found ${actual}.`);
    }
}
requireMatch('dist/release/.env.example', /^OSCAR_VERSION=(.+)$/m, version, 'OSCAR_VERSION');
requireMatch(
    'dist/release/compose.yaml',
    /^\s+OSCAR_VERSION:\s*"\$\{OSCAR_VERSION:-([^}]+)\}"\s*$/m,
    'local',
    'OSCAR image-version build argument fallback',
);
requireMatch(
    'dist/release/compose.yaml',
    /^\s+image:\s*"oscar-postgis:\$\{OSCAR_VERSION:-([^}]+)\}"\s*$/m,
    'local',
    'PostGIS image-version fallback',
);
requireMatch(
    'dist/release/docker/oscar/Dockerfile',
    /^ARG OSCAR_VERSION=(.+)$/m,
    'local',
    'OSCAR image-version argument fallback',
);
requirePattern(
    'dist/release/docker/oscar/Dockerfile',
    /COPY --chown=root:root docker\/oscar\/atomic-publish\.c \/tmp\/oscar-atomic-publish\.c/,
    'atomic publisher source included in image build',
);
requirePattern(
    'dist/release/docker/oscar/Dockerfile',
    /sha256sum \/tmp\/oscar-atomic-publish\.c \| awk '\{print \$1\}' > \/usr\/local\/share\/oscar-atomic-publish\.source\.sha256/,
    'atomic publisher source-provenance stamp',
);
requireMatch('dist/release/postgis/Dockerfile', /^ARG OSCAR_VERSION=(.+)$/m, 'local', 'PostGIS image-version argument fallback');
requireMatch(
    'dist/release/postgis/Dockerfile',
    /^\s*org\.opencontainers\.image\.version="([^"\n]+)"/m,
    '${OSCAR_VERSION}',
    'PostGIS OCI image-version label source',
);
requireMatch(
    'dist/release/postgis/Dockerfile',
    /^\s*com\.botts\.oscar\.storage-profile="([^"\n]+)"/m,
    '${OSCAR_VERSION}',
    'PostGIS storage-profile label source',
);
requireMatch(
    'dist/release/postgis/Dockerfile',
    /^ENV OSCAR_STORAGE_PROFILE_VERSION="([^"\n]+)"/m,
    '${OSCAR_VERSION}',
    'PostGIS runtime storage-profile source',
);
requirePattern(
    'dist/release/postgis/init-app-role.sh',
    /profile_version="\$\{OSCAR_STORAGE_PROFILE_VERSION:\?OSCAR_STORAGE_PROFILE_VERSION is required\}"/,
    'runtime-provided storage-profile marker version',
);
requirePattern(
    'dist/release/postgis/init-app-role.sh',
    /printf 'version=%s\\n' "\$\{profile_version\}"/,
    'dynamic storage-profile receipt version',
);
requirePattern(
    'dist/release/oscar-storage.sh',
    /required_release_version=\$\(awk [^\n]+OSCAR_VERSION[^\n]+\.env\.example/,
    'release version derived from .env.example',
);
requirePattern(
    'dist/release/oscar-storage.ps1',
    /\$RequiredReleaseVersion = \$releaseVersionLine\[0\]\.Substring\('OSCAR_VERSION='\.Length\)/,
    'release version derived from .env.example',
);
forbidPattern('dist/release/oscar-storage.sh', /required_release_version=['"]?\d+\.\d+\.\d+/, 'hard-coded storage release version');
forbidPattern('dist/release/oscar-storage.ps1', /\$RequiredReleaseVersion\s*=\s*['"]\d+\.\d+\.\d+/, 'hard-coded storage release version');
requirePattern(
    'dist/release/oscar-setup.sh',
    /OSCAR \$\(release_version\) storage deployment is not supported on macOS/,
    'dynamic setup macOS boundary version',
);
forbidPattern(
    'dist/release/oscar-setup.sh',
    /OSCAR \d+\.\d+\.\d+ storage deployment is not supported on macOS/,
    'hard-coded setup macOS boundary version',
);
requireMatch(
    'dist/release/docker/oscar/Dockerfile',
    /^\s*org\.opencontainers\.image\.version="([^"\n]+)"\s*$/m,
    '${OSCAR_VERSION}',
    'OCI image-version label source',
);
requirePattern(
    'README.md',
    new RegExp(`OSCAR ${escapedVersion} storage-profile deployment is intentionally blocked on macOS`),
    'macOS storage deployment safety boundary',
);
requirePattern(
    'dist/release/DEPLOYMENT.md',
    new RegExp(`The ${escapedVersion} storage profile fails closed on macOS`),
    'administrator-guide macOS safety boundary',
);
requirePattern(
    'dist/release/QUICKSTART.md',
    new RegExp(`OSCAR ${escapedVersion} deployment and storage operation are supported only on Windows 11`),
    'quick-start supported-host boundary',
);
forbidPattern(
    'README.md',
    /^- Apple Silicon macOS with Docker Desktop/m,
    'unsupported macOS deployment claim',
);
for (const relativePath of [
    'README.md',
    'changelog.md',
    'dist/release/DEPLOYMENT.md',
    'dist/release/QUICKSTART.md',
]) {
    forbidPattern(
        relativePath,
        /\b(?:re-authenticates|authenticated (?:bundle|image archive|installer paths))\b/i,
        'origin-authentication claim for an unsigned offline checksum manifest',
    );
}
forbidPattern(
    'docs/BACKUP_RESTORE.md',
    /\bexact signed\/offline OSCAR release\b/i,
    'signed-release claim without a release signature',
);
requireMatch('changelog.md', /^##\s+v?(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)(?:\s|$)/m, version, 'current changelog version');
requireMatch(
    'web/oscar-viewer/changelog.md',
    /^##\s+v?(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)(?:\s|$)/m,
    version,
    'current Viewer changelog version',
);
requireMatch(
    'include/osh-oakridge-modules/docs/oscar-operator-manual/README.md',
    /localized OSCAR (\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?) administrator/,
    version,
    'operator-manual asset version',
);
requireMatch(
    'include/osh-oakridge-modules/README.md',
    /complete OSCAR (\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?) administration/,
    version,
    'Modules documentation version',
);
requireMatch(
    'include/osh-oakridge-modules/services/sensorhub-service-oscar/src/main/resources/README.md',
    /detailed OSCAR (\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?) manual/,
    version,
    'OSCAR Service documentation version',
);

const localizedManuals = [
    'README.md',
    'README_es.md',
    'README_fr.md',
    'README_el.md',
];
const manualRoot = 'include/osh-oakridge-modules/services/sensorhub-service-oscar/src/main/resources/com/botts/impl/service/oscar/i18n';
for (const manual of localizedManuals) {
    const relativePath = `${manualRoot}/${manual}`;
    requireMatch(
        relativePath,
        /^# .*OSCAR (\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?).*$/m,
        version,
        'manual title version',
    );
    requireOnlyOscarVersion(relativePath);
    requireLocalizedMediaDefaults(relativePath);
}

requireMatch(
    'README.md',
    /OSCAR (\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?) therefore runs/,
    version,
    'source-test guidance version',
);
requireMatch(
    'dist/release/DEPLOYMENT.md',
    /To test OSCAR (\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?) from a connected release artifact/,
    version,
    'deployment-test guidance version',
);
requireMatch(
    'docs/STATUS_OF_HEALTH.md',
    /The OSCAR (\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?) Status of Health page/,
    version,
    'Status of Health guide version',
);
requireMatch(
    'docs/LIVE_VIDEO.md',
    /OSCAR (\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?) starts Lane Details video/,
    version,
    'live-video guide version',
);

for (const relativePath of [
    'README.md',
    'dist/release/DEPLOYMENT.md',
    'dist/release/QUICKSTART.md',
    'docs/ARCHIVE_FORMAT.md',
    'docs/BACKUP_RESTORE.md',
    'docs/DATA_LIFECYCLE.md',
    'docs/LIVE_VIDEO.md',
    'docs/STORAGE_ARCHITECTURE.md',
    'docs/STORAGE_OPERATIONS.md',
    'docs/STATUS_OF_HEALTH.md',
    'include/osh-oakridge-modules/README.md',
    'include/osh-oakridge-modules/docs/oscar-operator-manual/README.md',
    'include/osh-oakridge-modules/services/sensorhub-service-oscar/src/main/resources/README.md',
]) {
    requireOnlyOscarVersion(relativePath);
}

console.log(`Release metadata matches OSCAR ${version}.`);
