#!/usr/bin/env bash
set -Eeuo pipefail

script_path=${BASH_SOURCE[0]}
repo_root=$(CDPATH= cd -- "${script_path%/*}/.." && pwd -P)
helper="$repo_root/dist/release/docker/oscar/archive-object-helper.sh"
test_root=$(mktemp -d "$repo_root/.archive-helper-test.XXXXXX")
cleanup() {
    case $test_root in "$repo_root"/.archive-helper-test.*) rm -rf -- "$test_root" ;; esac
}
trap cleanup EXIT

sh -n "$helper"
archive="$test_root/archive"
export_root="$test_root/export"
outside="$test_root/outside"
mkdir -p "$archive/datasets/day=2026-10-17" "$export_root" "$outside"
relative=datasets/day=2026-10-17/object.parquet
printf 'portable observation bytes\n' >"$archive/$relative"
checksum=$(shasum -a 256 "$archive/$relative" | awk '{print $1}')

OSCAR_ARCHIVE_HELPER_ROOT="$archive" OSCAR_ARCHIVE_HELPER_EXPORT_ROOT="$export_root" \
    sh "$helper" verify "$relative" "$checksum"
OSCAR_ARCHIVE_HELPER_ROOT="$archive" OSCAR_ARCHIVE_HELPER_EXPORT_ROOT="$export_root" \
    sh "$helper" copy "$relative" "$checksum"
cmp -s "$archive/$relative" "$export_root/$relative"

wrong=$(printf '0%.0s' {1..64})
if OSCAR_ARCHIVE_HELPER_ROOT="$archive" sh "$helper" verify "$relative" "$wrong" >/dev/null 2>&1; then
    printf 'Archive helper accepted the wrong checksum.\n' >&2
    exit 1
fi

# A parent swapped to a symlink must never expose or delete an object outside
# the archive root.
printf 'outside sentinel\n' >"$outside/sentinel.parquet"
ln -s "$outside" "$archive/escape"
outside_sha=$(shasum -a 256 "$outside/sentinel.parquet" | awk '{print $1}')
for operation in verify copy delete; do
    if OSCAR_ARCHIVE_HELPER_ROOT="$archive" OSCAR_ARCHIVE_HELPER_EXPORT_ROOT="$export_root" \
        sh "$helper" "$operation" escape/sentinel.parquet "$outside_sha" >/dev/null 2>&1; then
        printf 'Archive helper followed a parent symlink during %s.\n' "$operation" >&2
        exit 1
    fi
done
grep -Fxq 'outside sentinel' "$outside/sentinel.parquet"

[[ $(OSCAR_ARCHIVE_HELPER_ROOT="$archive" sh "$helper" delete "$relative" "$checksum") == DELETED ]]
[[ ! -e $archive/$relative ]]
[[ $(OSCAR_ARCHIVE_HELPER_ROOT="$archive" sh "$helper" delete "$relative" "$checksum") == ALREADY_ABSENT ]]
printf 'Archive object helper tests passed.\n'
