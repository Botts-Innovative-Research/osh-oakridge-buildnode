#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');

const arguments_ = process.argv.slice(2);
const offline = arguments_.includes('--offline');
const expectedVersionArguments = arguments_.filter(argument => argument.startsWith('--expected-version='));
const positionalArguments = arguments_.filter(argument => argument !== '--offline' && !argument.startsWith('--expected-version='));
if (positionalArguments.length > 1 || positionalArguments.some(argument => argument.startsWith('-'))) {
    process.stderr.write('Usage: validate-packaged-release.js [--offline] [--expected-version=VERSION] [release-directory]\n');
    process.exit(2);
}
if (expectedVersionArguments.length > 1 || expectedVersionArguments[0] === '--expected-version=') {
    process.stderr.write('Usage: validate-packaged-release.js [--offline] [--expected-version=VERSION] [release-directory]\n');
    process.exit(2);
}
const root = path.resolve(positionalArguments[0] || 'build/install/oscar');
const sourceBuild = fs.readFileSync(path.resolve(__dirname, '..', 'build.gradle'), 'utf8');
const sourceVersion = sourceBuild.match(/^\s*version\s*=\s*"([^"]+)"\s*$/m)?.[1];
const requestedVersion = expectedVersionArguments[0]?.slice('--expected-version='.length);
const expectedVersion = requestedVersion || sourceVersion;
const fail = message => {
    process.stderr.write(`Packaged release validation failed: ${message}\n`);
    process.exitCode = 1;
};

const validateLocalizedMediaDefaults = relative => {
    const source = fs.readFileSync(path.join(root, relative), 'utf8');
    const section = source.match(/^### 4\.3[^\n]*\n([\s\S]*?)(?=\n### |(?![\s\S]))/m)?.[1];
    if (!section) {
        fail(`${relative} is missing localized video-retention section 4.3`);
        return;
    }
    const numericDefaults = section.split(/\r?\n/)
        .filter(line => line.startsWith('|'))
        .map(line => line.split('|').slice(1, -1).map(cell => cell.trim()))
        .filter(cells => cells.length >= 3 && /^\d+$/.test(cells[1]))
        .map(cells => Number(cells[1]));
    const expected = [0, 5, 6, 24, 360, 2, 24, 24, 15, 200, 200, 5, 85, 24];
    if (JSON.stringify(numericDefaults) !== JSON.stringify(expected)) {
        fail(`${relative} video-retention defaults do not match the production profile`);
    }
};

if (requestedVersion && sourceVersion !== requestedVersion) {
    fail(`expected build.gradle version ${requestedVersion}, received ${sourceVersion || '<unresolved>'}`);
}

if (!fs.existsSync(root) || !fs.statSync(root).isDirectory()) {
    fail(`release directory does not exist: ${root}`);
    process.exit();
}

const envPath = path.join(root, '.env.example');
if (!fs.existsSync(envPath)) {
    fail('missing .env.example');
    process.exit();
}
const env = Object.fromEntries(fs.readFileSync(envPath, 'utf8').split(/\r?\n/)
    .filter(line => line && !line.startsWith('#') && line.includes('='))
    .map(line => [line.slice(0, line.indexOf('=')), line.slice(line.indexOf('=') + 1)]));
const version = env.OSCAR_VERSION;
if (!expectedVersion || version !== expectedVersion) fail(`expected OSCAR_VERSION=${expectedVersion || '<unresolved>'}, received ${version || '<missing>'}`);
if (Object.hasOwn(env, 'OSCAR_POSTGIS_VERSION')) fail('OSCAR_POSTGIS_VERSION must not diverge from OSCAR_VERSION');
if (env.OSCAR_DEPLOYMENT_ID !== '') fail('OSCAR_DEPLOYMENT_ID must be empty in the packaged template');
if (env.OSCAR_BACKUP_MODE !== 'disabled') {
    fail(`OSCAR_BACKUP_MODE must be disabled in the packaged template, received ${env.OSCAR_BACKUP_MODE || '<missing>'}`);
}
for (const retiredName of ['OSCAR_BACKUP_RETENTION_COUNT', 'OSCAR_BACKUP_AUTO_PRUNE']) {
    if (Object.hasOwn(env, retiredName)) fail(`${retiredName} is retired from the single-snapshot backup contract`);
}
const backupDisabledMessages = {
    'oscar-storage.sh': 'OSCAR backups are disabled. Re-run upgrade with --backup-mode single --backup-dir <safe-absolute-backup-path> before using backup, verification, pruning, or restore.',
    'oscar-storage.ps1': 'OSCAR backups are disabled. Re-run upgrade with -BackupMode single -BackupDir <safe-absolute-backup-path> before using backup, verification, pruning, or restore.',
};
for (const [relative, expected] of Object.entries(backupDisabledMessages)) {
    const source = fs.readFileSync(path.join(root, relative), 'utf8');
    if (!source.includes(expected)) fail(`${relative} does not provide platform-correct disabled-backup guidance`);
}

const expected = [
    'oscar-storage.sh', 'oscar-storage.ps1', 'validate-storage-archive.sh',
    'postgis/archive-wal.sh', 'postgis/merge-wal-restore.sh', 'postgis/prepare-restore.sh',
    'docker/oscar/Dockerfile', 'docker/oscar/entrypoint.sh',
    'docker/oscar/archive-object-helper.sh',
    'docker/oscar/atomic-publish.c',
    'documentation/QUICKSTART.md', 'documentation/DEPLOYMENT.md',
    'documentation/LIVE_VIDEO.md', 'documentation/OPERATIONAL_VIEWS.md',
    'documentation/STATUS_OF_HEALTH.md', 'documentation/TRANSLATION_SYSTEM.md',
    'documentation/STORAGE_ARCHITECTURE.md', 'documentation/DATA_LIFECYCLE.md',
    'documentation/ARCHIVE_FORMAT.md', 'documentation/BACKUP_RESTORE.md',
    'documentation/STORAGE_OPERATIONS.md', 'documentation/daily-file-journal-v1.md',
    'documentation/retained-media-v1.md',
];
for (const relative of expected) {
    if (!fs.existsSync(path.join(root, relative))) fail(`missing required file: ${relative}`);
}

for (const relative of ['oscar-storage.sh', 'oscar-storage.ps1']) {
    const source = fs.readFileSync(path.join(root, relative), 'utf8');
    if (!source.includes('archive-generation-ids.txt')) {
        fail(`${relative} does not require the authenticated backup-time archive-generation inventory`);
    }
    for (const field of [
        'archive_generation_count',
        'archive_generation_inventory_sha256',
        'archive_generation_inventory_bytes',
    ]) {
        if (!source.includes(`${field} IS NOT DISTINCT FROM EXCLUDED.${field}`)) {
            fail(`${relative} does not collision-check compact archive receipt field ${field}`);
        }
    }
    if (/(^|\W)archive_generation_ids(\W|$)/m.test(source) || source.includes('ArchiveGenerationIdsSql')) {
        fail(`${relative} still embeds the archive-generation UUID set in SQL`);
    }
    if (relative === 'oscar-storage.sh' &&
        (!source.includes('pwd -P') || !source.includes('regular, non-symlink file'))) {
        fail('oscar-storage.sh does not physically resolve the release path and reject a symlinked launcher');
    }
    if (relative === 'oscar-storage.ps1' &&
        (!source.includes('Assert-NoReparseComponents $StorageScriptPath') ||
         !source.includes('Resolve-PhysicalContainmentPath $ScriptRoot'))) {
        fail('oscar-storage.ps1 does not reject release reparse points and use physical containment paths');
    }
}

const compose = fs.readFileSync(path.join(root, 'compose.yaml'), 'utf8');
for (const [modelName, externalName] of [
    ['oscar_state', 'oscar_oscar_state'],
    ['postgres_data', 'oscar_postgres_data'],
]) {
    const definition = new RegExp(`^  ${modelName}:\\r?\\n    external: true\\r?\\n    name: ${externalName}$`, 'm');
    if (!definition.test(compose)) {
        fail(`compose.yaml must attach ${externalName} as an exact external volume`);
    }
}
if (compose.includes('com.botts.oscar.deployment-id')) {
    fail('compose.yaml must not reconcile immutable deployment labels on named volumes');
}

const postgresService = compose.match(/^  postgres:\r?\n[\s\S]*?(?=^volumes:)/m)?.[0];
if (!postgresService || (postgresService.match(/- archive_mode=off/g) || []).length !== 1) {
    fail('the PostgreSQL service must set archive_mode=off exactly once');
}
for (const staleWalSetting of ['archive_mode=on', 'archive_command=', 'archive_timeout=', '/var/lib/postgresql/wal-archive']) {
    if (postgresService.includes(staleWalSetting)) {
        fail(`the PostgreSQL service still contains retired external-WAL setting ${staleWalSetting}`);
    }
}

const oscarService = compose.match(/^  oscar:\r?\n[\s\S]*?(?=^  postgres:)/m)?.[0];
const nativeTmpfs = '/run/oscar-native:rw,exec,nosuid,nodev,size=256m,mode=0700,uid=10001,gid=10001';
if (!oscarService?.includes('- /tmp:rw,noexec,nosuid,nodev')) {
    fail('the OSCAR service must keep /tmp on an explicit noexec tmpfs');
}
if (!oscarService?.includes(`- ${nativeTmpfs}`) || compose.split(nativeTmpfs).length !== 2) {
    fail('only the OSCAR service may receive the bounded owner-only executable native tmpfs');
}

const oscarDockerfile = fs.readFileSync(path.join(root, 'docker/oscar/Dockerfile'), 'utf8');
if (!/install --directory --owner=oscar --group=oscar --mode=0700[\s\\]*\n\s*\/var\/lib\/oscar \/run\/oscar-native/.test(oscarDockerfile)) {
    fail('the OSCAR image must provide a private native-tmpfs mount point');
}

const oscarEntrypoint = fs.readFileSync(path.join(root, 'docker/oscar/entrypoint.sh'), 'utf8');
const javaOptions = oscarEntrypoint.indexOf('exec java ${JAVA_OPTS:-}');
const managedJavaTmp = oscarEntrypoint.indexOf('-Djava.io.tmpdir="${NATIVE_TMP_DIR}"');
const managedJavaCppTmp = oscarEntrypoint.indexOf('-Dorg.bytedeco.javacpp.cachedir="${NATIVE_TMP_DIR}/javacpp"');
const managedDataTmp = oscarEntrypoint.indexOf('-Doscar.data.tmpdir=/tmp');
if (!oscarEntrypoint.includes('NATIVE_TMP_DIR=/run/oscar-native') ||
    !oscarEntrypoint.includes('if [ -n "${_JAVA_OPTIONS:-}" ]') ||
    !oscarEntrypoint.includes('is_tmpfs_mount /tmp') ||
    !oscarEntrypoint.includes('mount_has_option /tmp noexec') ||
    !oscarEntrypoint.includes('native_exec_probe=') ||
    javaOptions < 0 || managedJavaTmp < javaOptions ||
    managedJavaCppTmp < javaOptions || managedDataTmp < javaOptions) {
    fail('the OSCAR entrypoint must verify both tmpfs mounts and force managed native/data temp paths after JAVA_OPTS');
}

const expectedStorageDefaults = {
    OSCAR_ARCHIVE_DIR: '../oscar-storage/archive',
    OSCAR_BACKUP_DIR: '../oscar-storage/backups',
};
for (const [name, value] of Object.entries(expectedStorageDefaults)) {
    if (env[name] !== value) fail(`${name} must be ${value} in the packaged template`);
}
if (Object.prototype.hasOwnProperty.call(env, 'OSCAR_WAL_ARCHIVE_DIR')) {
    fail('the packaged template must not create a retired legacy-WAL root binding');
}

const standardConfigPath = path.join(root, 'osh-node-oscar', 'config.json');
if (!fs.existsSync(standardConfigPath)) {
    fail('missing osh-node-oscar/config.json');
} else {
    let standardConfig;
    try {
        standardConfig = JSON.parse(fs.readFileSync(standardConfigPath, 'utf8'));
    } catch (error) {
        fail(`osh-node-oscar/config.json is not valid JSON: ${error.message}`);
    }
    if (standardConfig) {
        const modules = Array.isArray(standardConfig) ? standardConfig : [];
        const oscarServiceConfig = modules.find(module => module?.objClass === 'com.botts.impl.service.oscar.OSCARServiceConfig');
        const tieredDatabaseConfig = modules.find(module =>
            module?.dbConfig?.objClass === 'org.sensorhub.impl.datastore.postgis.database.OscarTieredObsSystemDatabaseConfig')?.dbConfig;
        const archiveConfig = tieredDatabaseConfig?.archive;
        const expectedArchiveOutputs = [
            'gammaCounts', 'gammaThreshold', 'neutronCounts', 'setupGamma', 'setupNeutron',
        ];
        const videoRetentionConfig = oscarServiceConfig?.videoRetentionConfig;
        const dailyJournalConfig = modules.find(module =>
            module?.objClass === 'com.botts.impl.service.dailyfile.DailyFileJournalServiceConfig');
        const expectedVideoRetention = {
            timeToRetention: 0,
            videoQueryPeriod: 1,
            maximumCatchUpHours: 6,
            lateArrivalOverlapHours: 24,
            lateArrivalScanPeriodMinutes: 360,
            lateArrivalCatchUpHours: 2,
            reconciliationCatchUpHours: 24,
            reconciliationPeriodHours: 24,
            occupancyStreamRefreshMinutes: 15,
            enableFrameRetention: true,
            frameRetentionCount: 5,
            jpegQuality: 85,
            sourceRollbackGraceHours: 24,
            enableSecondaryFramePruning: true,
            secondaryFrameRetentionDays: 30,
            maintenanceWorkLimit: 200,
            metadataReclamationWorkLimit: 200,
        };
        for (const [field, expected] of Object.entries(expectedVideoRetention)) {
            if (videoRetentionConfig?.[field] !== expected) {
                fail(`the standard video-retention ${field} must be ${expected}`);
            }
        }
        if (archiveConfig?.storageMode !== 'PARQUET_PRIMARY') {
            fail('the standard profile must explicitly select PARQUET_PRIMARY');
        }
        if (archiveConfig?.hotRetentionDays !== 2) {
            fail('the inactive HOT_RETENTION compatibility value must remain 2 days');
        }
        if (archiveConfig?.parquetPrimaryArchiveDelayMinutes !== 5 ||
            archiveConfig?.immutableStageWindowMinutes !== 30 ||
            archiveConfig?.maximumFuturePhenomenonSkewMinutes !== 5 ||
            archiveConfig?.parquetPrimaryIntervalMinutes !== 1 ||
            archiveConfig?.maximumStagePartitionsPerCycle !== 8) {
            fail('the standard Parquet-primary profile must use a 30-minute stage, 5-minute delay, 5-minute future-skew limit, 1-minute worker, and 8-partition retirement bound');
        }
        if (archiveConfig?.intervalMinutes !== 60) {
            fail('the inactive HOT_RETENTION compatibility interval must remain 60 minutes');
        }
        if (archiveConfig?.maximumGenerationsPerCycle !== 2 ||
            archiveConfig?.maximumVerificationsPerCycle !== 2 ||
            archiveConfig?.maximumDeletionsPerCycle !== 2) {
            fail('the standard generation, verification, and inactive HOT_RETENTION deletion bounds must all equal 2');
        }
        if (archiveConfig?.rollbackGraceDays !== 3) {
            fail('the inactive HOT_RETENTION compatibility rollback grace must remain 3 days');
        }
        if (archiveConfig?.deleteHotAfterArchive !== true) {
            fail('the standard profile must retire verified Parquet-primary staging');
        }
        if (archiveConfig?.requireParityReceipt !== true) {
            fail('the standard profile must require a parity receipt before retiring immutable staging children');
        }
        if (dailyJournalConfig?.sealedJournalRetentionDays !== 30 ||
            dailyJournalConfig?.requireBackupBeforeSealedJournalDeletion !== false) {
            fail('the standard daily journal must retain sealed sources for 30 days and use exact replay without requiring managed backup');
        }
        if (JSON.stringify(archiveConfig?.outputNames) !== JSON.stringify(expectedArchiveOutputs)) {
            fail('the standard cold tier must remain limited to the five approved high-volume output names');
        }
    }
}

const files = [];
function walk(directory) {
    for (const entry of fs.readdirSync(directory, {withFileTypes: true})) {
        const absolute = path.join(directory, entry.name);
        if (entry.isDirectory()) walk(absolute);
        else if (entry.isFile()) files.push(path.relative(root, absolute).split(path.sep).join('/'));
    }
}
walk(root);

const forbidden = [
    /(^|\/)\.env$/,
    /(^|\/)(?:secrets|tls|data|backups|pgdata)(?:\/|$)/,
    /(^|\/)pre-restore-[^/]+(?:\/|$)/,
    /(^|\/)\.restore-secrets[^/]*(?:\/|$)/,
    /(^|\/)\.bundle-verified[^/]*$/,
    /(^|\/)\.oscar-init-state[^/]*$/,
    /(^|\/)\.oscar-volume-adoption[^/]*$/,
    /(^|\/)\.oscar-storage\.lock$/,
    /(^|\/)offline-images\.tar$/,
    /(^|\/)SHA256SUMS(?:\.hmac)?$/,
];
const allowedOfflineFiles = new Set(['offline-images.tar', 'SHA256SUMS']);
for (const relative of files) {
    if ((!offline || !allowedOfflineFiles.has(relative)) && forbidden.some(pattern => pattern.test(relative))) {
        fail(`runtime/generated material leaked into release: ${relative}`);
    }
}

const markdownFiles = files.filter(relative => relative.endsWith('.md'));
for (const manual of ['README.md', 'README_es.md', 'README_fr.md', 'README_el.md']) {
    const relative = `documentation/operator-manual/${manual}`;
    if (!files.includes(relative)) fail(`missing localized operator manual ${relative}`);
    else validateLocalizedMediaDefaults(relative);
}
const linkPattern = /!?\[[^\]]*\]\(([^)]+)\)/g;
for (const relative of markdownFiles) {
    const source = fs.readFileSync(path.join(root, relative), 'utf8');
    for (const match of source.matchAll(linkPattern)) {
        let target = match[1].trim();
        if (target.startsWith('<') && target.endsWith('>')) target = target.slice(1, -1);
        target = target.split(/\s+["']/u, 1)[0];
        if (!target || target.startsWith('#') || /^(?:https?:|mailto:|data:|codex:)/i.test(target)) continue;
        const withoutFragment = target.split('#', 1)[0].split('?', 1)[0];
        if (!withoutFragment) continue;
        let decoded;
        try { decoded = decodeURIComponent(withoutFragment); }
        catch { fail(`${relative} has a malformed local link: ${target}`); continue; }
        const resolved = path.resolve(path.dirname(path.join(root, relative)), decoded);
        if (resolved !== root && !resolved.startsWith(`${root}${path.sep}`)) {
            fail(`${relative} links outside the release: ${target}`);
        } else if (!fs.existsSync(resolved)) {
            fail(`${relative} has a broken local link: ${target}`);
        }
    }
}

const staleDocumentation = [
    [/OSCAR_BACKUP_RETENTION_COUNT\s*=\s*14|OSCAR_BACKUP_AUTO_PRUNE\s*=\s*true/, 'retired backup-pruning defaults'],
    [/newest 14 verified|14 verified (?:local )?backups/i, 'retired fourteen-backup policy'],
    [/PostgreSQL (?:stays online|is then stopped)[^\n]*archived-WAL|stable archived-WAL snapshot/i, 'retired v2 archived-WAL snapshot flow'],
    [/shipping (?:copy-only profile|default)[^\n]*deleteHotAfterArchive[^\n]*false|deleteHotAfterArchive=false[^\n]*shipping default/i, 'retired copy-only lifecycle default'],
    [/video retention age \| (?:1|7) days?|timeToRetention(?:=|` \()(?:1|one|seven)\b|five[- ]JPEGs?[^\n]{0,80}(?:after|at) one day|(?:after|at) one day[^\n]{0,80}five[- ]JPEGs?|one-day[^\n]{0,80}(?:exact-five[ -]?|five[- ])JPEGs?|after the configured seven-day retention age/i, 'retired delayed media default'],
    [/secondary[- ]drive|absolute-secondary-drive-path/i, 'retired mandatory-secondary-drive backup wording'],
    [/archive hot retention \| 30 days|older than 30 days|after the 30-day cutoff/i, 'retired thirty-day cold-tier default'],
];
for (const relative of markdownFiles) {
    const source = fs.readFileSync(path.join(root, relative), 'utf8');
    for (const [pattern, description] of staleDocumentation) {
        if (pattern.test(source)) fail(`${relative} contains ${description}`);
    }
}

if (!process.exitCode) {
    process.stdout.write(`Validated OSCAR ${version} package: ${files.length} files, ${markdownFiles.length} Markdown documents.\n`);
}
