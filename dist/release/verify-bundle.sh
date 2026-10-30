#!/usr/bin/env bash
set -Eeuo pipefail
script_path=${BASH_SOURCE[0]}
case $script_path in */*) script_parent=${script_path%/*} ;; *) script_parent=. ;; esac
script_dir=$(CDPATH= cd -- "$script_parent" && pwd -P)
cd "$script_dir"
assert_no_symlink_components() {
    local value=$1 remainder=${1#/} current='' component
    IFS='/' read -r -a components <<<"$remainder"
    for component in "${components[@]}"; do
        [[ -n $component ]] || continue
        current="$current/$component"
        [[ ! -L $current ]] || { printf 'ERROR: bundle path contains a symbolic-link component: %s\n' "$current" >&2; exit 1; }
        [[ -d $current ]] || { printf 'ERROR: bundle path component is not a directory: %s\n' "$current" >&2; exit 1; }
    done
}
sync_receipt_path() { sync -f "$1" 2>/dev/null || sync; }
atomic_replace_receipt() {
    local source=$1 destination=$2
    if mv --help 2>&1 | grep -q -- '--no-target-directory'; then
        mv -fT -- "$source" "$destination"
    elif command -v perl >/dev/null 2>&1; then
        perl -e 'rename($ARGV[0], $ARGV[1]) or die "rename: $!\n"' "$source" "$destination"
    else
        printf 'ERROR: an atomic same-directory rename implementation is required.\n' >&2
        return 1
    fi
}
is_reserved_runtime_path() {
    local candidate=$1
    [[ $candidate =~ ^(SHA256SUMS|\.bundle-verified|\.bundle-verified\.tmp\.[A-Za-z0-9._-]+|\.env|\.oscar-init-state|\.oscar-init-state\.tmp\.[A-Za-z0-9._-]+|\.oscar-volume-adoption|\.oscar-volume-adoption\.tmp\.[A-Za-z0-9._-]+|secrets/(oscar-admin-password|oscar-db-password|postgres-bootstrap-password|backup-key)\.txt|tls/server\.(crt|key)|pre-restore-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}/(\.env|secrets/(oscar-admin-password|oscar-db-password|postgres-bootstrap-password|backup-key)\.txt|tls/server\.(crt|key)))$ ]]
}
is_reserved_manifest_path() {
    local lowered
    lowered=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    case $lowered in
        secrets/*|tls/*|pre-restore-*/*) return 0 ;;
    esac
    is_reserved_runtime_path "$lowered"
}
assert_no_symlink_components "$script_dir"
[[ -f SHA256SUMS ]] || { printf 'ERROR: SHA256SUMS is missing.\n' >&2; exit 1; }
[[ ! -L SHA256SUMS ]] || { printf 'ERROR: SHA256SUMS must not be a symbolic link.\n' >&2; exit 1; }

# The checksum manifest is an exact bundle inventory, not merely a list of
# files that happen to be authenticated. This is essential because setup may
# execute bundled installers with administrator privileges.
inventory_scratch=$(mktemp -d "${TMPDIR:-/tmp}/oscar-bundle-inventory.XXXXXX")
cleanup_inventory() { rm -rf -- "$inventory_scratch"; }
trap cleanup_inventory EXIT HUP INT TERM
declared="$inventory_scratch/declared"
actual="$inventory_scratch/actual"
: >"$declared"
: >"$actual"
while IFS= read -r line || [[ -n $line ]]; do
    [[ $line =~ ^[0-9a-fA-F]{64}\ \*(.+)$ ]] || { printf 'ERROR: invalid SHA256SUMS entry.\n' >&2; exit 1; }
    relative=${BASH_REMATCH[1]}
    case "/$relative/" in
        //*|*/../*|*/./*|*//*|*\\*) printf 'ERROR: unsafe SHA256SUMS path: %s\n' "$relative" >&2; exit 1 ;;
    esac
    [[ -n $relative && $relative != /* ]] && ! is_reserved_manifest_path "$relative" || {
        printf 'ERROR: reserved or unsafe SHA256SUMS path: %s\n' "$relative" >&2; exit 1;
    }
    printf '%s\n' "$relative" >>"$declared"
done <SHA256SUMS
[[ -s $declared ]] || { printf 'ERROR: SHA256SUMS is empty.\n' >&2; exit 1; }
if [[ $(LC_ALL=C sort -f "$declared" | uniq -i -d | wc -l | tr -d '[:space:]') != 0 ]]; then
    printf 'ERROR: SHA256SUMS contains duplicate or case-colliding paths.\n' >&2
    exit 1
fi
while IFS= read -r -d '' entry; do
    relative=${entry#"$script_dir"/}
    if [[ -L $entry ]]; then
        printf 'ERROR: offline bundle contains a symbolic link: %s\n' "$relative" >&2
        exit 1
    fi
    if [[ -d $entry ]]; then continue; fi
    [[ -f $entry ]] || { printf 'ERROR: offline bundle contains a non-regular entry: %s\n' "$relative" >&2; exit 1; }
    if is_reserved_runtime_path "$relative"; then continue; fi
    printf '%s\n' "$relative" >>"$actual"
done < <(find "$script_dir" -mindepth 1 -print0)
LC_ALL=C sort -f "$declared" -o "$declared"
LC_ALL=C sort -f "$actual" -o "$actual"
cmp -s "$declared" "$actual" || {
    printf 'ERROR: SHA256SUMS does not exactly cover the offline bundle payload.\n' >&2
    exit 1
}
if command -v sha256sum >/dev/null 2>&1; then
    sha256sum --check --strict SHA256SUMS
    manifest_hash=$(sha256sum SHA256SUMS | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
    sed 's/ \*/  /' SHA256SUMS | shasum --algorithm 256 --check
    manifest_hash=$(shasum --algorithm 256 SHA256SUMS | awk '{print $1}')
else
    printf 'ERROR: sha256sum or shasum is required.\n' >&2
    exit 1
fi
cleanup_inventory
trap - EXIT HUP INT TERM
temporary_receipt=$(mktemp "$script_dir/.bundle-verified.tmp.XXXXXX")
cleanup_receipt() { rm -f -- "$temporary_receipt"; }
trap cleanup_receipt EXIT HUP INT TERM
printf '%s\n' "$manifest_hash" >"$temporary_receipt"
chmod 0644 "$temporary_receipt"
sync_receipt_path "$temporary_receipt"
receipt="$script_dir/.bundle-verified"
if [[ -e $receipt || -L $receipt ]]; then
    [[ -f $receipt && ! -L $receipt ]] || { printf 'ERROR: offline verification receipt is not a regular file.\n' >&2; exit 1; }
fi
atomic_replace_receipt "$temporary_receipt" "$receipt" || { printf 'ERROR: offline verification receipt could not be atomically replaced.\n' >&2; exit 1; }
sync_receipt_path "$script_dir"
trap - EXIT HUP INT TERM
printf 'Bundle integrity verified.\n'
