#!/bin/sh
set -eu

operation=${1:?missing archive helper operation}
relative=${2:?missing relative archive path}
expected_sha=${3:?missing expected SHA-256}
archive_root=${OSCAR_ARCHIVE_HELPER_ROOT:-/archive}
export_root=${OSCAR_ARCHIVE_HELPER_EXPORT_ROOT:-/export}

case $operation in verify|copy|delete) ;; *) printf 'ERROR: unknown archive helper operation\n' >&2; exit 2 ;; esac
case $expected_sha in
    *[!0-9a-f]*|'') printf 'ERROR: invalid expected archive checksum\n' >&2; exit 2 ;;
esac
[ "${#expected_sha}" -eq 64 ] || { printf 'ERROR: invalid expected archive checksum length\n' >&2; exit 2; }
case $relative in
    /*|''|*//*|*/../*|../*|*/..|..|*/./*|./*|*/.|.)
        printf 'ERROR: unsafe relative archive path: %s\n' "$relative" >&2
        exit 2
        ;;
esac
printf '%s' "$relative" | LC_ALL=C grep -Eq '^[A-Za-z0-9][A-Za-z0-9._/+=-]*$' || {
    printf 'ERROR: archive path contains unsupported characters: %s\n' "$relative" >&2
    exit 2
}

[ -d "$archive_root" ] && [ ! -L "$archive_root" ] || {
    printf 'ERROR: archive helper root is not a regular directory\n' >&2
    exit 1
}

# Resolve one component at a time. The OSCAR writer is stopped by the caller,
# and the helper sees only the archive bind mount, so a compromised application
# cannot redirect privileged access outside the host archive root.
old_ifs=$IFS
IFS=/
set -- $relative
IFS=$old_ifs
current=$archive_root
component_count=$#
index=0
for component do
    index=$((index + 1))
    case $component in ''|.|..) printf 'ERROR: unsafe archive component\n' >&2; exit 2 ;; esac
    current=$current/$component
    [ ! -L "$current" ] || { printf 'ERROR: archive path contains a symbolic link: %s\n' "$relative" >&2; exit 1; }
    if [ "$index" -lt "$component_count" ]; then
        [ -d "$current" ] || { printf 'ERROR: archive parent is not a directory: %s\n' "$relative" >&2; exit 1; }
    fi
done
[ -f "$current" ] && [ ! -L "$current" ] || {
    # A purge transaction records DELETING before filesystem removal. If the
    # host loses power after unlink but before the catalog receipt, a retry
    # must be able to complete that already-authorized delete. Parent
    # components were checked above and a dangling link is never "absent".
    if [ "$operation" = delete ] && [ ! -e "$current" ] && [ ! -L "$current" ]; then
        parent=${current%/*}
        sync -f "$parent"
        printf 'ALREADY_ABSENT\n'
        exit 0
    fi
    printf 'ERROR: archive object is not a regular non-link file: %s\n' "$relative" >&2
    exit 1
}

actual_sha=$(sha256sum "$current" | awk '{print $1}')
[ "$actual_sha" = "$expected_sha" ] || {
    printf 'ERROR: archive object checksum mismatch: %s\n' "$relative" >&2
    exit 1
}

case $operation in
    verify) exit 0 ;;
    copy)
        [ -d "$export_root" ] && [ ! -L "$export_root" ] || {
            printf 'ERROR: export helper root is not a regular directory\n' >&2
            exit 1
        }
        destination=$export_root/$relative
        parent=${destination%/*}
        [ "$parent" != "$destination" ] || parent=$export_root
        mkdir -p "$parent"
        [ ! -L "$parent" ] || { printf 'ERROR: export parent is a symbolic link\n' >&2; exit 1; }
        [ ! -e "$destination" ] && [ ! -L "$destination" ] || {
            printf 'ERROR: export destination already exists: %s\n' "$relative" >&2
            exit 1
        }
        cp -p -- "$current" "$destination"
        copied_sha=$(sha256sum "$destination" | awk '{print $1}')
        [ "$copied_sha" = "$expected_sha" ] || {
            rm -f -- "$destination"
            printf 'ERROR: copied archive object checksum mismatch: %s\n' "$relative" >&2
            exit 1
        }
        ;;
    delete)
        parent=${current%/*}
        rm -f -- "$current"
        [ ! -e "$current" ] && [ ! -L "$current" ] || {
            printf 'ERROR: archive object was not deleted: %s\n' "$relative" >&2
            exit 1
        }
        sync -f "$parent"
        printf 'DELETED\n'
        ;;
esac
