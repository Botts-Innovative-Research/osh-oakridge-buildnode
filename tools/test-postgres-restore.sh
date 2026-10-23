#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
docker info >/dev/null 2>&1 || {
    printf 'Docker is required for the PostgreSQL restore drill.\n' >&2
    exit 1
}

suffix="$$-$(date -u +%Y%m%d%H%M%S)"
image="oscar-postgis:restore-test-$suffix"
source_container="oscar-restore-source-$suffix"
restored_container="oscar-restore-target-$suffix"
data_volume="oscar_restore_data_$suffix"
backup_volume="oscar_restore_backup_$suffix"
corrupt_backup_volume="oscar_restore_corrupt_backup_$suffix"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/oscar-postgres-restore.XXXXXX")
password='oscar-restore-test-password'
epoch_id='12345678-1234-4234-8234-123456789abc'
backup_id='20261017T120000Z-1234abcd'
epoch_sha='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
generation_inventory_count=2
generation_inventory_bytes=74
if command -v sha256sum >/dev/null 2>&1; then
    generation_inventory_sha=$(printf '%s\n%s\n' \
        11111111-1111-4111-8111-111111111111 \
        22222222-2222-4222-8222-222222222222 | sha256sum | awk '{print $1}')
else
    generation_inventory_sha=$(printf '%s\n%s\n' \
        11111111-1111-4111-8111-111111111111 \
        22222222-2222-4222-8222-222222222222 | shasum --algorithm 256 | awk '{print $1}')
fi

cleanup() {
    docker rm -f "$source_container" "$restored_container" >/dev/null 2>&1 || true
    docker volume rm "$data_volume" "$backup_volume" "$corrupt_backup_volume" >/dev/null 2>&1 || true
    docker image rm "$image" >/dev/null 2>&1 || true
    rm -rf -- "$scratch"
}
trap cleanup EXIT HUP INT TERM

printf '%s\n' "$password" >"$scratch/oscar-db-password.txt"
chmod 0644 "$scratch/oscar-db-password.txt"

docker build --quiet --platform linux/amd64 --build-arg OSCAR_VERSION=3.9.2 --tag "$image" \
    "$repo_root/dist/release/postgis" >/dev/null
for volume in "$data_volume" "$backup_volume" "$corrupt_backup_volume"; do
    docker volume create "$volume" >/dev/null
done

# Named volumes start root-owned. All production-equivalent backup and restore
# work below runs capability-free as PostgreSQL UID/GID 999 after this exact
# test-only ownership bootstrap.
for volume in "$backup_volume" "$corrupt_backup_volume"; do
    docker run --rm --network none --user 0:0 --cap-drop ALL --cap-add CHOWN \
        --security-opt no-new-privileges --entrypoint chown --volume "$volume:/target" \
        "$image" 999:999 /target
    docker run --rm --network none --user 999:999 --cap-drop ALL \
        --security-opt no-new-privileges --entrypoint chmod --volume "$volume:/target" \
        "$image" 0700 /target
done

postgres_arguments=(
    postgres
    -c password_encryption=scram-sha-256
    -c archive_mode=off
)

docker run --detach --name "$source_container" --read-only \
    --tmpfs /tmp:rw,noexec,nosuid,nodev --tmpfs /var/run/postgresql:rw,noexec,nosuid,nodev \
    --env POSTGRES_PASSWORD="$password" --env POSTGRES_USER=postgres --env POSTGRES_DB=gis \
    --env OSCAR_DB_PASSWORD_FILE=/run/secrets/oscar_db_password \
    --volume "$scratch/oscar-db-password.txt:/run/secrets/oscar_db_password:ro" \
    --volume "$data_volume:/var/lib/postgresql/data" \
    "$image" "${postgres_arguments[@]}" >/dev/null

wait_ready() {
    local container=$1 attempt first_start second_start
    for attempt in {1..90}; do
        if docker exec "$container" test -f /var/lib/postgresql/data/.oscar-data-checksum-init >/dev/null 2>&1 &&
           docker exec --env PGPASSWORD="$password" "$container" \
            pg_isready --username postgres --dbname gis >/dev/null 2>&1; then
            # Initialization briefly starts a bootstrap postmaster. Require one
            # stable start timestamp so the test cannot stop that temporary server.
            first_start=$(docker exec --env PGPASSWORD="$password" "$container" \
                psql --set=ON_ERROR_STOP=1 --quiet --tuples-only --no-align \
                --username postgres --dbname gis --command 'SELECT pg_postmaster_start_time();' 2>/dev/null || true)
            sleep 2
            second_start=$(docker exec --env PGPASSWORD="$password" "$container" \
                psql --set=ON_ERROR_STOP=1 --quiet --tuples-only --no-align \
                --username postgres --dbname gis --command 'SELECT pg_postmaster_start_time();' 2>/dev/null || true)
            if [[ -n $first_start && $first_start == "$second_start" ]]; then
                return 0
            fi
        fi
        sleep 1
    done
    docker logs "$container" >&2 || true
    printf 'PostgreSQL container did not become ready: %s\n' "$container" >&2
    return 1
}

psql_value() {
    local container=$1 sql=$2
    docker exec --env PGPASSWORD="$password" "$container" \
        psql --set=ON_ERROR_STOP=1 --quiet --tuples-only --no-align \
        --username postgres --dbname gis --command "$sql" | tr -d '[:space:]'
}

assert_no_wal_mount() {
    local container=$1
    if docker inspect --format '{{range .Mounts}}{{println .Destination}}{{end}}' "$container" |
        grep -Fxq /var/lib/postgresql/wal-archive; then
        printf 'PostgreSQL unexpectedly received an external WAL archive mount: %s\n' "$container" >&2
        exit 1
    fi
}

assert_archiving_disabled() {
    local container=$1 settings mode command timeout
    settings=$(psql_value "$container" \
        "SELECT current_setting('archive_mode')||'|'||current_setting('archive_command')||'|'||current_setting('archive_timeout');")
    IFS='|' read -r mode command timeout <<<"$settings"
    [[ $mode == off && $timeout == 0 && ( -z $command || $command == '(disabled)' ) ]] || {
        printf 'PostgreSQL archiving settings drifted from off/disabled/zero: %s\n' "$settings" >&2
        exit 1
    }
    assert_no_wal_mount "$container"
}

wait_ready "$source_container"
assert_archiving_disabled "$source_container"
psql_value "$source_container" "
CREATE TABLE public.restore_probe(id integer PRIMARY KEY);
INSERT INTO public.restore_probe VALUES (1);
CREATE TABLE oscar.oscar_backup_epoch (
 id uuid PRIMARY KEY, state text NOT NULL, postgres_lsn pg_lsn,
 archive_generation_count bigint NOT NULL CHECK (archive_generation_count BETWEEN 0 AND 1000000),
 archive_generation_inventory_sha256 text NOT NULL CHECK (archive_generation_inventory_sha256 ~ '^[0-9a-f]{64}$'),
 archive_generation_inventory_bytes bigint NOT NULL CHECK (
   archive_generation_inventory_bytes BETWEEN 0 AND 37000000
   AND archive_generation_inventory_bytes = archive_generation_count * 37),
 manifest_path text,
 sha256 text, created_at timestamptz NOT NULL DEFAULT now(), verified_at timestamptz);" >/dev/null
source_timeline=$(psql_value "$source_container" 'SELECT timeline_id FROM pg_control_checkpoint();')
backup_lsn=$(psql_value "$source_container" 'SELECT pg_current_wal_lsn();')

docker run --rm --network "container:$source_container" --read-only --cap-drop ALL \
    --security-opt no-new-privileges --tmpfs /tmp:rw,noexec,nosuid,nodev \
    --user 999:999 --entrypoint sh --volume "$backup_volume:/backup" \
    "$image" -eu -c "PGPASSWORD='$password'; export PGPASSWORD; exec pg_basebackup --pgdata=/backup --username=postgres --dbname='host=127.0.0.1 port=5432 dbname=gis' --format=plain --wal-method=stream --checkpoint=fast"

docker run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges \
    --user 999:999 --entrypoint pg_verifybackup --volume "$backup_volume:/backup:ro" \
    "$image" /backup >/dev/null

# Prove the streamed WAL is part of the authenticated base backup: removing one
# required segment must make pg_verifybackup fail before any live state changes.
docker run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges \
    --user 999:999 --entrypoint sh --volume "$backup_volume:/source:ro" \
    --volume "$corrupt_backup_volume:/target" "$image" -eu -c \
    'cp -a /source/. /target/; segment=$(find /target/pg_wal -maxdepth 1 -type f -name "????????????????????????" -print -quit); test -n "$segment"; rm -- "$segment"'
if docker run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges \
    --user 999:999 --entrypoint pg_verifybackup --volume "$corrupt_backup_volume:/backup:ro" \
    "$image" /backup >/dev/null 2>&1; then
    printf 'pg_verifybackup accepted a base backup missing required streamed WAL.\n' >&2
    exit 1
fi
[[ $(psql_value "$source_container" 'SELECT count(*) FROM public.restore_probe;') == 1 ]] || {
    printf 'Corrupt-backup verification changed the running source database.\n' >&2
    exit 1
}

# This row is deliberately after the backup endpoint and must not appear after
# restore. No external source/WAL dependency is available to the target.
psql_value "$source_container" 'INSERT INTO public.restore_probe VALUES (2); CHECKPOINT;' >/dev/null
docker rm -f "$source_container" >/dev/null

docker run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges \
    --user 999:999 --entrypoint sh --volume "$data_volume:/data" \
    --volume "$backup_volume:/backup:ro" "$image" -eu -c \
    'find /data -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +; cp -a /backup/. /data/'
prepared_timeline=$(docker run --rm --network none --read-only --cap-drop ALL \
    --security-opt no-new-privileges --user 999:999 --entrypoint /usr/local/bin/oscar-prepare-restore \
    --volume "$data_volume:/data" "$image" /data | tr -d '[:space:]')
[[ $prepared_timeline == "$source_timeline" ]] || {
    printf 'Restore helper emitted timeline %s, expected %s.\n' "$prepared_timeline" "$source_timeline" >&2
    exit 1
}

docker run --detach --name "$restored_container" --read-only --cap-drop ALL \
    --security-opt no-new-privileges --user 999:999 \
    --tmpfs /tmp:rw,noexec,nosuid,nodev --tmpfs /var/run/postgresql:rw,noexec,nosuid,nodev,uid=999,gid=999,mode=0770 \
    --volume "$data_volume:/var/lib/postgresql/data" \
    "$image" "${postgres_arguments[@]}" >/dev/null
wait_ready "$restored_container"
assert_archiving_disabled "$restored_container"

restored_timeline=$(psql_value "$restored_container" 'SELECT timeline_id FROM pg_control_checkpoint();')
[[ $restored_timeline =~ ^[1-9][0-9]*$ && $restored_timeline -gt $source_timeline ]] || {
    printf 'Restore did not promote from timeline %s (current %s).\n' "$source_timeline" "$restored_timeline" >&2
    exit 1
}
[[ $(psql_value "$restored_container" "SELECT count(*)||'|'||min(id)||'|'||max(id) FROM public.restore_probe;") == '1|1|1' ]] || {
    printf 'Restore did not stop at the self-contained base-backup endpoint.\n' >&2
    exit 1
}

receipt=$(psql_value "$restored_container" "
WITH upserted AS (
 INSERT INTO oscar.oscar_backup_epoch(id,state,postgres_lsn,archive_generation_count,archive_generation_inventory_sha256,archive_generation_inventory_bytes,manifest_path,sha256,verified_at)
 VALUES ('$epoch_id','VERIFIED','$backup_lsn',$generation_inventory_count,'$generation_inventory_sha',$generation_inventory_bytes,'$backup_id/epoch.json','$epoch_sha',now())
 ON CONFLICT (id) DO UPDATE SET state='VERIFIED',
  verified_at=CASE WHEN oscar.oscar_backup_epoch.state='VERIFIED' THEN oscar.oscar_backup_epoch.verified_at ELSE now() END
 WHERE oscar.oscar_backup_epoch.state IN ('CREATED','VERIFIED')
   AND oscar.oscar_backup_epoch.postgres_lsn IS NOT DISTINCT FROM EXCLUDED.postgres_lsn
   AND oscar.oscar_backup_epoch.archive_generation_count IS NOT DISTINCT FROM EXCLUDED.archive_generation_count
   AND oscar.oscar_backup_epoch.archive_generation_inventory_sha256 IS NOT DISTINCT FROM EXCLUDED.archive_generation_inventory_sha256
   AND oscar.oscar_backup_epoch.archive_generation_inventory_bytes IS NOT DISTINCT FROM EXCLUDED.archive_generation_inventory_bytes
   AND oscar.oscar_backup_epoch.manifest_path IS NOT DISTINCT FROM EXCLUDED.manifest_path
   AND oscar.oscar_backup_epoch.sha256 IS NOT DISTINCT FROM EXCLUDED.sha256
 RETURNING id::text||'|'||state)
SELECT * FROM upserted;")
[[ $receipt == "$epoch_id|VERIFIED" ]] || {
    printf 'Restored VERIFIED epoch receipt was not committed.\n' >&2
    exit 1
}
psql_value "$restored_container" 'INSERT INTO public.restore_probe VALUES (3); CHECKPOINT;' >/dev/null

# Recovery GUCs are startup settings. RESET plus a clean restart must remove
# their durable source while retaining the promoted timeline, receipt, and new write.
psql_value "$restored_container" 'ALTER SYSTEM RESET restore_command;' >/dev/null
psql_value "$restored_container" 'ALTER SYSTEM RESET recovery_target;' >/dev/null
psql_value "$restored_container" 'ALTER SYSTEM RESET recovery_target_timeline;' >/dev/null
psql_value "$restored_container" 'ALTER SYSTEM RESET recovery_target_action;' >/dev/null
psql_value "$restored_container" 'SELECT pg_reload_conf();' >/dev/null
docker stop "$restored_container" >/dev/null
docker run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges \
    --user 999:999 --entrypoint sh --volume "$data_volume:/data:ro" "$image" -eu -c '
        test ! -e /data/recovery.signal
        test ! -e /data/standby.signal
        test ! -e /data/postgresql.auto.conf ||
            ! grep -Eq "^[[:space:]]*(restore_command|recovery_target|recovery_target_timeline|recovery_target_action)[[:space:]]*=" /data/postgresql.auto.conf
    '
docker start "$restored_container" >/dev/null
wait_ready "$restored_container"
assert_archiving_disabled "$restored_container"

cleanup_status=$(psql_value "$restored_container" "SELECT CASE WHEN pg_is_in_recovery() THEN '1' ELSE '0' END||'|'||timeline_id FROM pg_control_checkpoint();")
[[ $cleanup_status == "0|$restored_timeline" ]] || {
    printf 'Cleanup restart did not retain the promoted non-recovery timeline (expected 0|%s, got %s).\n' "$restored_timeline" "$cleanup_status" >&2
    exit 1
}
[[ $(psql_value "$restored_container" "SELECT string_agg(id::text,',' ORDER BY id) FROM public.restore_probe;") == '1,3' ]] || {
    printf 'Required restored data or the post-promotion write did not survive clean restart.\n' >&2
    exit 1
}
[[ $(psql_value "$restored_container" "SELECT state||'|'||postgres_lsn::text||'|'||archive_generation_count::text||'|'||archive_generation_inventory_sha256||'|'||archive_generation_inventory_bytes::text||'|'||manifest_path||'|'||sha256 FROM oscar.oscar_backup_epoch WHERE id='$epoch_id';") == "VERIFIED|$backup_lsn|$generation_inventory_count|$generation_inventory_sha|$generation_inventory_bytes|$backup_id/epoch.json|$epoch_sha" ]] || {
    printf 'Restored epoch receipt identity changed across clean restart.\n' >&2
    exit 1
}
[[ $(psql_value "$restored_container" "SELECT count(*) FILTER (WHERE (name='restore_command' AND setting='') OR (name='recovery_target' AND setting='') OR (name='recovery_target_timeline' AND setting='latest') OR (name='recovery_target_action' AND setting='pause'))||'|'||CASE WHEN bool_and(NOT pending_restart) THEN '1' ELSE '0' END FROM pg_settings WHERE name IN ('restore_command','recovery_target','recovery_target_timeline','recovery_target_action');") == '4|1' ]] || {
    printf 'Cleanup restart retained a recovery setting or pending_restart flag.\n' >&2
    exit 1
}

printf 'PostgreSQL self-contained restore drill passed with archive_mode=off and no WAL mount (timeline %s -> %s).\n' \
    "$source_timeline" "$restored_timeline"
