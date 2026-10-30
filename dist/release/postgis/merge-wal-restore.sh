#!/bin/sh
set -eu

# Merge one already-authenticated and structurally validated OSCAR WAL snapshot
# into the host-local archive without ever deleting or replacing an existing
# name. The caller may run this preflight/append phase while PostgreSQL is
# active: a concurrent valid publication is accepted only when byte-identical,
# and the normal no-replace archive publisher fails hard on any mismatch.
snapshot=${1:?missing WAL snapshot archive}
archive_root=${2:-/var/lib/postgresql/wal-archive}
stage=${3:?missing private merge staging directory}
publisher=${OSCAR_WAL_PUBLISHER:-/usr/local/bin/oscar-archive-wal}
case $publisher in /*) ;; *) echo 'ERROR: WAL publisher path must be absolute' >&2; exit 1 ;; esac
[ -x "$publisher" ] || { echo "ERROR: WAL publisher is unavailable: $publisher" >&2; exit 1; }

[ -f "$snapshot" ] && [ ! -L "$snapshot" ] || {
    echo 'ERROR: WAL restore snapshot is not a regular file' >&2; exit 1;
}
for directory in "$archive_root" "$stage"; do
    [ -d "$directory" ] && [ ! -L "$directory" ] || {
        echo "ERROR: WAL restore directory is missing or unsafe: $directory" >&2; exit 1;
    }
    if ! first_entry=$(find "$directory" -mindepth 1 -maxdepth 1 -print -quit); then
        echo "ERROR: unable to inspect WAL restore directory: $directory" >&2
        exit 1
    fi
    [ -z "$first_entry" ] || {
        [ "$directory" = "$archive_root" ] || {
            echo 'ERROR: private WAL merge staging directory is not empty' >&2; exit 1;
        }
    }
done

is_wal_name() {
    case $1 in
        [0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F].history) return 0 ;;
        [0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F]) return 0 ;;
        [0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F].[0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F].backup) return 0 ;;
        *) return 1 ;;
    esac
}

umask 077
LC_ALL=C
export LC_ALL

# Read the compressed archive a fixed number of times.  The former per-member
# `tar -t` plus `tar -xO` loop decompressed the complete gzip stream twice for
# every WAL object, making restore O(member-count * archive-size).  Validate the
# two complete listings first, then ask tar to extract only that validated file
# list in one sequential pass.  The control files live below a private name that
# cannot satisfy the WAL filename grammar and is never supplied to tar.
control=$stage/.oscar-wal-merge-control
[ ! -e "$control" ] && [ ! -L "$control" ] || {
    echo 'ERROR: private WAL merge control path already exists' >&2; exit 1;
}
mkdir "$control"
chmod 0700 "$control"
listing=$control/listing
details=$control/details
types=$control/types
records=$control/records
members=$control/members
extract_members=$control/extract-members
combined=$control/combined
stage_entries=$control/stage-entries
live_entries=$control/live-entries
: >"$records"
: >"$members"
: >"$extract_members"
tar -tzf "$snapshot" >"$listing"
tar -tvzf "$snapshot" >"$details"
[ -s "$listing" ] && [ -s "$details" ] || {
    echo 'ERROR: WAL restore snapshot has no members' >&2; exit 1;
}
cut -c1 "$details" >"$types"
[ "$(wc -l <"$types" | tr -d '[:space:]')" = \
  "$(wc -l <"$listing" | tr -d '[:space:]')" ] || {
    echo 'ERROR: WAL snapshot listing/type counts do not agree' >&2; exit 1;
}

paste "$types" "$listing" >"$combined"
while IFS="$(printf '\t')" read -r type member || [ -n "$member" ]; do
    case $member in
        .|./)
            [ "$type" = d ] || {
                echo 'ERROR: WAL snapshot root alias is not a directory' >&2; exit 1;
            }
            printf '.\n' >>"$records"
            continue
            ;;
        ./*) name=${member#./} ;;
        */) echo "ERROR: unexpected WAL snapshot directory member: $member" >&2; exit 1 ;;
        *) echo "ERROR: noncanonical WAL snapshot member: $member" >&2; exit 1 ;;
    esac
    [ "$type" = - ] || {
        echo "ERROR: WAL snapshot member is not a regular file: $member" >&2; exit 1;
    }
    is_wal_name "$name" || {
        echo "ERROR: unsafe WAL snapshot member: $member" >&2; exit 1;
    }
    printf '%s\n' "$name" >>"$records"
    printf '%s\n' "$name" >>"$members"
    printf '%s\n' "$member" >>"$extract_members"
done <"$combined"

if awk 'seen[$0]++ { duplicate=1 } END { exit duplicate ? 0 : 1 }' "$records"; then
    echo 'ERROR: WAL snapshot contains duplicate or aliased members' >&2
    exit 1
fi

if [ -s "$extract_members" ]; then
    tar -xzf "$snapshot" -C "$stage" --no-same-owner --no-same-permissions \
        -T "$extract_members"
fi

expected_count=$(wc -l <"$members" | tr -d '[:space:]')
find "$stage" -mindepth 1 -maxdepth 1 ! -name '.oscar-wal-merge-control' -print >"$stage_entries"
actual_count=$(wc -l <"$stage_entries" | tr -d '[:space:]')
[ "$actual_count" = "$expected_count" ] || {
    echo 'ERROR: WAL snapshot extraction produced an unexpected path set' >&2; exit 1;
}
while IFS= read -r name || [ -n "$name" ]; do
    [ -n "$name" ] || continue
    [ -f "$stage/$name" ] && [ ! -L "$stage/$name" ] || {
        echo "ERROR: extracted WAL snapshot member is not a regular file: $name" >&2; exit 1;
    }
    chmod 0600 "$stage/$name"
    sync -d "$stage/$name"
done <"$members"

# Fail before publishing even one name if any existing collision is unsafe or
# has different bytes. Also reject unrelated unsafe live-root entries here;
# the administrator-side root audit performs the same check before invocation.
find "$archive_root" -mindepth 1 -maxdepth 1 -print >"$live_entries"
while IFS= read -r existing; do
    name=${existing##*/}
    [ "$name" = .oscar-storage-root ] && continue
    is_wal_name "$name" || { echo "ERROR: unsafe existing WAL archive entry: $name" >&2; exit 1; }
    [ -f "$existing" ] && [ ! -L "$existing" ] || {
        echo "ERROR: existing WAL archive entry is not a regular file: $name" >&2; exit 1;
    }
done <"$live_entries"
while IFS= read -r name; do
    destination=$archive_root/$name
    if [ -e "$destination" ] || [ -L "$destination" ]; then
        [ -f "$destination" ] && [ ! -L "$destination" ] && cmp -s "$stage/$name" "$destination" || {
            echo "ERROR: restored WAL name collides with different or unsafe live content: $name" >&2
            exit 1
        }
    fi
done <"$members"

while IFS= read -r name; do
    "$publisher" "$stage/$name" "$name" "$archive_root"
done <"$members"
sync -f "$archive_root" 2>/dev/null || sync
rm -f -- "$listing" "$details" "$types" "$records" "$members" "$extract_members" \
    "$combined" "$stage_entries" "$live_entries"
rmdir "$control"
