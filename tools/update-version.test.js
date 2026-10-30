#!/usr/bin/env node

'use strict';

const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

test('updates canonical release metadata without rewriting historical guide boundaries', () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'oscar-version-update-'));
    const write = (relativePath, contents) => {
        const absolutePath = path.join(root, relativePath);
        fs.mkdirSync(path.dirname(absolutePath), {recursive: true});
        fs.writeFileSync(absolutePath, contents, 'utf8');
    };

    try {
        fs.mkdirSync(path.join(root, 'tools'), {recursive: true});
        fs.copyFileSync(path.join(__dirname, 'update-version.js'), path.join(root, 'tools/update-version.js'));
        write('build.gradle', 'allprojects {\n    version = "3.11.0"\n}\n');
        write('dist/config/standard/config.json', '{\n  "deploymentName": "OSCAR 3.11.0"\n}\n');
        write('dist/release/.env.example', 'OSCAR_VERSION=3.11.0\n');
        write('.github/workflows/release.yml', "env:\n  RELEASE_VERSION: '3.11.0'\n");
        write('changelog.md', '# Change log\n## 3.11.0 2026-10-17\n## 3.9.1 2026-10-16\n');
        write('web/oscar-viewer/changelog.md', '# Viewer change log\n## 3.11.0\n## 3.9.1\n');
        write('README.md', 'The storage migration boundary remains pre-3.11.0.\n');

        execFileSync(process.execPath, [path.join(root, 'tools/update-version.js'), '3.9.3']);

        assert.match(fs.readFileSync(path.join(root, 'build.gradle'), 'utf8'), /version = "3\.9\.3"/);
        assert.match(fs.readFileSync(path.join(root, 'dist/config/standard/config.json'), 'utf8'), /OSCAR 3\.9\.3/);
        assert.equal(fs.readFileSync(path.join(root, 'dist/release/.env.example'), 'utf8'), 'OSCAR_VERSION=3.9.3\n');
        assert.match(fs.readFileSync(path.join(root, '.github/workflows/release.yml'), 'utf8'), /RELEASE_VERSION: '3\.9\.3'/);
        assert.equal(
            fs.readFileSync(path.join(root, 'changelog.md'), 'utf8'),
            '# Change log\n## 3.11.0 2026-10-17\n## 3.9.1 2026-10-16\n',
        );
        assert.equal(
            fs.readFileSync(path.join(root, 'web/oscar-viewer/changelog.md'), 'utf8'),
            '# Viewer change log\n## 3.11.0\n## 3.9.1\n',
        );
        assert.equal(fs.readFileSync(path.join(root, 'README.md'), 'utf8'), 'The storage migration boundary remains pre-3.11.0.\n');
    } finally {
        fs.rmSync(root, {recursive: true, force: true});
    }
});
