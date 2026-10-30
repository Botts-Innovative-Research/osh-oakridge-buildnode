#!/usr/bin/env bash
set -Eeuo pipefail

script_path=${BASH_SOURCE[0]}
repo_root=$(CDPATH= cd -- "${script_path%/*}/.." && pwd -P)
shell_script="$repo_root/dist/release/oscar-storage.sh"
powershell_script="$repo_root/dist/release/oscar-storage.ps1"
setup_shell_script="$repo_root/dist/release/oscar-setup.sh"
setup_powershell_script="$repo_root/dist/release/oscar-setup.ps1"
compose_file="$repo_root/dist/release/compose.yaml"
archive_validator="$repo_root/dist/release/validate-storage-archive.sh"
archive_object_helper="$repo_root/dist/release/docker/oscar/archive-object-helper.sh"
oscar_dockerfile="$repo_root/dist/release/docker/oscar/Dockerfile"
oscar_entrypoint="$repo_root/dist/release/docker/oscar/entrypoint.sh"
standard_config="$repo_root/dist/config/standard/config.json"
environment_template="$repo_root/dist/release/.env.example"
linux_launcher="$repo_root/dist/release/oscar.sh"
windows_launcher="$repo_root/dist/release/oscar.bat"
test_root=$(mktemp -d "$repo_root/.storage-script-test.XXXXXX")

cleanup() {
    case $test_root in "$repo_root"/.storage-script-test.*) rm -rf -- "$test_root" ;; esac
}
trap cleanup EXIT

assert_contains() {
    local pattern=$1 file=$2
    grep -Eq -- "$pattern" "$file" || { printf 'Missing required pattern %s in %s\n' "$pattern" "$file" >&2; exit 1; }
}

assert_not_contains() {
    local pattern=$1 file=$2
    if grep -Eq -- "$pattern" "$file"; then
        printf 'Forbidden pattern %s found in %s\n' "$pattern" "$file" >&2
        exit 1
    fi
}

portable_mode() {
    local path=$1 raw
    if stat -c %a "$path" >/dev/null 2>&1; then
        stat -c %a "$path"
    else
        raw=$(stat -f %p "$path")
        printf '%o\n' "$((8#$raw & 07777))"
    fi
}

sha256_path() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
    else shasum --algorithm 256 "$1" | awk '{print $1}'; fi
}

bash -n "$shell_script"
bash -n "$setup_shell_script"
sh -n "$archive_validator"
sh -n "$archive_object_helper"
sh -n "$oscar_entrypoint"

# The 3.11.0 shipping profile is intentionally conservative about backup
# creation, but aggressive about the two bounded high-volume lifecycles. Keep
# these exact values visible in a fast source-level test so documentation or
# packaging cannot silently drift from the approved policy.
[[ $(grep -Fxc 'OSCAR_BACKUP_MODE=disabled' "$environment_template") == 1 ]] || {
    printf 'Packaged environment does not default OSCAR_BACKUP_MODE exactly to disabled.\n' >&2
    exit 1
}
for retired_backup_setting in OSCAR_BACKUP_RETENTION_COUNT OSCAR_BACKUP_AUTO_PRUNE; do
    if grep -Eq "^${retired_backup_setting}=" "$environment_template"; then
        printf 'Packaged environment still exposes retired setting %s.\n' "$retired_backup_setting" >&2
        exit 1
    fi
done
node - "$standard_config" <<'NODE'
const fs = require('node:fs');
const config = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const service = config.find(item => item.objClass === 'com.botts.impl.service.oscar.OSCARServiceConfig');
const database = config.find(item => item.dbConfig?.objClass ===
    'org.sensorhub.impl.datastore.postgis.database.OscarTieredObsSystemDatabaseConfig')?.dbConfig;
const archive = database?.archive;
const dailyJournal = config.find(item =>
    item.objClass === 'com.botts.impl.service.dailyfile.DailyFileJournalServiceConfig');
const outputs = ['gammaCounts', 'gammaThreshold', 'neutronCounts', 'setupGamma', 'setupNeutron'];
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
    maintenanceWorkLimit: 200,
    metadataReclamationWorkLimit: 200,
    enableFrameRetention: true,
    frameRetentionCount: 5,
    jpegQuality: 85,
    sourceRollbackGraceHours: 24,
    enableSecondaryFramePruning: true,
    secondaryFrameRetentionDays: 30,
};
if (Object.entries(expectedVideoRetention).some(([field, expected]) =>
        service?.videoRetentionConfig?.[field] !== expected) ||
    archive?.storageMode !== 'PARQUET_PRIMARY' ||
    archive?.hotRetentionDays !== 2 ||
    archive?.parquetPrimaryArchiveDelayMinutes !== 5 ||
    archive?.immutableStageWindowMinutes !== 30 ||
    archive?.maximumFuturePhenomenonSkewMinutes !== 5 ||
    archive?.parquetPrimaryIntervalMinutes !== 1 ||
    archive?.maximumStagePartitionsPerCycle !== 8 ||
    archive?.intervalMinutes !== 60 ||
    archive?.maximumGenerationsPerCycle !== 2 ||
    archive?.maximumVerificationsPerCycle !== 2 ||
    archive?.maximumDeletionsPerCycle !== 2 ||
    archive?.rollbackGraceDays !== 3 ||
    archive?.deleteHotAfterArchive !== true ||
    archive?.requireParityReceipt !== true ||
    dailyJournal?.sealedJournalRetentionDays !== 30 ||
    dailyJournal?.requireBackupBeforeSealedJournalDeletion !== false ||
    JSON.stringify(archive?.outputNames) !== JSON.stringify(outputs)) {
    throw new Error('standard lifecycle defaults no longer encode the production media cadence/grace, 30-minute Parquet-primary staging, 5-minute delay/skew, 1-minute worker, 8-partition retirement bound, inactive HOT_RETENTION compatibility values, 30-day exact-replay journal retention, and five-output allowlist');
}
NODE

[[ $(grep -Fxc '      - archive_mode=off' "$compose_file") == 1 ]] || {
    printf 'Compose does not set PostgreSQL archive_mode=off exactly once.\n' >&2
    exit 1
}
for forbidden_wal_compose_text in 'archive_mode=on' 'archive_command=' 'archive_timeout=' '/var/lib/postgresql/wal-archive'; do
    if grep -Fq -- "$forbidden_wal_compose_text" "$compose_file"; then
        printf 'Compose still contains retired external-WAL setting %s.\n' "$forbidden_wal_compose_text" >&2
        exit 1
    fi
done
assert_not_contains '^  backup-prune([[:space:]]|$)' "$linux_launcher"
assert_not_contains '^echo   backup-prune([[:space:]]|$)' "$windows_launcher"

backup_mode_fixture="$test_root/backup-mode"
mkdir -p "$backup_mode_fixture"
cp "$shell_script" "$backup_mode_fixture/oscar-storage.sh"
cp "$environment_template" "$backup_mode_fixture/.env.example"
write_backup_mode_environment() {
    local mode_line=$1
    cat >"$backup_mode_fixture/.env" <<EOF
OSCAR_VERSION=3.11.0
OSCAR_DEPLOYMENT_ID=11111111-1111-4111-8111-111111111111
OSCAR_ARCHIVE_DIR=$backup_mode_fixture/archive
$mode_line
OSCAR_BACKUP_DIR=$backup_mode_fixture/backups
OSCAR_WAL_ARCHIVE_DIR=$backup_mode_fixture/wal-archive
OSCAR_SECRETS_DIR=./secrets
OSCAR_TLS_DIR=./tls
OSCAR_BACKUP_KEY_FILE=./secrets/backup-key.txt
EOF
}
for accepted_backup_mode in disabled single; do
    write_backup_mode_environment "OSCAR_BACKUP_MODE=$accepted_backup_mode"
    resolved_mode=$(OSCAR_BACKUP_MODE=single bash -c '
        storage_script=$1
        set -- help
        source "$storage_script" >/dev/null
        assert_managed_environment_bindings
        configured_backup_mode
    ' _ "$backup_mode_fixture/oscar-storage.sh")
    [[ $resolved_mode == "$accepted_backup_mode" ]] || {
        printf 'Literal backup mode %s was not read exactly from .env.\n' "$accepted_backup_mode" >&2
        exit 1
    }
done

rm -f -- "$backup_mode_fixture/.env"
[[ $(OSCAR_BACKUP_MODE=single bash -c '
    storage_script=$1
    set -- help
    source "$storage_script" >/dev/null
    configured_backup_mode
' _ "$backup_mode_fixture/oscar-storage.sh") == disabled ]] || {
    printf 'Missing backup mode did not resolve to the fresh-install disabled default.\n' >&2
    exit 1
}

for rejected_backup_mode_line in \
    'OSCAR_BACKUP_MODE=' \
    'OSCAR_BACKUP_MODE=Disabled' \
    'OSCAR_BACKUP_MODE=SINGLE' \
    'OSCAR_BACKUP_MODE=${OSCAR_TEST_MODE}' \
    'OSCAR_BACKUP_MODE=disabled '; do
    write_backup_mode_environment "$rejected_backup_mode_line"
    if bash -c '
        storage_script=$1
        set -- help
        source "$storage_script" >/dev/null
        assert_managed_environment_bindings
    ' _ "$backup_mode_fixture/oscar-storage.sh" >/dev/null 2>&1; then
        printf 'Backup-mode validation accepted nonliteral or noncanonical value: %s\n' "$rejected_backup_mode_line" >&2
        exit 1
    fi
done
write_backup_mode_environment 'OSCAR_BACKUP_MODE=disabled'
printf 'OSCAR_BACKUP_MODE=single\n' >>"$backup_mode_fixture/.env"
if bash -c '
    storage_script=$1
    set -- help
    source "$storage_script" >/dev/null
    assert_managed_environment_bindings
' _ "$backup_mode_fixture/oscar-storage.sh" >/dev/null 2>&1; then
    printf 'Backup-mode validation accepted duplicate OSCAR_BACKUP_MODE bindings.\n' >&2
    exit 1
fi

assert_contains '--backup-mode disabled\|single' "$setup_shell_script"
assert_contains '--backup-dir ABSOLUTE_PATH' "$setup_shell_script"
assert_contains 'safe absolute path that does not overlap the release or archive roots' "$setup_shell_script"
assert_contains 'safe absolute path that does not overlap the release or archive roots' "$setup_powershell_script"
assert_contains 'backup\|backup-verify\|backup-prune\|restore\)' "$shell_script"
assert_contains 'Re-run upgrade with -BackupMode single -BackupDir <safe-absolute-backup-path>' "$powershell_script"
for backup_policy_script in "$setup_shell_script" "$setup_powershell_script" "$shell_script" "$powershell_script"; do
    assert_not_contains 'secondary[- ]drive|absolute-secondary-drive-path' "$backup_policy_script"
done
write_backup_mode_environment 'OSCAR_BACKUP_MODE=disabled'
if disabled_backup_error=$(bash -c '
    storage_script=$1
    set -- help
    source "$storage_script" >/dev/null
    require_single_backup_mode
' _ "$backup_mode_fixture/oscar-storage.sh" 2>&1); then
    printf 'Disabled backup mode allowed a protected backup command.\n' >&2
    exit 1
fi
grep -Fq -- '--backup-mode single --backup-dir <safe-absolute-backup-path>' <<<"$disabled_backup_error" || {
    printf 'Disabled backup-mode error did not provide exact upgrade opt-in guidance.\n' >&2
    exit 1
}
assert_not_contains '^prune_backups\(\)' "$shell_script"
assert_contains "backup-prune\) fail 'backup-prune is retired" "$shell_script"

# CURRENT is the authenticated commit point, not a timestamp heuristic. Its
# HMAC covers exactly the first three newline-terminated lines; the fourth line
# carries that base64 tag and the file has no additional fields.
current_fixture="$test_root/current-pointer"
current_id=20261020T120000Z-1234abcd
mkdir -p "$current_fixture"
printf 'pointer-test-key\n' >"$current_fixture/key.txt"
bash -c '
    storage_script=$1; fixture=$2; backup_id=$3
    set -- help; source "$storage_script" >/dev/null
    backup_dir=$fixture
    backup_key_file=$fixture/key.txt
    fsync_path() { :; }
    calculate_current_pointer_hmac() {
        local pointer=$1 key tag
        key=$(cat "$backup_key_file")
        tag=$(head -n 3 "$pointer" | openssl dgst -sha256 -hmac "$key" -binary | openssl base64 -A)
        [[ $tag =~ ^[A-Za-z0-9+/]{43}=$ ]] || fail "test pointer HMAC failed"
        printf "%s" "$tag"
    }
    write_current_backup_pointer "$backup_id" oscar:test
    [[ $(validate_current_backup_pointer oscar:test) == "$backup_id" ]]
' _ "$shell_script" "$current_fixture" "$current_id"
expected_current_hmac=$(head -n 3 "$current_fixture/CURRENT" |
    openssl dgst -sha256 -hmac pointer-test-key -binary | openssl base64 -A)
[[ $(wc -l <"$current_fixture/CURRENT" | tr -d '[:space:]') == 4 &&
   $(sed -n '1p' "$current_fixture/CURRENT") == format=oscar-current-backup &&
   $(sed -n '2p' "$current_fixture/CURRENT") == version=1 &&
   $(sed -n '3p' "$current_fixture/CURRENT") == "backup_id=$current_id" &&
   $(sed -n '4p' "$current_fixture/CURRENT") == "hmac_sha256=$expected_current_hmac" &&
   $(portable_mode "$current_fixture/CURRENT") == 600 ]] || {
    printf 'Bash CURRENT pointer did not match the exact four-line authenticated format.\n' >&2
    exit 1
}
cp "$current_fixture/CURRENT" "$current_fixture/CURRENT.valid"
printf 'UNTERMINATED' >>"$current_fixture/CURRENT"
chmod 0600 "$current_fixture/CURRENT"
if bash -c '
    storage_script=$1; fixture=$2
    set -- help; source "$storage_script" >/dev/null
    backup_dir=$fixture; backup_key_file=$fixture/key.txt
    calculate_current_pointer_hmac() {
        local pointer=$1 key
        key=$(cat "$backup_key_file")
        head -n 3 "$pointer" | openssl dgst -sha256 -hmac "$key" -binary | openssl base64 -A
    }
    validate_current_backup_pointer oscar:test
' _ "$shell_script" "$current_fixture" >/dev/null 2>&1; then
    printf 'Bash CURRENT pointer accepted an unterminated trailing record.\n' >&2
    exit 1
fi
cp "$current_fixture/CURRENT.valid" "$current_fixture/CURRENT"
sed 's/1234abcd/deadbeef/' "$current_fixture/CURRENT.valid" >"$current_fixture/CURRENT"
chmod 0600 "$current_fixture/CURRENT"
if bash -c '
    storage_script=$1; fixture=$2
    set -- help; source "$storage_script" >/dev/null
    backup_dir=$fixture; backup_key_file=$fixture/key.txt
    calculate_current_pointer_hmac() {
        local pointer=$1 key
        key=$(cat "$backup_key_file")
        head -n 3 "$pointer" | openssl dgst -sha256 -hmac "$key" -binary | openssl base64 -A
    }
    validate_current_backup_pointer oscar:test
' _ "$shell_script" "$current_fixture" >/dev/null 2>&1; then
    printf 'Bash CURRENT pointer accepted an unauthenticated backup-ID edit.\n' >&2
    exit 1
fi
mv "$current_fixture/CURRENT.valid" "$current_fixture/CURRENT"

# Without CURRENT, a unique fully accepted schema-v2 recovery point is adopted
# rather than deleted. Legacy, failed, unaccepted, partial, and old uncommitted
# tombstones remain available for operator review. Once CURRENT exists, cleanup
# still authenticates both finalized candidates and deletion tombstones.
uncommitted_fixture="$test_root/uncommitted-first-backup"
legacy_final_id=20261018T120000Z-11111111
legacy_tombstone_id=20261018T130000Z-22222222
accepted_id=20261020T120000Z-33333333
failed_final_id=20261020T130000Z-44444444
forged_marker_id=20261020T140000Z-55555555
v2_partial_delete_id=20261020T150000Z-66666666
partial_id=20261020T160000Z-77777777
accepted_tombstone_id=20261020T170000Z-88888888
forged_tombstone_id=20261020T180000Z-99999999
mkdir -p \
    "$uncommitted_fixture/$legacy_final_id" \
    "$uncommitted_fixture/.deleting-$legacy_tombstone_id" \
    "$uncommitted_fixture/$accepted_id" \
    "$uncommitted_fixture/$failed_final_id" \
    "$uncommitted_fixture/$forged_marker_id" \
    "$uncommitted_fixture/$partial_id.partial" \
    "$uncommitted_fixture/.deleting-uncommitted-v2-$v2_partial_delete_id"
find "$uncommitted_fixture" -type d -exec chmod 0700 {} +
printf '2026-10-20T12:00:00Z\n' >"$uncommitted_fixture/$forged_marker_id/VERIFIED"
chmod 0600 "$uncommitted_fixture/$forged_marker_id/VERIFIED"
printf 'the authenticated payload was partly removed before a simulated power loss\n' \
    >"$uncommitted_fixture/.deleting-uncommitted-v2-$v2_partial_delete_id/remaining-member"
recovery_output=$(bash -c '
    storage_script=$1; fixture=$2; accepted_id=$3; legacy_final_id=$4; legacy_tombstone_id=$5
    failed_final_id=$6; forged_marker_id=$7; accepted_tombstone_id=$8; forged_tombstone_id=$9
    set -- help; source "$storage_script" >/dev/null
    backup_dir=$fixture
    fsync_path() { :; }
    calculate_current_pointer_hmac() { printf "%s" AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=; }
    accepted_schema_v2_backup_for_cleanup() {
        case $1 in
            "$accepted_id"|"$accepted_tombstone_id") return 0 ;;
            "$legacy_final_id"|"$legacy_tombstone_id") return 11 ;;
            "$failed_final_id") return 10 ;;
            "$forged_marker_id"|"$forged_tombstone_id") return 12 ;;
            *) return 10 ;;
        esac
    }
    recover_single_backup_state oscar:test
    mkdir "$backup_dir/.deleting-$accepted_tombstone_id" "$backup_dir/.deleting-$forged_tombstone_id"
    chmod 0700 "$backup_dir/.deleting-$accepted_tombstone_id" "$backup_dir/.deleting-$forged_tombstone_id"
    recover_single_backup_state oscar:test
' _ "$shell_script" "$uncommitted_fixture" "$accepted_id" "$legacy_final_id" "$legacy_tombstone_id" \
    "$failed_final_id" "$forged_marker_id" "$accepted_tombstone_id" "$forged_tombstone_id" 2>&1)
[[ -d $uncommitted_fixture/$legacy_final_id &&
   -d $uncommitted_fixture/$legacy_tombstone_id &&
   ! -e $uncommitted_fixture/.deleting-$legacy_tombstone_id &&
   -d $uncommitted_fixture/$accepted_id &&
   -d $uncommitted_fixture/$failed_final_id &&
   -d $uncommitted_fixture/$forged_marker_id &&
   -d $uncommitted_fixture/$partial_id.partial &&
   -d $uncommitted_fixture/.deleting-uncommitted-v2-$v2_partial_delete_id &&
   ! -e $uncommitted_fixture/.deleting-$accepted_tombstone_id &&
   -d $uncommitted_fixture/.deleting-$forged_tombstone_id &&
   $(sed -n '3p' "$uncommitted_fixture/CURRENT") == "backup_id=$accepted_id" ]] || {
    printf 'Bash recovery cleanup did not adopt the sole accepted snapshot and preserve every unauthorized candidate.\n' >&2
    exit 1
}
for expected_warning in \
    'preserving legacy schema-version-1 recovery point' \
    'preserving incomplete or unauthenticated backup candidate' \
    'preserving authenticated but unaccepted schema-version-2 backup candidate' \
    'preserving incomplete backup staging candidate' \
    'preserving legacy uncommitted schema-version-2 deletion tombstone'; do
    grep -Fq "$expected_warning" <<<"$recovery_output" || {
        printf 'Bash cleanup did not emit expected preservation warning: %s\n' "$expected_warning" >&2
        exit 1
    }
done

# A corrupt acceptance receipt on CURRENT is a hard stop before any candidate
# or tombstone can be mutated.
corrupt_current_fixture="$test_root/corrupt-current-receipt"
corrupt_current_id=20261020T190000Z-aaaaaaaa
corrupt_candidate_id=20261020T200000Z-bbbbbbbb
mkdir -p "$corrupt_current_fixture/$corrupt_current_id" "$corrupt_current_fixture/$corrupt_candidate_id"
chmod 0700 "$corrupt_current_fixture" "$corrupt_current_fixture/$corrupt_current_id" "$corrupt_current_fixture/$corrupt_candidate_id"
: >"$corrupt_current_fixture/CURRENT"
if bash -c '
    storage_script=$1; fixture=$2; current_id=$3
    set -- help; source "$storage_script" >/dev/null
    backup_dir=$fixture
    validate_current_backup_pointer() { printf "%s" "$current_id"; }
    accepted_schema_v2_backup_for_cleanup() { [[ $1 != "$current_id" ]]; }
    recover_single_backup_state oscar:test
' _ "$shell_script" "$corrupt_current_fixture" "$corrupt_current_id" >/dev/null 2>&1; then
    printf 'Bash cleanup accepted CURRENT with a corrupt acceptance receipt.\n' >&2
    exit 1
fi
[[ -d $corrupt_current_fixture/$corrupt_current_id && -d $corrupt_current_fixture/$corrupt_candidate_id ]] || {
    printf 'Bash cleanup mutated candidates after CURRENT acceptance verification failed.\n' >&2
    exit 1
}
ambiguous_current_fixture="$test_root/ambiguous-current-recovery"
ambiguous_a=20261020T210000Z-cccccccc
ambiguous_b=20261020T220000Z-dddddddd
ambiguous_legacy=20261020T230000Z-eeeeeeee
mkdir -p "$ambiguous_current_fixture/$ambiguous_a" "$ambiguous_current_fixture/$ambiguous_b" \
    "$ambiguous_current_fixture/.deleting-$ambiguous_legacy"
chmod 0700 "$ambiguous_current_fixture" "$ambiguous_current_fixture/$ambiguous_a" \
    "$ambiguous_current_fixture/$ambiguous_b" "$ambiguous_current_fixture/.deleting-$ambiguous_legacy"
if bash -c '
    storage_script=$1; fixture=$2; legacy=$3
    set -- help; source "$storage_script" >/dev/null
    backup_dir=$fixture
    accepted_schema_v2_backup_for_cleanup() { [[ $1 == "$legacy" ]] && return 11; return 0; }
    recover_single_backup_state oscar:test
' _ "$shell_script" "$ambiguous_current_fixture" "$ambiguous_legacy" >/dev/null 2>&1; then
    printf 'Bash cleanup chose between multiple accepted candidates without CURRENT.\n' >&2
    exit 1
fi
[[ -d $ambiguous_current_fixture/$ambiguous_a && -d $ambiguous_current_fixture/$ambiguous_b &&
   -d $ambiguous_current_fixture/.deleting-$ambiguous_legacy &&
   ! -e $ambiguous_current_fixture/$ambiguous_legacy && ! -e $ambiguous_current_fixture/CURRENT ]] || {
    printf 'Bash ambiguous no-CURRENT cleanup did not preserve every accepted candidate.\n' >&2
    exit 1
}

# A failed producer must invalidate the entire recovery scan. Process
# substitution used to hide this status and could make two accepted candidates
# look like one, causing an unauthorized CURRENT reconstruction.
scan_failure_fixture="$test_root/failed-backup-enumeration"
scan_failure_a=20261021T010000Z-11111111
scan_failure_b=20261021T020000Z-22222222
mkdir -p "$scan_failure_fixture/$scan_failure_a" "$scan_failure_fixture/$scan_failure_b"
chmod 0700 "$scan_failure_fixture" "$scan_failure_fixture/$scan_failure_a" "$scan_failure_fixture/$scan_failure_b"
if bash -c '
    storage_script=$1; fixture=$2; first=$3
    set -- help; source "$storage_script" >/dev/null
    backup_dir=$fixture
    find() { printf "%s\0" "$fixture/$first"; return 42; }
    accepted_schema_v2_backup_for_cleanup() { return 0; }
    write_current_backup_pointer() { : >"$backup_dir/CURRENT"; }
    cleanup_uncommitted_schema_v2_snapshots oscar:test
' _ "$shell_script" "$scan_failure_fixture" "$scan_failure_a" >/dev/null 2>&1; then
    printf 'Bash no-CURRENT recovery ignored a failed directory enumeration.\n' >&2
    exit 1
fi
[[ -d $scan_failure_fixture/$scan_failure_a && -d $scan_failure_fixture/$scan_failure_b &&
   ! -e $scan_failure_fixture/CURRENT ]] || {
    printf 'Bash failed directory enumeration mutated or adopted a recovery candidate.\n' >&2
    exit 1
}
assert_contains 'cleanup_uncommitted_schema_v2_snapshots "\$image"' "$shell_script"
assert_contains '\$supplied_root == "\$backup_dir/\.deleting-\$backup_id"' "$shell_script"
assert_contains '\.deleting-uncommitted-v2-' "$shell_script"

# Generated TLS must cover the configured name plus every explicit LAN or
# Tailscale address, deduplicate repeated entries, and label IP/DNS SANs
# correctly. Keep this test independent of host network discovery.
tls_san_result=$(bash -c '
    setup_script=$1
    set -- help
    source "$setup_script" >/dev/null
    tls_mode=self-signed
    auto_network_sans=false
    tls_sans=(192.168.0.57 node.example-tailnet.ts.net 192.168.0.57)
    resolve_tls_sans oscar.local
    printf "%s\n%s\n" "${resolved_tls_sans[*]}" "$(tls_san_extension)"
' _ "$setup_shell_script")
expected_tls_san_result=$'oscar.local 192.168.0.57 node.example-tailnet.ts.net\nDNS:oscar.local,IP:192.168.0.57,DNS:node.example-tailnet.ts.net'
[[ $tls_san_result == "$expected_tls_san_result" ]] || {
    printf 'Bash TLS SAN resolution did not preserve the LAN/Tailscale certificate contract.\n' >&2
    exit 1
}
auto_tls_san_result=$(bash -c '
    setup_script=$1
    set -- help
    source "$setup_script" >/dev/null
    ip() {
        printf "%s\n" \
            "4: tailscale0 inet 100.86.149.49/32 scope global tailscale0" \
            "4: tailscale0 inet6 fd7a:115c:a1e0::f139:9532/128 scope global" \
            "5: docker0 inet 172.17.0.1/16 scope global docker0" \
            "28: eno1 inet 192.168.0.57/24 scope global eno1" \
            "28: eno1 inet6 fd5b:ad6:c937:50f1::1234/64 scope global temporary dynamic"
    }
    tailscale() { printf "%s\n" "{\"Self\":{\"DNSName\":\"node.example-tailnet.ts.net.\"}}"; }
    tls_mode=self-signed
    auto_network_sans=true
    tls_sans=()
    resolve_tls_sans oscar.local
    printf "%s" "${resolved_tls_sans[*]}"
' _ "$setup_shell_script")
[[ $auto_tls_san_result == 'oscar.local 100.86.149.49 fd7a:115c:a1e0::f139:9532 192.168.0.57 node.example-tailnet.ts.net' ]] || {
    printf 'Bash automatic TLS SAN discovery included a container/temporary address or missed LAN/Tailscale identity.\n' >&2
    exit 1
}
if bash -c '
    setup_script=$1
    set -- help
    source "$setup_script" >/dev/null
    tls_mode=self-signed
    auto_network_sans=false
    tls_sans=("invalid SAN")
    resolve_tls_sans oscar.local
' _ "$setup_shell_script" >/dev/null 2>&1; then
    printf 'Bash TLS SAN resolution accepted an invalid name.\n' >&2
    exit 1
fi
assert_contains 'ip -o address show up scope global' "$setup_shell_script"
assert_contains 'lo\|docker\*\|br-\*\|veth\*\|virbr\*\|cni\*\|podman\*' "$setup_shell_script"
assert_contains 'address == \*:\* && \$interface != tailscale\*' "$setup_shell_script"
assert_contains 'tailscale status --json' "$setup_shell_script"
assert_contains 'Copy only server\.crt to clients; never copy tls/server\.key' "$setup_shell_script"

# Docker Compose does not serialize a multi-service stop. Exercise the real
# storage helper with a mocked Compose boundary, and require the setup helper
# source to express the same gateway -> application -> database contract.
ordered_stop_actions="$test_root/ordered-stop.actions"
OSCAR_STORAGE_TEST_MODE=1 bash -c '
    storage_script=$1; actions=$2
    set -- help; source "$storage_script" >/dev/null
    compose() { printf "%s\n" "$*" >>"$actions"; }
    stop_deployment_ordered
' _ "$shell_script" "$ordered_stop_actions"
printf 'stop gateway\nstop oscar\nstop postgres\n' >"$test_root/ordered-stop.expected"
cmp -s "$test_root/ordered-stop.expected" "$ordered_stop_actions" || {
    printf 'Bash storage stop is not dependency ordered.\n' >&2
    exit 1
}
setup_stop_body=$(awk '
    /^stop_application_tier_ordered\(\)/ { capture=1 }
    /^psql_bootstrap\(\)/ { capture=0 }
    capture { print }
' "$setup_shell_script")
setup_gateway_stop=$(grep -n -m1 'compose stop gateway' <<<"$setup_stop_body" | cut -d: -f1)
setup_oscar_stop=$(grep -n -m1 'compose stop oscar' <<<"$setup_stop_body" | cut -d: -f1)
setup_postgres_stop=$(grep -n -m1 'compose stop postgres' <<<"$setup_stop_body" | cut -d: -f1)
[[ -n $setup_gateway_stop && -n $setup_oscar_stop && -n $setup_postgres_stop &&
   $setup_gateway_stop -lt $setup_oscar_stop && $setup_oscar_stop -lt $setup_postgres_stop ]] || {
    printf 'Bash setup stop is not dependency ordered.\n' >&2
    exit 1
}
assert_not_contains '^[[:space:]]*compose restart([[:space:]]|$)' "$setup_shell_script"
assert_not_contains 'compose stop gateway oscar postgres' "$shell_script"
assert_not_contains '^[[:space:]]*compose stop([[:space:]]*$)' "$setup_shell_script"
assert_not_contains "Invoke-Compose @\('restart'" "$setup_powershell_script"
assert_not_contains "Invoke-Compose @\('stop', 'gateway', 'oscar', 'postgres'\)" "$powershell_script"

# The release directory is part of every destructive containment decision.
# Resolve directory aliases physically and reject a launcher-file alias before
# reading deployment configuration.
release_physical="$test_root/release-physical"
release_alias="$test_root/release-alias"
mkdir -p "$release_physical"
cp "$shell_script" "$repo_root/dist/release/.env.example" "$release_physical/"
ln -s "$release_physical" "$release_alias"
resolved_release=$(bash -c '
    storage_script=$1
    set -- help
    source "$storage_script" >/dev/null
    printf "%s" "$script_dir"
' _ "$release_alias/oscar-storage.sh")
[[ $resolved_release == "$(CDPATH= cd -- "$release_physical" && pwd -P)" ]] || {
    printf 'Bash storage launcher did not canonicalize its release directory.\n' >&2
    exit 1
}
if bash -c '
    storage_script=$1
    set -- help
    source "$storage_script" >/dev/null
    validate_storage_path_shape TEST_ROOT "$script_dir/nested/archive"
' _ "$release_alias/oscar-storage.sh" >/dev/null 2>&1; then
    printf 'Bash storage containment accepted a root hidden inside a release-directory alias.\n' >&2
    exit 1
fi
ln -s "$release_physical/oscar-storage.sh" "$test_root/oscar-storage-link.sh"
if bash "$test_root/oscar-storage-link.sh" help >/dev/null 2>&1; then
    printf 'Bash storage launcher accepted a symlinked launcher file.\n' >&2
    exit 1
fi

assert_contains 'pwd -P' "$shell_script"
assert_contains 'regular, non-symlink file' "$shell_script"
assert_contains 'Assert-NoReparseComponents \$StorageScriptPath' "$powershell_script"
assert_contains 'Resolve-PhysicalContainmentPath \$ScriptRoot' "$powershell_script"

# Both archive-generation and archive-object expose a state column. Exercise
# the status command through its public function and require every generation
# projection/grouping column to remain explicitly bound to the generation
# alias so PostgreSQL cannot reject the LEFT JOIN as ambiguous.
archive_status_sql="$test_root/archive-status.sql"
bash -c '
    storage_script=$1; capture=$2
    set -- help; source "$storage_script" >/dev/null
    require_configured() { :; }
    psql_admin() { printf "%s\n" "$*" >>"$capture"; }
    audit_archive_filesystem() { :; }
    archive_status
' _ "$shell_script" "$archive_status_sql"
assert_contains 'SELECT g\.store_key, g\.id_scope, g\.state, g\.profile, count\(\*\) generations, coalesce\(sum\(g\.row_count\),0\) rows' "$archive_status_sql"
assert_contains 'GROUP BY g\.store_key, g\.id_scope, g\.state, g\.profile ORDER BY g\.store_key, g\.id_scope, g\.state, g\.profile' "$archive_status_sql"
assert_not_contains 'SELECT store_key, id_scope, state, profile' "$archive_status_sql"

if command -v pwsh >/dev/null 2>&1; then
    release_ps_physical="$test_root/release-ps-physical"
    release_ps_alias="$test_root/release-ps-alias"
    mkdir -p "$release_ps_physical"
    cp "$powershell_script" "$repo_root/dist/release/.env.example" "$release_ps_physical/"
    ln -s "$release_ps_physical" "$release_ps_alias"
    pwsh -NoLogo -NoProfile -File "$release_ps_physical/oscar-storage.ps1" -Command help >/dev/null
    if pwsh -NoLogo -NoProfile -File "$release_ps_alias/oscar-storage.ps1" -Command help >/dev/null 2>&1; then
        printf 'PowerShell storage launcher accepted a reparse/symlink release alias.\n' >&2
        exit 1
    fi
fi

# Every tar-validator container is otherwise read-only and must receive the
# same bounded, private scratch mount. Keep TMPDIR pinned so a future image
# environment cannot redirect validator writes outside that mount.
validator_tmpfs_spec='/tmp:rw,noexec,nosuid,nodev,size=256m,mode=0700,uid=0,gid=0'
[[ $(grep -Fxc "readonly validator_scratch_tmpfs=$validator_tmpfs_spec" "$shell_script") == 1 &&
   $(grep -F -- '--tmpfs "$validator_scratch_tmpfs" --env TMPDIR=/tmp --workdir / --user 0 --entrypoint sh' "$shell_script" | wc -l | tr -d ' ') == 3 ]] || {
    printf 'Bash tar-validator launches do not all use the exact bounded scratch tmpfs.\n' >&2
    exit 1
}
[[ $(grep -Fxc "\$ValidatorScratchTmpfs = '$validator_tmpfs_spec'" "$powershell_script") == 1 &&
   $(grep -F -- "'--tmpfs', \$ValidatorScratchTmpfs, '--env', 'TMPDIR=/tmp', '--workdir', '/', '--user', '0', '--entrypoint', 'sh'" "$powershell_script" | wc -l | tr -d ' ') == 3 ]] || {
    printf 'PowerShell tar-validator launches do not all use the exact bounded scratch tmpfs.\n' >&2
    exit 1
}

# Target-side bundle verification must authenticate the exact inventory on
# every run. A stale receipt, an extra privileged installer, a duplicate
# manifest path, or a link/reparse entry must never be accepted.
bundle_fixture="$test_root/offline-bundle"
mkdir -p "$bundle_fixture"
cp "$repo_root/dist/release/verify-bundle.sh" "$repo_root/dist/release/verify-bundle.ps1" "$bundle_fixture/"
printf 'authenticated payload\n' >"$bundle_fixture/payload.txt"
write_bundle_manifest() {
    : >"$bundle_fixture/SHA256SUMS"
    local relative
    for relative in payload.txt verify-bundle.ps1 verify-bundle.sh; do
        printf '%s *%s\n' "$(sha256_path "$bundle_fixture/$relative")" "$relative" >>"$bundle_fixture/SHA256SUMS"
    done
}
write_bundle_manifest
bash "$bundle_fixture/verify-bundle.sh" >/dev/null
if command -v pwsh >/dev/null 2>&1; then
    pwsh -NoLogo -NoProfile -File "$bundle_fixture/verify-bundle.ps1" >/dev/null
fi
printf 'corrupted after receipt\n' >"$bundle_fixture/payload.txt"
if bash "$bundle_fixture/verify-bundle.sh" >/dev/null 2>&1; then
    printf 'Bash bundle verifier trusted a stale receipt after payload mutation.\n' >&2; exit 1
fi
if command -v pwsh >/dev/null 2>&1 && pwsh -NoLogo -NoProfile -File "$bundle_fixture/verify-bundle.ps1" >/dev/null 2>&1; then
    printf 'PowerShell bundle verifier trusted a stale receipt after payload mutation.\n' >&2; exit 1
fi
printf 'authenticated payload\n' >"$bundle_fixture/payload.txt"
write_bundle_manifest
printf 'unmanifested installer\n' >"$bundle_fixture/extra.deb"
if bash "$bundle_fixture/verify-bundle.sh" >/dev/null 2>&1; then
    printf 'Bash bundle verifier accepted an unmanifested payload.\n' >&2; exit 1
fi
if command -v pwsh >/dev/null 2>&1 && pwsh -NoLogo -NoProfile -File "$bundle_fixture/verify-bundle.ps1" >/dev/null 2>&1; then
    printf 'PowerShell bundle verifier accepted an unmanifested payload.\n' >&2; exit 1
fi
rm -f -- "$bundle_fixture/extra.deb"
cp "$bundle_fixture/SHA256SUMS" "$test_root/offline-manifest-clean"
head -n 1 "$test_root/offline-manifest-clean" >>"$bundle_fixture/SHA256SUMS"
if bash "$bundle_fixture/verify-bundle.sh" >/dev/null 2>&1; then
    printf 'Bash bundle verifier accepted a duplicate manifest member.\n' >&2; exit 1
fi
if command -v pwsh >/dev/null 2>&1 && pwsh -NoLogo -NoProfile -File "$bundle_fixture/verify-bundle.ps1" >/dev/null 2>&1; then
    printf 'PowerShell bundle verifier accepted a duplicate manifest member.\n' >&2; exit 1
fi
mv "$test_root/offline-manifest-clean" "$bundle_fixture/SHA256SUMS"
ln -s payload.txt "$bundle_fixture/.bundle-verified.tmp.attacker"
if bash "$bundle_fixture/verify-bundle.sh" >/dev/null 2>&1; then
    printf 'Bash bundle verifier accepted a symlinked receipt temporary.\n' >&2; exit 1
fi
if command -v pwsh >/dev/null 2>&1 && pwsh -NoLogo -NoProfile -File "$bundle_fixture/verify-bundle.ps1" >/dev/null 2>&1; then
    printf 'PowerShell bundle verifier accepted a reparse/symlink receipt temporary.\n' >&2; exit 1
fi
rm -f -- "$bundle_fixture/.bundle-verified.tmp.attacker"
if command -v powershell.exe >/dev/null 2>&1; then
    powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$bundle_fixture/verify-bundle.ps1" >/dev/null
fi

bash "$repo_root/tools/test-archive-object-helper.sh"
assert_contains 'LOCK TABLE oscar_retention_hold IN SHARE ROW EXCLUSIVE MODE' "$shell_script"
assert_contains "SET state='DELETING'" "$shell_script"
assert_contains 'docker run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges' "$shell_script"
assert_contains '--cap-drop ALL --security-opt no-new-privileges' "$shell_script"
assert_contains '--cap-add DAC_READ_SEARCH --workdir / --user 0:0 --entrypoint pg_verifybackup' "$shell_script"
assert_contains 'SHA256SUMS\.hmac' "$shell_script"
assert_contains 'cannot be accepted as an authenticated \$required_release_version recovery point' "$shell_script"
assert_contains 'required_release_version=\$\(awk .*OSCAR_VERSION' "$shell_script"
assert_contains 'validate_backup_archive_members' "$shell_script"
assert_contains '^[[:space:]]+archive_verify reject-partials$' "$shell_script"
assert_contains 'tar .*--exclude="\./duckdb-tmp"' "$shell_script"
assert_contains 'validate_image_inventory "\$root" true' "$shell_script"
assert_contains 'acquire_storage_admin_lock' "$shell_script"
assert_contains 'Darwin\) lock_directory=/private/var/run/oscar-storage' "$shell_script"
assert_contains 'run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges' "$shell_script"
assert_contains 'archive_object_helper copy "\$relative" "\$expected_sha" ro "\$partial"' "$shell_script"
assert_contains 'archive_object_helper delete "\$relative" "\$expected_sha" rw' "$shell_script"
assert_contains 'compose stop oscar' "$shell_script"
assert_contains 'compose up --detach --no-deps --no-build --pull never --wait --wait-timeout 300 oscar' "$shell_script"
assert_contains 'DELETE FROM oscar_obs_overlay' "$shell_script"
assert_contains "subject_type='OBSERVATION'" "$shell_script"
assert_contains 'overlay_row\.generation_id=item\.generation_id' "$shell_script"
assert_contains 'DailyFileBackupConfirmationCli' "$shell_script"
assert_contains "state IN \('ACTIVE','DELETING'\)" "$shell_script"
assert_contains '^cleanup_snapshot_sidecar_temps\(\)' "$shell_script"
assert_contains 'Backup acceptance temporary must be administrator-owned with mode 0600' "$shell_script"
assert_contains 'validate_storage_directories' "$shell_script"
assert_contains 'prepare_restored_credentials_exact' "$shell_script"
assert_contains 'install_prepared_credentials_exact' "$shell_script"
assert_contains 'INSERT INTO oscar_retention_hold\(id,store_key,id_scope' "$shell_script"
assert_contains 'resolution_mode' "$shell_script"
assert_contains "THEN 'GENERATION_EXACT'" "$shell_script"
assert_contains "THEN 'HOT_EXACT'" "$shell_script"
assert_contains "THEN 'COLD_RANGE_CONSERVATIVE'" "$shell_script"
assert_contains 'FROM \\"\$store_key\\" any_hot_row' "$shell_script"
assert_contains 'FROM \\"\$store_key\\" exact_hot_row' "$shell_script"
assert_contains 'oscar_archive_id_block retired_block' "$shell_script"
assert_contains 'maximum=9223372036854775807' "$shell_script"
assert_contains 'INSERT INTO oscar_deletion_plan\(id, store_key, id_scope' "$shell_script"
assert_contains 'JOIN oscar_deletion_plan p ON p\.id=i\.plan_id' "$shell_script"
assert_contains 'g\.store_key=p\.store_key AND g\.id_scope=p\.id_scope' "$shell_script"
assert_contains 'ON CONFLICT \(subject_type,store_key,id_scope,subject_id\)' "$shell_script"
assert_contains 'archive purge --store-key %s --id-scope %s' "$shell_script"
assert_contains "VALUES \('OBSERVATIONS_PARQUET'\),\('GENERATION_MANIFEST'\),\('DATASTREAM_SCHEMAS'\)" "$shell_script"
assert_contains "g\.state IN \('ACTIVE','SEALED'\)" "$shell_script"
assert_contains '\$object_count != 1 \|\| \$object_state != ACTIVE' "$shell_script"
assert_contains '\$relative != "\$generation_object_path" \|\| \$expected != "\$generation_sha"' "$shell_script"
assert_contains '\$kind == GENERATION_MANIFEST && \$relative != "\$generation_manifest_path"' "$shell_script"
assert_contains 'Archive catalog changed during verification' "$shell_script"
assert_contains 'SELECT \* FROM required_rows UNION ALL SELECT \* FROM additional_rows' "$shell_script"
assert_contains 'UNION ALL SELECT \* FROM invalid_owner_rows' "$shell_script"
assert_contains "WHERE o\.state='ACTIVE' AND g\.state NOT IN \('ACTIVE','SEALED'\)" "$shell_script"
assert_contains "--field-separator=\\\$'\\\\x1f'" "$shell_script"
assert_contains 'ID_BLOCK_AND_SCHEMAS' "$shell_script"
assert_contains 'block\.min_id=g\.min_id AND block\.max_id=g\.max_id' "$shell_script"
assert_contains '! \$relative =~ \^\[1-9\]\[0-9\]\*\$' "$shell_script"
assert_contains '\$fields\[4\] -cne .MATCH.' "$powershell_script"
assert_contains 'block\.min_id=g\.min_id AND block\.max_id=g\.max_id' "$powershell_script"
assert_contains '\$fields\[5\] -cnotmatch .\^\[1-9\]\[0-9\]\*\$.' "$powershell_script"
assert_not_contains 'h\.subject_id::numeric BETWEEN g\.min_id AND g\.max_id' "$shell_script"
assert_not_contains 'h\.subject_id::numeric BETWEEN held_block\.min_id AND held_block\.max_id' "$shell_script"
assert_not_contains "numeric_subject'::numeric" "$shell_script"
assert_contains 'assert_deployment_volume_ownership "\$adopt_legacy_volumes"' "$setup_shell_script"
assert_contains 'require_upgrade_environment_keys' "$setup_shell_script"
assert_contains 'ensure_fresh_init_volumes' "$setup_shell_script"
assert_contains 'preserve \.oscar-volume-adoption' "$setup_shell_script"
assert_contains 'normalize_legacy_backup_key_binding' "$setup_shell_script"
assert_contains 'require_canonical_credential_bindings' "$setup_shell_script"
assert_contains 'Initialize-LegacyBackupKeyBinding' "$setup_powershell_script"
assert_contains 'Assert-UpgradeableEnvironmentBindings' "$setup_powershell_script"
assert_contains 'Initialize-FreshDeploymentVolumes' "$setup_powershell_script"
assert_contains 'docker run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges' "$setup_shell_script"
assert_contains '--tmpfs /tmp:rw,noexec,nosuid,nodev --workdir / --user 0:0 --entrypoint sh --volume "\$\{tls_dir\}:/tls:ro"' "$setup_shell_script"
assert_contains 'case \$output in \*" does match certificate"\)' "$setup_shell_script"
assert_contains '\$nameOutput = Get-DockerOutput @\(' "$setup_powershell_script"
assert_contains "'run', '--rm', '--network', 'none', '--read-only', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges'.*'--user', '0:0', '--entrypoint', 'openssl'.*tlsDirectory.*:/tls:ro" "$setup_powershell_script"
assert_contains "'x509', '-in', '/tls/server\.crt', '-noout'" "$setup_powershell_script"
assert_contains '\$nameCheck, \$sanName\)' "$setup_powershell_script"
assert_contains 'if \(\$nameOutput -cne \$expectedNameOutput\)' "$setup_powershell_script"
assert_not_contains '\$nameCommand' "$setup_powershell_script"
assert_contains "Get-ComposeShellInputOutput \\\$markerCheck @\\('exec', '-T', 'postgres', 'sh', '-seu', \\\$expectedVersion\\)" "$setup_powershell_script"
assert_contains "Get-ComposeShellInputOutput \\\$configCheck @\\('exec', '-T', 'oscar', 'sh', '-seu'\\)" "$setup_powershell_script"
assert_contains '# oscar-powershell-stdin-terminator' "$setup_powershell_script"
assert_not_contains "'-c', \\\$markerCheck" "$setup_powershell_script"
assert_not_contains "'-c', \\\$configCheck" "$setup_powershell_script"
for powershell_release_script in "$setup_powershell_script" "$powershell_script"; do
    assert_not_contains "'-c'" "$powershell_release_script"
    assert_not_contains "'--command'" "$powershell_release_script"
    assert_not_contains '\$@' "$powershell_release_script"
done
assert_contains '\$pinned = @\('"'"'run'"'"', '"'"'--interactive'"'"'\)' "$setup_powershell_script"
assert_contains '\$pinned = @\('"'"'run'"'"', '"'"'--interactive'"'"'\)' "$powershell_script"
assert_contains "OSCAR_STORAGE_RELAY_PAYLOAD" "$setup_powershell_script"
assert_contains "'-EncodedCommand', \\\$encodedCommand" "$setup_powershell_script"
assert_contains "'Parameters\|ScriptPath'" "$setup_powershell_script"
assert_not_contains "'-File', \\\$storageScript" "$setup_powershell_script"
assert_contains 'for attempt in \{1\.\.30\}' "$setup_shell_script"
assert_contains 'after 30 seconds' "$setup_shell_script"
assert_contains 'grep -Fq "\\"objClass\\": \\"com\.botts\.impl\.service\.dailyfile\.DailyFileJournalServiceConfig\\""' "$setup_shell_script"
assert_not_contains "grep -Fq '\"objClass" "$setup_shell_script"
assert_contains 'for \(\$attempt = 1; \$attempt -le 30; \$attempt\+\+\)' "$setup_powershell_script"
assert_contains 'after 30 seconds' "$setup_powershell_script"

# A clean-directory upgrade must move every release-local bind and Compose
# provenance label to the new directory, including an otherwise unchanged
# PostgreSQL service. Ordinary start remains non-recreating. Keep the exact
# Bash/PowerShell contracts in parity and never renew/remove persistent data.
extract_case_body() {
    local file=$1 start=$2 end=$3
    awk -v start="$start" -v end="$end" '
        $0 == start { capture=1 }
        capture { print }
        capture && index($0, end) == 1 { exit }
    ' "$file"
}
bash_start_case=$(extract_case_body "$setup_shell_script" '    start)' '    stop)')
bash_upgrade_case=$(extract_case_body "$setup_shell_script" '    upgrade)' '    *)')
ps_start_case=$(extract_case_body "$setup_powershell_script" "        'start' {" "        'stop' {")
ps_upgrade_case=$(extract_case_body "$setup_powershell_script" "        'upgrade' {" "        'backup' {")

[[ $(grep -Fxc '        compose up --detach --no-build --pull never --wait --wait-timeout 240' <<<"$bash_start_case") == 1 &&
   $bash_start_case != *--force-recreate* ]] || {
    printf 'Bash ordinary start must remain non-recreating.\n' >&2
    exit 1
}
[[ $(grep -Fxc '        bash "$script_dir/oscar-storage.sh" upgrade-state' <<<"$bash_upgrade_case") == 1 &&
   $bash_upgrade_case != *--renew-anon-volumes* && $bash_upgrade_case != *'compose down'* ]] || {
    printf 'Bash upgrade must delegate its locked persistent-state transition exactly once.\n' >&2
    exit 1
}
[[ $(grep -Fxc "            Invoke-Compose @('up', '--detach', '--no-build', '--pull', 'never', '--wait', '--wait-timeout', '240')" <<<"$ps_start_case") == 1 &&
   $ps_start_case != *--force-recreate* ]] || {
    printf 'PowerShell ordinary start must remain non-recreating.\n' >&2
    exit 1
}
[[ $(grep -Fxc "            Invoke-StorageCommand 'upgrade-state' \$null" <<<"$ps_upgrade_case") == 1 &&
   $ps_upgrade_case != *--renew-anon-volumes* && $ps_upgrade_case != *"Invoke-Compose @('down'"* ]] || {
    printf 'PowerShell upgrade must delegate its locked persistent-state transition exactly once.\n' >&2
    exit 1
}
bash_upgrade_state_body=$(awk '
    /^upgrade_persistent_state\(\)/ { capture=1 }
    /^confirm_daily_journal_backup\(\)/ { capture=0 }
    capture { print }
' "$shell_script")
ps_upgrade_state_body=$(awk '
    /^function Invoke-UpgradePersistentState/ { capture=1 }
    /^function Write-Checksums/ { capture=0 }
    capture { print }
' "$powershell_script")
[[ $(grep -Fxc '    compose up --detach --force-recreate --no-build --pull never --wait --wait-timeout 240' <<<"$bash_upgrade_state_body") == 1 &&
   $bash_upgrade_state_body == *'--config /var/lib/oscar/config.json'* &&
   $bash_upgrade_state_body == *'umask 077'* &&
   $bash_upgrade_state_body != *--renew-anon-volumes* && $bash_upgrade_state_body != *'compose down'* ]] || {
    printf 'Bash locked upgrade workflow must use config-aware migration and recreate services without replacing data.\n' >&2
    exit 1
}
[[ $(grep -Fxc "    Invoke-Compose @('up', '--detach', '--force-recreate', '--no-build', '--pull', 'never', '--wait', '--wait-timeout', '240')" <<<"$ps_upgrade_state_body") == 1 &&
   $ps_upgrade_state_body == *'--config /var/lib/oscar/config.json'* &&
   $ps_upgrade_state_body == *'umask 077'* &&
   $ps_upgrade_state_body != *--renew-anon-volumes* && $ps_upgrade_state_body != *"Invoke-Compose @('down'"* ]] || {
    printf 'PowerShell locked upgrade workflow must use config-aware migration and recreate services without replacing data.\n' >&2
    exit 1
}
assert_contains '^upgrade_persistent_state\(\)' "$shell_script"
assert_contains '^function Invoke-UpgradePersistentState' "$powershell_script"
assert_contains 'DailyFileJournalIndexMigration' "$shell_script"
assert_contains 'DailyFileJournalIndexMigration' "$powershell_script"

# Execute the real Bash transition function across mocked Docker/Compose
# boundaries. The ordered stop and config-aware migration must precede the
# restart, and a migration failure must leave the application stopped.
bash_upgrade_actions="$test_root/bash-upgrade-state.actions"
OSCAR_STORAGE_TEST_MODE=1 bash -c '
    storage_script=$1; actions=$2
    set -- help; source "$storage_script" >/dev/null
    oscar_image() { printf "%s" oscar:test; }
    docker() { printf "legacy-cleanup\n" >>"$actions"; }
    compose() {
        case "$1 ${2:-}" in
            "stop gateway") printf "stop-gateway\n" >>"$actions" ;;
            "stop oscar") printf "stop-oscar\n" >>"$actions" ;;
            "run --rm")
                [[ "$*" == *"--entrypoint sh oscar -eu -c"* && "$*" == *"umask 077"* && "$*" == *"--config /var/lib/oscar/config.json"* ]]
                printf "migrate\n" >>"$actions"
                ;;
            "config --quiet") printf "config\n" >>"$actions" ;;
            "up --detach")
                [[ "$*" == *"--force-recreate"* && "$*" != *"--renew-anon-volumes"* ]]
                printf "start\n" >>"$actions"
                ;;
            *) return 91 ;;
        esac
    }
    upgrade_persistent_state >/dev/null
' _ "$shell_script" "$bash_upgrade_actions"
printf 'stop-gateway\nstop-oscar\nlegacy-cleanup\nmigrate\nconfig\nstart\n' >"$test_root/bash-upgrade-state.expected"
cmp -s "$test_root/bash-upgrade-state.expected" "$bash_upgrade_actions" || {
    printf 'Bash locked upgrade transition ordering is incorrect.\n' >&2
    exit 1
}
bash_upgrade_failure_actions="$test_root/bash-upgrade-state-failure.actions"
if OSCAR_STORAGE_TEST_MODE=1 bash -c '
    storage_script=$1; actions=$2
    set -- help; source "$storage_script" >/dev/null
    oscar_image() { printf "%s" oscar:test; }
    docker() { printf "legacy-cleanup\n" >>"$actions"; }
    compose() {
        case "$1 ${2:-}" in
            "stop gateway") printf "stop-gateway\n" >>"$actions" ;;
            "stop oscar") printf "stop-oscar\n" >>"$actions" ;;
            "run --rm") printf "migration-failed\n" >>"$actions"; return 42 ;;
            "up --detach") printf "UNSAFE-START\n" >>"$actions" ;;
            *) return 91 ;;
        esac
    }
    upgrade_persistent_state >/dev/null
' _ "$shell_script" "$bash_upgrade_failure_actions" >/dev/null 2>&1; then
    printf 'Bash locked upgrade transition ignored migration failure.\n' >&2
    exit 1
fi
if grep -Fq 'UNSAFE-START' "$bash_upgrade_failure_actions"; then
    printf 'Bash locked upgrade transition restarted after migration failure.\n' >&2
    exit 1
fi

# A connected init/upgrade always rebuilds the local OSCAR/PostGIS images, even
# when their mutable pre-release tags are cached. Recheck the inventory after
# those builds: an unnecessary gateway pull would make that valid local state
# depend on registry credentials/network access. Pull remains required when the
# gateway really is absent.
bash -c '
    setup_script=$1
    set -- help
    source "$setup_script" >/dev/null
    script_dir=$(mktemp -d)
    trap '\''rm -rf -- "$script_dir"'\'' EXIT
    built=false
    gateway_present=true
    actions=()
    required_images() { printf "%s\n" oscar:test oscar-postgis:test gateway:test; }
    container_image_exists() {
        case $1 in
            oscar:test|oscar-postgis:test) $built ;;
            gateway:test) $gateway_present ;;
            *) return 1 ;;
        esac
    }
    heading() { :; }
    compose() {
        actions+=("$*")
        case "$*" in
            "build oscar postgres") built=true ;;
            "pull gateway") gateway_present=true ;;
            *) return 97 ;;
        esac
    }
    prepare_deployment_images
    [[ ${#actions[@]} == 1 && ${actions[0]} == "build oscar postgres" ]] || exit 41

    built=false
    gateway_present=false
    actions=()
    prepare_deployment_images
    [[ ${#actions[@]} == 2 && ${actions[0]} == "build oscar postgres" && ${actions[1]} == "pull gateway" ]] || exit 42

    built=true
    gateway_present=true
    actions=()
    prepare_deployment_images
    [[ ${#actions[@]} == 1 && ${actions[0]} == "build oscar postgres" ]] || exit 43
' _ "$setup_shell_script" || {
    printf 'Bash connected image preparation did not avoid an unnecessary cached-gateway pull.\n' >&2
    exit 1
}

# Java native libraries need one executable extraction point without weakening
# the general-purpose temporary mount. The entrypoint owns java.io.tmpdir and
# must reject a missing, shared, permissive, or non-executable native tmpfs.
oscar_service_block=$(sed -n '/^  oscar:$/,/^  postgres:$/p' "$compose_file")
[[ $(grep -Fxc '      - /tmp:rw,noexec,nosuid,nodev' <<<"$oscar_service_block") == 1 &&
   $(grep -Fxc '      - /run/oscar-native:rw,exec,nosuid,nodev,size=256m,mode=0700,uid=10001,gid=10001' <<<"$oscar_service_block") == 1 &&
   $(grep -Fxc '      - /run/oscar-native:rw,exec,nosuid,nodev,size=256m,mode=0700,uid=10001,gid=10001' "$compose_file") == 1 ]] || {
    printf 'Compose must keep /tmp noexec and grant only OSCAR a bounded owner-only native tmpfs.\n' >&2
    exit 1
}
assert_contains 'install --directory --owner=oscar --group=oscar --mode=0700' "$oscar_dockerfile"
assert_contains '/var/lib/oscar /run/oscar-native' "$oscar_dockerfile"
assert_contains '^NATIVE_TMP_DIR=/run/oscar-native$' "$oscar_entrypoint"
assert_contains '^READY_FILE=/tmp/oscar-ready$' "$oscar_entrypoint"
assert_contains 'rm -f -- "\$\{READY_FILE\}" "\$\{READY_FILE\}\.tmp"' "$oscar_entrypoint"
assert_contains 'test -f /tmp/oscar-ready && curl --silent --show-error' "$compose_file"
assert_contains 'if \[ -n "\$\{_JAVA_OPTIONS:-\}" \]' "$oscar_entrypoint"
assert_contains 'is_tmpfs_mount /tmp' "$oscar_entrypoint"
assert_contains 'mount_has_option /tmp noexec' "$oscar_entrypoint"
assert_contains 'mount_has_option /tmp nosuid' "$oscar_entrypoint"
assert_contains 'mount_has_option /tmp nodev' "$oscar_entrypoint"
assert_contains 'mount_has_option "\$\{NATIVE_TMP_DIR\}" nosuid' "$oscar_entrypoint"
assert_contains 'mount_has_option "\$\{NATIVE_TMP_DIR\}" nodev' "$oscar_entrypoint"
assert_contains 'stat -c .*%u:%g:%a.*NATIVE_TMP_DIR' "$oscar_entrypoint"
assert_contains 'native_exec_probe=.*NATIVE_TMP_DIR' "$oscar_entrypoint"
assert_contains '-Djava\.io\.tmpdir="\$\{NATIVE_TMP_DIR\}"' "$oscar_entrypoint"
assert_contains '-Dorg\.bytedeco\.javacpp\.cachedir="\$\{NATIVE_TMP_DIR\}/javacpp"' "$oscar_entrypoint"
assert_contains '-Doscar\.data\.tmpdir=/tmp' "$oscar_entrypoint"
java_opts_line=$(grep -n -m1 'exec java \${JAVA_OPTS:-}' "$oscar_entrypoint" | cut -d: -f1)
managed_tmp_line=$(grep -n -m1 -- '-Djava.io.tmpdir="${NATIVE_TMP_DIR}"' "$oscar_entrypoint" | cut -d: -f1)
managed_javacpp_line=$(grep -n -m1 -- '-Dorg.bytedeco.javacpp.cachedir="${NATIVE_TMP_DIR}/javacpp"' "$oscar_entrypoint" | cut -d: -f1)
managed_data_tmp_line=$(grep -n -m1 -- '-Doscar.data.tmpdir=/tmp' "$oscar_entrypoint" | cut -d: -f1)
[[ -n $java_opts_line && -n $managed_tmp_line && -n $managed_javacpp_line &&
   -n $managed_data_tmp_line && $java_opts_line -lt $managed_tmp_line &&
   $java_opts_line -lt $managed_javacpp_line && $java_opts_line -lt $managed_data_tmp_line ]] || {
    printf 'Managed native and data temp directories must follow and override administrator JAVA_OPTS.\n' >&2
    exit 1
}

# Setup owns the named-volume lifecycle and validates either the immutable
# deployment label or an exact legacy-adoption receipt before Compose starts.
# Declaring these volumes external keeps Compose v5 from trying to reconcile
# an immutable label on an adopted volume and offering to recreate live data.
compose_volume_block=$(sed -n '/^volumes:$/,/^secrets:$/p' "$compose_file")
expected_compose_volume_block=$'volumes:\n  oscar_state:\n    external: true\n    name: oscar_oscar_state\n  postgres_data:\n    external: true\n    name: oscar_postgres_data\n\nsecrets:'
if [[ $compose_volume_block != "$expected_compose_volume_block" ]]; then
    printf 'Compose named volumes must remain exact external resources owned by setup.\n' >&2
    exit 1
fi

# A real pre-3.11.0 deployment does not have the backup-key binding. Upgrade may
# add only that missing canonical binding; custom, duplicate, and current-release
# omissions remain hard failures under the strict credential-binding validator.
write_391_env_fixture() {
    local destination=$1
    cat >"$destination" <<'EOF'
OSCAR_VERSION=3.9.1
OSCAR_POSTGIS_VERSION=16-3.5
OSCAR_POSTGIS_PLATFORM=linux/amd64
OSCAR_HTTPS_PORT=443
OSCAR_HOSTNAME=oscar.local
OSCAR_SECRETS_DIR=./secrets
OSCAR_TLS_DIR=./tls
OSCAR_JAVA_OPTS=-Xms1g -Xmx6g -Xss256k -XX:ReservedCodeCacheSize=512m -XX:+UseG1GC -XX:+HeapDumpOnOutOfMemoryError
EOF
}

legacy_binding_bash="$test_root/legacy-binding-bash"
legacy_custom_bash="$test_root/legacy-binding-custom-bash"
legacy_duplicate_bash="$test_root/legacy-binding-duplicate-bash"
current_missing_bash="$test_root/current-binding-missing-bash"
mkdir -p "$legacy_binding_bash" "$legacy_custom_bash" "$legacy_duplicate_bash" "$current_missing_bash"
write_391_env_fixture "$legacy_binding_bash/.env"
write_391_env_fixture "$legacy_custom_bash/.env"
write_391_env_fixture "$legacy_duplicate_bash/.env"
write_391_env_fixture "$current_missing_bash/.env"
printf 'OSCAR_BACKUP_KEY_FILE=/source/keys/backup-key.txt\n' >>"$legacy_custom_bash/.env"
printf 'OSCAR_BACKUP_KEY_FILE=./secrets/backup-key.txt\nOSCAR_BACKUP_KEY_FILE=./secrets/backup-key.txt\n' >>"$legacy_duplicate_bash/.env"
sed -i.bak 's/^OSCAR_VERSION=3\.9\.1$/OSCAR_VERSION=3.11.0/' "$current_missing_bash/.env"
rm -f "$current_missing_bash/.env.bak"

bash -c '
    setup_script=$1; fixture=$2
    set -- help
    source "$setup_script" >/dev/null
    script_dir=$fixture
    normalize_backup_mode_for_upgrade
    normalize_legacy_backup_key_binding
    require_canonical_credential_bindings
' _ "$setup_shell_script" "$legacy_binding_bash" >/dev/null
[[ $(grep -Fxc 'OSCAR_BACKUP_KEY_FILE=./secrets/backup-key.txt' "$legacy_binding_bash/.env") == 1 ]] || {
    printf 'Bash upgrade did not add exactly one canonical backup-key binding to a 3.9.1 environment.\n' >&2
    exit 1
}

for unsafe_fixture in "$legacy_custom_bash" "$legacy_duplicate_bash" "$current_missing_bash"; do
    if bash -c '
        setup_script=$1; fixture=$2
        set -- help
        source "$setup_script" >/dev/null
        script_dir=$fixture
        normalize_backup_mode_for_upgrade
        normalize_legacy_backup_key_binding
        require_canonical_credential_bindings
    ' _ "$setup_shell_script" "$unsafe_fixture" >/dev/null 2>&1; then
        printf 'Bash upgrade accepted an unsafe or non-legacy backup-key binding fixture: %s\n' "$unsafe_fixture" >&2
        exit 1
    fi
done
[[ $(grep -Fxc 'OSCAR_BACKUP_KEY_FILE=/source/keys/backup-key.txt' "$legacy_custom_bash/.env") == 1 &&
   $(grep -Fc 'OSCAR_BACKUP_KEY_FILE=' "$legacy_duplicate_bash/.env") == 2 &&
   $(grep -Fc 'OSCAR_BACKUP_KEY_FILE=' "$current_missing_bash/.env" || true) == 0 ]] || {
    printf 'Bash legacy normalization overwrote, collapsed, or inserted a forbidden backup-key binding.\n' >&2
    exit 1
}

# Exercise the actual normalization order for a real 3.9.1 environment: the
# preliminary validator accepts absent new-schema keys, explicit adoption adds
# the deployment identity, storage initialization adds all three roots, and the
# strict validator then accepts the resulting 3.11.0 schema.
legacy_upgrade_path_bash="$test_root/legacy-upgrade-path-bash"
mkdir -p "$legacy_upgrade_path_bash"
write_391_env_fixture "$legacy_upgrade_path_bash/.env"
bash -c '
    setup_script=$1; fixture=$2
    set -- help
    source "$setup_script" >/dev/null
    script_dir=$fixture
    docker() {
        if [[ $1 == volume && $2 == inspect && ${3:-} == --format ]]; then
            case $4 in
                *CreatedAt*) [[ $5 == oscar_oscar_state ]] && printf "2026-01-01T00:00:00Z" || printf "2026-01-02T00:00:00Z" ;;
                *) printf "<no value>" ;;
            esac
            return 0
        fi
        [[ $1 == volume && $2 == inspect ]]
    }
    require_upgrade_environment_keys
    normalize_backup_mode_for_upgrade
    normalize_legacy_backup_key_binding
    require_canonical_credential_bindings
    assert_deployment_volume_ownership true
    configure_storage_paths
    require_unique_literal_environment_keys
    set_env_value OSCAR_VERSION 3.11.0
    require_managed_environment_bindings
' _ "$setup_shell_script" "$legacy_upgrade_path_bash" >/dev/null
for binding in OSCAR_VERSION OSCAR_DEPLOYMENT_ID OSCAR_ARCHIVE_DIR OSCAR_BACKUP_MODE OSCAR_BACKUP_DIR; do
    [[ $(grep -c "^${binding}=" "$legacy_upgrade_path_bash/.env") == 1 ]] || {
        printf 'Bash legacy upgrade did not normalize exactly one %s binding.\n' "$binding" >&2
        exit 1
    }
done

legacy_duplicate_root_bash="$test_root/legacy-duplicate-root-bash"
mkdir -p "$legacy_duplicate_root_bash"
write_391_env_fixture "$legacy_duplicate_root_bash/.env"
printf 'OSCAR_ARCHIVE_DIR=/one\nOSCAR_ARCHIVE_DIR=/two\n' >>"$legacy_duplicate_root_bash/.env"
if bash -c '
    setup_script=$1; fixture=$2
    set -- help
    source "$setup_script" >/dev/null
    script_dir=$fixture
    require_upgrade_environment_keys
' _ "$setup_shell_script" "$legacy_duplicate_root_bash" >/dev/null 2>&1; then
    printf 'Bash preliminary upgrade validation accepted duplicate optional storage bindings.\n' >&2
    exit 1
fi

# `init --skip-start` must leave exact deployment-labelled named volumes so a
# later start can pass the same ownership gate without special-case weakening.
skip_start_bash="$test_root/skip-start-bash"
mkdir -p "$skip_start_bash/mock-volumes"
skip_start_deployment=12345678-1234-4234-8234-123456789abc
printf 'OSCAR_DEPLOYMENT_ID=%s\n' "$skip_start_deployment" >"$skip_start_bash/.env"
printf 'format=oscar-init-state\nversion=1\ndeployment_id=%s\nstate=INITIALIZING\n' "$skip_start_deployment" >"$skip_start_bash/.oscar-init-state"
bash -c '
    setup_script=$1; fixture=$2; deployment=$3
    set -- help
    source "$setup_script" >/dev/null
    script_dir=$fixture
    docker() {
        if [[ $1 == volume && $2 == inspect && ${3:-} == --format ]]; then
            [[ -f $fixture/mock-volumes/$5 ]] || return 1
            printf "%s" "$deployment"
            return 0
        fi
        if [[ $1 == volume && $2 == inspect ]]; then
            [[ -f $fixture/mock-volumes/$3 ]]
            return
        fi
        if [[ $1 == volume && $2 == create && $3 == --label && $4 == "com.botts.oscar.deployment-id=$deployment" ]]; then
            : >"$fixture/mock-volumes/$5"
            printf "%s\n" "$5"
            return 0
        fi
        return 1
    }
    ensure_fresh_init_volumes
    assert_deployment_volume_ownership false
    ensure_fresh_init_volumes
    [[ -f $fixture/mock-volumes/oscar_oscar_state && -f $fixture/mock-volumes/oscar_postgres_data ]]
' _ "$setup_shell_script" "$skip_start_bash" "$skip_start_deployment" >/dev/null

mkdir -p "$test_root/version-invalid-bash"
cp "$shell_script" "$test_root/version-invalid-bash/oscar-storage.sh"
printf 'OSCAR_VERSION=not-a-version\n' >"$test_root/version-invalid-bash/.env.example"
if bash "$test_root/version-invalid-bash/oscar-storage.sh" help >/dev/null 2>&1; then
    printf 'Bash storage CLI accepted a malformed packaged release version.\n' >&2
    exit 1
fi

# A visible tag and release label are insufficient after a same-tag rebuild.
# The authenticated backup inventory must bind restore to the exact image ID.
inventory_fixture="$test_root/image-inventory-retag"
inventory_version=$(awk -F= '$1 == "OSCAR_VERSION" { print substr($0, index($0, "=") + 1); exit }' "$repo_root/dist/release/.env.example")
mkdir -p "$inventory_fixture"
cat >"$inventory_fixture/image-inventory.txt" <<EOF
format=oscar-image-inventory
version=1
application_name=oscar:$inventory_version
application_id=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
application_repo_digests=null
application_version_label=$inventory_version
postgres_name=oscar-postgis:$inventory_version
postgres_id=sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
postgres_repo_digests=null
postgres_version_label=$inventory_version
postgres_storage_profile_label=$inventory_version
gateway_name=nginxinc/nginx-unprivileged:1.28.1-alpine
gateway_id=sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
gateway_repo_digests=null
created_at=2026-10-17T12:00:00Z
EOF
if bash -c '
    storage_script=$1; fixture=$2; version=$3
    set -- help
    source "$storage_script" >/dev/null
    resolve_release_images() { printf "%s\n%s\n%s\n" "oscar:$version" "oscar-postgis:$version" "nginxinc/nginx-unprivileged:1.28.1-alpine"; }
    image_inspect_value() {
        case "$1|$2" in
            "oscar:$version|{{.Id}}") printf "sha256:%064d" 0 | tr 0 b ;;
            "oscar-postgis:$version|{{.Id}}") printf "sha256:%064d" 0 | tr 0 c ;;
            "nginxinc/nginx-unprivileged:1.28.1-alpine|{{.Id}}") printf "sha256:%064d" 0 | tr 0 d ;;
            *"|{{json .RepoDigests}}") printf null ;;
            *"org.opencontainers.image.version"*) printf "%s" "$version" ;;
            *"com.botts.oscar.storage-profile"*) printf "%s" "$version" ;;
            *) return 1 ;;
        esac
    }
    validate_image_inventory "$fixture" false
    validate_image_inventory "$fixture" true
' _ "$shell_script" "$inventory_fixture" "$inventory_version" >/dev/null 2>&1; then
    printf 'Bash restore accepted a same-name image whose immutable ID changed.\n' >&2
    exit 1
fi

# docker save/load preserves the content-addressed image ID and labels but may
# discard registry RepoDigests. Provenance drift must warn, not make an exact
# offline backup unrestorable.
portable_inventory_fixture="$test_root/image-inventory-portable"
mkdir -p "$portable_inventory_fixture"
cat >"$portable_inventory_fixture/image-inventory.txt" <<EOF
format=oscar-image-inventory
version=1
application_name=oscar:$inventory_version
application_id=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
application_repo_digests=["oscar@sha256:1111111111111111111111111111111111111111111111111111111111111111"]
application_version_label=$inventory_version
postgres_name=oscar-postgis:$inventory_version
postgres_id=sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
postgres_repo_digests=["oscar-postgis@sha256:2222222222222222222222222222222222222222222222222222222222222222"]
postgres_version_label=$inventory_version
postgres_storage_profile_label=$inventory_version
gateway_name=nginxinc/nginx-unprivileged:1.28.1-alpine
gateway_id=sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
gateway_repo_digests=["nginxinc/nginx-unprivileged@sha256:3333333333333333333333333333333333333333333333333333333333333333"]
created_at=2026-10-17T12:00:00Z
EOF
bash -c '
    storage_script=$1; fixture=$2; version=$3
    set -- help
    source "$storage_script" >/dev/null
    resolve_release_images() { printf "%s\n%s\n%s\n" "oscar:$version" "oscar-postgis:$version" "nginxinc/nginx-unprivileged:1.28.1-alpine"; }
    image_inspect_value() {
        case "$1|$2" in
            "oscar:$version|{{.Id}}") printf "sha256:%064d" 0 | tr 0 a ;;
            "oscar-postgis:$version|{{.Id}}") printf "sha256:%064d" 0 | tr 0 c ;;
            "nginxinc/nginx-unprivileged:1.28.1-alpine|{{.Id}}") printf "sha256:%064d" 0 | tr 0 d ;;
            *"|{{json .RepoDigests}}") printf null ;;
            *"org.opencontainers.image.version"*) printf "%s" "$version" ;;
            *"com.botts.oscar.storage-profile"*) printf "%s" "$version" ;;
            *) return 1 ;;
        esac
    }
    validate_image_inventory "$fixture" true
' _ "$shell_script" "$portable_inventory_fixture" "$inventory_version" >/dev/null

deployment_id=12345678-1234-4234-8234-123456789abc
volume_fixture="$test_root/volume-ownership-bash"
mkdir -p "$volume_fixture"
printf 'OSCAR_DEPLOYMENT_ID=%s\n' "$deployment_id" >"$volume_fixture/.env"

# Matching labels are accepted.
bash -c '
    setup_script=$1; fixture=$2; deployment=$3
    set -- help
    source "$setup_script" >/dev/null
    script_dir=$fixture
    docker() {
        if [[ $1 == volume && $2 == inspect && ${3:-} == --format ]]; then
            case $4 in
                *CreatedAt*) printf "2026-01-01T00:00:00Z" ;;
                *) printf "%s" "$deployment" ;;
            esac
            return 0
        fi
        [[ $1 == volume && $2 == inspect ]]
    }
    assert_deployment_volume_ownership false
' _ "$setup_shell_script" "$volume_fixture" "$deployment_id"

# Missing, mixed, and unacknowledged legacy volumes must all fail closed.
for volume_case in missing mixed legacy; do
    if bash -c '
        setup_script=$1; fixture=$2; deployment=$3; scenario=$4
        set -- help
        source "$setup_script" >/dev/null
        script_dir=$fixture
        docker() {
            if [[ $1 == volume && $2 == inspect && ${3:-} != --format ]]; then
                [[ $scenario != missing || $3 != oscar_postgres_data ]]
                return
            fi
            if [[ $1 == volume && $2 == inspect && ${3:-} == --format ]]; then
                volume=$5
                case $4 in
                    *CreatedAt*) printf "2026-01-01T00:00:00Z" ;;
                    *)
                        case $scenario:$volume in
                            mixed:oscar_postgres_data) printf "87654321-4321-4321-8321-cba987654321" ;;
                            mixed:*) printf "%s" "$deployment" ;;
                            legacy:*) printf "<no value>" ;;
                        esac
                        ;;
                esac
                return 0
            fi
            return 1
        }
        assert_deployment_volume_ownership false
    ' _ "$setup_shell_script" "$volume_fixture" "$deployment_id" "$volume_case" >/dev/null 2>&1; then
        printf 'Bash volume ownership accepted unsafe %s state.\n' "$volume_case" >&2
        exit 1
    fi
done

# Explicit legacy adoption records both immutable creation identities; the
# receipt works on later runs and fails if either volume identity changes.
rm -f "$volume_fixture/.oscar-volume-adoption"
bash -c '
    setup_script=$1; fixture=$2
    set -- help
    source "$setup_script" >/dev/null
    script_dir=$fixture
    mock_state_created=2026-01-01T00:00:00Z
    mock_postgres_created=2026-01-02T00:00:00Z
    docker() {
        if [[ $1 == volume && $2 == inspect && ${3:-} != --format ]]; then return 0; fi
        if [[ $1 == volume && $2 == inspect && ${3:-} == --format ]]; then
            case $4 in
                *CreatedAt*) [[ $5 == oscar_oscar_state ]] && printf "%s" "$mock_state_created" || printf "%s" "$mock_postgres_created" ;;
                *) printf "<no value>" ;;
            esac
            return 0
        fi
        return 1
    }
    assert_deployment_volume_ownership true
    [[ -f $fixture/.oscar-volume-adoption && ! -L $fixture/.oscar-volume-adoption ]]
    assert_deployment_volume_ownership false
    mock_postgres_created=2026-01-03T00:00:00Z
    if validate_volume_adoption_receipt "$(get_env_value OSCAR_DEPLOYMENT_ID)"; then
        exit 42
    fi
' _ "$setup_shell_script" "$volume_fixture"
[[ -f $volume_fixture/.oscar-volume-adoption ]] || {
    printf 'Bash legacy-volume adoption did not create its audit receipt.\n' >&2
    exit 1
}

# Storage administration is intentionally destructive. Prove that its path
# guard rejects a filesystem root, nested managed roots, and symlinked path
# components before an archive, purge, backup, or restore can be dispatched.
if bash -c '
    storage_script=$1
    set -- help
    source "$storage_script" >/dev/null
    validate_storage_path_shape OSCAR_ARCHIVE_DIR /
' _ "$shell_script" >/dev/null 2>&1; then
    printf 'Bash accepted the filesystem root as managed storage.\n' >&2
    exit 1
fi

mkdir -p "$test_root/storage-roots/archive/backups" "$test_root/storage-roots/wal"
if bash -c '
    storage_script=$1; fixture=$2
    set -- help
    source "$storage_script" >/dev/null
    archive_dir=$fixture/archive
    backup_dir=$fixture/archive/backups
    wal_archive_dir=$fixture/wal
    validate_storage_directories
' _ "$shell_script" "$test_root/storage-roots" >/dev/null 2>&1; then
    printf 'Bash accepted overlapping managed storage roots.\n' >&2
    exit 1
fi

mkdir -p "$test_root/storage-real/archive" "$test_root/storage-real/backups" "$test_root/storage-real/wal"
ln -s "$test_root/storage-real" "$test_root/storage-link"
if bash -c '
    storage_script=$1; fixture=$2
    set -- help
    source "$storage_script" >/dev/null
    archive_dir=$fixture/archive
    backup_dir=$fixture/backups
    wal_archive_dir=$fixture/wal
    validate_storage_directories
' _ "$shell_script" "$test_root/storage-link" >/dev/null 2>&1; then
    printf 'Bash accepted a symlink component in managed storage roots.\n' >&2
    exit 1
fi

# Root identities are deployment- and kind-bound, durably created without
# replacing an existing name, and explicit adoption is required for nonempty
# legacy storage. Numeric service groups are mocked because this suite is also
# run by an unprivileged macOS release builder.
identity_fixture="$test_root/root-identity-bash"
identity_release="$identity_fixture/release"
identity_roots="$identity_fixture/roots"
mkdir -p "$identity_release" "$identity_roots/archive" "$identity_roots/backups" "$identity_roots/wal"
printf 'legacy archive payload\n' >"$identity_roots/archive/existing.parquet"
printf 'OSCAR_DEPLOYMENT_ID=%s\nOSCAR_BACKUP_MODE=single\n' "$deployment_id" >"$identity_release/.env"
bash -c '
    storage_script=$1; release_root=$2; roots=$3
    set -- help
    source "$storage_script" >/dev/null
    script_dir=$release_root
    archive_dir=$roots/archive
    backup_dir=$roots/backups
    wal_archive_dir=$roots/wal
    require_admin() { :; }
    chown() { :; }
    file_group_id() {
        case $1 in
            "$archive_dir") printf 10001 ;;
            "$backup_dir") printf 0 ;;
            "$wal_archive_dir") printf 999 ;;
            *) command stat -f %g "$1" ;;
        esac
    }
    prepare_storage_directories --adopt-existing
' _ "$shell_script" "$identity_release" "$identity_roots" >/dev/null

[[ $(wc -l <"$identity_roots/archive/.oscar-storage-root" | tr -d '[:space:]') == 8 &&
   $(grep -Fxc 'format=oscar-storage-root-identity' "$identity_roots/archive/.oscar-storage-root") == 1 &&
   $(grep -Fxc 'version=1' "$identity_roots/archive/.oscar-storage-root") == 1 &&
   $(grep -Fxc "deployment_id=$deployment_id" "$identity_roots/archive/.oscar-storage-root") == 1 &&
   $(grep -Fxc 'root_kind=archive' "$identity_roots/archive/.oscar-storage-root") == 1 &&
   $(grep -Fxc 'adoption=explicit-existing' "$identity_roots/archive/.oscar-storage-root") == 1 &&
   $(grep -Fxc 'adoption=new' "$identity_roots/backups/.oscar-storage-root") == 1 ]] || {
    printf 'Bash storage-root identities do not contain the exact version-1/adoption schema.\n' >&2
    exit 1
}
archive_root_mode=$(portable_mode "$identity_roots/archive")
backup_root_mode=$(portable_mode "$identity_roots/backups")
[[ $archive_root_mode == 1770 && $backup_root_mode == 700 &&
   ! -e $identity_roots/wal/.oscar-storage-root ]] || {
    printf 'Bash active storage roots do not have sticky service-writer/private backup modes, or setup claimed retired WAL storage.\n' >&2
    exit 1
}

cp "$identity_roots/archive/.oscar-storage-root" "$identity_fixture/valid-marker"
sed 's/^root_kind=archive$/root_kind=backup/' "$identity_fixture/valid-marker" >"$identity_roots/archive/.oscar-storage-root"
if bash -c '
    storage_script=$1; release_root=$2; archive_root=$3
    set -- help; source "$storage_script" >/dev/null
    script_dir=$release_root
    file_group_id() { printf 10001; }
    assert_storage_root_identity "$archive_root" archive
' _ "$shell_script" "$identity_release" "$identity_roots/archive" >/dev/null 2>&1; then
    printf 'Bash accepted a storage root carrying the wrong root kind.\n' >&2
    exit 1
fi
cp "$identity_fixture/valid-marker" "$identity_roots/archive/.oscar-storage-root"
sed "s/^deployment_id=.*/deployment_id=87654321-4321-4321-8321-cba987654321/" \
    "$identity_fixture/valid-marker" >"$identity_roots/archive/.oscar-storage-root"
if bash -c '
    storage_script=$1; release_root=$2; archive_root=$3
    set -- help; source "$storage_script" >/dev/null
    script_dir=$release_root
    file_group_id() { printf 10001; }
    assert_storage_root_identity "$archive_root" archive
' _ "$shell_script" "$identity_release" "$identity_roots/archive" >/dev/null 2>&1; then
    printf 'Bash accepted a foreign-deployment storage root.\n' >&2
    exit 1
fi
rm -f "$identity_roots/archive/.oscar-storage-root"
ln -s "$identity_fixture/valid-marker" "$identity_roots/archive/.oscar-storage-root"
if bash -c '
    storage_script=$1; release_root=$2; archive_root=$3
    set -- help; source "$storage_script" >/dev/null
    script_dir=$release_root
    file_group_id() { printf 10001; }
    assert_storage_root_identity "$archive_root" archive
' _ "$shell_script" "$identity_release" "$identity_roots/archive" >/dev/null 2>&1; then
    printf 'Bash accepted a symlinked storage-root identity marker.\n' >&2
    exit 1
fi

unclaimed_fixture="$test_root/unclaimed-root-bash"
mkdir -p "$unclaimed_fixture/release" "$unclaimed_fixture/roots/archive" \
    "$unclaimed_fixture/roots/backups" "$unclaimed_fixture/roots/wal"
printf 'OSCAR_DEPLOYMENT_ID=%s\n' "$deployment_id" >"$unclaimed_fixture/release/.env"
printf 'unclaimed payload\n' >"$unclaimed_fixture/roots/archive/object"
if bash -c '
    storage_script=$1; release_root=$2; roots=$3; mutation_log=$4
    set -- help; source "$storage_script" >/dev/null
    script_dir=$release_root
    archive_dir=$roots/archive; backup_dir=$roots/backups; wal_archive_dir=$roots/wal
    require_admin() { :; }
    chown() { printf "%s\n" "$*" >>"$mutation_log"; }
    prepare_storage_directories
' _ "$shell_script" "$unclaimed_fixture/release" "$unclaimed_fixture/roots" \
    "$unclaimed_fixture/mutations" >/dev/null 2>&1; then
    printf 'Bash implicitly adopted a nonempty unclaimed storage root.\n' >&2
    exit 1
fi
[[ ! -e $unclaimed_fixture/mutations ]] || {
    printf 'Bash changed root ownership before rejecting unclaimed storage.\n' >&2
    exit 1
}

repair_fixture="$test_root/interrupted-backup-root-bash"
mkdir -p "$repair_fixture/release" "$repair_fixture/backups"
printf 'OSCAR_DEPLOYMENT_ID=%s\n' "$deployment_id" >"$repair_fixture/release/.env"
cp "$identity_roots/backups/.oscar-storage-root" "$repair_fixture/backups/.oscar-storage-root"
chmod 0710 "$repair_fixture/backups"
bash -c '
    storage_script=$1; release_root=$2; backup_root=$3
    set -- help; source "$storage_script" >/dev/null
    script_dir=$release_root
    mock_group=999
    file_group_id() { printf "%s" "$mock_group"; }
    chown() { mock_group=0; }
    fsync_path() { :; }
    assert_storage_root_identity "$backup_root" backup
    [[ $mock_group == 0 && $(file_mode "$backup_root") == 700 ]]
' _ "$shell_script" "$repair_fixture/release" "$repair_fixture/backups" || {
    printf 'Bash did not normalize the exact interrupted-backup root permission state.\n' >&2
    exit 1
}

# Restored credentials are a replacement set, not an overlay. Exercise the
# helper directly so stale keys and certificates cannot survive a restore.
# The source fixture deliberately represents another host: host-local identity,
# endpoint, platform, and paths must remain target values, while portable
# source configuration still travels.
credential_live="$test_root/credential-install-bash"
credential_restore="$credential_live/restore"
mkdir -p "$credential_live/secrets" "$credential_live/tls" \
    "$credential_restore/secrets" "$credential_restore/tls"
target_deployment_id=12345678-1234-4234-8234-123456789abc
source_deployment_id=87654321-4321-4321-8321-cba987654321
cat >"$credential_live/.env" <<EOF
OSCAR_VERSION=$inventory_version
OSCAR_DEPLOYMENT_ID=$target_deployment_id
OSCAR_POSTGIS_PLATFORM=linux/arm64
OSCAR_HTTPS_PORT=9443
OSCAR_HOSTNAME=restore-target.example
OSCAR_SECRETS_DIR=./secrets
OSCAR_TLS_DIR=./tls
OSCAR_ARCHIVE_DIR=$test_root/target-storage/archive
OSCAR_BACKUP_MODE=single
OSCAR_WAL_ARCHIVE_DIR=$test_root/target-storage/wal
OSCAR_BACKUP_DIR=$test_root/target-storage/backups
OSCAR_BACKUP_KEY_FILE=./secrets/backup-key.txt
OSCAR_BACKUP_RETENTION_COUNT=7
EOF
printf 'stale\n' >"$credential_live/secrets/stale.key"
printf 'stale\n' >"$credential_live/tls/stale.crt"
cat >"$credential_restore/.env" <<EOF
OSCAR_VERSION=$inventory_version
OSCAR_DEPLOYMENT_ID=$source_deployment_id
OSCAR_POSTGIS_PLATFORM=linux/amd64
OSCAR_HTTPS_PORT=443
OSCAR_HOSTNAME=backup-source.example
OSCAR_SECRETS_DIR=/source/release-secrets
OSCAR_TLS_DIR=/source/release-tls
OSCAR_ARCHIVE_DIR=/source/storage/archive
OSCAR_BACKUP_MODE=disabled
OSCAR_WAL_ARCHIVE_DIR=/source/storage/wal
OSCAR_BACKUP_DIR=/source/storage/backups
OSCAR_BACKUP_KEY_FILE=/source/keys/backup-key.txt
OSCAR_BACKUP_RETENTION_COUNT=99
EOF
printf 'new\n' >"$credential_restore/secrets/current.key"
printf 'new\n' >"$credential_restore/tls/current.crt"
bash -c '
    storage_script=$1; source_dir=$2; destination=$3; deployment=$4
    set -- help
    source "$storage_script" >/dev/null
    prepare_restored_credentials_exact "$source_dir" "$destination"
    install_prepared_credentials_exact "$source_dir" "$destination"
    script_dir=$destination
    docker() {
        if [[ $1 == volume && $2 == inspect && ${3:-} == --format ]]; then
            printf "%s" "$deployment"
            return 0
        fi
        [[ $1 == volume && $2 == inspect ]]
    }
    assert_deployment_volume_ownership
' _ "$shell_script" "$credential_restore" "$credential_live" "$target_deployment_id"
for expected_binding in \
    "OSCAR_DEPLOYMENT_ID=$target_deployment_id" \
    'OSCAR_POSTGIS_PLATFORM=linux/arm64' \
    'OSCAR_HTTPS_PORT=9443' \
    'OSCAR_HOSTNAME=restore-target.example' \
    'OSCAR_SECRETS_DIR=./secrets' \
    'OSCAR_TLS_DIR=./tls' \
    "OSCAR_ARCHIVE_DIR=$test_root/target-storage/archive" \
    'OSCAR_BACKUP_MODE=single' \
    "OSCAR_WAL_ARCHIVE_DIR=$test_root/target-storage/wal" \
    "OSCAR_BACKUP_DIR=$test_root/target-storage/backups" \
    'OSCAR_BACKUP_KEY_FILE=./secrets/backup-key.txt'; do
    grep -Fxq "$expected_binding" "$credential_live/.env" || {
        printf 'Bash cross-host restore did not preserve target binding: %s\n' "$expected_binding" >&2
        exit 1
    }
done
[[ $(grep -Fxc 'OSCAR_BACKUP_RETENTION_COUNT=99' "$credential_live/.env") == 1 &&
   -f $credential_live/secrets/current.key && ! -e $credential_live/secrets/stale.key &&
   -f $credential_live/tls/current.crt && ! -e $credential_live/tls/stale.crt ]] || {
    printf 'Bash restore did not merge portable configuration or replace credential and TLS trees exactly.\n' >&2
    exit 1
}

credential_unsafe_target="$test_root/credential-unsafe-target-bash"
credential_unsafe_source="$credential_unsafe_target/restore"
mkdir -p "$credential_unsafe_target/secrets" "$credential_unsafe_target/tls" \
    "$credential_unsafe_source/secrets" "$credential_unsafe_source/tls"
grep -v '^OSCAR_BACKUP_DIR=' "$credential_live/.env" >"$credential_unsafe_target/.env"
cp "$credential_live/.env" "$credential_unsafe_source/.env"
printf 'must survive\n' >"$credential_unsafe_target/secrets/live-sentinel.key"
printf 'replacement\n' >"$credential_unsafe_source/secrets/source.key"
printf 'replacement\n' >"$credential_unsafe_source/tls/source.crt"
if bash -c '
    storage_script=$1; source_dir=$2; destination=$3
    set -- help
    source "$storage_script" >/dev/null
    prepare_restored_credentials_exact "$source_dir" "$destination"
    install_prepared_credentials_exact "$source_dir" "$destination"
' _ "$shell_script" "$credential_unsafe_source" "$credential_unsafe_target" >/dev/null 2>&1; then
    printf 'Bash restore accepted a target missing a host-local binding.\n' >&2
    exit 1
fi
[[ -f $credential_unsafe_target/secrets/live-sentinel.key ]] || {
    printf 'Bash restore changed live credentials before rejecting an unsafe target environment.\n' >&2
    exit 1
}

# The complete restore entry point must decrypt, merge, and validate before it
# can stop services or dispatch any destructive Compose run.
preflight_backup_id=20261017T130000Z-deadbeef
preflight_root="$credential_live/preflight-backups/$preflight_backup_id"
preflight_payload="$test_root/invalid-restored-credentials-bash"
preflight_compose_marker="$test_root/preflight-compose-bash"
mkdir -p "$preflight_root" "$preflight_payload/secrets"
cp "$credential_live/.env" "$preflight_payload/.env"
printf 'incomplete\n' >"$preflight_payload/secrets/source.key"
if bash -c '
    storage_script=$1; destination=$2; backups=$3; backup_id=$4; payload=$5; marker=$6
    set -- help
    source "$storage_script" >/dev/null
    script_dir=$destination
    backup_dir=$backups
    backup_key_file=$destination/secrets/backup-key.txt
    require_admin() { :; }
    require_configured() { :; }
    require_backup_key() { :; }
    assert_deployment_volume_ownership() { :; }
    require_restore_compatibility() { :; }
    verify_backup() { :; }
    compose() { : >"$marker"; }
    docker() {
        local argument restore_path
        for argument in "$@"; do
            case $argument in
                *:/restore)
                    restore_path=${argument%:/restore}
                    cp "$payload/.env" "$restore_path/.env"
                    cp -R "$payload/secrets" "$restore_path/secrets"
                    return 0
                    ;;
            esac
        done
        return 1
    }
    restore_backup --backup "$backup_id" --confirm "$backup_id"
' _ "$shell_script" "$credential_live" "${preflight_root%/$preflight_backup_id}" \
    "$preflight_backup_id" "$preflight_payload" "$preflight_compose_marker" >/dev/null 2>&1; then
    printf 'Bash restore accepted an incomplete staged credential set.\n' >&2
    exit 1
fi
[[ ! -e $preflight_compose_marker && ! -e $credential_live/pre-restore-$preflight_backup_id ]] || {
    printf 'Bash restore reached a destructive operation before credential preflight completed.\n' >&2
    exit 1
}

# New backups and restores are self-contained in postgres/pg_wal. Legacy WAL
# helpers remain packaged solely so authenticated schema-v1 media can still be
# inspected/restored; the schema-v2 create/restore paths never stage or merge a
# cumulative WAL tar and PostgreSQL never receives the legacy host root.
shell_create_body=$(awk '/^create_backup\(\)/,/^verify_backup\(\)/' "$shell_script")
shell_verify_body=$(awk '/^verify_backup\(\)/,/^require_restore_compatibility\(\)/' "$shell_script")
shell_restore_body=$(awk '/^restore_backup\(\)/,/^archive_status\(\)/' "$shell_script")
[[ $(grep -Fc '"version": 2' <<<"$shell_create_body") == 1 &&
   $(grep -Fc -- '--wal-method=stream' <<<"$shell_create_body") -ge 1 &&
   $(grep -Fc 'wal-archive.tar.gz' <<<"$shell_create_body") == 0 &&
   $(grep -Fc 'wal_archive_dir' <<<"$shell_create_body") == 0 &&
   $(grep -Fc 'epoch_schema_version == 1 && wal_entries == 1' <<<"$shell_verify_body") == 1 &&
   $(grep -Fc 'epoch_schema_version == 2 && wal_entries == 0' <<<"$shell_verify_body") == 1 &&
   $(grep -Fc 'wal-archive.tar.gz' <<<"$shell_restore_body") == 0 &&
   $(grep -Fc 'oscar-merge-wal-restore' <<<"$shell_restore_body") == 0 ]] || {
    printf 'Bash schema-v2 create/restore flow still depends on cumulative external WAL.\n' >&2
    exit 1
}

ps_restore_body=$(awk '/^function Restore-Backup\(/,/^function Show-ArchiveStatus/' "$powershell_script")
[[ $(grep -Fc 'tar --no-same-owner --no-overwrite-dir --strip-components=1 -C /state -xzf /restore-state.tar.gz' <<<"$shell_restore_body") == 1 &&
   $(grep -Fc 'tar --no-same-owner --no-overwrite-dir --strip-components=1 -C /archive -xzf /restore-archive.tar.gz' <<<"$shell_restore_body") == 1 &&
   $(grep -Fc 'tar --no-same-owner --no-overwrite-dir --strip-components=1 -C /state -xzf /restore-state.tar.gz' <<<"$ps_restore_body") == 1 &&
   $(grep -Fc 'tar --no-same-owner --no-overwrite-dir --strip-components=1 -C /archive -xzf /restore-archive.tar.gz' <<<"$ps_restore_body") == 1 ]] || {
    printf 'Restore extraction can overwrite metadata on an existing Docker volume or bind-mount root.\n' >&2
    exit 1
}

credential_invalid="$credential_live/invalid"
mkdir -p "$credential_invalid/secrets"
printf 'INVALID=true\n' >"$credential_invalid/.env"
printf 'must survive\n' >"$credential_live/secrets/live-sentinel.key"
if bash -c '
    storage_script=$1; source_dir=$2; destination=$3
    set -- help
    source "$storage_script" >/dev/null
    prepare_restored_credentials_exact "$source_dir" "$destination"
    install_prepared_credentials_exact "$source_dir" "$destination"
' _ "$shell_script" "$credential_invalid" "$credential_live" >/dev/null 2>&1; then
    printf 'Bash restore accepted an incomplete credential replacement set.\n' >&2
    exit 1
fi
[[ -f $credential_live/secrets/live-sentinel.key ]] || {
    printf 'Bash restore changed live credentials before validating the replacement set.\n' >&2
    exit 1
}

mkdir -p "$test_root/tar-good/data" "$test_root/tar-bad-link" "$test_root/tar-bad-fifo"
printf 'safe payload\n' >"$test_root/tar-good/data/value.txt"
tar -czf "$test_root/good.tar.gz" -C "$test_root/tar-good" .
sh "$archive_validator" good "$test_root/good.tar.gz"
missing_validator_scratch="$test_root/missing-validator-scratch"
if scratch_failure=$(TMPDIR="$missing_validator_scratch" sh "$archive_validator" good "$test_root/good.tar.gz" 2>&1); then
    printf 'Archive validator succeeded without a writable scratch directory.\n' >&2
    exit 1
fi
grep -Fq "archive validator cannot create its private scratch directory: $missing_validator_scratch" <<<"$scratch_failure" || {
    printf 'Archive validator scratch failure was not actionable.\n' >&2
    exit 1
}

# Concurrent validators sharing one scratch root must use collision-resistant
# private directories and clean them all. A symlink at the former PID-derived
# name must remain untouched, proving it is no longer a write target.
validator_shared_scratch="$test_root/validator-shared-scratch"
validator_sentinel="$test_root/validator-old-name-sentinel"
mkdir -p "$validator_shared_scratch"
printf 'unchanged\n' >"$validator_sentinel"
# shellcheck source=/dev/null
. "$archive_validator"
old_validator_name="$validator_shared_scratch/oscar-tar-validation-$$.names"
ln -s "$validator_sentinel" "$old_validator_name"
work=caller-work-sentinel
scratch_root=caller-scratch-sentinel
caller_exit_trap=$(trap -p EXIT)
if TMPDIR="$missing_validator_scratch" validate_storage_archive good "$test_root/good.tar.gz" >/dev/null 2>&1; then
    printf 'Sourced archive validator succeeded without scratch.\n' >&2
    exit 1
fi
[[ $work == caller-work-sentinel && $scratch_root == caller-scratch-sentinel &&
   $(trap -p EXIT) == "$caller_exit_trap" ]] || {
    printf 'Sourced archive validator leaked work state or replaced its caller EXIT trap.\n' >&2
    exit 1
}
unset work scratch_root
validator_pids=()
for _ in {1..8}; do
    TMPDIR="$validator_shared_scratch" sh "$archive_validator" good "$test_root/good.tar.gz" &
    validator_pids+=("$!")
done
for validator_pid in "${validator_pids[@]}"; do wait "$validator_pid"; done
TMPDIR="$validator_shared_scratch" validate_storage_archive good "$test_root/good.tar.gz"
[[ $(cat "$validator_sentinel") == unchanged && -L $old_validator_name ]] || {
    printf 'Archive validator followed or replaced the former predictable scratch name.\n' >&2
    exit 1
}
if find "$validator_shared_scratch" -mindepth 1 -maxdepth 1 -type d -name 'oscar-tar-validation.*' -print -quit | grep -q .; then
    printf 'Concurrent archive validators left private scratch directories behind.\n' >&2
    exit 1
fi

ln -s /etc/passwd "$test_root/tar-bad-link/link"
tar -czf "$test_root/link.tar.gz" -C "$test_root/tar-bad-link" .
if sh "$archive_validator" malicious-link "$test_root/link.tar.gz" >/dev/null 2>&1; then
    printf 'Archive validator accepted a symbolic link.\n' >&2
    exit 1
fi
mkfifo "$test_root/tar-bad-fifo/pipe"
tar -czf "$test_root/fifo.tar.gz" -C "$test_root/tar-bad-fifo" . 2>/dev/null
if sh "$archive_validator" malicious-fifo "$test_root/fifo.tar.gz" >/dev/null 2>&1; then
    printf 'Archive validator accepted a FIFO.\n' >&2
    exit 1
fi
if ! tar -czf "$test_root/traversal.tar.gz" -s ',^\./data/value.txt$,../escape,' \
        -C "$test_root/tar-good" ./data/value.txt 2>/dev/null ||
        ! tar -tzf "$test_root/traversal.tar.gz" 2>/dev/null | grep -Fxq '../escape'; then
    command -v python3 >/dev/null 2>&1 || { printf 'Python is required to build the traversal test fixture on this tar implementation.\n' >&2; exit 1; }
    python3 - "$test_root/traversal.tar.gz" <<'PY'
import io
import sys
import tarfile

with tarfile.open(sys.argv[1], "w:gz") as archive:
    member = tarfile.TarInfo("../escape")
    payload = b"unsafe"
    member.size = len(payload)
    archive.addfile(member, io.BytesIO(payload))
PY
fi
if sh "$archive_validator" malicious-traversal "$test_root/traversal.tar.gz" >/dev/null 2>&1; then
    printf 'Archive validator accepted a parent-directory traversal.\n' >&2
    exit 1
fi

# Duplicate and aliased names are rejected for every payload label, and state
# backups can never address the external archive or legacy backup mount paths.
mkdir -p "$test_root/tar-state-good/data" "$test_root/tar-state-reserved/backups"
printf 'state\n' >"$test_root/tar-state-good/data/state.bin"
printf 'recovery media\n' >"$test_root/tar-state-reserved/backups/point.bin"
tar -czf "$test_root/oscar-state-good.tar.gz" -C "$test_root/tar-state-good" .
sh "$archive_validator" oscar-state "$test_root/oscar-state-good.tar.gz"
if command -v python3 >/dev/null 2>&1; then
    python3 - "$test_root/oscar-state-scale.tar.gz" <<'PY'
import io
import sys
import tarfile

with tarfile.open(sys.argv[1], "w:gz", compresslevel=1) as archive:
    for idx in range(5000):
        member = tarfile.TarInfo(
            f"files/videos/retained-media/v1/events/ev{idx:06d}/lanes/dXJuOm9zaDpzeXN0ZW06bGFuZTpsYW5lLTMx/cameras/dXJuOm9zaDpzZW5zb3I6ZmZtcGVnOmxhbmU6bGFuZS0zMTow/frame-01.jpg"
        )
        member.size = 0
        archive.addfile(member, io.BytesIO(b""))
PY
    sh "$archive_validator" oscar-state "$test_root/oscar-state-scale.tar.gz"
fi
tar -czf "$test_root/oscar-state-reserved.tar.gz" -C "$test_root/tar-state-reserved" .
if sh "$archive_validator" oscar-state "$test_root/oscar-state-reserved.tar.gz" >/dev/null 2>&1; then
    printf 'OSCAR-state validator accepted a reserved backups path.\n' >&2
    exit 1
fi
tar -czf "$test_root/oscar-state-duplicate.tar.gz" -C "$test_root/tar-state-good" \
    ./data/state.bin ./data/state.bin
if sh "$archive_validator" oscar-state "$test_root/oscar-state-duplicate.tar.gz" >/dev/null 2>&1; then
    printf 'OSCAR-state validator accepted duplicate members.\n' >&2
    exit 1
fi
python3 - "$test_root/oscar-state-alias.tar.gz" <<'PY'
import io
import sys
import tarfile

with tarfile.open(sys.argv[1], "w:gz") as archive:
    for name in ("./data/value", "data/value"):
        member = tarfile.TarInfo(name)
        payload = b"alias"
        member.size = len(payload)
        archive.addfile(member, io.BytesIO(payload))
PY
if sh "$archive_validator" oscar-state "$test_root/oscar-state-alias.tar.gz" >/dev/null 2>&1; then
    printf 'OSCAR-state validator accepted extraction-path aliases.\n' >&2
    exit 1
fi

mkdir -p "$test_root/tar-cold/datasets/observations/date=2026-10-17/profile=RAW_GATED" "$test_root/tar-wal"
printf 'parquet\n' >"$test_root/tar-cold/datasets/observations/date=2026-10-17/profile=RAW_GATED/generation-11111111-1111-4111-8111-111111111111.parquet"
printf 'wal\n' >"$test_root/tar-wal/000000010000000000000001"
tar -czf "$test_root/cold-good.tar.gz" -C "$test_root/tar-cold" .
tar -czf "$test_root/wal-good.tar.gz" -C "$test_root/tar-wal" .
sh "$archive_validator" cold-archive "$test_root/cold-good.tar.gz"
sh "$archive_validator" wal-archive "$test_root/wal-good.tar.gz"
printf 'unexpected\n' >"$test_root/tar-wal/not-a-wal-segment"
tar -czf "$test_root/wal-bad-name.tar.gz" -C "$test_root/tar-wal" .
if sh "$archive_validator" wal-archive "$test_root/wal-bad-name.tar.gz" >/dev/null 2>&1; then
    printf 'WAL validator accepted a filename outside the PostgreSQL archive grammar.\n' >&2
    exit 1
fi

mkdir -p "$test_root/marker-archive"
printf 'must remain host-local\n' >"$test_root/marker-archive/.oscar-storage-root"
tar -C "$test_root/marker-archive" -czf "$test_root/marker-archive.tar.gz" .
for archive_label in cold-archive wal-archive; do
    if sh "$archive_validator" "$archive_label" "$test_root/marker-archive.tar.gz" >/dev/null 2>&1; then
        printf '%s validator accepted a source storage-root identity marker.\n' "$archive_label" >&2
        exit 1
    fi
done

release_config_files=(
    .dockerignore .env.example DEPLOYMENT.md QUICKSTART.md compose.yaml
    docker/gateway/default.conf docker/oscar/archive-object-helper.sh docker/oscar/atomic-publish.c docker/oscar/Dockerfile docker/oscar/entrypoint.sh
    oscar-setup.ps1 oscar-setup.sh oscar-storage.ps1 oscar-storage.sh oscar.bat oscar.sh
    postgis/Dockerfile postgis/archive-wal.sh postgis/merge-wal-restore.sh postgis/prepare-restore.sh postgis/init-app-role.sh postgis/init-extensions.sql validate-storage-archive.sh
)
tar -C "$repo_root/dist/release" -czf "$test_root/release-config-good.tar.gz" "${release_config_files[@]}"
sh "$archive_validator" release-config "$test_root/release-config-good.tar.gz"

mkdir -p "$test_root/release-config-fixture/postgis/pgdata"
for relative in "${release_config_files[@]}"; do
    parent=${relative%/*}
    [[ $parent == "$relative" ]] && parent=.
    mkdir -p "$test_root/release-config-fixture/$parent"
    cp "$repo_root/dist/release/$relative" "$test_root/release-config-fixture/$relative"
done
printf 'must never be archived\n' >"$test_root/release-config-fixture/postgis/pgdata/SENTINEL"
tar -C "$test_root/release-config-fixture" -czf "$test_root/release-config-pgdata.tar.gz" \
    "${release_config_files[@]}" postgis/pgdata/SENTINEL
if sh "$archive_validator" release-config "$test_root/release-config-pgdata.tar.gz" >/dev/null 2>&1; then
    printf 'Release-config validator accepted a pgdata sentinel.\n' >&2
    exit 1
fi

tar -C "$repo_root/dist/release" -czf "$test_root/release-config-duplicate.tar.gz" \
    "${release_config_files[@]}" compose.yaml
if sh "$archive_validator" release-config "$test_root/release-config-duplicate.tar.gz" >/dev/null 2>&1; then
    printf 'Release-config validator accepted a duplicate member.\n' >&2
    exit 1
fi

# Exercise the actual nonblocking Bash lock implementation. On Linux the sourced
# process holds flock directly; on BSD/macOS lockf holds the helper invocation.
lock_root="$test_root/lock"
mkdir -p "$lock_root"
lock_ready="$lock_root/ready"
lock_helper="$lock_root/helper.sh"
printf 'OSCAR_DEPLOYMENT_ID=%s\n' "$deployment_id" >"$lock_root/.env"
printf '%s\n' '#!/bin/sh' ': >"$STORAGE_LOCK_READY"' 'sleep 3' >"$lock_helper"
chmod 0700 "$lock_helper"
(
    OSCAR_STORAGE_TEST_MODE=1 STORAGE_LOCK_READY="$lock_ready" bash -c '
        storage_script=$1
        lock_directory=$2
        helper_script=$3
        ready_file=$4
        set -- help
        source "$storage_script" >/dev/null
        script_dir=$lock_directory
        script_path=$helper_script
        storage_command=backup
        storage_original_args=(test)
        OSCAR_STORAGE_LOCK_DIR="$lock_directory/stable-locks" acquire_storage_admin_lock
        : >"$ready_file"
        sleep 3
    ' _ "$shell_script" "$lock_root" "$lock_helper" "$lock_ready"
) &
lock_holder=$!
for _ in {1..50}; do [[ -e $lock_ready ]] && break; sleep 0.1; done
[[ -e $lock_ready ]] || { printf 'Bash lock holder did not start.\n' >&2; exit 1; }
if OSCAR_STORAGE_TEST_MODE=1 bash -c '
    storage_script=$1
    lock_directory=$2
    helper_script=$3
    set -- help
    source "$storage_script" >/dev/null
    script_dir=$lock_directory
    script_path=$helper_script
    storage_command=backup
    storage_original_args=(test)
    OSCAR_STORAGE_LOCK_DIR="$lock_directory/stable-locks" acquire_storage_admin_lock
' _ "$shell_script" "$lock_root" "$lock_helper" >/dev/null 2>&1; then
    printf 'Bash storage lock allowed a concurrent command.\n' >&2
    exit 1
fi

# Journal confirmation is a separately HMAC-authenticated post-verification
# audit sidecar. It is excluded from the immutable core manifest; corruption
# warns but cannot invalidate or manufacture authenticated core acceptance.
acceptance_id=20261017T120000Z-1234abcd
release_version=$(awk -F= '$1 == "OSCAR_VERSION" { print substr($0, index($0, "=") + 1); exit }' "$repo_root/dist/release/.env.example")
acceptance_root="$test_root/acceptance/backups/$acceptance_id"
mkdir -p "$acceptance_root"
chmod 0700 "$acceptance_root"
printf 'authenticated OSCAR state fixture\n' >"$acceptance_root/oscar-state.tar.gz"
for recovery_payload in archive.tar.gz deployment-secrets.tar.gz.enc image-inventory.txt release-config.tar.gz wal-archive.tar.gz; do
    printf 'authenticated %s fixture\n' "$recovery_payload" >"$acceptance_root/$recovery_payload"
done
printf '%s\n' \
    11111111-1111-4111-8111-111111111111 \
    22222222-2222-4222-8222-222222222222 >"$acceptance_root/archive-generation-ids.txt"
acceptance_sha=$(if command -v sha256sum >/dev/null 2>&1; then sha256sum "$acceptance_root/oscar-state.tar.gz" | awk '{print $1}'; else shasum --algorithm 256 "$acceptance_root/oscar-state.tar.gz" | awk '{print $1}'; fi)
acceptance_tag=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
printf '%s\n' \
    'format=oscar-journal-backup-confirmation' \
    'version=2' \
    "backup_id=$acceptance_id" \
    "oscar_state_sha256=$acceptance_sha" \
    "hmac_sha256=$acceptance_tag" >"$acceptance_root/JOURNAL_CONFIRMED"
printf '%s\n' \
    '{' \
    '  "format": "oscar-backup-epoch",' \
    '  "version": 1,' \
    '  "backupEpochId": "12345678-1234-4123-8123-123456789abc",' \
    '  "backupId": "20261017T120000Z-1234abcd",' \
    '  "createdAt": "2026-10-17T12:00:00Z",' \
    "  \"oscarVersion\": \"$release_version\"," \
    '  "postgresLsn": "0/12345678",' \
    '  "archiveRoot": "/var/lib/oscar/archive",' \
    '  "secrets": "test fixture",' \
    '  "state": "CREATED"' \
    '}' >"$acceptance_root/epoch.json"
(
    cd "$acceptance_root"
    find . -type f ! -name JOURNAL_CONFIRMED ! -name SHA256SUMS ! -name SHA256SUMS.hmac -print0 | sort -z |
        while IFS= read -r -d '' recovery_file; do
            if command -v sha256sum >/dev/null 2>&1; then sha256sum "$recovery_file"; else shasum --algorithm 256 "$recovery_file"; fi
        done >SHA256SUMS
)
printf 'authenticated-for-test\n' >"$acceptance_root/SHA256SUMS.hmac"
printf 'test key\n' >"$test_root/acceptance/backup-key.txt"
printf 'corrupt receipt\n' >"$acceptance_root/JOURNAL_CONFIRMED"
bash -c '
    storage_script=$1
    fixture_root=$2
    fixture_key=$3
    backup_id=$4
    set -- help
    source "$storage_script" >/dev/null
    backup_dir=$fixture_root
    backup_key_file=$fixture_key
    require_admin() { :; }
    require_configured() { :; }
    require_backup_key() { :; }
    oscar_image() { printf "%s" oscar:test; }
    postgres_image() { printf "%s" postgres:test; }
    require_local_image() { :; }
    verify_checksum_hmac() { :; }
    docker() { :; }
    compose() { :; }
    validate_release_config_archive() { :; }
    validate_backup_archive_members() { :; }
    validate_image_inventory() { :; }
    calculate_journal_confirmation_hmac() { printf "%s" AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=; }
    psql_admin() { :; }
    verify_backup "$backup_id"
' _ "$shell_script" "$test_root/acceptance/backups" "$test_root/acceptance/backup-key.txt" "$acceptance_id" >/dev/null
[[ -f $acceptance_root/VERIFIED && ! -L $acceptance_root/VERIFIED ]] || {
    printf 'Bash audit-sidecar corruption incorrectly blocked authenticated core recovery acceptance.\n' >&2
    exit 1
}
rm -f -- "$acceptance_root/VERIFIED"
printf '%s\n' \
    'format=oscar-journal-backup-confirmation' \
    'version=2' \
    "backup_id=$acceptance_id" \
    "oscar_state_sha256=$acceptance_sha" \
    "hmac_sha256=$acceptance_tag" >"$acceptance_root/JOURNAL_CONFIRMED"
cp "$acceptance_root/JOURNAL_CONFIRMED" "$acceptance_root/JOURNAL_CONFIRMED.valid"
printf 'UNTERMINATED' >>"$acceptance_root/JOURNAL_CONFIRMED"
if bash -c '
    storage_script=$1; root=$2; backup_id=$3; state_sha=$4
    set -- help; source "$storage_script" >/dev/null
    calculate_journal_confirmation_hmac() { printf "%s" AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=; }
    validate_journal_confirmation_receipt "$root" "$backup_id" "$state_sha" oscar:test
' _ "$shell_script" "$acceptance_root" "$acceptance_id" "$acceptance_sha" >/dev/null 2>&1; then
    printf 'Bash journal confirmation accepted an unterminated trailing record.\n' >&2
    exit 1
fi
mv "$acceptance_root/JOURNAL_CONFIRMED.valid" "$acceptance_root/JOURNAL_CONFIRMED"
bash -c '
    storage_script=$1; fixture_root=$2; fixture_key=$3; backup_id=$4
    set -- help; source "$storage_script" >/dev/null
    backup_dir=$fixture_root; backup_key_file=$fixture_key
    require_admin() { :; }; require_configured() { :; }; require_backup_key() { :; }
    oscar_image() { printf "%s" oscar:test; }; postgres_image() { printf "%s" postgres:test; }
    require_local_image() { :; }; verify_checksum_hmac() { :; }; docker() { :; }; compose() { :; }
    validate_release_config_archive() { :; }; validate_backup_archive_members() { :; }; validate_image_inventory() { :; }
    calculate_journal_confirmation_hmac() { printf "%s" AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=; }
    verify_backup "$backup_id"
' _ "$shell_script" "$test_root/acceptance/backups" "$test_root/acceptance/backup-key.txt" "$acceptance_id" >/dev/null
[[ -f $acceptance_root/VERIFIED && ! -L $acceptance_root/VERIFIED ]] || {
    printf 'Bash authenticated core with a valid journal audit sidecar did not produce VERIFIED.\n' >&2
    exit 1
}

# Crash-left acceptance temporaries are authenticated metadata staging, not
# immutable payloads. A safe exact temporary must not make the core verifier
# reject the snapshot, and cleanup may remove it only after verification.
acceptance_temporary="$acceptance_root/.VERIFIED.A1b2C3"
printf 'interrupted VERIFIED publication\n' >"$acceptance_temporary"
chmod 0600 "$acceptance_temporary"
bash -c '
    storage_script=$1; fixture_root=$2; fixture_key=$3; backup_id=$4; temporary=$5
    set -- help; source "$storage_script" >/dev/null
    backup_dir=$fixture_root; backup_key_file=$fixture_key
    require_admin() { :; }; require_configured() { :; }; require_backup_key() { :; }
    oscar_image() { printf "%s" oscar:test; }; postgres_image() { printf "%s" postgres:test; }
    require_local_image() { :; }; verify_checksum_hmac() { :; }; docker() { :; }; compose() { :; }
    validate_release_config_archive() { :; }; validate_backup_archive_members() { :; }; validate_image_inventory() { :; }
    calculate_journal_confirmation_hmac() { printf "%s" AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=; }
    fsync_path() { :; }
    verify_backup "$backup_id" read-only
    [[ -f $temporary ]]
    cleanup_snapshot_sidecar_temps "$fixture_root/$backup_id"
    [[ ! -e $temporary && ! -L $temporary ]]
' _ "$shell_script" "$test_root/acceptance/backups" "$test_root/acceptance/backup-key.txt" \
    "$acceptance_id" "$acceptance_temporary"

unsafe_acceptance_temporary="$acceptance_root/.JOURNAL_CONFIRMED.Z9y8X7"
mkdir "$unsafe_acceptance_temporary"
if bash -c '
    storage_script=$1; root=$2
    set -- help; source "$storage_script" >/dev/null
    validate_backup_manifest_inventory "$root"
' _ "$shell_script" "$acceptance_root" >/dev/null 2>&1; then
    printf 'Bash backup verification ignored an acceptance temporary directory.\n' >&2
    exit 1
fi
rmdir "$unsafe_acceptance_temporary"

# The manifest inventory itself must also observe a failed recursive producer;
# a partial result that happens to equal SHA256SUMS is not a complete scan.
manifest_scan_fixture="$test_root/failed-manifest-enumeration"
mkdir -p "$manifest_scan_fixture"
printf 'payload\n' >"$manifest_scan_fixture/payload"
printf '%s  ./payload\n' "$(sha256_path "$manifest_scan_fixture/payload")" >"$manifest_scan_fixture/SHA256SUMS"
if bash -c '
    storage_script=$1; root=$2
    set -- help; source "$storage_script" >/dev/null
    find() { printf "%s\0" "$root/payload"; return 42; }
    validate_backup_manifest_inventory "$root"
' _ "$shell_script" "$manifest_scan_fixture" >/dev/null 2>&1; then
    printf 'Bash backup manifest verification ignored a failed filesystem enumeration.\n' >&2
    exit 1
fi
# Cleanup authorization is stricter than core verification: a plausible
# VERIFIED marker cannot substitute for the authenticated journal receipt.
bash -c '
    storage_script=$1; fixture_root=$2; backup_id=$3
    set -- help; source "$storage_script" >/dev/null
    backup_dir=$fixture_root
    verify_backup() { :; }
    backup_schema_version() { printf "%s" 2; }
    oscar_image() { printf "%s" oscar:test; }
    validate_journal_confirmation_receipt() {
        grep -Fqx "hmac_sha256=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" "$1/JOURNAL_CONFIRMED"
    }
    accepted_schema_v2_backup_for_cleanup "$backup_id"
    cp "$fixture_root/$backup_id/VERIFIED" "$fixture_root/$backup_id/VERIFIED.valid"
    printf "\n" >>"$fixture_root/$backup_id/VERIFIED"
    if accepted_schema_v2_backup_for_cleanup "$backup_id"; then
        fail "noncanonical VERIFIED bytes authorized cleanup"
    fi
    mv "$fixture_root/$backup_id/VERIFIED.valid" "$fixture_root/$backup_id/VERIFIED"
    printf "%s\n" "forged receipt" >"$fixture_root/$backup_id/JOURNAL_CONFIRMED"
    if accepted_schema_v2_backup_for_cleanup "$backup_id"; then
        fail "forged VERIFIED marker authorized cleanup without a valid receipt"
    fi
' _ "$shell_script" "$test_root/acceptance/backups" "$acceptance_id"
printf '%s\n' \
    'format=oscar-journal-backup-confirmation' \
    'version=2' \
    "backup_id=$acceptance_id" \
    "oscar_state_sha256=$acceptance_sha" \
    "hmac_sha256=$acceptance_tag" >"$acceptance_root/JOURNAL_CONFIRMED"
rm -f -- "$acceptance_root/VERIFIED"
bash -c '
    storage_script=$1; fixture_root=$2; fixture_key=$3; backup_id=$4
    set -- help; source "$storage_script" >/dev/null
    backup_dir=$fixture_root; backup_key_file=$fixture_key
    require_admin() { :; }; require_configured() { :; }; require_backup_key() { :; }
    oscar_image() { printf "%s" oscar:test; }; postgres_image() { printf "%s" postgres:test; }
    require_local_image() { :; }; verify_checksum_hmac() { :; }; docker() { :; }
    validate_release_config_archive() { :; }; validate_backup_archive_members() { :; }; validate_image_inventory() { :; }
    calculate_journal_confirmation_hmac() { printf "%s" AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=; }
    write_verified_marker() { : >"$fixture_root/UNSAFE-VERIFIED"; }
    upsert_verified_backup_epoch() { : >"$fixture_root/UNSAFE-CATALOG"; }
    verify_backup "$backup_id" read-only
' _ "$shell_script" "$test_root/acceptance/backups" "$test_root/acceptance/backup-key.txt" "$acceptance_id" >/dev/null
[[ ! -e $test_root/acceptance/backups/UNSAFE-VERIFIED && ! -e $test_root/acceptance/backups/UNSAFE-CATALOG ]] || {
    printf 'Bash read-only verification mutated acceptance state.\n' >&2
    exit 1
}

# The authenticated generation inventory is canonical, bounded, and independent
# of later live-catalog drift. Its SQL receipt is only count/hash/bytes; UUIDs
# remain in the checksummed file and are never materialized into a SQL literal.
generation_inventory_fixture="$test_root/generation-inventory-bash"
mkdir -p "$generation_inventory_fixture"
cp "$acceptance_root/archive-generation-ids.txt" "$generation_inventory_fixture/archive-generation-ids.txt"
generation_inventory_sha=$(sha256_path "$generation_inventory_fixture/archive-generation-ids.txt")
bash -c '
    storage_script=$1; root=$2; expected_sha=$3
    set -- help; source "$storage_script" >/dev/null
    [[ $(validate_archive_generation_inventory "$root") == "2|$expected_sha|74" ]]
' _ "$shell_script" "$generation_inventory_fixture" "$generation_inventory_sha"
: >"$generation_inventory_fixture/archive-generation-ids.txt"
bash -c '
    storage_script=$1; root=$2
    set -- help; source "$storage_script" >/dev/null
    [[ $(validate_archive_generation_inventory "$root") == "0|e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855|0" ]]
' _ "$shell_script" "$generation_inventory_fixture"
for invalid_inventory in duplicate unsorted uppercase unterminated crlf bom; do
    case $invalid_inventory in
        duplicate)
            printf '%s\n%s\n' 11111111-1111-4111-8111-111111111111 11111111-1111-4111-8111-111111111111 \
                >"$generation_inventory_fixture/archive-generation-ids.txt" ;;
        unsorted)
            printf '%s\n%s\n' 22222222-2222-4222-8222-222222222222 11111111-1111-4111-8111-111111111111 \
                >"$generation_inventory_fixture/archive-generation-ids.txt" ;;
        uppercase)
            printf '%s\n' AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA >"$generation_inventory_fixture/archive-generation-ids.txt" ;;
        unterminated)
            printf '%s' 11111111-1111-4111-8111-111111111111 >"$generation_inventory_fixture/archive-generation-ids.txt" ;;
        crlf)
            printf '%s\r\n' 11111111-1111-4111-8111-111111111111 >"$generation_inventory_fixture/archive-generation-ids.txt" ;;
        bom)
            printf '\357\273\277%s\n' 11111111-1111-4111-8111-111111111111 >"$generation_inventory_fixture/archive-generation-ids.txt" ;;
    esac
    if bash -c '
        storage_script=$1; root=$2
        set -- help; source "$storage_script" >/dev/null
        validate_archive_generation_inventory "$root"
    ' _ "$shell_script" "$generation_inventory_fixture" >/dev/null 2>&1; then
        printf 'Bash accepted a noncanonical %s archive-generation inventory.\n' "$invalid_inventory" >&2
        exit 1
    fi
done

# A nontrivial inventory proves bounded streaming across many read buffers. An
# oversized sparse file proves the advertised 37 MB ceiling is checked before
# any record scan or hash operation.
awk 'BEGIN { for (i=0; i<10000; i++) printf "00000000-0000-4000-8000-%012d\n", i }' \
    >"$generation_inventory_fixture/archive-generation-ids.txt"
large_inventory_sha=$(sha256_path "$generation_inventory_fixture/archive-generation-ids.txt")
bash -c '
    storage_script=$1; root=$2; expected_sha=$3
    set -- help; source "$storage_script" >/dev/null
    [[ $(validate_archive_generation_inventory "$root") == "10000|$expected_sha|370000" ]]
' _ "$shell_script" "$generation_inventory_fixture" "$large_inventory_sha"
dd if=/dev/null of="$generation_inventory_fixture/archive-generation-ids.txt" bs=1 seek=37000001 2>/dev/null
if bash -c '
    storage_script=$1; root=$2
    set -- help; source "$storage_script" >/dev/null
    validate_archive_generation_inventory "$root"
' _ "$shell_script" "$generation_inventory_fixture" >/dev/null 2>&1; then
    printf 'Bash accepted an archive-generation inventory above 37,000,000 bytes.\n' >&2
    exit 1
fi
cp "$acceptance_root/archive-generation-ids.txt" "$generation_inventory_fixture/archive-generation-ids.txt"

# No failure before immutable-core acceptance may reach the live daily-journal
# confirmation bridge. This explicitly injects a full-verifier failure into the
# creation completion phase and requires zero confirmation side effects.
if bash -c '
    storage_script=$1; marker=$2
    set -- help; source "$storage_script" >/dev/null
    verify_backup() { fail "injected immutable-core verification failure"; }
    confirm_daily_journal_backup() { : >"$marker"; }
    write_journal_confirmation_receipt() { : >"$marker.receipt"; }
    accept_and_confirm_created_backup 20261017T120000Z-1234abcd /unused oscar:test aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
' _ "$shell_script" "$test_root/UNSAFE-LIVE-JOURNAL-CONFIRMATION" >/dev/null 2>&1; then
    printf 'Bash backup acceptance ignored an injected core-verification failure.\n' >&2
    exit 1
fi
[[ ! -e $test_root/UNSAFE-LIVE-JOURNAL-CONFIRMATION &&
   ! -e $test_root/UNSAFE-LIVE-JOURNAL-CONFIRMATION.receipt ]] || {
    printf 'Bash backup confirmed live journal retention before core VERIFIED acceptance.\n' >&2
    exit 1
}
bash -c '
    storage_script=$1; root=$2; backup_id=$3; capture=$4
    set -- help; source "$storage_script" >/dev/null
    mock_receipt=12345678-1234-4123-8123-123456789abc\|VERIFIED
    assert_deployment_volume_ownership() { :; }
    psql_admin() { sql=$(cat); printf "%s\n" "$sql" >"$capture"; printf "%s\n" "$mock_receipt"; }
    upsert_verified_backup_epoch "$root" "$backup_id" 12345678-1234-4123-8123-123456789abc 0/12345678
    mock_receipt=
    if (upsert_verified_backup_epoch "$root" "$backup_id" 12345678-1234-4123-8123-123456789abc 0/12345678); then
        printf "foreign epoch collision was accepted\n" >&2; exit 1
    fi
' _ "$shell_script" "$acceptance_root" "$acceptance_id" "$test_root/acceptance/catalog-sql" >/dev/null 2>&1
grep -Fq "oscar_backup_epoch.state IN ('CREATED','VERIFIED')" "$test_root/acceptance/catalog-sql" &&
grep -Fq 'postgres_lsn IS NOT DISTINCT FROM EXCLUDED.postgres_lsn' "$test_root/acceptance/catalog-sql" &&
grep -Fq 'archive_generation_count IS NOT DISTINCT FROM EXCLUDED.archive_generation_count' "$test_root/acceptance/catalog-sql" &&
grep -Fq 'archive_generation_inventory_sha256 IS NOT DISTINCT FROM EXCLUDED.archive_generation_inventory_sha256' "$test_root/acceptance/catalog-sql" &&
grep -Fq 'archive_generation_inventory_bytes IS NOT DISTINCT FROM EXCLUDED.archive_generation_inventory_bytes' "$test_root/acceptance/catalog-sql" &&
grep -Fq ",2,'$generation_inventory_sha',74," "$test_root/acceptance/catalog-sql" &&
! grep -Fq 'archive_generation_ids' "$test_root/acceptance/catalog-sql" &&
! grep -Fq '11111111-1111-4111-8111-111111111111' "$test_root/acceptance/catalog-sql" &&
! grep -Fq 'FROM oscar_archive_generation' "$test_root/acceptance/catalog-sql" &&
grep -Fq 'sha256 IS NOT DISTINCT FROM EXCLUDED.sha256' "$test_root/acceptance/catalog-sql" || {
    printf 'Bash VERIFIED epoch upsert is not bound to the authenticated backup-time generation set.\n' >&2
    exit 1
}

# Offline verification remains valid, but discovery of a running foreign
# fixed-name project must fail before either acceptance marker or catalog write.
rm -f -- "$acceptance_root/VERIFIED" "$test_root/acceptance/UNSAFE-FOREIGN-VERIFIED" \
    "$test_root/acceptance/UNSAFE-FOREIGN-CATALOG" "$test_root/acceptance/FOREIGN-GUARD-RAN"
if bash -c '
    storage_script=$1; fixture_root=$2; fixture_key=$3; backup_id=$4; markers=$5
    set -- help; source "$storage_script" >/dev/null
    backup_dir=$fixture_root; backup_key_file=$fixture_key
    require_admin() { :; }; require_configured() { :; }; require_backup_key() { :; }
    oscar_image() { printf "%s" oscar:test; }; postgres_image() { printf "%s" postgres:test; }
    require_local_image() { :; }; verify_checksum_hmac() { :; }; docker() { :; }
    validate_release_config_archive() { :; }; validate_backup_archive_members() { :; }; validate_image_inventory() { :; }
    calculate_journal_confirmation_hmac() { printf "%s" AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=; }
    compose() { [[ " $* " == *" ps --status running --services "* ]] && printf "postgres\n"; }
    assert_deployment_volume_ownership() { : >"$markers/FOREIGN-GUARD-RAN"; fail "foreign deployment"; }
    write_verified_marker() { : >"$markers/UNSAFE-FOREIGN-VERIFIED"; }
    upsert_verified_backup_epoch() { : >"$markers/UNSAFE-FOREIGN-CATALOG"; }
    verify_backup "$backup_id"
' _ "$shell_script" "$test_root/acceptance/backups" "$test_root/acceptance/backup-key.txt" "$acceptance_id" "$test_root/acceptance" >/dev/null 2>&1; then
    printf 'Bash backup verification accepted a running foreign deployment.\n' >&2
    exit 1
fi
[[ -e $test_root/acceptance/FOREIGN-GUARD-RAN &&
   ! -e $test_root/acceptance/UNSAFE-FOREIGN-VERIFIED &&
   ! -e $test_root/acceptance/UNSAFE-FOREIGN-CATALOG ]] || {
    printf 'Bash foreign-volume guard ran after acceptance/catalog mutation.\n' >&2
    exit 1
}

# A malicious state tar rejected by the scoped validator must never reach the
# extraction container used by the daily-journal bridge.
if bash -c '
    storage_script=$1; fixture_root=$2; backup_id=$3
    set -- help; source "$storage_script" >/dev/null
    backup_dir=$fixture_root; script_dir=$fixture_root
    mkdir -p "$fixture_root/$backup_id"
    : >"$fixture_root/$backup_id/oscar-state.tar.gz"
    chown() { :; }; chmod() { :; }; compose() { :; }
    docker() {
        if [[ " $* " == *" /validate-storage-archive.sh oscar-state "* ]]; then return 42; fi
        : >"$fixture_root/UNSAFE-EXTRACTION"
    }
    confirm_daily_journal_backup "$backup_id" "$fixture_root/$backup_id" oscar:test aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
' _ "$shell_script" "$test_root/journal-prevalidation-bash" "$acceptance_id" >/dev/null 2>&1; then
    printf 'Bash journal bridge ignored scoped archive validation failure.\n' >&2
    exit 1
fi
[[ ! -e $test_root/journal-prevalidation-bash/UNSAFE-EXTRACTION ]] || {
    printf 'Bash journal bridge extracted before archive validation.\n' >&2
    exit 1
}

journal_isolation_root="$test_root/journal-isolation-bash"
journal_isolation_capture="$journal_isolation_root/java.args"
journal_extractor_capture="$journal_isolation_root/extractor.args"
journal_chown_capture="$journal_isolation_root/chown.args"
mkdir -p "$journal_isolation_root/$acceptance_id"
: >"$journal_isolation_root/$acceptance_id/oscar-state.tar.gz"
bash -c '
    storage_script=$1; fixture_root=$2; backup_id=$3; capture=$4; extractor_capture=$5; chown_capture=$6
    set -- help; source "$storage_script" >/dev/null
    backup_dir=$fixture_root; script_dir=$fixture_root
    chown() { printf "%s\n" "$*" >"$chown_capture"; }; chmod() { :; }
    compose() {
        [[ ${1:-} != run ]] || { : >"$fixture_root/UNSAFE-COMPOSE-RUN"; return 1; }
        return 0
    }
    docker() {
        if [[ " $* " == *" --entrypoint java "* ]]; then
            printf "%s\n" "$*" >"$capture"
        elif [[ " $* " == *" --entrypoint sh "* && " $* " != *" /validate-storage-archive.sh oscar-state "* ]]; then
            printf "%s\n" "$*" >"$extractor_capture"
        fi
        return 0
    }
    confirm_daily_journal_backup "$backup_id" "$fixture_root/$backup_id" oscar:test aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
' _ "$shell_script" "$journal_isolation_root" "$acceptance_id" "$journal_isolation_capture" \
    "$journal_extractor_capture" "$journal_chown_capture"
snapshot_path=$(awk '{print $NF}' "$journal_chown_capture")
[[ -s $journal_isolation_capture && ! -e $journal_isolation_root/UNSAFE-COMPOSE-RUN ]] &&
[[ -s $journal_extractor_capture && -s $journal_chown_capture ]] &&
grep -Fq -- '--network none --read-only --cap-drop ALL --security-opt no-new-privileges' "$journal_extractor_capture" &&
grep -Fq -- '--workdir / --user 0:0 --entrypoint sh' "$journal_extractor_capture" &&
grep -Fq -- "--volume $journal_isolation_root/$acceptance_id/oscar-state.tar.gz:/oscar-state.tar.gz:ro" "$journal_extractor_capture" &&
grep -Eq -- "--volume $journal_isolation_root/\\.journal-confirm-$acceptance_id\\.[^ ]+:/snapshot" "$journal_extractor_capture" &&
! grep -Fq -- "--volume $journal_isolation_root/$acceptance_id:/" "$journal_extractor_capture" &&
! grep -Fq -- '--cap-add' "$journal_extractor_capture" &&
grep -Fq -- 'tar --no-same-owner -C /snapshot -xzf /oscar-state.tar.gz' "$journal_extractor_capture" &&
grep -Fq -- 'find /snapshot -type d -exec chmod 0700' "$journal_extractor_capture" &&
grep -Fq -- 'find /snapshot -type f -exec chmod 0600' "$journal_extractor_capture" &&
grep -Fq -- "0:10001 $snapshot_path" "$journal_chown_capture" &&
grep -Fq -- 'find "$snapshot" -mindepth 1 -exec chown -h 10001:10001' "$shell_script" &&
grep -Fq -- '--network none --read-only --cap-drop ALL --security-opt no-new-privileges' "$journal_isolation_capture" &&
grep -Fq -- '--tmpfs /tmp:rw,noexec,nosuid,nodev --user 10001:10001 --entrypoint java' "$journal_isolation_capture" &&
grep -Fq -- '--volume oscar_oscar_state:/var/lib/oscar' "$journal_isolation_capture" &&
grep -Fq -- "--volume $snapshot_path:/verified-snapshot:ro" "$journal_isolation_capture" || {
    printf 'Bash journal confirmation is not confined to the state volume and offline hardened container.\n' >&2
    exit 1
}

# The extracted journal tree may be application-owned, but its scratch root
# remains administrator-owned with a narrowly recognizable 0710/10001 shape so
# the next locked command can recover it after a host power loss.
journal_scratch_recovery_root="$test_root/journal-scratch-recovery-bash"
journal_scratch="$journal_scratch_recovery_root/.journal-confirm-$acceptance_id.A1b2C3"
mkdir -p "$journal_scratch"
chmod 0700 "$journal_scratch_recovery_root" "$journal_scratch"
bash -c '
    storage_script=$1; fixture=$2; expected_scratch=$3
    set -- help; source "$storage_script" >/dev/null
    backup_dir=$fixture
    file_owner_id() { printf "%s" "${EUID:-$(id -u)}"; }
    file_group_id() { [[ $1 == "$expected_scratch" ]] && printf "%s" 10001; }
    file_mode() { [[ $1 == "$expected_scratch" ]] && printf "%s" 710; }
    fsync_path() { :; }
    cleanup_abandoned_single_backup_staging
' _ "$shell_script" "$journal_scratch_recovery_root" "$journal_scratch"
[[ ! -e $journal_scratch ]] || {
    printf 'Bash recovery did not remove an exact crash-left journal scratch directory.\n' >&2
    exit 1
}

unsafe_restore_scratch="$journal_scratch_recovery_root/.restore-payload-$acceptance_id.A1b2C3"
mkdir -p "$unsafe_restore_scratch"
if bash -c '
    storage_script=$1; fixture=$2; expected_scratch=$3
    set -- help; source "$storage_script" >/dev/null
    backup_dir=$fixture
    file_owner_id() { printf "%s" "${EUID:-$(id -u)}"; }
    file_group_id() { [[ $1 == "$expected_scratch" ]] && printf "%s" 10001; }
    file_mode() { [[ $1 == "$expected_scratch" ]] && printf "%s" 710; }
    fsync_path() { :; }
    cleanup_abandoned_single_backup_staging
' _ "$shell_script" "$journal_scratch_recovery_root" "$unsafe_restore_scratch" >/dev/null 2>&1; then
    printf 'Bash recovery accepted the journal-only scratch ACL for a restore payload.\n' >&2
    exit 1
fi
[[ -d $unsafe_restore_scratch ]] || {
    printf 'Bash recovery removed an unsafe restore scratch directory.\n' >&2
    exit 1
}

# Every uid0 helper in setup and storage needs a neutral cwd. All are
# capability-free except the read-only backup verifier's single
# DAC_READ_SEARCH bridge. In particular, the application image owns
# /var/lib/oscar as uid 10001 with mode 0700, so a uid0 process cannot safely
# inherit that cwd.
awk '
    FNR == 1 { previous="" }
    /--user 0(:0)?([[:space:]]|$)/ {
        root_helpers++
        if (index(previous "\n" $0, "--workdir /") == 0) missing++
    }
    { previous=$0 }
    END { exit !(root_helpers == 17 && missing == 0) }
' "$shell_script" "$setup_shell_script" || {
    printf 'Bash root helper inherited an image-owned working directory.\n' >&2
    exit 1
}
windows_root_helper_count=$(grep -hE -- "'--user', '0(:0)?'" "$powershell_script" "$setup_powershell_script" | wc -l | tr -d ' ')
windows_neutral_root_helper_count=$(grep -hE -- "'--workdir', '/', '--user', '0(:0)?'" "$powershell_script" "$setup_powershell_script" | wc -l | tr -d ' ')
[[ $windows_root_helper_count == 18 && $windows_neutral_root_helper_count == "$windows_root_helper_count" ]] || {
    printf 'PowerShell root helper inherited an image-owned working directory.\n' >&2
    exit 1
}
assert_contains '-days 3650' "$setup_shell_script"
assert_contains '-checkend 0' "$setup_shell_script"
assert_contains "'-days', '3650'" "$setup_powershell_script"
assert_contains '-checkend 0' "$setup_powershell_script"

# A failure after both validation and extraction must remove the private
# snapshot and resume exactly the application services that were running.
journal_resume_root="$test_root/journal-resume-bash"
journal_resume_actions="$journal_resume_root/compose.actions"
mkdir -p "$journal_resume_root/$acceptance_id"
: >"$journal_resume_root/$acceptance_id/oscar-state.tar.gz"
if bash -c '
    storage_script=$1; fixture_root=$2; backup_id=$3; actions=$4
    set -- help; source "$storage_script" >/dev/null
    backup_dir=$fixture_root; script_dir=$fixture_root
    chown() { :; }; chmod() { :; }
    compose() {
        case "$*" in
            "ps --status running --services") printf "gateway\noscar\npostgres\n" ;;
            "stop gateway") printf "stop-gateway\n" >>"$actions" ;;
            "stop oscar") printf "stop-oscar\n" >>"$actions" ;;
            "up --detach --no-build --pull never oscar gateway") printf "resume-oscar-gateway\n" >>"$actions" ;;
        esac
    }
    docker() {
        [[ " $* " != *" --entrypoint java "* ]] || return 73
        return 0
    }
    confirm_daily_journal_backup "$backup_id" "$fixture_root/$backup_id" oscar:test aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
' _ "$shell_script" "$journal_resume_root" "$acceptance_id" "$journal_resume_actions" >/dev/null 2>&1; then
    printf 'Bash journal confirmation ignored an injected post-extraction failure.\n' >&2
    exit 1
fi
[[ $(grep -Fxc stop-gateway "$journal_resume_actions") == 1 &&
   $(grep -Fxc stop-oscar "$journal_resume_actions") == 1 &&
   $(grep -Fxc resume-oscar-gateway "$journal_resume_actions") == 1 &&
   -z $(find "$journal_resume_root" -mindepth 1 -maxdepth 1 -type d -name ".journal-confirm-$acceptance_id.*" -print -quit) ]] || {
    printf 'Bash journal confirmation did not clean its snapshot and resume the prior services after failure.\n' >&2
    exit 1
}
wait "$lock_holder"

# Archive verification must enumerate the Cartesian set of every query-visible
# generation and every required object kind. Missing and duplicate catalog
# objects must fail before an apparently healthy subset can be checksummed.
archive_completeness_fixture="$test_root/archive-completeness-bash"
mkdir -p "$archive_completeness_fixture"
printf 'object\n' >"$archive_completeness_fixture/object"
archive_fixture_sha=$(sha256_path "$archive_completeness_fixture/object")
bash -c '
    storage_script=$1; fixture=$2; fixture_sha=$3; mode=$4
    set -- help; source "$storage_script" >/dev/null
    require_configured() { :; }
    psql_admin() {
        local query=${!#}
        [[ $query == *"CROSS JOIN required"* ]] || return 0
        [[ $query == *"g.state IN"* ]] || return 44
        local generation=12345678-1234-4234-8234-123456789abc
        case $mode in
            valid)
                printf "REQUIRED\037%s\037OBSERVATIONS_PARQUET\0371\037ACTIVE\037datasets/a.parquet\037%s\037datasets/a.parquet\037%s\037datasets/a.manifest.json\n" "$generation" "$fixture_sha" "$fixture_sha"
                printf "REQUIRED\037%s\037GENERATION_MANIFEST\0371\037ACTIVE\037datasets/a.manifest.json\037%s\037datasets/a.parquet\037%s\037datasets/a.manifest.json\n" "$generation" "$fixture_sha" "$fixture_sha"
                printf "REQUIRED\037%s\037DATASTREAM_SCHEMAS\0371\037ACTIVE\037datasets/a.schemas.json.gz\037%s\037datasets/a.parquet\037%s\037datasets/a.manifest.json\n" "$generation" "$fixture_sha" "$fixture_sha"
                printf "ADDITIONAL\037%s\037AUDIT_SIDECAR\0371\037ACTIVE\037datasets/a.audit\037%s\037datasets/a.parquet\037%s\037datasets/a.manifest.json\n" "$generation" "$fixture_sha" "$fixture_sha"
                printf "RELATIONAL\037%s\037ID_BLOCK_AND_SCHEMAS\0371\037MATCH\0371\037\037datasets/a.parquet\037%s\037datasets/a.manifest.json\n" "$generation" "$fixture_sha"
                ;;
            missing)
                printf "REQUIRED\037%s\037OBSERVATIONS_PARQUET\0371\037ACTIVE\037datasets/a.parquet\037%s\037datasets/a.parquet\037%s\037datasets/a.manifest.json\n" "$generation" "$fixture_sha" "$fixture_sha"
                printf "REQUIRED\037%s\037GENERATION_MANIFEST\0370\037MISSING\037missing\037bad\037datasets/a.parquet\037%s\037datasets/a.manifest.json\n" "$generation" "$fixture_sha"
                printf "REQUIRED\037%s\037DATASTREAM_SCHEMAS\0371\037ACTIVE\037datasets/a.schemas.json.gz\037%s\037datasets/a.parquet\037%s\037datasets/a.manifest.json\n" "$generation" "$fixture_sha" "$fixture_sha"
                ;;
            duplicate)
                printf "REQUIRED\037%s\037OBSERVATIONS_PARQUET\0372\037ACTIVE\037datasets/a.parquet\037%s\037datasets/a.parquet\037%s\037datasets/a.manifest.json\n" "$generation" "$fixture_sha" "$fixture_sha"
                printf "REQUIRED\037%s\037GENERATION_MANIFEST\0371\037ACTIVE\037datasets/a.manifest.json\037%s\037datasets/a.parquet\037%s\037datasets/a.manifest.json\n" "$generation" "$fixture_sha" "$fixture_sha"
                printf "REQUIRED\037%s\037DATASTREAM_SCHEMAS\0371\037ACTIVE\037datasets/a.schemas.json.gz\037%s\037datasets/a.parquet\037%s\037datasets/a.manifest.json\n" "$generation" "$fixture_sha" "$fixture_sha"
                ;;
        esac
    }
    archive_object_path() { printf "%s/object" "$fixture"; }
    sha256_file() { printf "%s" "$fixture_sha"; }
    audit_archive_filesystem() { :; }
    archive_verify
' _ "$shell_script" "$archive_completeness_fixture" "$archive_fixture_sha" valid >/dev/null
for invalid_mode in missing duplicate stale-path stale-hash relational inactive-owner; do
    if bash -c '
        storage_script=$1; fixture=$2; fixture_sha=$3; mode=$4
        set -- help; source "$storage_script" >/dev/null
        require_configured() { :; }
        psql_admin() {
            local query=${!#}
            [[ $query == *"CROSS JOIN required"* ]] || return 0
            local generation=12345678-1234-4234-8234-123456789abc
            local parquet_count=1 parquet_path=datasets/a.parquet generation_path=datasets/a.parquet generation_sha=$fixture_sha
            if [[ $mode == inactive-owner ]]; then
                printf "INVALID_OWNER\037%s\037AUDIT_SIDECAR\0371\037ACTIVE\037datasets/a.audit\037%s\037\037\037\n" \
                    "$generation" "$fixture_sha"
                return
            fi
            [[ $mode == duplicate ]] && parquet_count=2
            [[ $mode == stale-path ]] && generation_path=datasets/stale.parquet
            [[ $mode == stale-hash ]] && generation_sha=$(printf "%064d" 0 | tr 0 b)
            printf "REQUIRED\037%s\037OBSERVATIONS_PARQUET\037%s\037ACTIVE\037%s\037%s\037%s\037%s\037datasets/a.manifest.json\n" \
                "$generation" "$parquet_count" "$parquet_path" "$fixture_sha" "$generation_path" "$generation_sha"
            if [[ $mode == missing ]]; then
                printf "REQUIRED\037%s\037GENERATION_MANIFEST\0370\037MISSING\037missing\037bad\037%s\037%s\037datasets/a.manifest.json\n" \
                    "$generation" "$generation_path" "$generation_sha"
            else
                printf "REQUIRED\037%s\037GENERATION_MANIFEST\0371\037ACTIVE\037datasets/a.manifest.json\037%s\037%s\037%s\037datasets/a.manifest.json\n" \
                    "$generation" "$fixture_sha" "$generation_path" "$generation_sha"
            fi
            printf "REQUIRED\037%s\037DATASTREAM_SCHEMAS\0371\037ACTIVE\037datasets/a.schemas.json.gz\037%s\037%s\037%s\037datasets/a.manifest.json\n" \
                "$generation" "$fixture_sha" "$generation_path" "$generation_sha"
            if [[ $mode == relational ]]; then
                printf "RELATIONAL\037%s\037ID_BLOCK_AND_SCHEMAS\0372\037MISMATCH\0370\037\037%s\037%s\037datasets/a.manifest.json\n" \
                    "$generation" "$generation_path" "$generation_sha"
            fi
        }
        archive_object_path() { printf "%s/object" "$fixture"; }
        sha256_file() { printf "%s" "$fixture_sha"; }
        audit_archive_filesystem() { :; }
        archive_verify
    ' _ "$shell_script" "$archive_completeness_fixture" "$archive_fixture_sha" "$invalid_mode" >/dev/null 2>&1; then
        printf 'Bash archive verification accepted a %s required-object catalog.\n' "$invalid_mode" >&2
        exit 1
    fi
done

# A stable first snapshot is not enough while the live archiver can activate a
# generation. Adding or removing a canonical row set between the pre/post
# snapshots must fail, covering both publication and purge races.
for change_mode in activation purge; do
    if bash -c '
        storage_script=$1; fixture=$2; fixture_sha=$3; mode=$4
        set -- help; source "$storage_script" >/dev/null
        require_configured() { :; }
        counter=$fixture/catalog-$mode.count
        rm -f -- "$counter"
        emit_generation() {
            local generation=$1 prefix=$2
            printf "REQUIRED\037%s\037OBSERVATIONS_PARQUET\0371\037ACTIVE\037datasets/%s.parquet\037%s\037datasets/%s.parquet\037%s\037datasets/%s.manifest.json\n" \
                "$generation" "$prefix" "$fixture_sha" "$prefix" "$fixture_sha" "$prefix"
            printf "REQUIRED\037%s\037GENERATION_MANIFEST\0371\037ACTIVE\037datasets/%s.manifest.json\037%s\037datasets/%s.parquet\037%s\037datasets/%s.manifest.json\n" \
                "$generation" "$prefix" "$fixture_sha" "$prefix" "$fixture_sha" "$prefix"
            printf "REQUIRED\037%s\037DATASTREAM_SCHEMAS\0371\037ACTIVE\037datasets/%s.schemas.json.gz\037%s\037datasets/%s.parquet\037%s\037datasets/%s.manifest.json\n" \
                "$generation" "$prefix" "$fixture_sha" "$prefix" "$fixture_sha" "$prefix"
            printf "RELATIONAL\037%s\037ID_BLOCK_AND_SCHEMAS\0371\037MATCH\0371\037\037datasets/%s.parquet\037%s\037datasets/%s.manifest.json\n" \
                "$generation" "$prefix" "$fixture_sha" "$prefix"
        }
        psql_admin() {
            local query=${!#} call=0
            [[ $query == *"CROSS JOIN required"* ]] || return 0
            [[ -f $counter ]] && call=$(<"$counter")
            call=$((call+1)); printf "%s" "$call" >"$counter"
            if [[ $mode == activation || $call == 1 ]]; then
                emit_generation 12345678-1234-4234-8234-123456789abc a
            fi
            if [[ $mode == activation && $call -gt 1 ]]; then
                emit_generation 87654321-4321-4234-8234-cba987654321 b
            fi
        }
        archive_object_path() { printf "%s/object" "$fixture"; }
        sha256_file() { printf "%s" "$fixture_sha"; }
        audit_archive_filesystem() { :; }
        archive_verify
    ' _ "$shell_script" "$archive_completeness_fixture" "$archive_fixture_sha" "$change_mode" >/dev/null 2>&1; then
        printf 'Bash archive verification accepted a concurrent catalog %s.\n' "$change_mode" >&2
        exit 1
    fi
done

# Observation IDs are persisted and indexed as signed BIGINT. Reject decimal
# values outside that exact domain before interpolating a typed SQL literal.
if ! bash -c '
    storage_script=$1; set -- help; source "$storage_script" >/dev/null
    valid_observation_id 1 && valid_observation_id 9223372036854775807 &&
        ! valid_observation_id 0 && ! valid_observation_id 9223372036854775808 &&
        ! valid_observation_id 9999999999999999999
' _ "$shell_script"; then
    printf 'Bash observation-ID validation does not enforce the positive signed-BIGINT domain.\n' >&2
    exit 1
fi

# Both retention-hold selector forms must survive Bash's AND/OR precedence.
bash -c '
    storage_script=$1; set -- help; source "$storage_script" >/dev/null
    require_admin() { :; }; require_configured() { :; }
    psql_admin() {
        local query=${!#} mode=HOT_EXACT
        [[ $query == *"'ARCHIVE_GENERATION'='ARCHIVE_GENERATION'"* ]] && mode=GENERATION_EXACT
        printf "87654321-4321-4234-8234-cba987654321\t%s\n" "$mode"
    }
    archive_hold create --store-key observations --id-scope 1 \
        --generation 12345678-1234-4234-8234-123456789abc --reason test --created-by tester
    archive_hold create --store-key observations --id-scope 1 \
        --observation 42 --reason test --created-by tester
' _ "$shell_script" >/dev/null

# Observation IDs are global only within a store/scope and archive ID blocks
# are coarse min/max indexes.  With eligible and ineligible streams
# interleaved, a sparse retired generation can therefore span an unrelated
# exact hot row.  Exact row state is authoritative; only a cold-only lookup
# may use the conservative range fallback.
hold_sql_capture="$test_root/observation-hold.sql"
bash -c '
    storage_script=$1; capture=$2
    set -- help; source "$storage_script" >/dev/null
    require_admin() { :; }; require_configured() { :; }
    psql_admin() {
        local query=${!#}
        printf "%s\n" "$query" >"$capture"
        printf "87654321-4321-4234-8234-cba987654321\tHOT_EXACT\n"
    }
    archive_hold create --store-key observations --id-scope 4 \
        --observation 102 --reason interleaved-test --created-by tester
' _ "$shell_script" "$hold_sql_capture" >/dev/null
hold_sql=$(LC_ALL=C tr '\n\r\t' '   ' <"$hold_sql_capture" | tr -s '[:space:]' ' ')
assert_ordered_hold_terms() {
    local remainder=$1 term
    shift
    for term in "$@"; do
        [[ $remainder == *"$term"* ]] || {
            printf 'Observation-hold SQL is missing or misorders its exact/range precedence term: %s\n' "$term" >&2
            exit 1
        }
        remainder=${remainder#*"$term"}
    done
}
assert_ordered_hold_terms "$hold_sql" \
    'SELECT 1 FROM oscar_tombstone' \
    'THEN CASE' \
    'SELECT 1 FROM "observations" any_hot_row' \
    'THEN CASE WHEN EXISTS (' \
    'SELECT 1 FROM "observations" exact_hot_row' \
    'SELECT 1 FROM oscar_archive_generation exact_owner' \
    "exact_owner.state IN ('ACTIVE','SEALED')" \
    "THEN 'HOT_EXACT'" \
    'WHEN EXISTS (' \
    'SELECT 1 FROM oscar_archive_id_block active_block' \
    'AND NOT EXISTS (' \
    'SELECT 1 FROM oscar_archive_id_block retired_block' \
    "THEN 'COLD_RANGE_CONSERVATIVE'" \
    'END AS resolution_mode'
[[ $hold_sql != *"::numeric"* &&
   $(grep -o -- "::bigint" <<<"$hold_sql" | wc -l | tr -d ' ') == 4 ]] || {
    printf 'Observation-hold SQL does not preserve bigint index operands.\n' >&2
    exit 1
}

observation_hold_fixture_mode() {
    local exact_present=$1 exact_eligible=$2 active_range=$3 retired_range=$4 tombstoned=$5
    ((tombstoned == 0)) || { printf REJECTED; return; }
    if ((exact_present == 1)); then
        ((exact_eligible == 1)) && printf HOT_EXACT || printf REJECTED
    else
        ((active_range == 1 && retired_range == 0)) && printf COLD_RANGE_CONSERVATIVE || printf REJECTED
    fi
}
assert_observation_hold_fixture() {
    local name=$1 expected=$2 actual
    shift 2
    actual=$(observation_hold_fixture_mode "$@")
    [[ $actual == "$expected" ]] || {
        printf 'Observation-hold sparse/interleaved fixture failed: %s (expected=%s actual=%s)\n' \
            "$name" "$expected" "$actual" >&2
        exit 1
    }
}
# A retired generation contains sparse IDs 100/104, so its [100,104] block
# also spans unrelated exact rows 102/103 and an ambiguous cold-only ID 101.
assert_observation_hold_fixture exact-hot-over-retired-range HOT_EXACT 1 1 1 1 0
assert_observation_hold_fixture exact-active-owned-over-retired-range HOT_EXACT 1 1 1 1 0
assert_observation_hold_fixture exact-sealed-owned-over-retired-range HOT_EXACT 1 1 1 1 0
assert_observation_hold_fixture exact-retired-owned REJECTED 1 0 1 1 0
assert_observation_hold_fixture cold-active-retired-ambiguous REJECTED 0 0 1 1 0
assert_observation_hold_fixture cold-active-only COLD_RANGE_CONSERVATIVE 0 0 1 0 0
assert_observation_hold_fixture cold-retired-only REJECTED 0 0 0 1 0
assert_observation_hold_fixture exact-hot-tombstoned REJECTED 1 1 1 1 1
assert_observation_hold_fixture unknown REJECTED 0 0 0 0 0

# A purge object list is a here-string. Commands inside that loop must not
# inherit it as stdin, or the first Docker/psql child can consume the remaining
# rows and strand a confirmed plan after deleting only its first object.
purge_stream_fixture="$test_root/purge-stream-bash"
mkdir -p "$purge_stream_fixture"
bash -c '
    storage_script=$1; fixture=$2
    set -- help; source "$storage_script" >/dev/null
    require_admin() { :; }; require_configured() { :; }
    token=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    token_hash=$(printf "%s" "$token" | sha256sum | awk "{print \$1}")
    fixture_generation=12345678-1234-4234-8234-123456789abc
    plan=87654321-4321-4234-8234-cba987654321
    digest=$(printf "%064d" 0 | tr 0 a)
    compose() { :; }
    archive_object_helper() {
        case $1 in
            verify) return 0 ;;
            delete)
                printf "%s\n" "$2" >>"$fixture/deleted"
                printf "DELETED\n"
                ;;
            *) return 2 ;;
        esac
    }
    psql_admin() {
        local query=${!#}
        case $query in
            *"SELECT subject_id, state, confirmation_hash"*)
                printf "2026-01-01T00:00:00Z|PLANNED|%s\n" "$token_hash"
                ;;
            *"o.state IN ('\''ACTIVE'\'','\''DELETING'\'')"*)
                for suffix in parquet manifest schemas; do
                    printf "%s\tdatasets/test/object.%s\t%s\tACTIVE\n" "$fixture_generation" "$suffix" "$digest"
                done
                ;;
            *"g.state='\''DELETING'\'' AND o.state='\''DELETING'\''"*)
                for suffix in parquet manifest schemas; do
                    printf "%s\tdatasets/test/object.%s\t%s\tDELETING\n" "$fixture_generation" "$suffix" "$digest"
                done
                ;;
            *"UPDATE oscar_archive_object SET state='\''DELETED'\''"*)
                # Deliberately attempt to consume one input row. The production
                # call must provide /dev/null, leaving the loop stream intact.
                IFS= read -r swallowed || true
                printf "updated\n" >>"$fixture/catalog-updates"
                ;;
            *"UPDATE oscar_deletion_plan_item i SET state='\''COMPLETED'\''"*)
                : >"$fixture/finalized"
                ;;
            *"SELECT state FROM oscar_deletion_plan"*)
                if [[ -f $fixture/finalized &&
                      $(wc -l <"$fixture/deleted") -eq 3 &&
                      $(wc -l <"$fixture/catalog-updates") -eq 3 ]]; then
                    printf "COMPLETED\n"
                else
                    printf "CONFIRMED\n"
                fi
                ;;
        esac
    }
    archive_purge --store-key obs --id-scope 4 --plan "$plan" --token "$token"
' _ "$shell_script" "$purge_stream_fixture" >/dev/null
[[ -f $purge_stream_fixture/finalized &&
   $(wc -l <"$purge_stream_fixture/deleted") -eq 3 &&
   $(wc -l <"$purge_stream_fixture/catalog-updates") -eq 3 ]] || {
    printf 'Bash archive purge did not finalize all three streamed objects and its plan.\n' >&2
    exit 1
}

# PowerShell materializes database rows into an array before invoking helpers,
# so child process stdin cannot consume the remaining purge work.
assert_contains '\$objects = @\(Invoke-PsqlLines' "$powershell_script"
assert_contains 'foreach \(\$line in \$objects\)' "$powershell_script"

# The old retention engine is gone. Cleanup of an established single snapshot
# is reachable only after authenticated CURRENT verification and requires the
# current recovery point itself to carry valid schema-v2 acceptance sidecars.
# Every candidate and tombstone is independently classified before deletion.
cleanup_body=$(awk '/^cleanup_noncurrent_backup_snapshots\(\)/,/^cleanup_abandoned_single_backup_staging\(\)/' "$shell_script")
[[ $(grep -Fc 'validate_current_backup_pointer' <<<"$cleanup_body") -ge 1 &&
   $(grep -Fc 'accepted_schema_v2_backup_for_cleanup "$current_id"' <<<"$cleanup_body") == 1 &&
   $(grep -Fc 'accepted_schema_v2_backup_for_cleanup "$backup_id" "$path"' <<<"$cleanup_body") -ge 1 &&
   $(grep -Fc 'CURRENT backup cannot be a deletion candidate' <<<"$cleanup_body") == 1 ]] || {
    printf 'Bash single-snapshot cleanup is not guarded by authenticated CURRENT verification.\n' >&2
    exit 1
}
create_commit_line=$(grep -n -m1 'write_current_backup_pointer "$backup_id"' <<<"$shell_create_body" | cut -d: -f1)
create_cleanup_line=$(grep -n -m1 'cleanup_noncurrent_backup_snapshots "$backup_id"' <<<"$shell_create_body" | cut -d: -f1)
[[ -n $create_commit_line && -n $create_cleanup_line && $create_commit_line -lt $create_cleanup_line ]] || {
    printf 'Bash backup cleanup can run before CURRENT commits.\n' >&2
    exit 1
}

mkdir -p "$test_root/reconcile-ok/datasets/observations/date=2026-10-17/profile=RAW_GATED"
printf 'authenticated separately by the storage-root identity gate\n' >"$test_root/reconcile-ok/.oscar-storage-root"
printf 'registered' >"$test_root/reconcile-ok/datasets/observations/date=2026-10-17/profile=RAW_GATED/generation-11111111-1111-4111-8111-111111111111.parquet"
printf 'writing' >"$test_root/reconcile-ok/datasets/observations/date=2026-10-17/profile=RAW_GATED/generation-22222222-2222-4222-8222-222222222222.parquet.partial"
printf 'helper writing' >"$test_root/reconcile-ok/datasets/observations/date=2026-10-17/profile=RAW_GATED/generation-44444444-4444-4444-8444-444444444444.parquet.partial.a1b2c3"
bash -c '
    storage_script=$1
    test_archive=$2
    set -- help
    source "$storage_script" >/dev/null
    archive_dir=$test_archive
    psql_admin() { printf "%s\n" "datasets/observations/date=2026-10-17/profile=RAW_GATED/generation-11111111-1111-4111-8111-111111111111.parquet"; }
    audit_archive_filesystem
' _ "$shell_script" "$test_root/reconcile-ok" >/dev/null

if bash -c '
    storage_script=$1
    test_archive=$2
    set -- help
    source "$storage_script" >/dev/null
    archive_dir=$test_archive
    psql_admin() { printf "%s\n" "datasets/observations/date=2026-10-17/profile=RAW_GATED/generation-11111111-1111-4111-8111-111111111111.parquet"; }
    audit_archive_filesystem true
' _ "$shell_script" "$test_root/reconcile-ok" >/dev/null 2>&1; then
    printf 'Bash quiesced archive audit accepted a partial suffix variant.\n' >&2
    exit 1
fi

mkdir -p "$test_root/reconcile-partial-link/datasets/observations"
ln -s "$test_root/archive/datasets/ok/object.parquet" \
    "$test_root/reconcile-partial-link/datasets/observations/generation.partial.race"
if bash -c '
    storage_script=$1; test_archive=$2
    set -- help; source "$storage_script" >/dev/null
    archive_dir=$test_archive
    psql_admin() { :; }
    audit_archive_filesystem true
' _ "$shell_script" "$test_root/reconcile-partial-link" >/dev/null 2>&1; then
    printf 'Bash quiesced archive audit accepted a symlinked partial suffix variant.\n' >&2
    exit 1
fi

mkdir -p "$test_root/reconcile-nested-marker/datasets"
printf 'not a root identity\n' >"$test_root/reconcile-nested-marker/datasets/.oscar-storage-root"
if bash -c '
    storage_script=$1; test_archive=$2
    set -- help; source "$storage_script" >/dev/null
    archive_dir=$test_archive
    psql_admin() { :; }
    audit_archive_filesystem
' _ "$shell_script" "$test_root/reconcile-nested-marker" >/dev/null 2>&1; then
    printf 'Bash archive reconciliation exempted a nested storage-root marker.\n' >&2
    exit 1
fi

mkdir -p "$test_root/reconcile-orphan/datasets/observations"
printf 'orphan' >"$test_root/reconcile-orphan/datasets/observations/generation-orphan.parquet"
if bash -c '
    storage_script=$1
    test_archive=$2
    set -- help
    source "$storage_script" >/dev/null
    archive_dir=$test_archive
    psql_admin() { :; }
    audit_archive_filesystem
' _ "$shell_script" "$test_root/reconcile-orphan" >/dev/null 2>&1; then
    printf 'Bash archive reconciliation accepted an unregistered final object.\n' >&2
    exit 1
fi

mkdir -p "$test_root/reconcile-stale/datasets/observations/date=2026-10-17/profile=RAW_GATED"
printf 'stale' >"$test_root/reconcile-stale/datasets/observations/date=2026-10-17/profile=RAW_GATED/generation-33333333-3333-4333-8333-333333333333.parquet.partial"
touch -t 202001010000 "$test_root/reconcile-stale/datasets/observations/date=2026-10-17/profile=RAW_GATED/generation-33333333-3333-4333-8333-333333333333.parquet.partial"
if bash -c '
    storage_script=$1
    test_archive=$2
    set -- help
    source "$storage_script" >/dev/null
    archive_dir=$test_archive
    psql_admin() { :; }
    audit_archive_filesystem
' _ "$shell_script" "$test_root/reconcile-stale" >/dev/null 2>&1; then
    printf 'Bash archive reconciliation accepted a stale partial.\n' >&2
    exit 1
fi

mkdir -p "$test_root/archive/datasets/ok"
printf 'ok' >"$test_root/archive/datasets/ok/object.parquet"
ln -s /etc/passwd "$test_root/archive/datasets/ok/escape.parquet"
expected=$(realpath "$test_root/archive/datasets/ok/object.parquet")
actual=$(bash -c '
    storage_script=$1; test_archive=$2
    set -- help
    source "$storage_script" >/dev/null
    archive_dir=$test_archive
    archive_object_path datasets/ok/object.parquet false
' _ "$shell_script" "$test_root/archive")
[[ $actual == "$expected" ]] || { printf 'Bash valid-path resolution mismatch.\n' >&2; exit 1; }

if bash -c '
    storage_script=$1; test_archive=$2
    set -- help
    source "$storage_script" >/dev/null
    archive_dir=$test_archive
    archive_object_path datasets/ok/escape.parquet false
' _ "$shell_script" "$test_root/archive" >/dev/null 2>&1; then
    printf 'Bash accepted a symlink archive object.\n' >&2
    exit 1
fi

if bash -c '
    storage_script=$1; test_archive=$2
    set -- help
    source "$storage_script" >/dev/null
    archive_dir=$test_archive
    archive_object_path ../etc/passwd false
' _ "$shell_script" "$test_root/archive" >/dev/null 2>&1; then
    printf 'Bash accepted archive traversal.\n' >&2
    exit 1
fi

missing=$(bash -c '
    storage_script=$1; test_archive=$2
    set -- help
    source "$storage_script" >/dev/null
    archive_dir=$test_archive
    archive_object_path datasets/ok/already-deleted.parquet true
' _ "$shell_script" "$test_root/archive")
expected_missing="$(realpath "$test_root/archive/datasets/ok")/already-deleted.parquet"
[[ $missing == "$expected_missing" ]] || { printf 'Bash purge-resume path mismatch.\n' >&2; exit 1; }

# Archive export must quiesce only OSCAR, move bytes through the locked-down
# helper, and restore the prior OSCAR state on both success and helper failure.
archive_export_fixture="$test_root/archive-export-bash"
mkdir -p "$archive_export_fixture/archive" "$archive_export_fixture/success-parent" \
    "$archive_export_fixture/failure-parent"
bash -c '
    storage_script=$1; fixture=$2
    set -- help; source "$storage_script" >/dev/null
    archive_dir=$fixture/archive
    require_configured() { :; }
    chown() { :; }
    publish_export_directory() { mv "$1" "$2"; }
    compose() {
        if [[ $1 == ps ]]; then printf "oscar\n"; return; fi
        printf "%s\n" "$*" >>"$fixture/compose-success.log"
    }
    psql_admin() {
        case "$*" in
            *"SELECT o.relative_path,o.sha256"*) printf "datasets/ok/object.parquet\t%064d\n" 0 | tr 0 a ;;
            *"row_to_json"*) printf "{\"id\":\"generation\"}\n" ;;
            *"json_agg"*) printf "[]\n" ;;
        esac
    }
    archive_object_helper() {
        [[ $1 == copy && $3 =~ ^a{64}$ && $4 == ro && -d $5 ]]
        mkdir -p "$5/${2%/*}"
        printf "copied through helper\n" >"$5/$2"
    }
    archive_export --store-key obs --id-scope 1 \
        --generation 12345678-1234-4234-8234-123456789abc \
        --destination "$fixture/success-parent/export"
' _ "$shell_script" "$archive_export_fixture" >/dev/null
grep -Fxq 'stop oscar' "$archive_export_fixture/compose-success.log"
grep -Fxq 'up --detach --no-deps --no-build --pull never --wait --wait-timeout 300 oscar' \
    "$archive_export_fixture/compose-success.log"
[[ -f $archive_export_fixture/success-parent/export/datasets/ok/object.parquet ]] || {
    printf 'Bash archive export did not publish the helper-created copy.\n' >&2
    exit 1
}

if bash -c '
    storage_script=$1; fixture=$2
    set -- help; source "$storage_script" >/dev/null
    archive_dir=$fixture/archive
    require_configured() { :; }
    chown() { :; }
    compose() {
        if [[ $1 == ps ]]; then printf "oscar\n"; return; fi
        printf "%s\n" "$*" >>"$fixture/compose-failure.log"
    }
    psql_admin() {
        case "$*" in *"SELECT o.relative_path,o.sha256"*) printf "datasets/ok/object.parquet\t%064d\n" 0 | tr 0 a ;; esac
    }
    archive_object_helper() { return 71; }
    archive_export --store-key obs --id-scope 1 \
        --generation 12345678-1234-4234-8234-123456789abc \
        --destination "$fixture/failure-parent/export"
' _ "$shell_script" "$archive_export_fixture" >/dev/null 2>&1; then
    printf 'Bash archive export ignored a helper failure.\n' >&2
    exit 1
fi
grep -Fxq 'stop oscar' "$archive_export_fixture/compose-failure.log"
grep -Fxq 'up --detach --no-deps --no-build --pull never oscar' \
    "$archive_export_fixture/compose-failure.log"
[[ ! -e $archive_export_fixture/failure-parent/export &&
   -z $(find "$archive_export_fixture/failure-parent" -maxdepth 1 -name '.export.partial.*' -print -quit) ]] || {
    printf 'Bash failed archive export left a partial or final destination.\n' >&2
    exit 1
}

helper_wrapper_fixture="$test_root/archive-helper-wrapper-bash"
mkdir -p "$helper_wrapper_fixture/archive" "$helper_wrapper_fixture/export"
bash -c '
    storage_script=$1; fixture=$2
    set -- help; source "$storage_script" >/dev/null
    archive_dir=$fixture/archive
    oscar_image() { printf oscar:test; }
    docker() { printf "%s\n" "$@" >"$fixture/copy.args"; }
    archive_object_helper copy datasets/ok/object.parquet "$(printf "%064d" 0 | tr 0 a)" ro "$fixture/export"
    docker() { printf "%s\n" "$@" >"$fixture/delete.args"; printf "DELETED\n"; }
    [[ $(archive_object_helper delete datasets/ok/object.parquet "$(printf "%064d" 0 | tr 0 a)" rw) == DELETED ]]
' _ "$shell_script" "$helper_wrapper_fixture"
for required_arg in run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges \
    /usr/local/bin/oscar-archive-object "$helper_wrapper_fixture/archive:/archive:ro" \
    "$helper_wrapper_fixture/export:/export" oscar:test copy; do
    grep -Fxq -- "$required_arg" "$helper_wrapper_fixture/copy.args" || {
        printf 'Bash archive helper wrapper omitted locked-down copy argument: %s\n' "$required_arg" >&2
        exit 1
    }
done
grep -Fxq -- "$helper_wrapper_fixture/archive:/archive:rw" "$helper_wrapper_fixture/delete.args"
[[ $(grep -Fxc -- '--volume' "$helper_wrapper_fixture/delete.args") == 1 ]] || {
    printf 'Bash archive delete helper received a mount other than the archive root.\n' >&2
    exit 1
}

if command -v pwsh >/dev/null 2>&1; then
    STORAGE_SCRIPT_PATH="$powershell_script" pwsh -NoLogo -NoProfile -Command '
        $ErrorActionPreference = "Stop"
        . $env:STORAGE_SCRIPT_PATH -Command help *> $null
        & {
            $actions = New-Object Collections.Generic.List[string]
            function Get-OscarImage { return "oscar:test" }
            function Get-DockerShellInputOutput([string]$InputText, [string[]]$Arguments) {
                if ($InputText -notmatch "umask 077" -or (($Arguments -join " ") -notmatch "--entrypoint sh")) {
                    throw "PowerShell legacy cleanup did not use the restricted shell contract"
                }
                [void]$actions.Add("legacy-cleanup"); return @()
            }
            function Get-ComposeShellInputOutput([string]$InputText, [string[]]$Arguments) {
                $joined = $Arguments -join " "
                if ($InputText -notmatch "umask 077" -or $InputText -notmatch "--config /var/lib/oscar/config.json" -or $joined -notmatch "--entrypoint sh oscar -seu") {
                    throw "PowerShell migration did not use the config-aware restricted shell contract"
                }
                [void]$actions.Add("migrate"); return @()
            }
            function Invoke-Compose([string[]]$Arguments) {
                $joined = $Arguments -join " "
                switch -Regex ($joined) {
                    "^stop gateway$" { [void]$actions.Add("stop-gateway"); return }
                    "^stop oscar$" { [void]$actions.Add("stop-oscar"); return }
                    "^config --quiet$" { [void]$actions.Add("config"); return }
                    "^up --detach --force-recreate --no-build --pull never --wait --wait-timeout 240$" { [void]$actions.Add("start"); return }
                    default { throw "Unexpected PowerShell upgrade Compose action: $joined" }
                }
            }
            Invoke-UpgradePersistentState *> $null
            if (($actions -join ",") -cne "stop-gateway,stop-oscar,legacy-cleanup,migrate,config,start") {
                throw "PowerShell locked upgrade transition ordering is incorrect: $($actions -join ",")"
            }
        }
        & {
            $actions = New-Object Collections.Generic.List[string]
            function Get-OscarImage { return "oscar:test" }
            function Get-DockerShellInputOutput([string]$InputText, [string[]]$Arguments) {
                [void]$actions.Add("legacy-cleanup"); return @()
            }
            function Get-ComposeShellInputOutput([string]$InputText, [string[]]$Arguments) {
                [void]$actions.Add("migration-failed"); throw "injected migration failure"
            }
            function Invoke-Compose([string[]]$Arguments) {
                $joined = $Arguments -join " "
                if ($joined -eq "stop gateway") { [void]$actions.Add("stop-gateway"); return }
                if ($joined -eq "stop oscar") { [void]$actions.Add("stop-oscar"); return }
                if ($joined -match "^up ") { [void]$actions.Add("UNSAFE-START"); return }
                throw "Unexpected PowerShell failure-path Compose action: $joined"
            }
            try {
                Invoke-UpgradePersistentState *> $null
                throw "PowerShell locked upgrade transition ignored migration failure"
            } catch {
                if ($_.Exception.Message -eq "PowerShell locked upgrade transition ignored migration failure") { throw }
            }
            if ($actions -contains "UNSAFE-START") {
                throw "PowerShell locked upgrade transition restarted after migration failure"
            }
        }
    '
    STORAGE_SCRIPT_TEST_ROOT="$test_root" STORAGE_SCRIPT_PATH="$powershell_script" \
        pwsh -NoLogo -NoProfile -Command '
            $ErrorActionPreference = "Stop"
            $parseErrors = $null
            [void][Management.Automation.Language.Parser]::ParseFile(
                $env:STORAGE_SCRIPT_PATH, [ref]$null, [ref]$parseErrors)
            if ($parseErrors.Count) { throw ($parseErrors -join "`n") }
            . $env:STORAGE_SCRIPT_PATH -Command help *> $null
            $validObject = "datasets/observations/date=2026-10-17/profile=RAW_GATED/generation-11111111-1111-4111-8111-111111111111.parquet"
            if (-not (Test-ArchiveObjectPath $validObject)) {
                throw "PowerShell rejected an approved archive object path"
            }
            if (Test-ArchiveObjectPath "foreign/file") {
                throw "PowerShell accepted an archive catalog path outside the approved layout"
            }
            & {
                function Write-PsqlLinesToFile([string]$Sql, [string]$Path) {
                    [IO.File]::WriteAllText($Path, "foreign/file`n", $Utf8NoBom)
                }
                $invalidCatalog = Join-Path $env:STORAGE_SCRIPT_TEST_ROOT "invalid-catalog-paths.txt"
                try {
                    Write-RegisteredArchivePaths $invalidCatalog
                    throw "PowerShell accepted an absent catalog object outside the approved layout"
                } catch {
                    if ($_.Exception.Message -eq "PowerShell accepted an absent catalog object outside the approved layout") { throw }
                }
            }
            $savedArchive = $ArchiveDirectory
            $savedBackup = $BackupDirectory
            $savedWal = $WalArchiveDirectory
            $ArchiveDirectory = [IO.Path]::GetPathRoot($env:STORAGE_SCRIPT_TEST_ROOT)
            $BackupDirectory = Join-Path $env:STORAGE_SCRIPT_TEST_ROOT "broad-test/backups"
            $WalArchiveDirectory = Join-Path $env:STORAGE_SCRIPT_TEST_ROOT "broad-test/wal"
            try {
                Assert-StorageRootShapes
                throw "PowerShell accepted a volume root as managed storage"
            } catch {
                if ($_.Exception.Message -eq "PowerShell accepted a volume root as managed storage") { throw }
            }
            $ArchiveDirectory = Join-Path $env:STORAGE_SCRIPT_TEST_ROOT "storage-roots/archive"
            $BackupDirectory = Join-Path $ArchiveDirectory "backups"
            $WalArchiveDirectory = Join-Path $env:STORAGE_SCRIPT_TEST_ROOT "storage-roots/wal"
            try {
                Assert-StorageRootShapes -IncludeBackup
                throw "PowerShell accepted overlapping managed storage roots"
            } catch {
                if ($_.Exception.Message -eq "PowerShell accepted overlapping managed storage roots") { throw }
            }
            $ArchiveDirectory = $savedArchive
            $BackupDirectory = $savedBackup
            $WalArchiveDirectory = $savedWal
            $ArchiveDirectory = Join-Path $env:STORAGE_SCRIPT_TEST_ROOT "archive"
            $valid = Resolve-ConfinedArchivePath "datasets/ok/object.parquet"
            $expected = [IO.Path]::GetFullPath((Join-Path $ArchiveDirectory "datasets/ok/object.parquet"))
            if ($valid -cne $expected) { throw "PowerShell valid-path resolution mismatch" }
            try {
                [void](Resolve-ConfinedArchivePath "../etc/passwd")
                throw "PowerShell accepted archive traversal"
            } catch { if ($_.Exception.Message -eq "PowerShell accepted archive traversal") { throw } }
            try {
                [void](Resolve-ConfinedArchivePath "datasets/ok/escape.parquet")
                throw "PowerShell accepted a symlink archive object"
            } catch { if ($_.Exception.Message -eq "PowerShell accepted a symlink archive object") { throw } }
            $missing = Resolve-ConfinedArchivePath "datasets/ok/already-deleted.parquet" -AllowMissing
            $expectedMissing = [IO.Path]::GetFullPath((Join-Path $ArchiveDirectory "datasets/ok/already-deleted.parquet"))
            if ($missing -cne $expectedMissing) { throw "PowerShell purge-resume path mismatch" }

            $inventoryRoot = Join-Path $env:STORAGE_SCRIPT_TEST_ROOT "image-inventory-retag"
            [void](Read-ImageInventory $inventoryRoot)
            function Resolve-ReleaseImages {
                return [pscustomobject]@{
                    application = "oscar:$RequiredReleaseVersion"
                    postgres = "oscar-postgis:$RequiredReleaseVersion"
                    gateway = "nginxinc/nginx-unprivileged:1.28.1-alpine"
                }
            }
            function Get-ImageInspectValue([string]$Image, [string]$Field) {
                return "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
            }
            try {
                Confirm-ImageInventory $inventoryRoot -CompareCurrent
                throw "PowerShell restore accepted a same-name image whose immutable ID changed"
            } catch {
                if ($_.Exception.Message -eq "PowerShell restore accepted a same-name image whose immutable ID changed") { throw }
            }

            $portableInventoryRoot = Join-Path $env:STORAGE_SCRIPT_TEST_ROOT "image-inventory-portable"
            function Get-ImageInspectValue([string]$Image, [string]$Field) {
                if ($Field -ceq "Id") {
                    switch -CaseSensitive ($Image) {
                        "oscar:$RequiredReleaseVersion" { return "sha256:" + ("a" * 64) }
                        "oscar-postgis:$RequiredReleaseVersion" { return "sha256:" + ("c" * 64) }
                        "nginxinc/nginx-unprivileged:1.28.1-alpine" { return "sha256:" + ("d" * 64) }
                    }
                }
                if ($Field -ceq "RepoDigests") { return "null" }
                if ($Field -ceq "org.opencontainers.image.version") { return $RequiredReleaseVersion }
                if ($Field -ceq "com.botts.oscar.storage-profile") { return $RequiredReleaseVersion }
                throw "Unexpected image inspection: $Image $Field"
            }
            Confirm-ImageInventory $portableInventoryRoot -CompareCurrent

            $credentialLive = Join-Path $env:STORAGE_SCRIPT_TEST_ROOT "credential-install-powershell"
            $credentialRestore = Join-Path $credentialLive "restore"
            foreach ($directory in @(
                (Join-Path $credentialLive "secrets"), (Join-Path $credentialLive "tls"),
                (Join-Path $credentialRestore "secrets"), (Join-Path $credentialRestore "tls"))) {
                [IO.Directory]::CreateDirectory($directory) | Out-Null
            }
            $targetDeployment = "12345678-1234-4234-8234-123456789abc"
            $sourceDeployment = "87654321-4321-4321-8321-cba987654321"
            $targetArchive = Join-Path $env:STORAGE_SCRIPT_TEST_ROOT "target-storage/archive"
            $targetWal = Join-Path $env:STORAGE_SCRIPT_TEST_ROOT "target-storage/wal"
            $targetBackups = Join-Path $env:STORAGE_SCRIPT_TEST_ROOT "target-storage/backups"
            $targetBindings = @(
                "OSCAR_VERSION=$RequiredReleaseVersion",
                "OSCAR_DEPLOYMENT_ID=$targetDeployment",
                "OSCAR_POSTGIS_PLATFORM=windows/amd64",
                "OSCAR_HTTPS_PORT=9443",
                "OSCAR_HOSTNAME=restore-target.example",
                "OSCAR_SECRETS_DIR=./secrets",
                "OSCAR_TLS_DIR=./tls",
                "OSCAR_ARCHIVE_DIR=$targetArchive",
                "OSCAR_BACKUP_MODE=single",
                "OSCAR_WAL_ARCHIVE_DIR=$targetWal",
                "OSCAR_BACKUP_DIR=$targetBackups",
                "OSCAR_BACKUP_KEY_FILE=./secrets/backup-key.txt",
                "OSCAR_BACKUP_RETENTION_COUNT=7"
            )
            $sourceBindings = @(
                "OSCAR_VERSION=$RequiredReleaseVersion",
                "OSCAR_DEPLOYMENT_ID=$sourceDeployment",
                "OSCAR_POSTGIS_PLATFORM=linux/amd64",
                "OSCAR_HTTPS_PORT=443",
                "OSCAR_HOSTNAME=backup-source.example",
                "OSCAR_SECRETS_DIR=C:\source\release-secrets",
                "OSCAR_TLS_DIR=C:\source\release-tls",
                "OSCAR_ARCHIVE_DIR=/source/storage/archive",
                "OSCAR_BACKUP_MODE=disabled",
                "OSCAR_WAL_ARCHIVE_DIR=/source/storage/wal",
                "OSCAR_BACKUP_DIR=/source/storage/backups",
                "OSCAR_BACKUP_KEY_FILE=C:\source\keys\backup-key.txt",
                "OSCAR_BACKUP_RETENTION_COUNT=99"
            )
            [IO.File]::WriteAllLines((Join-Path $credentialLive ".env"), $targetBindings, $Utf8NoBom)
            [IO.File]::WriteAllText((Join-Path $credentialLive "secrets/stale.key"), "stale")
            [IO.File]::WriteAllText((Join-Path $credentialLive "tls/stale.crt"), "stale")
            [IO.File]::WriteAllLines((Join-Path $credentialRestore ".env"), $sourceBindings, $Utf8NoBom)
            [IO.File]::WriteAllText((Join-Path $credentialRestore "secrets/current.key"), "new")
            [IO.File]::WriteAllText((Join-Path $credentialRestore "tls/current.crt"), "new")
            Prepare-RestoredDeploymentCredentials $credentialRestore $credentialLive
            Install-PreparedDeploymentCredentials $credentialRestore $credentialLive
            $installedBindings = @([IO.File]::ReadAllLines((Join-Path $credentialLive ".env")))
            foreach ($expected in @($targetBindings | Where-Object { $_ -notmatch "^OSCAR_BACKUP_RETENTION_COUNT=" })) {
                if (@($installedBindings | Where-Object { $_ -ceq $expected }).Count -ne 1) {
                    throw "PowerShell cross-host restore did not preserve target binding: $expected"
                }
            }
            if (@($installedBindings | Where-Object { $_ -ceq "OSCAR_BACKUP_RETENTION_COUNT=99" }).Count -ne 1 -or
                -not (Test-Path -LiteralPath (Join-Path $credentialLive "secrets/current.key") -PathType Leaf) -or
                (Test-Path -LiteralPath (Join-Path $credentialLive "secrets/stale.key")) -or
                -not (Test-Path -LiteralPath (Join-Path $credentialLive "tls/current.crt") -PathType Leaf) -or
                (Test-Path -LiteralPath (Join-Path $credentialLive "tls/stale.crt"))) {
                throw "PowerShell restore did not merge portable configuration or replace credential and TLS trees exactly"
            }
            $storageScriptRoot = $ScriptRoot
            $ScriptRoot = $credentialLive
            function Test-DockerVolume([string]$Volume) { return $true }
            function Get-VolumeDeploymentLabel([string]$Volume) { return $targetDeployment }
            Assert-DeploymentVolumeOwnership
            $ScriptRoot = $storageScriptRoot

            $unsafeLive = Join-Path $env:STORAGE_SCRIPT_TEST_ROOT "credential-unsafe-target-powershell"
            $unsafeRestore = Join-Path $unsafeLive "restore"
            foreach ($directory in @(
                (Join-Path $unsafeLive "secrets"), (Join-Path $unsafeLive "tls"),
                (Join-Path $unsafeRestore "secrets"), (Join-Path $unsafeRestore "tls"))) {
                [IO.Directory]::CreateDirectory($directory) | Out-Null
            }
            [IO.File]::WriteAllLines(
                (Join-Path $unsafeLive ".env"),
                @($installedBindings | Where-Object { $_ -notmatch "^OSCAR_BACKUP_DIR=" }),
                $Utf8NoBom)
            [IO.File]::WriteAllLines((Join-Path $unsafeRestore ".env"), $installedBindings, $Utf8NoBom)
            [IO.File]::WriteAllText((Join-Path $unsafeLive "secrets/live-sentinel.key"), "must survive")
            [IO.File]::WriteAllText((Join-Path $unsafeRestore "secrets/source.key"), "replacement")
            [IO.File]::WriteAllText((Join-Path $unsafeRestore "tls/source.crt"), "replacement")
            try {
                Prepare-RestoredDeploymentCredentials $unsafeRestore $unsafeLive
                Install-PreparedDeploymentCredentials $unsafeRestore $unsafeLive
                throw "PowerShell restore accepted a target missing a host-local binding"
            } catch {
                if ($_.Exception.Message -eq "PowerShell restore accepted a target missing a host-local binding") { throw }
            }
            if (-not (Test-Path -LiteralPath (Join-Path $unsafeLive "secrets/live-sentinel.key") -PathType Leaf)) {
                throw "PowerShell restore changed live credentials before rejecting an unsafe target environment"
            }

            $sortFixture = Join-Path $env:STORAGE_SCRIPT_TEST_ROOT "archive-sort-powershell"
            [IO.Directory]::CreateDirectory($sortFixture) | Out-Null
            $rawCandidates = Join-Path $sortFixture "candidates.raw"
            $sortedCandidates = Join-Path $sortFixture "candidates.sorted"
            [IO.File]::WriteAllLines($rawCandidates, @("delta","alpha","gamma","alpha","beta"), $Utf8NoBom)
            ConvertTo-ArchiveAuditSortedUniqueFile $rawCandidates $sortedCandidates 2
            if (([IO.File]::ReadAllLines($sortedCandidates) -join ",") -cne "alpha,beta,delta,gamma") {
                throw "PowerShell bounded archive sort did not order and deduplicate across chunks"
            }
            $catalogFirstRaw = Join-Path $sortFixture "catalog-first.raw"
            $catalogSecondRaw = Join-Path $sortFixture "catalog-second.raw"
            $catalogFirst = Join-Path $sortFixture "catalog-first.sorted"
            $catalogSecond = Join-Path $sortFixture "catalog-second.sorted"
            $catalogMerged = Join-Path $sortFixture "catalog-merged.sorted"
            [IO.File]::WriteAllLines($catalogFirstRaw, @("gamma","alpha"), $Utf8NoBom)
            [IO.File]::WriteAllLines($catalogSecondRaw, @("epsilon","beta","alpha"), $Utf8NoBom)
            ConvertTo-ArchiveAuditSortedUniqueFile $catalogFirstRaw $catalogFirst 1
            ConvertTo-ArchiveAuditSortedUniqueFile $catalogSecondRaw $catalogSecond 1
            Merge-ArchiveAuditSortedFiles $catalogFirst $catalogSecond $catalogMerged
            if (([IO.File]::ReadAllLines($catalogMerged) -join ",") -cne "alpha,beta,epsilon,gamma") {
                throw "PowerShell bounded archive sort did not merge catalog snapshots"
            }
            $missing = Compare-ArchiveAuditSortedFiles $sortedCandidates $catalogMerged 2>$null
            if ($missing -ne 1) { throw "PowerShell streaming archive comparison did not identify exactly one orphan" }

            $ArchiveDirectory = Join-Path $env:STORAGE_SCRIPT_TEST_ROOT "reconcile-ok"
            $catalogPath = "datasets/observations/date=2026-10-17/profile=RAW_GATED/generation-11111111-1111-4111-8111-111111111111.parquet"
            $racePath = "datasets/observations/date=2026-10-17/profile=RAW_GATED/generation-55555555-5555-4555-8555-555555555555.schemas.json.gz"
            [IO.File]::WriteAllText((Join-Path $ArchiveDirectory ($racePath.Replace("/", [IO.Path]::DirectorySeparatorChar))), "activated during scan")
            $script:ArchiveCatalogReads = 0
            function Write-PsqlLinesToFile([string]$Sql, [string]$Path) {
                if (-not $Sql.Contains("oscar_archive_object") -or -not $Sql.Contains("ACTIVE") -or
                    -not $Sql.Contains("DELETING") -or -not $Sql.Contains("ORDER BY relative_path")) {
                    throw "PowerShell archive reconciliation used a noncanonical catalog query"
                }
                $script:ArchiveCatalogReads++
                $rows = @($catalogPath)
                if ($script:ArchiveCatalogReads -ge 2) { $rows += $racePath }
                [IO.File]::WriteAllLines($Path, $rows, $Utf8NoBom)
            }
            Test-ArchiveFilesystemRegistration
            if ($script:ArchiveCatalogReads -ne 2) {
                throw "PowerShell archive reconciliation did not merge exactly two file-backed catalog snapshots"
            }
            try {
                Test-ArchiveFilesystemRegistration -RejectPartials
                throw "PowerShell quiesced archive audit accepted partial suffix variants"
            } catch {
                if ($_.Exception.Message -eq "PowerShell quiesced archive audit accepted partial suffix variants") { throw }
            }
            $ArchiveDirectory = Join-Path $env:STORAGE_SCRIPT_TEST_ROOT "reconcile-partial-link"
            try {
                Test-ArchiveFilesystemRegistration -RejectPartials
                throw "PowerShell quiesced archive audit accepted a symlinked partial suffix variant"
            } catch {
                if ($_.Exception.Message -eq "PowerShell quiesced archive audit accepted a symlinked partial suffix variant") { throw }
            }
            $ArchiveDirectory = Join-Path $env:STORAGE_SCRIPT_TEST_ROOT "reconcile-nested-marker"
            try {
                Test-ArchiveFilesystemRegistration
                throw "PowerShell archive reconciliation exempted a nested storage-root marker"
            } catch {
                if ($_.Exception.Message -eq "PowerShell archive reconciliation exempted a nested storage-root marker") { throw }
            }
            $ArchiveDirectory = Join-Path $env:STORAGE_SCRIPT_TEST_ROOT "reconcile-ok"
            $orphan = Join-Path $ArchiveDirectory "datasets/observations/date=2026-10-17/profile=RAW_GATED/generation-66666666-6666-4666-8666-666666666666.manifest.json"
            [IO.Directory]::CreateDirectory((Split-Path -Parent $orphan)) | Out-Null
            [IO.File]::WriteAllText($orphan, "orphan")
            try {
                Test-ArchiveFilesystemRegistration
                throw "PowerShell archive reconciliation accepted an orphan"
            } catch {
                if ($_.Exception.Message -eq "PowerShell archive reconciliation accepted an orphan") { throw }
            } finally { Remove-Item -LiteralPath $orphan -Force }

            # Exercise the separately authenticated post-verification journal
            # audit sidecar. It is not part of the immutable core manifest.
            $acceptanceId = "20261017T120000Z-1234abcd"
            $BackupDirectory = Join-Path $env:STORAGE_SCRIPT_TEST_ROOT "acceptance/backups"
            $BackupKeyFile = Join-Path $env:STORAGE_SCRIPT_TEST_ROOT "acceptance/backup-key.txt"
            function Assert-Administrator {}
            function Assert-Configured {}
            function Assert-BackupKey {}
            function Get-OscarImage { return "oscar:test" }
            function Get-PostgresImage { return "postgres:test" }
            function Assert-LocalImage([string]$Image) {}
            function Confirm-ChecksumHmac([string]$Root, [string]$Image) {}
            function Get-JournalConfirmationHmac([string]$ReceiptPath, [string]$Image) { return "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" }
            function Invoke-External([string]$File, [string[]]$Arguments) {}
            function Invoke-DockerShellInput([string]$InputText, [string[]]$Arguments) {}
            function Invoke-Compose([string[]]$Arguments) {}
            function Protect-AdministratorFile([string]$Path) {}
            function Assert-AdministratorFile([string]$Path, [string]$Description) {}
            function Protect-PrivateDirectory([string]$Path) {}
            function Protect-DockerStorageDirectory([string]$Path, [string]$DockerAccess) {}
            function Protect-DockerReadableAdministratorFile([string]$Path) {}
            function Confirm-ReleaseConfigArchive([string]$Root, [string]$Image) {}
            function Confirm-BackupArchiveMembers([string]$Root, [string]$Image) {}
            function Confirm-ImageInventory([string]$Root, [switch]$CompareCurrent) {}
            function Get-ComposeOutput([string[]]$Arguments) { return @() }

            $acceptanceBackupDirectory = $BackupDirectory
            $pointerFixture = Join-Path $env:STORAGE_SCRIPT_TEST_ROOT "current-pointer-powershell"
            $pointerId = "20261020T120000Z-1234abcd"
            [IO.Directory]::CreateDirectory((Join-Path $pointerFixture $pointerId)) | Out-Null
            $pointerPath = Join-Path $pointerFixture "CURRENT"
            $pointerTag = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
            $pointerRaw = "format=oscar-current-backup`nversion=1`nbackup_id=$pointerId`nhmac_sha256=$pointerTag`n"
            $nonCanonicalMetadataEncodings = @(
                (New-Object Text.UTF8Encoding($true))
                (New-Object Text.UnicodeEncoding($false, $true))
            )
            [IO.File]::WriteAllText($pointerPath, $pointerRaw, $Utf8NoBom)
            $currentPointerHmacImplementation = ${function:Get-CurrentPointerHmac}
            function Get-CurrentPointerHmac([string]$PointerPath, [string]$Image) { return $pointerTag }
            $BackupDirectory = $pointerFixture
            if ((Read-CurrentBackupId) -cne $pointerId) { throw "PowerShell rejected the canonical CURRENT pointer" }
            [IO.File]::WriteAllText($pointerPath, $pointerRaw.TrimEnd([char[]]"`r`n"), $Utf8NoBom)
            try {
                [void](Read-CurrentBackupId)
                throw "PowerShell CURRENT pointer accepted a missing final LF"
            } catch {
                if ($_.Exception.Message -eq "PowerShell CURRENT pointer accepted a missing final LF") { throw }
                if ($_.Exception.Message -notlike "*not canonically LF-terminated*") { throw }
            }
            foreach ($encoding in $nonCanonicalMetadataEncodings) {
                [IO.File]::WriteAllText($pointerPath, $pointerRaw, $encoding)
                try {
                    [void](Read-CurrentBackupId)
                    throw "PowerShell CURRENT pointer accepted noncanonical BOM or UTF-16 bytes"
                } catch {
                    if ($_.Exception.Message -eq "PowerShell CURRENT pointer accepted noncanonical BOM or UTF-16 bytes") { throw }
                    if ($_.Exception.Message -notlike "*not canonically LF-terminated*") { throw }
                }
            }
            [IO.File]::WriteAllText($pointerPath, $pointerRaw, $Utf8NoBom)
            Set-Item -Path Function:Get-CurrentPointerHmac -Value $currentPointerHmacImplementation
            $BackupDirectory = $acceptanceBackupDirectory

            $generationInventoryRoot = Join-Path $env:STORAGE_SCRIPT_TEST_ROOT "generation-inventory-powershell"
            [IO.Directory]::CreateDirectory($generationInventoryRoot) | Out-Null
            $generationInventory = Join-Path $generationInventoryRoot "archive-generation-ids.txt"
            [IO.File]::Copy(
                (Join-Path (Join-Path $BackupDirectory $acceptanceId) "archive-generation-ids.txt"),
                $generationInventory,
                $true)
            $expectedGenerationSha = (Get-FileHash -LiteralPath $generationInventory -Algorithm SHA256).Hash.ToLowerInvariant()
            $generationReceipt = Get-ArchiveGenerationInventory $generationInventoryRoot
            if ($generationReceipt.Count -ne 2 -or $generationReceipt.Bytes -ne 74 -or
                $generationReceipt.Sha256 -cne $expectedGenerationSha) {
                throw "PowerShell did not produce the compact authenticated generation receipt"
            }
            [IO.File]::WriteAllBytes($generationInventory, [byte[]]@())
            $emptyReceipt = Get-ArchiveGenerationInventory $generationInventoryRoot
            if ($emptyReceipt.Count -ne 0 -or $emptyReceipt.Bytes -ne 0 -or
                $emptyReceipt.Sha256 -cne "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855") {
                throw "PowerShell rejected the canonical zero-generation inventory receipt"
            }
            $invalidInventories = @(
                "11111111-1111-4111-8111-111111111111`n11111111-1111-4111-8111-111111111111`n",
                "22222222-2222-4222-8222-222222222222`n11111111-1111-4111-8111-111111111111`n",
                "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA`n",
                "11111111-1111-4111-8111-111111111111",
                "11111111-1111-4111-8111-111111111111`r`n",
                ([Text.Encoding]::UTF8.GetString([byte[]](0xef,0xbb,0xbf)) + "11111111-1111-4111-8111-111111111111`n")
            )
            foreach ($invalidInventory in $invalidInventories) {
                [IO.File]::WriteAllText($generationInventory, $invalidInventory, $Utf8NoBom)
                try {
                    [void](Get-ArchiveGenerationInventory $generationInventoryRoot)
                    throw "PowerShell accepted a noncanonical archive-generation inventory"
                } catch {
                    if ($_.Exception.Message -eq "PowerShell accepted a noncanonical archive-generation inventory") { throw }
                }
            }
            [IO.File]::Copy(
                (Join-Path (Join-Path $BackupDirectory $acceptanceId) "archive-generation-ids.txt"),
                $generationInventory,
                $true)

            $largeWriter = [IO.StreamWriter]::new($generationInventory, $false, $Utf8NoBom)
            $largeWriter.NewLine = "`n"
            try {
                for ($index = 0; $index -lt 10000; $index++) {
                    $largeWriter.WriteLine(("00000000-0000-4000-8000-{0:D12}" -f $index))
                }
            } finally { $largeWriter.Dispose() }
            $largeSha = (Get-FileHash -LiteralPath $generationInventory -Algorithm SHA256).Hash.ToLowerInvariant()
            $largeReceipt = Get-ArchiveGenerationInventory $generationInventoryRoot
            if ($largeReceipt.Count -ne 10000 -or $largeReceipt.Bytes -ne 370000 -or
                $largeReceipt.Sha256 -cne $largeSha) {
                throw "PowerShell streaming archive-generation receipt failed its practical boundary fixture"
            }
            $oversized = [IO.File]::Open($generationInventory, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try { $oversized.SetLength(37000001) } finally { $oversized.Dispose() }
            try {
                [void](Get-ArchiveGenerationInventory $generationInventoryRoot)
                throw "PowerShell accepted an archive-generation inventory above 37,000,000 bytes"
            } catch {
                if ($_.Exception.Message -eq "PowerShell accepted an archive-generation inventory above 37,000,000 bytes") { throw }
            }
            [IO.File]::Copy(
                (Join-Path (Join-Path $BackupDirectory $acceptanceId) "archive-generation-ids.txt"),
                $generationInventory,
                $true)

            $catalogSqlCapture = Join-Path $env:STORAGE_SCRIPT_TEST_ROOT "catalog-upsert-powershell.sql"
            $script:MockEpochReceipt = "12345678-1234-4123-8123-123456789abc|VERIFIED"
            function Assert-DeploymentVolumeOwnership {}
            function Invoke-PsqlScript([string]$Sql) {
                [IO.File]::WriteAllText($catalogSqlCapture, $Sql, $Utf8NoBom)
                return $script:MockEpochReceipt
            }
            Set-VerifiedBackupEpochReceipt (Join-Path $BackupDirectory $acceptanceId) $acceptanceId "12345678-1234-4123-8123-123456789abc" "0/12345678"
            $catalogSql = [IO.File]::ReadAllText($catalogSqlCapture)
            $expectedReceiptFragment = ",2," + [char]39 + $expectedGenerationSha + [char]39 + ",74,"
            if (-not $catalogSql.Contains($expectedReceiptFragment) -or
                $catalogSql.Contains("FROM oscar_archive_generation") -or
                $catalogSql.Contains("archive_generation_ids") -or
                $catalogSql.Contains("11111111-1111-4111-8111-111111111111") -or
                -not $catalogSql.Contains("archive_generation_count IS NOT DISTINCT FROM EXCLUDED.archive_generation_count") -or
                -not $catalogSql.Contains("archive_generation_inventory_sha256 IS NOT DISTINCT FROM EXCLUDED.archive_generation_inventory_sha256") -or
                -not $catalogSql.Contains("archive_generation_inventory_bytes IS NOT DISTINCT FROM EXCLUDED.archive_generation_inventory_bytes")) {
                throw "PowerShell VERIFIED epoch upsert is not bound to the compact authenticated backup-time generation receipt"
            }
            $script:MockEpochReceipt = ""
            try {
                Set-VerifiedBackupEpochReceipt (Join-Path $BackupDirectory $acceptanceId) $acceptanceId "12345678-1234-4123-8123-123456789abc" "0/12345678"
                throw "PowerShell accepted a foreign same-UUID epoch collision"
            } catch {
                if ($_.Exception.Message -eq "PowerShell accepted a foreign same-UUID epoch collision") { throw }
            }
            $verified = Join-Path (Join-Path $BackupDirectory $acceptanceId) "VERIFIED"
            Remove-Item -LiteralPath $verified -Force -ErrorAction SilentlyContinue
            $journalReceipt = Join-Path (Join-Path $BackupDirectory $acceptanceId) "JOURNAL_CONFIRMED"
            $acceptanceStateSha = (Get-FileHash -LiteralPath (Join-Path (Join-Path $BackupDirectory $acceptanceId) "oscar-state.tar.gz") -Algorithm SHA256).Hash.ToLowerInvariant()
            $validJournalReceipt = [IO.File]::ReadAllText($journalReceipt)
            [IO.File]::WriteAllText($journalReceipt, $validJournalReceipt.TrimEnd([char[]]"`r`n"), $Utf8NoBom)
            try {
                Confirm-JournalConfirmationReceipt (Join-Path $BackupDirectory $acceptanceId) $acceptanceId $acceptanceStateSha "oscar:test"
                throw "PowerShell journal confirmation accepted a missing final LF"
            } catch {
                if ($_.Exception.Message -eq "PowerShell journal confirmation accepted a missing final LF") { throw }
                if ($_.Exception.Message -notlike "*not canonically LF-terminated*") { throw }
            }
            foreach ($encoding in $nonCanonicalMetadataEncodings) {
                [IO.File]::WriteAllText($journalReceipt, $validJournalReceipt, $encoding)
                try {
                    Confirm-JournalConfirmationReceipt (Join-Path $BackupDirectory $acceptanceId) $acceptanceId $acceptanceStateSha "oscar:test"
                    throw "PowerShell journal confirmation accepted noncanonical BOM or UTF-16 bytes"
                } catch {
                    if ($_.Exception.Message -eq "PowerShell journal confirmation accepted noncanonical BOM or UTF-16 bytes") { throw }
                    if ($_.Exception.Message -notlike "*not canonically LF-terminated*") { throw }
                }
            }
            [IO.File]::WriteAllText($journalReceipt, $validJournalReceipt, $Utf8NoBom)
            [IO.File]::WriteAllText($journalReceipt, "corrupt receipt`n", $Utf8NoBom)
            Confirm-Backup $acceptanceId -WarningAction SilentlyContinue
            if (-not (Test-Path -LiteralPath $verified -PathType Leaf)) {
                throw "PowerShell audit-sidecar corruption incorrectly blocked authenticated core recovery acceptance"
            }
            Remove-Item -LiteralPath $verified -Force
            [IO.File]::WriteAllText($journalReceipt, $validJournalReceipt, $Utf8NoBom)
            Confirm-Backup $acceptanceId
            if (-not (Test-Path -LiteralPath $verified -PathType Leaf) -or
                ((Get-Item -LiteralPath $verified).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "PowerShell authenticated journal receipt did not produce VERIFIED"
            }
            Confirm-BackupAcceptanceSidecars (Join-Path $BackupDirectory $acceptanceId) $acceptanceId $acceptanceStateSha "oscar:test"
            $validVerifiedMarker = [IO.File]::ReadAllText($verified)
            [IO.File]::WriteAllText($verified, $validVerifiedMarker + "`n", $Utf8NoBom)
            try {
                Confirm-BackupAcceptanceSidecars (Join-Path $BackupDirectory $acceptanceId) $acceptanceId $acceptanceStateSha "oscar:test"
                throw "PowerShell VERIFIED marker accepted more than one final LF"
            } catch {
                if ($_.Exception.Message -eq "PowerShell VERIFIED marker accepted more than one final LF") { throw }
                if ($_.Exception.Message -notlike "*VERIFIED marker is malformed*") { throw }
            }
            foreach ($encoding in $nonCanonicalMetadataEncodings) {
                [IO.File]::WriteAllText($verified, $validVerifiedMarker, $encoding)
                try {
                    Confirm-BackupAcceptanceSidecars (Join-Path $BackupDirectory $acceptanceId) $acceptanceId $acceptanceStateSha "oscar:test"
                    throw "PowerShell VERIFIED marker accepted noncanonical BOM or UTF-16 bytes"
                } catch {
                    if ($_.Exception.Message -eq "PowerShell VERIFIED marker accepted noncanonical BOM or UTF-16 bytes") { throw }
                    if ($_.Exception.Message -notlike "*VERIFIED marker is malformed*") { throw }
                }
            }
            [IO.File]::WriteAllText($verified, $validVerifiedMarker, $Utf8NoBom)
            [IO.File]::WriteAllText($journalReceipt, "forged receipt`n", $Utf8NoBom)
            try {
                Confirm-BackupAcceptanceSidecars (Join-Path $BackupDirectory $acceptanceId) $acceptanceId $acceptanceStateSha "oscar:test"
                throw "PowerShell accepted a forged VERIFIED marker without a valid journal receipt"
            } catch {
                if ($_.Exception.Message -eq "PowerShell accepted a forged VERIFIED marker without a valid journal receipt") { throw }
            }
            [IO.File]::WriteAllText($journalReceipt, $validJournalReceipt, $Utf8NoBom)
            Remove-Item -LiteralPath $verified -Force
            function Write-VerifiedMarker([string]$Root) { throw "read-only wrote VERIFIED" }
            function Set-VerifiedBackupEpochReceipt([string]$Root,[string]$Id,[string]$EpochId,[string]$PostgresLsn) { throw "read-only wrote catalog" }
            function Assert-BackupCleanupAcl([string]$Path, [string]$Description) {}
            $acceptanceRoot = Join-Path $BackupDirectory $acceptanceId
            $acceptanceTemporary = Join-Path $acceptanceRoot ".VERIFIED.0123456789abcdef0123456789abcdef"
            [IO.File]::WriteAllText($acceptanceTemporary, "interrupted acceptance publication", $Utf8NoBom)
            Confirm-Backup $acceptanceId -ReadOnly
            if ((Test-Path -LiteralPath $verified) -or -not (Test-Path -LiteralPath $acceptanceTemporary -PathType Leaf)) {
                throw "PowerShell read-only verification mutated acceptance state"
            }
            Remove-BackupAcceptanceTemporaries $acceptanceRoot $acceptanceId
            if (Test-Path -LiteralPath $acceptanceTemporary) {
                throw "PowerShell did not recover a safe crash-left acceptance temporary"
            }
            $unsafeAcceptanceTemporary = Join-Path $acceptanceRoot ".JOURNAL_CONFIRMED.0123456789abcdef0123456789abcdef"
            [IO.Directory]::CreateDirectory($unsafeAcceptanceTemporary) | Out-Null
            try {
                Confirm-Backup $acceptanceId -ReadOnly
                throw "PowerShell core verification ignored an unsafe acceptance temporary"
            } catch {
                if ($_.Exception.Message -eq "PowerShell core verification ignored an unsafe acceptance temporary") { throw }
                if ($_.Exception.Message -notlike "*Backup acceptance temporary is unsafe*") { throw }
            } finally {
                Remove-Item -LiteralPath $unsafeAcceptanceTemporary -Recurse -Force
            }

            $foreignGuard = Join-Path $env:STORAGE_SCRIPT_TEST_ROOT "FOREIGN-GUARD-RAN-PS"
            $unsafeForeignVerified = Join-Path $env:STORAGE_SCRIPT_TEST_ROOT "UNSAFE-FOREIGN-VERIFIED-PS"
            $unsafeForeignCatalog = Join-Path $env:STORAGE_SCRIPT_TEST_ROOT "UNSAFE-FOREIGN-CATALOG-PS"
            function Get-ComposeOutput([string[]]$Arguments) { return @("postgres") }
            function Assert-DeploymentVolumeOwnership {
                [IO.File]::WriteAllText($foreignGuard, "guard")
                throw "foreign deployment"
            }
            function Write-VerifiedMarker([string]$Root) { [IO.File]::WriteAllText($unsafeForeignVerified, "unsafe") }
            function Set-VerifiedBackupEpochReceipt([string]$Root,[string]$Id,[string]$EpochId,[string]$PostgresLsn) {
                [IO.File]::WriteAllText($unsafeForeignCatalog, "unsafe")
            }
            try {
                Confirm-Backup $acceptanceId
                throw "PowerShell backup verification accepted a running foreign deployment"
            } catch {
                if ($_.Exception.Message -eq "PowerShell backup verification accepted a running foreign deployment") { throw }
            }
            if (-not (Test-Path -LiteralPath $foreignGuard -PathType Leaf) -or
                (Test-Path -LiteralPath $unsafeForeignVerified) -or
                (Test-Path -LiteralPath $unsafeForeignCatalog)) {
                throw "PowerShell foreign-volume guard ran after acceptance/catalog mutation"
            }

            # Validator failure must precede the UID-10001 extraction launch.
            $journalExtraction = Join-Path $env:STORAGE_SCRIPT_TEST_ROOT "UNSAFE-JOURNAL-EXTRACTION"
            function Get-ComposeOutput([string[]]$Arguments) { return @("postgres") }
            function Invoke-Compose([string[]]$Arguments) {}
            function Invoke-DockerShellInput([string]$InputText, [string[]]$Arguments) {
                if ($InputText -match "/validate-storage-archive\.sh oscar-state") {
                    throw "deliberate scoped validator failure"
                }
                [IO.File]::WriteAllText($journalExtraction, "extraction launched")
            }
            function Invoke-External([string]$File, [string[]]$Arguments) {}
            $journalStateHash = (Get-FileHash -LiteralPath (Join-Path (Join-Path $BackupDirectory $acceptanceId) "oscar-state.tar.gz") -Algorithm SHA256).Hash.ToLowerInvariant()
            try {
                Confirm-DailyJournalBackup $acceptanceId (Join-Path $BackupDirectory $acceptanceId) "oscar:test" $journalStateHash
                throw "PowerShell journal bridge ignored scoped validator failure"
            } catch {
                if ($_.Exception.Message -eq "PowerShell journal bridge ignored scoped validator failure") { throw }
            }
            if (Test-Path -LiteralPath $journalExtraction) { throw "PowerShell journal bridge extracted before archive validation" }

            $journalIsolationCapture = Join-Path $env:STORAGE_SCRIPT_TEST_ROOT "journal-confirmation-java.args"
            function Get-ComposeOutput([string[]]$Arguments) { return @("postgres") }
            function Invoke-Compose([string[]]$Arguments) {
                if ($Arguments.Count -gt 0 -and $Arguments[0] -ceq "run") {
                    throw "PowerShell journal confirmation used the Compose service container"
                }
            }
            function Invoke-DockerShellInput([string]$InputText, [string[]]$Arguments) {}
            function Invoke-External([string]$File, [string[]]$Arguments) {
                $joined = $Arguments -join " "
                if ($joined -match "--entrypoint java") {
                    [IO.File]::WriteAllText($journalIsolationCapture, $joined)
                }
            }
            Confirm-DailyJournalBackup $acceptanceId (Join-Path $BackupDirectory $acceptanceId) "oscar:test" $journalStateHash
            if (-not (Test-Path -LiteralPath $journalIsolationCapture -PathType Leaf)) {
                throw "PowerShell journal confirmation did not launch its isolated Java container"
            }
            $journalIsolationArguments = [IO.File]::ReadAllText($journalIsolationCapture)
            foreach ($required in @(
                "--network none --read-only --cap-drop ALL --security-opt no-new-privileges",
                "--tmpfs /tmp:rw,noexec,nosuid,nodev --user 10001:10001 --entrypoint java",
                "--volume oscar_oscar_state:/var/lib/oscar")) {
                if (-not $journalIsolationArguments.Contains($required)) {
                    throw "PowerShell journal confirmation lacks isolated container argument: $required"
                }
            }

            # Inject a verifier failure and prove creation cannot reach live
            # journal confirmation or its audit sidecar before core VERIFIED.
            $unsafeJournalConfirmation = Join-Path $env:STORAGE_SCRIPT_TEST_ROOT "UNSAFE-LIVE-JOURNAL-CONFIRMATION-PS"
            function Confirm-Backup([string]$Id, [switch]$ReadOnly) { throw "injected immutable-core verification failure" }
            function Confirm-DailyJournalBackup([string]$Id, [string]$Root, [string]$Image, [string]$OscarStateSha256) {
                [IO.File]::WriteAllText($unsafeJournalConfirmation, "unsafe")
            }
            function Write-JournalConfirmationReceipt([string]$Root, [string]$Id, [string]$OscarStateSha256, [string]$Image) {
                [IO.File]::WriteAllText("$unsafeJournalConfirmation.receipt", "unsafe")
            }
            try {
                Complete-NewBackupAcceptance $acceptanceId "unused" "oscar:test" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                throw "PowerShell backup acceptance ignored an injected core-verification failure"
            } catch {
                if ($_.Exception.Message -eq "PowerShell backup acceptance ignored an injected core-verification failure") { throw }
            }
            if ((Test-Path -LiteralPath $unsafeJournalConfirmation) -or (Test-Path -LiteralPath "$unsafeJournalConfirmation.receipt")) {
                throw "PowerShell backup confirmed live journal retention before core VERIFIED acceptance"
            }

            $preflightId = "20261017T130000Z-deadbeef"
            $preflightBackupDirectory = Join-Path $credentialLive "preflight-backups"
            [IO.Directory]::CreateDirectory((Join-Path $preflightBackupDirectory $preflightId)) | Out-Null
            $preflightPayload = Join-Path $env:STORAGE_SCRIPT_TEST_ROOT "invalid-restored-credentials-powershell"
            [IO.Directory]::CreateDirectory((Join-Path $preflightPayload "secrets")) | Out-Null
            [IO.File]::WriteAllLines((Join-Path $preflightPayload ".env"), $installedBindings, $Utf8NoBom)
            [IO.File]::WriteAllText((Join-Path $preflightPayload "secrets/source.key"), "incomplete")
            $preflightComposeMarker = Join-Path $env:STORAGE_SCRIPT_TEST_ROOT "preflight-compose-powershell"
            $ScriptRoot = $credentialLive
            $BackupDirectory = $preflightBackupDirectory
            $BackupKeyFile = Join-Path $credentialLive "secrets/backup-key.txt"
            function Assert-Administrator {}
            function Assert-Configured {}
            function Assert-BackupKey {}
            function Assert-DeploymentVolumeOwnership {}
            function Assert-RestoreCompatibility([string]$Root) {}
            function Confirm-Backup([string]$Id, [switch]$ConfirmJournal) {}
            function Invoke-Compose([string[]]$Arguments) {
                [IO.File]::WriteAllText($preflightComposeMarker, ($Arguments -join " "))
            }
            function Invoke-DockerShellInput([string]$InputText, [string[]]$Arguments) {
                $mount = @($Arguments | Where-Object { $_ -like "*:/restore" } | Select-Object -First 1)
                if ($mount.Count -ne 1) { throw "Restore mock did not receive a staging mount" }
                $restorePath = $mount[0].Substring(0, $mount[0].Length - ":/restore".Length)
                Copy-Item -LiteralPath (Join-Path $preflightPayload ".env"), (Join-Path $preflightPayload "secrets") -Destination $restorePath -Recurse
            }
            function Invoke-External([string]$File, [string[]]$Arguments) {}
            try {
                Restore-Backup $preflightId $preflightId
                throw "PowerShell restore accepted an incomplete staged credential set"
            } catch {
                if ($_.Exception.Message -eq "PowerShell restore accepted an incomplete staged credential set") { throw }
            }
            if ((Test-Path -LiteralPath $preflightComposeMarker) -or
                (Test-Path -LiteralPath (Join-Path $credentialLive "pre-restore-$preflightId"))) {
                throw "PowerShell restore reached a destructive operation before credential preflight completed"
            }
        '

    STORAGE_SCRIPT_TEST_ROOT="$test_root" STORAGE_SCRIPT_PATH="$powershell_script" \
        pwsh -NoLogo -NoProfile -Command '
            $ErrorActionPreference = "Stop"
            . $env:STORAGE_SCRIPT_PATH -Command help *> $null
            $deployment = "12345678-1234-4234-8234-123456789abc"
            function Assert-Administrator {}
            function Protect-AdministratorFile([string]$Path) {}
            function Assert-AdministratorFile([string]$Path, [string]$Description) {
                if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$Description is missing" }
                if (((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw "$Description is a reparse point"
                }
            }
            function Protect-PrivateDirectory([string]$Path) {}
            function Protect-DockerStorageDirectory([string]$Path, [string]$DockerAccess) {}
            function Protect-DockerReadableAdministratorFile([string]$Path) {}

            $identityBase = Join-Path $env:STORAGE_SCRIPT_TEST_ROOT "root-identity-powershell"
            $ScriptRoot = Join-Path $identityBase "release"
            $ArchiveDirectory = Join-Path $identityBase "roots/archive"
            $BackupDirectory = Join-Path $identityBase "roots/backups"
            $WalArchiveDirectory = Join-Path $identityBase "roots/wal"
            [IO.Directory]::CreateDirectory($ScriptRoot) | Out-Null
            foreach ($directory in @($ArchiveDirectory, $BackupDirectory, $WalArchiveDirectory)) {
                [IO.Directory]::CreateDirectory($directory) | Out-Null
            }
            [IO.File]::WriteAllLines((Join-Path $ScriptRoot ".env"), @(
                "OSCAR_VERSION=3.11.0", "OSCAR_DEPLOYMENT_ID=$deployment",
                "OSCAR_BACKUP_MODE=single",
                "OSCAR_ARCHIVE_DIR=$ArchiveDirectory", "OSCAR_BACKUP_DIR=$BackupDirectory",
                "OSCAR_WAL_ARCHIVE_DIR=$WalArchiveDirectory", "OSCAR_SECRETS_DIR=./secrets",
                "OSCAR_TLS_DIR=./tls", "OSCAR_BACKUP_KEY_FILE=./secrets/backup-key.txt"
            ), $Utf8NoBom)
            [IO.File]::WriteAllText((Join-Path $ArchiveDirectory "legacy-object"), "legacy")
            try {
                Initialize-StorageDirectories
                throw "PowerShell implicitly adopted a nonempty unclaimed storage root"
            } catch {
                if ($_.Exception.Message -eq "PowerShell implicitly adopted a nonempty unclaimed storage root") { throw }
            }
            if (Test-Path -LiteralPath (Join-Path $ArchiveDirectory ".oscar-storage-root")) {
                throw "PowerShell partially claimed roots before rejecting implicit adoption"
            }
            Initialize-StorageDirectories -AdoptExisting
            $archiveMarker = Join-Path $ArchiveDirectory ".oscar-storage-root"
            $backupMarker = Join-Path $BackupDirectory ".oscar-storage-root"
            $archiveLines = @([IO.File]::ReadAllLines($archiveMarker))
            if ($archiveLines.Count -ne 8 -or
                @($archiveLines | Where-Object { $_ -ceq "format=oscar-storage-root-identity" }).Count -ne 1 -or
                @($archiveLines | Where-Object { $_ -ceq "version=1" }).Count -ne 1 -or
                @($archiveLines | Where-Object { $_ -ceq "deployment_id=$deployment" }).Count -ne 1 -or
                @($archiveLines | Where-Object { $_ -ceq "root_kind=archive" }).Count -ne 1 -or
                @($archiveLines | Where-Object { $_ -ceq "adoption=explicit-existing" }).Count -ne 1 -or
                @([IO.File]::ReadAllLines($backupMarker) | Where-Object { $_ -ceq "adoption=new" }).Count -ne 1) {
                throw "PowerShell storage-root identities do not have the exact version-1/adoption schema"
            }
            Assert-StorageRootIdentities
            $validMarker = [IO.File]::ReadAllText($archiveMarker)
            [IO.File]::WriteAllText($archiveMarker, $validMarker.Replace("root_kind=archive", "root_kind=backup"))
            try {
                Assert-StorageRootIdentity $ArchiveDirectory "archive"
                throw "PowerShell accepted a swapped storage root"
            } catch { if ($_.Exception.Message -eq "PowerShell accepted a swapped storage root") { throw } }
            [IO.File]::WriteAllText($archiveMarker, $validMarker.Replace($deployment, "87654321-4321-4321-8321-cba987654321"))
            try {
                Assert-StorageRootIdentity $ArchiveDirectory "archive"
                throw "PowerShell accepted a foreign storage root"
            } catch { if ($_.Exception.Message -eq "PowerShell accepted a foreign storage root") { throw } }

            $helperBase = Join-Path $env:STORAGE_SCRIPT_TEST_ROOT "archive-helper-wrapper-powershell"
            $ArchiveDirectory = Join-Path $helperBase "archive"
            $exportRoot = Join-Path $helperBase "export"
            [IO.Directory]::CreateDirectory($ArchiveDirectory) | Out-Null
            [IO.Directory]::CreateDirectory($exportRoot) | Out-Null
            function Get-OscarImage { return "oscar:test" }
            $script:HelperArguments = @()
            function Get-ExternalOutput([string]$Program, [string[]]$Arguments) {
                $script:HelperArguments = @($Arguments)
                if ($Arguments -contains "delete") { return @("DELETED") }
                return @()
            }
            $null = Invoke-ArchiveObjectHelper "copy" "datasets/ok/object.parquet" ("a" * 64) "ro" $exportRoot
            foreach ($required in @(
                "run", "--rm", "--network", "none", "--read-only", "--cap-drop", "ALL",
                "--security-opt", "no-new-privileges", "/usr/local/bin/oscar-archive-object",
                "${ArchiveDirectory}:/archive:ro", "${exportRoot}:/export", "oscar:test", "copy")) {
                if ($script:HelperArguments -notcontains $required) { throw "PowerShell archive helper omitted argument: $required" }
            }
            $deleteResult = Invoke-ArchiveObjectHelper "delete" "datasets/ok/object.parquet" ("a" * 64) "rw"
            if ($deleteResult -cne "DELETED" -or $script:HelperArguments -notcontains "${ArchiveDirectory}:/archive:rw" -or
                @($script:HelperArguments | Where-Object { $_ -ceq "--volume" }).Count -ne 1) {
                throw "PowerShell archive delete helper mounts more than the writable archive root or lost its outcome"
            }

            $exportBase = Join-Path $env:STORAGE_SCRIPT_TEST_ROOT "archive-export-powershell"
            $ArchiveDirectory = Join-Path $exportBase "archive"
            [IO.Directory]::CreateDirectory($ArchiveDirectory) | Out-Null
            $StoreKey = "obs"; $IdScope = "1"
            $script:ComposeCalls = New-Object System.Collections.Generic.List[string]
            function Get-ComposeOutput([string[]]$Arguments) {
                if ($Arguments[0] -ceq "ps") { return @("oscar") }
                return @()
            }
            function Invoke-Compose([string[]]$Arguments) { $script:ComposeCalls.Add(($Arguments -join " ")) }
            function Invoke-PsqlLines([string]$Sql) { return @("datasets/ok/object.parquet`t$("a" * 64)") }
            function Invoke-Psql([string]$Sql, [switch]$Table) {
                if ($Sql -like "*json_agg*") { return "[]" }
                return "{`"id`":`"generation`"}"
            }
            function Invoke-ArchiveObjectHelper(
                [string]$Operation, [string]$Relative, [string]$ExpectedSha256,
                [string]$ArchiveAccess, [string]$ExportRoot = "") {
                if ($Operation -cne "copy" -or $ArchiveAccess -cne "ro" -or -not $ExportRoot) { throw "unsafe helper request" }
                $destination = Join-Path $ExportRoot ($Relative.Replace("/", [IO.Path]::DirectorySeparatorChar))
                [IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
                [IO.File]::WriteAllText($destination, "copied through helper")
            }
            $successTarget = Join-Path $exportBase "success/export"
            Export-ArchiveGeneration "12345678-1234-4234-8234-123456789abc" $successTarget
            if (-not (Test-Path -LiteralPath (Join-Path $successTarget "datasets/ok/object.parquet") -PathType Leaf) -or
                $script:ComposeCalls -notcontains "stop oscar" -or
                $script:ComposeCalls -notcontains "up --detach --no-deps --no-build --pull never --wait --wait-timeout 300 oscar") {
                throw "PowerShell archive export did not use helper quiescence/resume semantics"
            }
            $script:ComposeCalls.Clear()
            function Invoke-ArchiveObjectHelper(
                [string]$Operation, [string]$Relative, [string]$ExpectedSha256,
                [string]$ArchiveAccess, [string]$ExportRoot = "") { throw "deliberate helper race failure" }
            $failureTarget = Join-Path $exportBase "failure/export"
            try {
                Export-ArchiveGeneration "12345678-1234-4234-8234-123456789abc" $failureTarget
                throw "PowerShell archive export ignored a helper failure"
            } catch {
                if ($_.Exception.Message -eq "PowerShell archive export ignored a helper failure") { throw }
            }
            if ($script:ComposeCalls -notcontains "stop oscar" -or
                $script:ComposeCalls -notcontains "up --detach --no-deps --no-build --pull never --wait --wait-timeout 300 oscar" -or
                (Test-Path -LiteralPath $failureTarget) -or
                @(Get-ChildItem -LiteralPath (Split-Path -Parent $failureTarget) -Filter ".export.partial-*" -ErrorAction SilentlyContinue).Count -ne 0) {
                throw "PowerShell failed archive export did not resume OSCAR and remove its fresh partial"
            }

            function Assert-BackupModeEnabled {}
            try {
                Remove-ExpiredBackups 2
                throw "PowerShell accepted the retired backup-prune operation"
            } catch {
                if ($_.Exception.Message -eq "PowerShell accepted the retired backup-prune operation") { throw }
                if ($_.Exception.Message -notlike "*backup-prune is retired*") {
                    throw "PowerShell backup-prune retirement guidance changed unexpectedly"
                }
            }
            exit 0
        '

    STORAGE_SCRIPT_TEST_ROOT="$test_root" STORAGE_SCRIPT_PATH="$powershell_script" \
        pwsh -NoLogo -NoProfile -Command '
            $ErrorActionPreference = "Stop"
            . $env:STORAGE_SCRIPT_PATH -Command help *> $null

            $BackupDirectory = Join-Path $env:STORAGE_SCRIPT_TEST_ROOT "single-recovery-no-current-powershell"
            [IO.Directory]::CreateDirectory($BackupDirectory) | Out-Null
            $confirmBackupImplementation = ${function:Confirm-Backup}
            $moveDurableNoReplaceImplementation = ${function:Move-DurableNoReplace}
            function Assert-Administrator {}
            function Assert-Configured {}
            function Assert-BackupKey {}
            function Assert-BackupModeEnabled {}
            function Assert-StorageRootIdentity([string]$Root, [string]$Kind) {}
            function Assert-BackupCleanupAcl([string]$Path, [string]$Description) {}
            function Sync-DurableMetadata([string]$Path) {}

            $rootOverrideProbeId = "20261020T110000Z-00000000"
            $rootOverrideProbe = Join-Path $BackupDirectory ".deleting-$rootOverrideProbeId"
            try {
                & $confirmBackupImplementation -Id $rootOverrideProbeId -ReadOnly -RootOverride $rootOverrideProbe
                throw "PowerShell accepted a missing deletion snapshot"
            } catch {
                if ($_.Exception.Message -notlike "Backup does not exist:*") {
                    throw "PowerShell did not permit the confined read-only deletion snapshot root"
                }
            }
            try {
                & $confirmBackupImplementation -Id $rootOverrideProbeId -RootOverride $rootOverrideProbe
                throw "PowerShell permitted a writable deletion snapshot root"
            } catch {
                if ($_.Exception.Message -eq "PowerShell permitted a writable deletion snapshot root") { throw }
                if ($_.Exception.Message -notlike "Backup verification root is not a confined*") {
                    throw "PowerShell writable deletion-root rejection changed unexpectedly"
                }
            }

            $script:AuthenticatedRecoveryCandidates = New-Object System.Collections.Generic.List[string]
            $script:CorruptCurrentAcceptance = $false
            function Confirm-Backup(
                [string]$Id,
                [switch]$ReadOnly,
                [string]$RootOverride,
                [switch]$RequireAcceptance
            ) {
                if (-not $ReadOnly -or -not $RequireAcceptance -or $RootOverride) {
                    throw "CURRENT recovery did not request strict read-only acceptance verification"
                }
                if ($script:CorruptCurrentAcceptance) { throw "corrupt CURRENT journal-confirmation receipt" }
            }
            function Get-BackupCleanupDisposition([string]$Id, [string]$Root) {
                $classificationPath = Join-Path $Root "cleanup-state.txt"
                if (-not (Test-Path -LiteralPath $classificationPath -PathType Leaf)) {
                    return [pscustomobject]@{ State = "Preserve"; Reason = "incomplete or unauthenticated core" }
                }
                $state = [IO.File]::ReadAllText($classificationPath)
                $script:AuthenticatedRecoveryCandidates.Add("$Id|$([IO.Path]::GetFileName($Root))|$state")
                if ($state -ceq "Accepted") {
                    return [pscustomobject]@{ State = "Accepted"; Reason = "authenticated accepted schema-version-2 recovery point" }
                }
                if ($state -ceq "Legacy") {
                    return [pscustomobject]@{ State = "Legacy"; Reason = "legacy schema-version-1 recovery point" }
                }
                return [pscustomobject]@{ State = "Preserve"; Reason = $state }
            }
            function New-RecoveryCandidate([string]$Name, [string]$CleanupState) {
                $root = Join-Path $BackupDirectory $Name
                [IO.Directory]::CreateDirectory($root) | Out-Null
                [IO.File]::WriteAllText((Join-Path $root "cleanup-state.txt"), $CleanupState)
            }
            $script:RecoveryMoveDestinations = New-Object System.Collections.Generic.List[string]
            function Move-DurableNoReplace([string]$Source, [string]$Destination) {
                $script:RecoveryMoveDestinations.Add([IO.Path]::GetFileName($Destination))
                & $moveDurableNoReplaceImplementation -Source $Source -Destination $Destination
            }

            $danglingCurrentCandidate = "20261020T111000Z-00000001"
            New-RecoveryCandidate $danglingCurrentCandidate 2
            $danglingTarget = Join-Path $BackupDirectory ".missing-current-target"
            $danglingPointer = Join-Path $BackupDirectory "CURRENT"
            [IO.File]::WriteAllText($danglingTarget, "temporary symlink target")
            New-Item -ItemType SymbolicLink -Path $danglingPointer -Target $danglingTarget | Out-Null
            Remove-Item -LiteralPath $danglingTarget -Force
            $literalPointer = @(Get-ChildItem -LiteralPath $BackupDirectory -Force |
                Where-Object { $_.Name -ceq "CURRENT" })
            if ($literalPointer.Count -ne 1 -or
                ($literalPointer[0].Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
                throw "PowerShell dangling-CURRENT fixture did not create a literal reparse entry"
            }
            try {
                Invoke-SingleBackupRecoveryCleanup
                throw "PowerShell treated a dangling CURRENT reparse entry as absent"
            } catch {
                if ($_.Exception.Message -eq "PowerShell treated a dangling CURRENT reparse entry as absent") { throw }
                if ($_.Exception.Message -notlike "CURRENT backup pointer is a reparse point*") {
                    throw "PowerShell dangling CURRENT rejection changed unexpectedly"
                }
            }
            if (-not (Test-Path -LiteralPath (Join-Path $BackupDirectory $danglingCurrentCandidate) -PathType Container) -or
                $script:AuthenticatedRecoveryCandidates.Count -ne 0) {
                throw "PowerShell mutated a backup candidate after a dangling CURRENT reparse entry"
            }
            [IO.File]::Delete($danglingPointer)
            Remove-Item -LiteralPath (Join-Path $BackupDirectory $danglingCurrentCandidate) -Recurse -Force

            $script:CurrentRecoveryId = $null
            function Read-CurrentBackupId([switch]$AllowMissing) { return $script:CurrentRecoveryId }
            function Write-CurrentBackupPointer([string]$Id, [string]$Image) {
                $script:CurrentRecoveryId = $Id
                [IO.File]::WriteAllText((Join-Path $BackupDirectory "CURRENT"), "fixture")
            }
            function Get-OscarImage { return "oscar:test" }

            $v2FinalA = "20261020T120000Z-11111111"
            $v2FinalB = "20261020T130000Z-22222222"
            $v2Tombstone = "20261020T140000Z-33333333"
            $v1Final = "20261020T150000Z-44444444"
            $v1Tombstone = "20261020T160000Z-55555555"
            $v2UncommittedTombstone = "20261020T170000Z-66666666"
            New-RecoveryCandidate $v2FinalA "Accepted"
            $adoptedAcceptanceTemporary = Join-Path (Join-Path $BackupDirectory $v2FinalA) ".VERIFIED.0123456789abcdef0123456789abcdef"
            [IO.File]::WriteAllText($adoptedAcceptanceTemporary, "interrupted acceptance publication")
            New-RecoveryCandidate $v2FinalB "failed finalized schema-version-2 core"
            New-RecoveryCandidate ".deleting-$v2Tombstone" "forged VERIFIED marker without valid receipt"
            New-RecoveryCandidate $v1Final "Legacy"
            New-RecoveryCandidate ".deleting-$v1Tombstone" "Legacy"
            $partialUncommittedTombstone = Join-Path $BackupDirectory ".deleting-uncommitted-v2-$v2UncommittedTombstone"
            [IO.Directory]::CreateDirectory($partialUncommittedTombstone) | Out-Null
            [IO.File]::WriteAllText((Join-Path $partialUncommittedTombstone "partially-removed-payload"), "fragment")

            $partialId = "20261020T180000Z-77777777"
            New-RecoveryCandidate "$partialId.partial" "incomplete partial"
            $firstWarnings = @(Invoke-SingleBackupRecoveryCleanup 3>&1 | ForEach-Object { [string]$_ })
            if ($script:CurrentRecoveryId -cne $v2FinalA -or
                -not (Test-Path -LiteralPath (Join-Path $BackupDirectory $v2FinalA) -PathType Container) -or
                (Test-Path -LiteralPath $adoptedAcceptanceTemporary)) {
                throw "PowerShell did not adopt the sole accepted schema-version-2 candidate as CURRENT"
            }
            foreach ($preserved in @(
                    $v2FinalB, ".deleting-$v2Tombstone", ".deleting-uncommitted-v2-$v2UncommittedTombstone",
                    "$partialId.partial", $v1Final, $v1Tombstone)) {
                if (-not (Test-Path -LiteralPath (Join-Path $BackupDirectory $preserved) -PathType Container)) {
                    throw "PowerShell removed a failed, forged, partial, uncommitted, or legacy recovery candidate: $preserved"
                }
            }
            if (Test-Path -LiteralPath (Join-Path $BackupDirectory ".deleting-$v1Tombstone")) {
                throw "PowerShell left a restored schema-version-1 backup in tombstone form"
            }
            foreach ($warningText in @(
                    "Preserving backup candidate for operator review",
                    "Preserving backup deletion tombstone for operator review",
                    "Preserving legacy schema-version-1 recovery point",
                    "Preserving incomplete backup staging candidate",
                    "Preserving legacy uncommitted schema-version-2 deletion tombstone")) {
                if (-not (($firstWarnings -join "`n").Contains($warningText))) {
                    throw "PowerShell cleanup did not emit preservation warning: $warningText"
                }
            }

            $acceptedTombstone = "20261020T190000Z-88888888"
            New-RecoveryCandidate ".deleting-$acceptedTombstone" "Accepted"
            Invoke-SingleBackupRecoveryCleanup 3>$null
            if (Test-Path -LiteralPath (Join-Path $BackupDirectory ".deleting-$acceptedTombstone")) {
                throw "PowerShell retained a fully authenticated accepted deletion tombstone"
            }
            foreach ($preserved in @($v2FinalB, ".deleting-$v2Tombstone", $v1Final, $v1Tombstone, "$partialId.partial")) {
                if (-not (Test-Path -LiteralPath (Join-Path $BackupDirectory $preserved) -PathType Container)) {
                    throw "PowerShell post-CURRENT cleanup removed an unauthorized recovery candidate: $preserved"
                }
            }

            $corruptReceiptCandidate = "20261020T200000Z-99999999"
            New-RecoveryCandidate $corruptReceiptCandidate "Accepted"
            $script:CorruptCurrentAcceptance = $true
            try {
                Invoke-SingleBackupRecoveryCleanup 3>$null
                throw "PowerShell cleanup accepted CURRENT with a corrupt journal-confirmation receipt"
            } catch {
                if ($_.Exception.Message -eq "PowerShell cleanup accepted CURRENT with a corrupt journal-confirmation receipt") { throw }
                if ($_.Exception.Message -notlike "*corrupt CURRENT journal-confirmation receipt*") { throw }
            }
            if (-not (Test-Path -LiteralPath (Join-Path $BackupDirectory $corruptReceiptCandidate) -PathType Container)) {
                throw "PowerShell mutated a candidate after CURRENT acceptance verification failed"
            }

            $BackupDirectory = Join-Path $env:STORAGE_SCRIPT_TEST_ROOT "single-recovery-ambiguous-powershell"
            [IO.Directory]::CreateDirectory($BackupDirectory) | Out-Null
            $script:CurrentRecoveryId = $null
            $script:CorruptCurrentAcceptance = $false
            $ambiguousA = "20261020T210000Z-aaaaaaaa"
            $ambiguousB = "20261020T220000Z-bbbbbbbb"
            New-RecoveryCandidate $ambiguousA "Accepted"
            New-RecoveryCandidate $ambiguousB "Accepted"
            $ambiguousPointerTemp = Join-Path $BackupDirectory ".CURRENT.tmp.0123456789abcdef0123456789abcdef"
            [IO.File]::WriteAllText($ambiguousPointerTemp, "interrupted pointer evidence")
            $ambiguousScratch = Join-Path $BackupDirectory ".journal-confirm-$ambiguousA-0123456789abcdef0123456789abcdef"
            [IO.Directory]::CreateDirectory($ambiguousScratch) | Out-Null
            try {
                Invoke-SingleBackupRecoveryCleanup 3>$null
                throw "PowerShell cleanup chose between multiple accepted candidates without CURRENT"
            } catch {
                if ($_.Exception.Message -eq "PowerShell cleanup chose between multiple accepted candidates without CURRENT") { throw }
                if ($_.Exception.Message -notlike "*Cannot reconstruct CURRENT unambiguously*") { throw }
            }
            foreach ($preserved in @($ambiguousA, $ambiguousB)) {
                if (-not (Test-Path -LiteralPath (Join-Path $BackupDirectory $preserved) -PathType Container)) {
                    throw "PowerShell ambiguous no-CURRENT cleanup removed accepted candidate: $preserved"
                }
            }
            if (-not (Test-Path -LiteralPath $ambiguousPointerTemp -PathType Leaf) -or
                -not (Test-Path -LiteralPath $ambiguousScratch -PathType Container)) {
                throw "PowerShell ambiguous no-CURRENT cleanup removed crash evidence before failing closed"
            }
        ' >/dev/null

    legacy_binding_powershell="$test_root/legacy-binding-powershell"
    legacy_custom_powershell="$test_root/legacy-binding-custom-powershell"
    legacy_duplicate_powershell="$test_root/legacy-binding-duplicate-powershell"
    current_missing_powershell="$test_root/current-binding-missing-powershell"
    legacy_upgrade_path_powershell="$test_root/legacy-upgrade-path-powershell"
    legacy_duplicate_root_powershell="$test_root/legacy-duplicate-root-powershell"
    mkdir -p "$legacy_binding_powershell" "$legacy_custom_powershell" \
        "$legacy_duplicate_powershell" "$current_missing_powershell" \
        "$legacy_upgrade_path_powershell" "$legacy_duplicate_root_powershell"
    write_391_env_fixture "$legacy_binding_powershell/.env"
    write_391_env_fixture "$legacy_custom_powershell/.env"
    write_391_env_fixture "$legacy_duplicate_powershell/.env"
    write_391_env_fixture "$current_missing_powershell/.env"
    write_391_env_fixture "$legacy_upgrade_path_powershell/.env"
    write_391_env_fixture "$legacy_duplicate_root_powershell/.env"
    printf 'OSCAR_BACKUP_KEY_FILE=C:\\source\\keys\\backup-key.txt\n' >>"$legacy_custom_powershell/.env"
    printf 'OSCAR_BACKUP_KEY_FILE=./secrets/backup-key.txt\nOSCAR_BACKUP_KEY_FILE=./secrets/backup-key.txt\n' >>"$legacy_duplicate_powershell/.env"
    sed -i.bak 's/^OSCAR_VERSION=3\.9\.1$/OSCAR_VERSION=3.11.0/' "$current_missing_powershell/.env"
    rm -f "$current_missing_powershell/.env.bak"
    printf 'OSCAR_ARCHIVE_DIR=C:\\one\nOSCAR_ARCHIVE_DIR=C:\\two\n' >>"$legacy_duplicate_root_powershell/.env"
    STORAGE_SETUP_PATH="$setup_powershell_script" \
    LEGACY_BINDING_FIXTURE="$legacy_binding_powershell" \
    LEGACY_CUSTOM_FIXTURE="$legacy_custom_powershell" \
    LEGACY_DUPLICATE_FIXTURE="$legacy_duplicate_powershell" \
    CURRENT_MISSING_FIXTURE="$current_missing_powershell" \
        pwsh -NoLogo -NoProfile -Command '
            $ErrorActionPreference = "Stop"
            . $env:STORAGE_SETUP_PATH -Command help *> $null
            function Expect-BindingFailure([string]$Description) {
                try {
                    Assert-CanonicalCredentialBindings
                    throw "UNEXPECTED-SUCCESS:$Description"
                } catch {
                    if ($_.Exception.Message -eq "UNEXPECTED-SUCCESS:$Description") { throw }
                }
            }

            $ScriptRoot = $env:LEGACY_BINDING_FIXTURE
            [void](Initialize-UpgradeBackupMode)
            Initialize-LegacyBackupKeyBinding
            Assert-CanonicalCredentialBindings
            $matches = @([IO.File]::ReadAllLines((Join-Path $ScriptRoot ".env")) |
                Where-Object { $_ -ceq "OSCAR_BACKUP_KEY_FILE=./secrets/backup-key.txt" })
            if ($matches.Count -ne 1) { throw "PowerShell did not add exactly one canonical legacy backup-key binding" }

            $ScriptRoot = $env:LEGACY_CUSTOM_FIXTURE
            [void](Initialize-UpgradeBackupMode)
            Initialize-LegacyBackupKeyBinding
            Expect-BindingFailure "custom backup-key binding"
            $matches = @([IO.File]::ReadAllLines((Join-Path $ScriptRoot ".env")) |
                Where-Object { $_ -ceq "OSCAR_BACKUP_KEY_FILE=C:\source\keys\backup-key.txt" })
            if ($matches.Count -ne 1) { throw "PowerShell overwrote a custom backup-key binding" }

            $ScriptRoot = $env:LEGACY_DUPLICATE_FIXTURE
            [void](Initialize-UpgradeBackupMode)
            Initialize-LegacyBackupKeyBinding
            Expect-BindingFailure "duplicate backup-key bindings"
            $matches = @([IO.File]::ReadAllLines((Join-Path $ScriptRoot ".env")) |
                Where-Object { $_ -match "^OSCAR_BACKUP_KEY_FILE=" })
            if ($matches.Count -ne 2) { throw "PowerShell collapsed duplicate backup-key bindings" }

            $ScriptRoot = $env:CURRENT_MISSING_FIXTURE
            [void](Initialize-UpgradeBackupMode)
            Initialize-LegacyBackupKeyBinding
            Expect-BindingFailure "current release missing backup-key binding"
            $matches = @([IO.File]::ReadAllLines((Join-Path $ScriptRoot ".env")) |
                Where-Object { $_ -match "^OSCAR_BACKUP_KEY_FILE=" })
            if ($matches.Count -ne 0) { throw "PowerShell inserted a missing binding into a current-release environment" }
        '

    STORAGE_SETUP_PATH="$setup_powershell_script" \
    LEGACY_UPGRADE_FIXTURE="$legacy_upgrade_path_powershell" \
    LEGACY_DUPLICATE_ROOT_FIXTURE="$legacy_duplicate_root_powershell" \
        pwsh -NoLogo -NoProfile -Command '
            $ErrorActionPreference = "Stop"
            . $env:STORAGE_SETUP_PATH -Command help *> $null
            $ScriptRoot = $env:LEGACY_UPGRADE_FIXTURE
            Assert-UpgradeableEnvironmentBindings
            [void](Initialize-UpgradeBackupMode)
            Initialize-LegacyBackupKeyBinding
            Assert-CanonicalCredentialBindings
            function Invoke-ExternalProbe([scriptblock]$Action) { return $true }
            function Get-VolumeDeploymentLabel([string]$Volume) { return "" }
            function Get-DockerOutput([string[]]$Arguments) {
                $volume = $Arguments[-1]
                $created = if ($volume -ceq "oscar_oscar_state") { "2026-01-01T00:00:00Z" } else { "2026-01-02T00:00:00Z" }
                $record = [pscustomobject]@{ Name = $volume; CreatedAt = $created; Labels = $null }
                return ConvertTo-Json -InputObject @($record) -Compress
            }
            Assert-DeploymentVolumeOwnership $true
            Initialize-StoragePaths
            Assert-UniqueLiteralEnvironmentKeys
            Set-EnvValue "OSCAR_VERSION" "3.11.0"
            Assert-ManagedEnvironmentBindings
            $lines = [IO.File]::ReadAllLines((Join-Path $ScriptRoot ".env"))
            foreach ($name in @("OSCAR_VERSION", "OSCAR_DEPLOYMENT_ID", "OSCAR_ARCHIVE_DIR", "OSCAR_BACKUP_MODE", "OSCAR_BACKUP_DIR")) {
                if (@($lines | Where-Object { $_.StartsWith("$name=", [StringComparison]::Ordinal) }).Count -ne 1) {
                    throw "PowerShell legacy upgrade did not normalize exactly one $name binding"
                }
            }

            $ScriptRoot = $env:LEGACY_DUPLICATE_ROOT_FIXTURE
            try {
                Assert-UpgradeableEnvironmentBindings
                throw "UNEXPECTED-SUCCESS:duplicate optional storage binding"
            } catch {
                if ($_.Exception.Message -eq "UNEXPECTED-SUCCESS:duplicate optional storage binding") { throw }
            }
            exit 0
        '

    skip_start_powershell="$test_root/skip-start-powershell"
    mkdir -p "$skip_start_powershell"
    printf 'OSCAR_DEPLOYMENT_ID=%s\n' "$deployment_id" >"$skip_start_powershell/.env"
    printf 'format=oscar-init-state\nversion=1\ndeployment_id=%s\nstate=INITIALIZING\n' "$deployment_id" >"$skip_start_powershell/.oscar-init-state"
    STORAGE_SETUP_PATH="$setup_powershell_script" STORAGE_SETUP_TEST_ROOT="$skip_start_powershell" \
        pwsh -NoLogo -NoProfile -Command '
            $ErrorActionPreference = "Stop"
            . $env:STORAGE_SETUP_PATH -Command help *> $null
            $ScriptRoot = $env:STORAGE_SETUP_TEST_ROOT
            $deployment = "12345678-1234-4234-8234-123456789abc"
            $script:Volumes = @{}
            function docker {
                $dockerArgs = @($args)
                if ($dockerArgs.Count -ge 3 -and $dockerArgs[0] -ceq "volume" -and $dockerArgs[1] -ceq "inspect") {
                    $volume = if ($dockerArgs.Count -ge 5 -and $dockerArgs[2] -ceq "--format") { $dockerArgs[4] } else { $dockerArgs[2] }
                    if (-not $script:Volumes.ContainsKey($volume)) { $global:LASTEXITCODE = 1; return }
                    if ($dockerArgs.Count -ge 5 -and $dockerArgs[2] -ceq "--format") { $deployment }
                    else {
                        $record = [pscustomobject]@{
                            Name = $volume
                            CreatedAt = "2026-01-01T00:00:00Z"
                            Labels = [pscustomobject]@{ "com.botts.oscar.deployment-id" = $deployment }
                        }
                        ConvertTo-Json -InputObject @($record) -Compress
                    }
                    $global:LASTEXITCODE = 0
                    return
                }
                if ($dockerArgs.Count -eq 5 -and $dockerArgs[0] -ceq "volume" -and $dockerArgs[1] -ceq "create" -and
                    $dockerArgs[2] -ceq "--label" -and $dockerArgs[3] -ceq "com.botts.oscar.deployment-id=$deployment") {
                    $script:Volumes[$dockerArgs[4]] = $true
                    $dockerArgs[4]
                    $global:LASTEXITCODE = 0
                    return
                }
                $global:LASTEXITCODE = 1
            }
            Initialize-FreshDeploymentVolumes
            Assert-DeploymentVolumeOwnership $false
            Initialize-FreshDeploymentVolumes
            if (-not $script:Volumes.ContainsKey("oscar_oscar_state") -or -not $script:Volumes.ContainsKey("oscar_postgres_data")) {
                throw "PowerShell skip-start initialization did not create both labelled named volumes"
            }
            exit 0
        ' >/dev/null

    ps_volume_root="$test_root/volume-ownership-powershell"
    mkdir -p "$ps_volume_root"
    STORAGE_SETUP_TEST_ROOT="$ps_volume_root" STORAGE_SETUP_PATH="$setup_powershell_script" \
        pwsh -NoLogo -NoProfile -Command '
            $ErrorActionPreference = "Stop"
            . $env:STORAGE_SETUP_PATH -Command help *> $null
            $ScriptRoot = $env:STORAGE_SETUP_TEST_ROOT
            $deployment = "12345678-1234-4234-8234-123456789abc"
            $script:MockDeployment = $deployment
            function Get-ConfiguredEnvValue([string]$Name) { return $script:MockDeployment }
            function Invoke-ExternalProbe([scriptblock]$Action) { return $true }
            function Expect-Failure([scriptblock]$Action, [string]$Description) {
                try { & $Action; throw "UNEXPECTED-SUCCESS:$Description" }
                catch { if ($_.Exception.Message -eq "UNEXPECTED-SUCCESS:$Description") { throw } }
            }

            $script:MockStateLabel = $deployment; $script:MockPostgresLabel = $deployment
            function Get-VolumeDeploymentLabel([string]$Volume) {
                if ($Volume -ceq "oscar_oscar_state") { return $script:MockStateLabel }
                return $script:MockPostgresLabel
            }
            Assert-DeploymentVolumeOwnership $false

            $script:MockPostgresLabel = "87654321-4321-4321-8321-cba987654321"
            Expect-Failure { Assert-DeploymentVolumeOwnership $false } "mixed volume labels"

            function Invoke-ExternalProbe([scriptblock]$Action) { return $false }
            Expect-Failure { Assert-DeploymentVolumeOwnership $false } "missing volume"

            function Invoke-ExternalProbe([scriptblock]$Action) { return $true }
            $script:MockStateLabel = ""; $script:MockPostgresLabel = ""
            Expect-Failure { Assert-DeploymentVolumeOwnership $false } "unacknowledged legacy volumes"

            $script:MockStateCreated = "2026-01-01T00:00:00Z"
            $script:MockPostgresCreated = "2026-01-02T00:00:00Z"
            function Get-DockerOutput([string[]]$Arguments) {
                $volume = $Arguments[-1]
                $created = if ($volume -ceq "oscar_oscar_state") { $script:MockStateCreated } else { $script:MockPostgresCreated }
                $record = [pscustomobject]@{ Name = $volume; CreatedAt = $created; Labels = $null }
                return ConvertTo-Json -InputObject @($record) -Compress
            }
            Assert-DeploymentVolumeOwnership $true
            $receipt = Join-Path $ScriptRoot ".oscar-volume-adoption"
            if (-not (Test-Path -LiteralPath $receipt -PathType Leaf)) { throw "PowerShell legacy adoption did not create its receipt" }
            Assert-DeploymentVolumeOwnership $false
            $script:MockPostgresCreated = "2026-01-03T00:00:00Z"
            if (Test-VolumeAdoptionReceipt $deployment) { throw "PowerShell adoption receipt accepted a changed volume creation identity" }
        '

    ps_lock_root="$test_root/ps-lock"
    mkdir -p "$ps_lock_root"
    printf 'OSCAR_DEPLOYMENT_ID=%s\n' "$deployment_id" >"$ps_lock_root/.env"
    ps_lock_ready="$ps_lock_root/ready"
    OSCAR_STORAGE_TEST_MODE=1 OSCAR_STORAGE_LOCK_DIR="$ps_lock_root/stable-locks" STORAGE_SCRIPT_TEST_ROOT="$ps_lock_root" STORAGE_SCRIPT_PATH="$powershell_script" STORAGE_LOCK_READY="$ps_lock_ready" \
        pwsh -NoLogo -NoProfile -Command '
            . $env:STORAGE_SCRIPT_PATH -Command help *> $null
            $Command = "backup"
            $ScriptRoot = $env:STORAGE_SCRIPT_TEST_ROOT
            function Assert-NoReparseComponents([string]$FullPath, [switch]$AllowMissingLeaf) {}
            function Protect-PrivateDirectory([string]$Path) {}
            function Protect-DockerStorageDirectory([string]$Path, [string]$DockerAccess) {}
            function Protect-AdministratorFile([string]$Path) {}
            function Assert-AdministratorFile([string]$Path, [string]$Description) {}
            try {
                Enter-StorageAdminLock
                [IO.File]::WriteAllText($env:STORAGE_LOCK_READY, "ready")
                Start-Sleep -Seconds 3
            } finally { Exit-StorageAdminLock }
        ' &
    ps_lock_holder=$!
    for _ in {1..50}; do [[ -e $ps_lock_ready ]] && break; sleep 0.1; done
    [[ -e $ps_lock_ready ]] || { printf 'PowerShell lock holder did not start.\n' >&2; exit 1; }
    if OSCAR_STORAGE_TEST_MODE=1 OSCAR_STORAGE_LOCK_DIR="$ps_lock_root/stable-locks" STORAGE_SCRIPT_TEST_ROOT="$ps_lock_root" STORAGE_SCRIPT_PATH="$powershell_script" \
        pwsh -NoLogo -NoProfile -Command '
            . $env:STORAGE_SCRIPT_PATH -Command help *> $null
            $Command = "backup"
            $ScriptRoot = $env:STORAGE_SCRIPT_TEST_ROOT
            function Assert-NoReparseComponents([string]$FullPath, [switch]$AllowMissingLeaf) {}
            function Protect-PrivateDirectory([string]$Path) {}
            function Protect-DockerStorageDirectory([string]$Path, [string]$DockerAccess) {}
            function Protect-AdministratorFile([string]$Path) {}
            function Assert-AdministratorFile([string]$Path, [string]$Description) {}
            try { Enter-StorageAdminLock; exit 0 } catch { exit 1 } finally { Exit-StorageAdminLock }
        '; then
        printf 'PowerShell storage lock allowed a concurrent command.\n' >&2
        exit 1
    fi
    wait "$ps_lock_holder"
fi

assert_contains 'LOCK TABLE oscar_retention_hold IN SHARE ROW EXCLUSIVE MODE' "$powershell_script"
assert_contains "SET state='DELETING'" "$powershell_script"
assert_contains "'run', '--rm', '--network', 'none', '--read-only', '--cap-drop', 'ALL', '--cap-add', 'DAC_READ_SEARCH', '--security-opt', 'no-new-privileges', '--workdir', '/', '--user', '0:0', '--entrypoint', 'pg_verifybackup'" "$powershell_script"
assert_not_contains "'--user', '999:999', '--entrypoint', 'pg_verifybackup'" "$powershell_script"
assert_contains 'SHA256SUMS\.hmac' "$powershell_script"
assert_contains 'cannot be accepted as an authenticated \$RequiredReleaseVersion recovery point' "$powershell_script"
assert_contains 'RequiredReleaseVersion = \$releaseVersionLine' "$powershell_script"
assert_contains 'Confirm-BackupArchiveMembers' "$powershell_script"
assert_contains '^[[:space:]]+Confirm-ArchiveObjects -RejectPartials$' "$powershell_script"
assert_contains "tar --exclude='\./archive' --exclude='\./backups' --exclude='\./duckdb-tmp'" "$powershell_script"
assert_contains 'Confirm-ImageInventory \$Root -CompareCurrent' "$powershell_script"
assert_contains 'Enter-StorageAdminLock' "$powershell_script"
assert_contains "'run', '--rm', '--network', 'none', '--read-only', '--cap-drop', 'ALL'" "$powershell_script"
assert_contains 'Invoke-ArchiveObjectHelper '\''copy'\'' \$fields\[0\] \$fields\[1\] '\''ro'\'' \$partial' "$powershell_script"
assert_contains 'Invoke-ArchiveObjectHelper '\''delete'\'' \$fields\[1\] \$fields\[2\] '\''rw'\''' "$powershell_script"
assert_contains "Invoke-Compose @\('stop', 'oscar'\)" "$powershell_script"
assert_contains "'up', '--detach', '--no-deps', '--no-build', '--pull', 'never', '--wait', '--wait-timeout', '300', 'oscar'" "$powershell_script"
assert_contains 'DELETE FROM oscar_obs_overlay' "$powershell_script"
assert_contains "subject_type='OBSERVATION'" "$powershell_script"
assert_contains 'overlay_row\.generation_id=item\.generation_id' "$powershell_script"
assert_contains 'DailyFileBackupConfirmationCli' "$powershell_script"
assert_contains "state IN \('ACTIVE','DELETING'\)" "$powershell_script"
assert_contains 'markerItem\.Attributes.*ReparsePoint' "$powershell_script"
assert_contains 'Assert-StorageRootsReady' "$powershell_script"
assert_contains 'Prepare-RestoredDeploymentCredentials' "$powershell_script"
assert_contains 'Install-PreparedDeploymentCredentials' "$powershell_script"
assert_contains 'INSERT INTO oscar_retention_hold\(id,store_key,id_scope' "$powershell_script"
assert_contains 'resolution_mode' "$powershell_script"
assert_contains "THEN 'GENERATION_EXACT'" "$powershell_script"
assert_contains "THEN 'HOT_EXACT'" "$powershell_script"
assert_contains "THEN 'COLD_RANGE_CONSERVATIVE'" "$powershell_script"
assert_contains 'FROM "\$StoreKey" any_hot_row' "$powershell_script"
assert_contains 'FROM "\$StoreKey" exact_hot_row' "$powershell_script"
assert_contains 'oscar_archive_id_block retired_block' "$powershell_script"
assert_contains '\[long\]::TryParse\(\$Value, \[ref\]\$parsed\)' "$powershell_script"
assert_contains 'INSERT INTO oscar_deletion_plan\(id,store_key,id_scope' "$powershell_script"
assert_contains 'JOIN oscar_deletion_plan p ON p\.id=i\.plan_id' "$powershell_script"
assert_contains 'g\.store_key=p\.store_key AND g\.id_scope=p\.id_scope' "$powershell_script"
assert_contains 'ON CONFLICT \(subject_type,store_key,id_scope,subject_id\)' "$powershell_script"
assert_contains 'archive purge -StoreKey \$StoreKey -IdScope \$IdScope' "$powershell_script"
assert_contains "VALUES \('OBSERVATIONS_PARQUET'\),\('GENERATION_MANIFEST'\),\('DATASTREAM_SCHEMAS'\)" "$powershell_script"
assert_contains "g\.state IN \('ACTIVE','SEALED'\)" "$powershell_script"
assert_contains 'chr\(31\)' "$powershell_script"
assert_not_contains "E'\\\\\\\\t'" "$powershell_script"
assert_contains "\\\$fields\[3\] -cne '1' -or \\\$fields\[4\] -cne 'ACTIVE'" "$powershell_script"
assert_contains "\\\$fields\[5\] -cne \\\$fields\[7\] -or \\\$fields\[6\] -cne \\\$fields\[8\]" "$powershell_script"
assert_contains "\\\$fields\[2\] -ceq 'GENERATION_MANIFEST'.*\\\$fields\[5\] -cne \\\$fields\[9\]" "$powershell_script"
assert_contains 'Archive catalog changed during verification' "$powershell_script"
assert_contains 'SELECT \* FROM required_rows UNION ALL SELECT \* FROM additional_rows' "$powershell_script"
assert_contains 'UNION ALL SELECT \* FROM invalid_owner_rows' "$powershell_script"
assert_contains "WHERE o\.state='ACTIVE' AND g\.state NOT IN \('ACTIVE','SEALED'\)" "$powershell_script"
assert_not_contains 'h\.subject_id::numeric BETWEEN g\.min_id AND g\.max_id' "$powershell_script"
assert_not_contains 'h\.subject_id::numeric BETWEEN held_block\.min_id AND held_block\.max_id' "$powershell_script"
assert_not_contains "numericSubject'::numeric" "$powershell_script"

# Backup generation UUIDs remain only in the authenticated file. Both launchers
# stream and frame that file, then persist only a compact count/hash/byte receipt.
for compact_script in "$shell_script" "$powershell_script"; do
    assert_not_contains '(^|[^A-Za-z0-9_])archive_generation_ids([^A-Za-z0-9_]|$)' "$compact_script"
    assert_contains 'archive_generation_count IS NOT DISTINCT FROM EXCLUDED\.archive_generation_count' "$compact_script"
    assert_contains 'archive_generation_inventory_sha256 IS NOT DISTINCT FROM EXCLUDED\.archive_generation_inventory_sha256' "$compact_script"
    assert_contains 'archive_generation_inventory_bytes IS NOT DISTINCT FROM EXCLUDED\.archive_generation_inventory_bytes' "$compact_script"
done
assert_contains 'ORDER BY id LIMIT \$\(\(max_backup_archive_generation_ids \+ 1\)\)' "$shell_script"
assert_contains 'ORDER BY id LIMIT \$\(\$MaxBackupArchiveGenerationIds \+ 1\)' "$powershell_script"
assert_contains 'bytes == count \* 37' "$shell_script"
assert_contains '\$bytesRead -ne \(\$count \* 37\)' "$powershell_script"
assert_contains 'stat -c %s -- "\$file"' "$shell_script"
bash_inventory_body=$(awk '/^validate_archive_generation_inventory\(\)/,/^write_archive_generation_inventory\(\)/' "$shell_script")
if grep -Eq 'wc -c|sort -c|awk |uuid\[\]|archive_generation_ids_sql' <<<"$bash_inventory_body"; then
    printf 'Bash archive-generation receipt still materializes or serializes the UUID inventory.\n' >&2
    exit 1
fi
ps_inventory_body=$(awk '/^function Get-ArchiveGenerationInventory/,/^function Write-ArchiveGenerationInventory/' "$powershell_script")
if grep -Eq 'ReadAllBytes|ReadAllLines| -split | -join |Invoke-PsqlLines|uuid\[\]' <<<"$ps_inventory_body"; then
    printf 'PowerShell archive-generation receipt still materializes or serializes the UUID inventory.\n' >&2
    exit 1
fi
ps_inventory_capture_body=$(awk '/^function Write-ArchiveGenerationInventory/,/^function Set-VerifiedBackupEpochReceipt/' "$powershell_script")
if ! grep -Fq 'Write-PsqlLinesToFile' <<<"$ps_inventory_capture_body" ||
   grep -Eq 'Invoke-PsqlLines|ReadAllBytes|ReadAllLines| -split | -join ' <<<"$ps_inventory_capture_body"; then
    printf 'PowerShell archive-generation capture does not stream PostgreSQL output directly to its file.\n' >&2
    exit 1
fi
bash_inventory_capture_body=$(awk '/^write_archive_generation_inventory\(\)/,/^upsert_verified_backup_epoch\(\)/' "$shell_script")
if ! grep -Eq 'psql_admin .* >?"?\$file"|>\"?\$file\"?' <<<"$bash_inventory_capture_body" ||
   grep -Eq '\$\([^)]*psql_admin|paste -sd|uuid\[\]' <<<"$bash_inventory_capture_body"; then
    printf 'Bash archive-generation capture does not stream PostgreSQL output directly to its file.\n' >&2
    exit 1
fi
assert_contains '\$writer\.NewLine = "`n"' "$powershell_script"

# Windows reconciliation must never collect the complete catalog or candidate
# set in RAM. It streams both PostgreSQL snapshots to disk, external-sorts in a
# fixed-size buffer, pairwise-merges runs, and compares two sorted readers.
assert_not_contains '^function Get-RegisteredArchivePaths' "$powershell_script"
assert_contains '^\$ArchiveAuditSortChunkLines = 4096$' "$powershell_script"
assert_contains '^function ConvertTo-ArchiveAuditSortedUniqueFile' "$powershell_script"
assert_contains '^function Compare-ArchiveAuditSortedFiles' "$powershell_script"
ps_reconcile_body=$(awk '/^function Test-ArchiveFilesystemRegistration/,/^function Protect-PrivateDirectory/' "$powershell_script")
if grep -Eq 'Collections\.Generic\.HashSet|New-Object System\.Collections\.Generic\.List\[string\]|Invoke-PsqlLines' <<<"$ps_reconcile_body"; then
    printf 'PowerShell archive reconciliation still materializes a full catalog/candidate collection.\n' >&2
    exit 1
fi
for operation in \
    'Write-RegisteredArchivePaths $catalogFirstRaw' \
    'Write-RegisteredArchivePaths $catalogSecondRaw' \
    'ConvertTo-ArchiveAuditSortedUniqueFile $candidateRaw $candidateSorted' \
    'Compare-ArchiveAuditSortedFiles $candidateSorted $catalogMerged' \
    '[IO.Directory]::EnumerateFileSystemEntries'; do
    grep -Fq -- "$operation" <<<"$ps_reconcile_body" || {
        printf 'PowerShell archive reconciliation is missing bounded operation: %s\n' "$operation" >&2
        exit 1
    }
done
assert_contains 'Assert-DeploymentVolumeOwnership \(\[bool\]\$AdoptLegacyVolumes\)' "$setup_powershell_script"
assert_contains 'preserve \.oscar-volume-adoption' "$setup_powershell_script"
assert_contains 'Assert-CanonicalCredentialBindings' "$setup_powershell_script"

bash_restore_decrypt=$(grep -n "openssl enc -d .*tar -C /restore" "$shell_script" | tail -n 1 | cut -d: -f1)
bash_restore_prepare=$(grep -n 'prepare_restored_credentials_exact "\$restore_temp"' "$shell_script" | tail -n 1 | cut -d: -f1)
bash_restore_stop=$(grep -n '^[[:space:]]*stop_deployment_ordered$' "$shell_script" | tail -n 1 | cut -d: -f1)
[[ -n $bash_restore_decrypt && -n $bash_restore_prepare && -n $bash_restore_stop &&
   $bash_restore_decrypt -lt $bash_restore_prepare && $bash_restore_prepare -lt $bash_restore_stop ]] || {
    printf 'Bash restore does not validate staged credentials before destructive Compose operations.\n' >&2
    exit 1
}

ps_restore_decrypt=$(grep -n "openssl enc -d .*tar -C /restore" "$powershell_script" | tail -n 1 | cut -d: -f1)
ps_restore_prepare=$(grep -n 'Prepare-RestoredDeploymentCredentials \$restoreTemp' "$powershell_script" | tail -n 1 | cut -d: -f1)
ps_restore_stop=$(grep -n '^[[:space:]]*Stop-DeploymentOrdered$' "$powershell_script" | tail -n 1 | cut -d: -f1)
[[ -n $ps_restore_decrypt && -n $ps_restore_prepare && -n $ps_restore_stop &&
   $ps_restore_decrypt -lt $ps_restore_prepare && $ps_restore_prepare -lt $ps_restore_stop ]] || {
    printf 'PowerShell restore does not validate staged credentials before destructive Compose operations.\n' >&2
    exit 1
}

bash_backup_stop=$(grep -n '\$resume_oscar && compose stop oscar' "$shell_script" | head -n 1 | cut -d: -f1)
bash_backup_archive_verify=$(grep -n '^[[:space:]]*archive_verify reject-partials$' "$shell_script" | head -n 1 | cut -d: -f1)
bash_backup_snapshot=$(grep -n 'pg_basebackup --pgdata=' "$shell_script" | head -n 1 | cut -d: -f1)
[[ -n $bash_backup_stop && -n $bash_backup_archive_verify && -n $bash_backup_snapshot &&
   $bash_backup_stop -lt $bash_backup_archive_verify && $bash_backup_archive_verify -lt $bash_backup_snapshot ]] || {
    printf 'Bash backup does not verify the quiesced archive before snapshot creation.\n' >&2
    exit 1
}

ps_backup_stop=$(grep -n "Invoke-Compose @('stop', 'oscar')" "$powershell_script" | head -n 1 | cut -d: -f1)
ps_backup_archive_verify=$(grep -n '^[[:space:]]*Confirm-ArchiveObjects -RejectPartials$' "$powershell_script" | head -n 1 | cut -d: -f1)
ps_backup_snapshot=$(grep -n 'pg_basebackup --pgdata=' "$powershell_script" | head -n 1 | cut -d: -f1)
[[ -n $ps_backup_stop && -n $ps_backup_archive_verify && -n $ps_backup_snapshot &&
   $ps_backup_stop -lt $ps_backup_archive_verify && $ps_backup_archive_verify -lt $ps_backup_snapshot ]] || {
    printf 'PowerShell backup does not verify the quiesced archive before snapshot creation.\n' >&2
    exit 1
}

bash_accept_body=$(awk '/^accept_and_confirm_created_backup\(\)/,/^create_backup\(\)/' "$shell_script")
bash_accept_verify=$(grep -n -m1 'verify_backup "\$backup_id"' <<<"$bash_accept_body" | cut -d: -f1)
bash_accept_confirm=$(grep -n -m1 'confirm_daily_journal_backup' <<<"$bash_accept_body" | cut -d: -f1)
bash_accept_receipt=$(grep -n -m1 'write_journal_confirmation_receipt' <<<"$bash_accept_body" | cut -d: -f1)
bash_create_body=$(awk '/^create_backup\(\)/,/^verify_backup\(\)/' "$shell_script")
bash_checksums=$(grep -n -m1 'find \. -type f ! -name SHA256SUMS' <<<"$bash_create_body" | cut -d: -f1)
bash_publish=$(grep -n -m1 'publish_export_directory "\$work" "\$final"' <<<"$bash_create_body" | cut -d: -f1)
bash_accept=$(grep -n -m1 'accept_and_confirm_created_backup' <<<"$bash_create_body" | cut -d: -f1)
[[ -n $bash_accept_verify && -n $bash_accept_confirm && -n $bash_accept_receipt &&
   -n $bash_checksums && -n $bash_publish && -n $bash_accept &&
   $bash_checksums -lt $bash_publish && $bash_publish -lt $bash_accept &&
   $bash_accept_verify -lt $bash_accept_confirm && $bash_accept_confirm -lt $bash_accept_receipt ]] || {
    printf 'Bash backup does not verify the authenticated published core before live journal confirmation.\n' >&2
    exit 1
}
ps_accept_body=$(awk '/^function Complete-NewBackupAcceptance/,/^function New-Backup/' "$powershell_script")
ps_accept_verify=$(grep -n -m1 'Confirm-Backup \$Id' <<<"$ps_accept_body" | cut -d: -f1)
ps_accept_confirm=$(grep -n -m1 'Confirm-DailyJournalBackup' <<<"$ps_accept_body" | cut -d: -f1)
ps_accept_receipt=$(grep -n -m1 'Write-JournalConfirmationReceipt' <<<"$ps_accept_body" | cut -d: -f1)
ps_create_body=$(awk '/^function New-Backup/,/^function Confirm-BackupManifestInventory/' "$powershell_script")
ps_checksums=$(grep -n -m1 'Write-Checksums \$work' <<<"$ps_create_body" | cut -d: -f1)
ps_publish=$(grep -n -m1 'Move-DurableNoReplace \$work \$final' <<<"$ps_create_body" | cut -d: -f1)
ps_accept=$(grep -n -m1 'Complete-NewBackupAcceptance' <<<"$ps_create_body" | cut -d: -f1)
[[ -n $ps_accept_verify && -n $ps_accept_confirm && -n $ps_accept_receipt &&
   -n $ps_checksums && -n $ps_publish && -n $ps_accept &&
   $ps_checksums -lt $ps_publish && $ps_publish -lt $ps_accept &&
   $ps_accept_verify -lt $ps_accept_confirm && $ps_accept_confirm -lt $ps_accept_receipt ]] || {
    printf 'PowerShell backup does not verify the authenticated published core before live journal confirmation.\n' >&2
    exit 1
}

printf 'OSCAR storage script safety tests passed.\n'
