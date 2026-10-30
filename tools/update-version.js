#!/usr/bin/env node

'use strict';

const fs = require('node:fs');
const path = require('node:path');

const repositoryRoot = path.resolve(__dirname, '..');
const version = process.argv[2];

if (process.argv.length !== 3 || version === '--help' || version === '-h') {
    const output = version === '--help' || version === '-h' ? process.stdout : process.stderr;
    output.write('Usage: node tools/update-version.js <version>\n');
    process.exit(version === '--help' || version === '-h' ? 0 : 1);
}

const coreVersion = '(0|[1-9]\\d*)\\.(0|[1-9]\\d*)\\.(0|[1-9]\\d*)';
const prerelease = '(?:-[0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*)?';
const semanticVersion = new RegExp(`^${coreVersion}${prerelease}$`);

if (!semanticVersion.test(version)) {
    console.error(`Invalid version "${version}". Use a semantic version such as 3.9.0 or 3.9.0-rc.1.`);
    process.exit(1);
}

const updates = [
    {
        file: 'build.gradle',
        pattern: /(^\s*version\s*=\s*")[^"]+("\s*$)/m,
        replacement: `$1${version}$2`,
    },
    {
        file: 'dist/config/standard/config.json',
        pattern: /(^\s*"deploymentName"\s*:\s*"OSCAR )[^"]+("\s*,?\s*$)/m,
        replacement: `$1${version}$2`,
    },
    {
        file: 'dist/release/.env.example',
        pattern: /(^OSCAR_VERSION=).*$/m,
        replacement: `$1${version}`,
    },
    {
        file: '.github/workflows/release.yml',
        pattern: /(^\s*RELEASE_VERSION:\s*')[^']+('\s*$)/m,
        replacement: `$1${version}$2`,
    },
];

const preparedUpdates = updates.map((update) => {
    const absolutePath = path.join(repositoryRoot, update.file);
    const original = fs.readFileSync(absolutePath, 'utf8');
    const matches = original.match(new RegExp(update.pattern.source, 'gm')) || [];

    if (matches.length !== 1) {
        throw new Error(`Expected exactly one version field in ${update.file}; found ${matches.length}.`);
    }

    return {
        ...update,
        absolutePath,
        original,
        updated: original.replace(update.pattern, update.replacement),
    };
});

const changedUpdates = preparedUpdates.filter((update) => update.original !== update.updated);

if (changedUpdates.length === 0) {
    console.log(`OSCAR is already at version ${version}.`);
    process.exit(0);
}

const writtenUpdates = [];

try {
    for (const update of changedUpdates) {
        fs.writeFileSync(update.absolutePath, update.updated, 'utf8');
        writtenUpdates.push(update);
    }
} catch (error) {
    for (const update of writtenUpdates.reverse()) {
        fs.writeFileSync(update.absolutePath, update.original, 'utf8');
    }
    throw error;
}

console.log(`Updated OSCAR to version ${version}:`);
for (const update of changedUpdates) {
    console.log(`  ${update.file}`);
}
