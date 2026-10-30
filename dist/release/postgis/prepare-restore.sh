#!/bin/sh
set -eu

# Prepare a verified plain pg_basebackup for one safe primary restore. The
# recovery_target=immediate stops at the online backup end, while the explicit
# current timeline prevents following a later fork. Every supported backup was
# created with pg_basebackup --wal-method=stream, so required WAL is already in
# pg_wal. The always-miss restore command proves recovery has no external WAL
# dependency; completion then promotes onto a fresh timeline.
data_directory=${1:-/var/lib/postgresql/data}
case "$data_directory" in /*) ;; *) echo 'ERROR: PostgreSQL data directory must be absolute' >&2; exit 1 ;; esac
[ -d "$data_directory" ] && [ ! -L "$data_directory" ] || {
    echo 'ERROR: PostgreSQL restore data directory is missing or unsafe' >&2
    exit 1
}

backup_label=$data_directory/backup_label
[ -f "$backup_label" ] && [ ! -L "$backup_label" ] || {
    echo 'ERROR: restored pg_basebackup has no regular backup_label' >&2
    exit 1
}
timeline_count=$(grep -Ec '^START TIMELINE: [1-9][0-9]{0,9}$' "$backup_label" || true)
[ "$timeline_count" -eq 1 ] || {
    echo 'ERROR: backup_label must contain exactly one valid START TIMELINE' >&2
    exit 1
}
source_timeline=$(sed -n 's/^START TIMELINE: \([1-9][0-9]*\)$/\1/p' "$backup_label")
[ "$source_timeline" -le 4294967295 ] 2>/dev/null || {
    echo 'ERROR: backup_label timeline is outside the PostgreSQL timeline range' >&2
    exit 1
}

auto_conf=$data_directory/postgresql.auto.conf
if [ -e "$auto_conf" ] || [ -L "$auto_conf" ]; then
    [ -f "$auto_conf" ] && [ ! -L "$auto_conf" ] || {
        echo 'ERROR: postgresql.auto.conf is not a regular file' >&2
        exit 1
    }
fi
for signal in recovery.signal standby.signal; do
    [ ! -e "$data_directory/$signal" ] && [ ! -L "$data_directory/$signal" ] || {
        echo "ERROR: restored pg_basebackup unexpectedly contains $signal" >&2
        exit 1
    }
done

umask 077
configuration_temp=$data_directory/.postgresql.auto.conf.oscar-restore.$$
signal_temp=$data_directory/.recovery.signal.oscar-restore.$$
cleanup() { rm -f -- "$configuration_temp" "$signal_temp"; }
trap cleanup EXIT HUP INT TERM

if [ -f "$auto_conf" ]; then
    awk '
        !/^[[:space:]]*(restore_command|recovery_target(_[a-z_]+)?|primary_conninfo|primary_slot_name|promote_trigger_file)[[:space:]]*=/ { print }
    ' "$auto_conf" >"$configuration_temp"
else
    : >"$configuration_temp"
fi
cat >>"$configuration_temp" <<'EOF'
# OSCAR one-time restore recovery: stop at this online backup's consistency point.
restore_command = '/bin/false'
recovery_target = 'immediate'
recovery_target_timeline = 'current'
recovery_target_action = 'promote'
EOF
: >"$signal_temp"
chmod 0600 "$configuration_temp" "$signal_temp"
sync -f "$configuration_temp" 2>/dev/null || sync
sync -f "$signal_temp" 2>/dev/null || sync
mv -f -- "$configuration_temp" "$auto_conf"
mv -- "$signal_temp" "$data_directory/recovery.signal"
sync -f "$data_directory" 2>/dev/null || sync
trap - EXIT HUP INT TERM

printf '%s\n' "$source_timeline"
