#!/usr/bin/env bash
set -Eeuo pipefail

script_path=${BASH_SOURCE[0]}
repo_root=$(CDPATH= cd -- "${script_path%/*}/.." && pwd -P)
helper="$repo_root/dist/release/postgis/archive-wal.sh"
test_root=$(mktemp -d "$repo_root/.wal-archive-test.XXXXXX")
cleanup() {
    case $test_root in "$repo_root"/.wal-archive-test.*) rm -rf -- "$test_root" ;; esac
}
trap cleanup EXIT

sh -n "$helper"
archive="$test_root/archive"
mkdir -p "$archive"
name=000000010000000000000001
source_one="$test_root/source-one"
source_two="$test_root/source-two"
printf 'first WAL payload\n' >"$source_one"
printf 'different WAL payload\n' >"$source_two"

sh "$helper" "$source_one" "$name" "$archive"
cmp -s "$source_one" "$archive/$name"

# Two concurrent writers with different bytes may not overwrite one another.
race_name=000000010000000000000004
race_one_status="$test_root/race-one.status"
race_two_status="$test_root/race-two.status"
(sh "$helper" "$source_one" "$race_name" "$archive" >/dev/null 2>&1; printf '%s' "$?" >"$race_one_status") &
race_one_pid=$!
(sh "$helper" "$source_two" "$race_name" "$archive" >/dev/null 2>&1; printf '%s' "$?" >"$race_two_status") &
race_two_pid=$!
set +e
wait "$race_one_pid"
wait "$race_two_pid"
set -e
[[ -f $race_one_status || -f $race_two_status ]]
if cmp -s "$source_one" "$archive/$race_name"; then
    [[ ! -f $race_two_status || $(cat "$race_two_status") != 0 ]]
elif cmp -s "$source_two" "$archive/$race_name"; then
    [[ ! -f $race_one_status || $(cat "$race_one_status") != 0 ]]
else
    printf 'Concurrent WAL publication produced bytes from neither source.\n' >&2
    exit 1
fi
[[ -z $(find "$archive" -maxdepth 1 -name '*.partial.*' -print -quit) ]]

# A retry with identical bytes is idempotent.
sh "$helper" "$source_one" "$name" "$archive"

# Reusing the segment name for different bytes must fail without replacing the
# previously durable object.
if sh "$helper" "$source_two" "$name" "$archive" >/dev/null 2>&1; then
    printf 'WAL helper accepted different bytes for an existing segment name.\n' >&2
    exit 1
fi
cmp -s "$source_one" "$archive/$name"

# A failed durability barrier is a hard archive failure and leaves neither a
# final object nor an interrupted partial.
fake_bin="$test_root/fake-bin"
mkdir -p "$fake_bin"
printf '#!/bin/sh\nexit 42\n' >"$fake_bin/sync"
chmod 0555 "$fake_bin/sync"
failed_name=000000010000000000000002
if PATH="$fake_bin:$PATH" sh "$helper" "$source_one" "$failed_name" "$archive" >/dev/null 2>&1; then
    printf 'WAL helper reported success after a failed durability barrier.\n' >&2
    exit 1
fi
[[ ! -e $archive/$failed_name && -z $(find "$archive" -maxdepth 1 -name ".$failed_name.partial.*" -print -quit) ]]

# Unsafe names and a destination symlink are rejected.
if sh "$helper" "$source_one" '../escape' "$archive" >/dev/null 2>&1; then
    printf 'WAL helper accepted an unsafe archive name.\n' >&2
    exit 1
fi
link_name=000000010000000000000003
ln -s "$test_root/outside" "$archive/$link_name"
if sh "$helper" "$source_one" "$link_name" "$archive" >/dev/null 2>&1; then
    printf 'WAL helper accepted a destination symlink.\n' >&2
    exit 1
fi
[[ ! -e $test_root/outside ]]

printf 'WAL archive publication tests passed.\n'
