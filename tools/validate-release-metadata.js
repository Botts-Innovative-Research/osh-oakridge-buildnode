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

requireMatch('build.gradle', /^\s*version\s*=\s*"([^"]+)"\s*$/m, version, 'version');
requireMatch(
    'dist/config/standard/config.json',
    /^\s*"deploymentName"\s*:\s*"OSCAR ([^"]+)"\s*,?\s*$/m,
    version,
    'deployment version',
);
requireMatch('dist/release/.env.example', /^OSCAR_VERSION=(.+)$/m, version, 'OSCAR_VERSION');
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

for (const relativePath of [
    'README.md',
    'dist/release/DEPLOYMENT.md',
    'docs/STATUS_OF_HEALTH.md',
    'include/osh-oakridge-modules/README.md',
    'include/osh-oakridge-modules/docs/oscar-operator-manual/README.md',
    'include/osh-oakridge-modules/services/sensorhub-service-oscar/src/main/resources/README.md',
]) {
    requireOnlyOscarVersion(relativePath);
}

console.log(`Release metadata matches OSCAR ${version}.`);
