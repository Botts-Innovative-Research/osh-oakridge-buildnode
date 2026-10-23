#!/bin/sh
set -eu

# PostgreSQL substitutes %p and %f in archive_command. Keep all publication
# inside the dedicated WAL archive mount and never overwrite a completed
# segment: reusing a segment name with different bytes must stop PostgreSQL
# from recycling the source WAL.
source_path=${1:?missing source WAL path}
wal_name=${2:?missing WAL file name}
archive_root=${3:-/var/lib/postgresql/wal-archive}

case $wal_name in
    [0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F].history) ;;
    [0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F]) ;;
    [0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F].[0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F].backup) ;;
    *) printf 'ERROR: refusing unsafe PostgreSQL WAL archive name: %s\n' "$wal_name" >&2; exit 1 ;;
esac

[ -f "$source_path" ] && [ ! -L "$source_path" ] || {
    printf 'ERROR: source WAL is not a regular non-link file: %s\n' "$source_path" >&2
    exit 1
}
[ -d "$archive_root" ] && [ ! -L "$archive_root" ] || {
    printf 'ERROR: WAL archive root is not a regular directory: %s\n' "$archive_root" >&2
    exit 1
}

destination=$archive_root/$wal_name

same_existing_segment() {
    [ -f "$destination" ] && [ ! -L "$destination" ] && cmp -s -- "$source_path" "$destination"
}

if [ -e "$destination" ] || [ -L "$destination" ]; then
    if same_existing_segment; then
        # A prior invocation may have published the bytes and then lost power
        # before returning success. Repeat the durability barrier before acking.
        sync -d "$destination"
        sync -f "$archive_root"
        exit 0
    fi
    printf 'ERROR: archived WAL name already exists with different or unsafe content: %s\n' "$destination" >&2
    exit 1
fi

umask 077
partial=$(mktemp "$archive_root/.$wal_name.partial.XXXXXX")
cleanup() { rm -f -- "$partial"; }
trap cleanup EXIT HUP INT TERM

# Flush the complete temporary inode before publishing it. A same-filesystem
# hard-link creates the final name atomically and fails if that name already
# exists; unlike `mv -n`, this has an unambiguous no-replace contract.
cp -- "$source_path" "$partial"
sync -d "$partial"
if ln -- "$partial" "$destination" 2>/dev/null; then
    rm -f -- "$partial"
    sync -d "$destination"
    sync -f "$archive_root"
    trap - EXIT HUP INT TERM
    exit 0
fi

# If a previous/retried archive command won the publication race, accept only
# byte-for-byte identical content. A mismatch remains a hard failure so the
# PostgreSQL archiver retains the live WAL and retries visibly.
if same_existing_segment; then
    rm -f -- "$partial"
    sync -d "$destination"
    sync -f "$archive_root"
    trap - EXIT HUP INT TERM
    exit 0
fi

printf 'ERROR: could not atomically publish WAL without replacing an existing segment: %s\n' "$destination" >&2
exit 1
