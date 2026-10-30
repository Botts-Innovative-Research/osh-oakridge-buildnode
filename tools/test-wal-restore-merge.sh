#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
helper=$repo_root/dist/release/postgis/merge-wal-restore.sh
publisher=$repo_root/dist/release/postgis/archive-wal.sh
test_root=$(mktemp -d "${TMPDIR:-/tmp}/oscar-wal-restore.XXXXXX")
cleanup() { find "$test_root" -depth -delete; }
trap cleanup EXIT HUP INT TERM
real_tar=$(command -v tar)
real_find=$(command -v find)
real_paste=$(command -v paste)

# macOS sync lacks GNU -d/-f; the helpers' ordering is covered statically and
# the Linux Docker drill exercises the real durability syscalls.
mkdir "$test_root/bin"
cat >"$test_root/bin/sync" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"$test_root/bin/tar" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "$*" >>"${OSCAR_TEST_TAR_LOG:?}"
exec "${OSCAR_TEST_REAL_TAR:?}" "$@"
EOF
cat >"$test_root/bin/find" <<'EOF'
#!/bin/sh
set -eu
if [ -n "${OSCAR_TEST_FAIL_FIND_ROOT:-}" ] && [ "${1:-}" = "$OSCAR_TEST_FAIL_FIND_ROOT" ]; then
    exit 71
fi
if [ -n "${OSCAR_TEST_FAIL_FIND_ONCE_ROOT:-}" ] && [ "${1:-}" = "$OSCAR_TEST_FAIL_FIND_ONCE_ROOT" ] &&
   [ ! -e "${OSCAR_TEST_FIND_ONCE_SENTINEL:?}" ]; then
    : >"$OSCAR_TEST_FIND_ONCE_SENTINEL"
    exit 73
fi
exec "${OSCAR_TEST_REAL_FIND:?}" "$@"
EOF
cat >"$test_root/bin/paste" <<'EOF'
#!/bin/sh
set -eu
[ "${OSCAR_TEST_FAIL_PASTE:-0}" != 1 ] || exit 72
exec "${OSCAR_TEST_REAL_PASTE:?}" "$@"
EOF
chmod 0755 "$test_root/bin/sync" "$test_root/bin/tar" "$test_root/bin/find" "$test_root/bin/paste"
export OSCAR_TEST_REAL_TAR=$real_tar
export OSCAR_TEST_REAL_FIND=$real_find
export OSCAR_TEST_REAL_PASTE=$real_paste
export OSCAR_TEST_TAR_LOG=$test_root/tar-calls.log
export COPYFILE_DISABLE=1
: >"$OSCAR_TEST_TAR_LOG"
export PATH="$test_root/bin:$PATH"
export OSCAR_WAL_PUBLISHER=$publisher
sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}';
    else shasum --algorithm 256 "$1" | awk '{print $1}'; fi
}

duplicate=000000010000000000000001
missing=000000010000000000000002
future=000000010000000000000003
new_before_conflict=000000010000000000000004
mkdir "$test_root/live" "$test_root/input" "$test_root/stage"
printf 'identical backup WAL\n' >"$test_root/input/$duplicate"
printf 'missing backup WAL\n' >"$test_root/input/$missing"
cp "$test_root/input/$duplicate" "$test_root/live/$duplicate"
printf 'future live WAL\n' >"$test_root/live/$future"
future_hash=$(sha256_file "$test_root/live/$future")
tar -C "$test_root/input" -czf "$test_root/good.tar.gz" .
: >"$OSCAR_TEST_TAR_LOG"
sh "$helper" "$test_root/good.tar.gz" "$test_root/live" "$test_root/stage"
[[ $(wc -l <"$OSCAR_TEST_TAR_LOG" | tr -d '[:space:]') == 3 ]] || {
    printf 'WAL merge did not use exactly two validation passes and one extraction pass.\n' >&2; exit 1;
}
grep -q -- '^-tzf ' "$OSCAR_TEST_TAR_LOG" &&
grep -q -- '^-tvzf ' "$OSCAR_TEST_TAR_LOG" &&
grep -q -- '^-xzf .* -T ' "$OSCAR_TEST_TAR_LOG" &&
! grep -q -- '-xO' "$OSCAR_TEST_TAR_LOG" || {
    printf 'WAL merge tar invocation contract is not fixed-pass extraction.\n' >&2; exit 1;
}
cmp "$test_root/input/$duplicate" "$test_root/live/$duplicate"
cmp "$test_root/input/$missing" "$test_root/live/$missing"
[[ $(sha256_file "$test_root/live/$future") == "$future_hash" ]] || {
    printf 'WAL merge changed a post-backup live object.\n' >&2; exit 1;
}

find "$test_root/stage" -mindepth 1 -delete
mkdir "$test_root/conflict-input"
printf 'would be new\n' >"$test_root/conflict-input/$new_before_conflict"
printf 'different collision\n' >"$test_root/conflict-input/$duplicate"
tar -C "$test_root/conflict-input" -czf "$test_root/conflict.tar.gz" .
if sh "$helper" "$test_root/conflict.tar.gz" "$test_root/live" "$test_root/stage" >/dev/null 2>&1; then
    printf 'WAL merge accepted a different-byte collision.\n' >&2; exit 1;
fi
[[ ! -e $test_root/live/$new_before_conflict ]] || {
    printf 'WAL merge published before completing collision preflight.\n' >&2; exit 1;
}

find "$test_root/stage" -mindepth 1 -delete
printf 'unsafe\n' >"$test_root/live/not-a-wal-name"
if sh "$helper" "$test_root/good.tar.gz" "$test_root/live" "$test_root/stage" >/dev/null 2>&1; then
    printf 'WAL merge accepted an unsafe existing root entry.\n' >&2; exit 1;
fi
[[ $(sha256_file "$test_root/live/$future") == "$future_hash" ]] || {
    printf 'Failed WAL merge changed a preserved live object.\n' >&2; exit 1;
}

# Member count must not increase the number of complete gzip scans.  This is a
# regression oracle for the former per-member list/extract algorithm.
mkdir "$test_root/bulk-input" "$test_root/bulk-live" "$test_root/bulk-stage"
for index in $(seq 16 79); do
    printf -v segment '%024X' "$index"
    printf 'bulk WAL %s\n' "$segment" >"$test_root/bulk-input/$segment"
done
tar -C "$test_root/bulk-input" -czf "$test_root/bulk.tar.gz" .
: >"$OSCAR_TEST_TAR_LOG"
sh "$helper" "$test_root/bulk.tar.gz" "$test_root/bulk-live" "$test_root/bulk-stage"
[[ $(wc -l <"$OSCAR_TEST_TAR_LOG" | tr -d '[:space:]') == 3 &&
   $(find "$test_root/bulk-live" -mindepth 1 -maxdepth 1 -type f | wc -l | tr -d '[:space:]') == 64 ]] || {
    printf 'WAL merge work scaled with members or omitted a bulk member.\n' >&2; exit 1;
}

# Reject hostile member types, aliases, duplicate targets, and noncanonical
# names before extracting or publishing even one otherwise valid WAL object.
hostile_live=$test_root/hostile-live
hostile_stage=$test_root/hostile-stage
mkdir "$hostile_live" "$hostile_stage"
hostile_safe=000000010000000000000080
hostile_bad=000000010000000000000081

mkdir "$test_root/symlink-input"
printf 'safe\n' >"$test_root/symlink-input/$hostile_safe"
ln -s "$hostile_safe" "$test_root/symlink-input/$hostile_bad"
tar -C "$test_root/symlink-input" -czf "$test_root/symlink.tar.gz" .
if sh "$helper" "$test_root/symlink.tar.gz" "$hostile_live" "$hostile_stage" >/dev/null 2>&1; then
    printf 'WAL merge accepted a symlink member.\n' >&2; exit 1;
fi
[[ ! -e $hostile_live/$hostile_safe ]] || {
    printf 'WAL merge published before rejecting a symlink member.\n' >&2; exit 1;
}

find "$hostile_stage" -mindepth 1 -delete
mkdir "$test_root/hardlink-input"
printf 'safe\n' >"$test_root/hardlink-input/$hostile_safe"
ln "$test_root/hardlink-input/$hostile_safe" "$test_root/hardlink-input/$hostile_bad"
tar -C "$test_root/hardlink-input" -czf "$test_root/hardlink.tar.gz" \
    "./$hostile_safe" "./$hostile_bad"
if sh "$helper" "$test_root/hardlink.tar.gz" "$hostile_live" "$hostile_stage" >/dev/null 2>&1; then
    printf 'WAL merge accepted a hardlink member.\n' >&2; exit 1;
fi
[[ ! -e $hostile_live/$hostile_safe && ! -e $hostile_live/$hostile_bad ]] || {
    printf 'WAL merge published before rejecting a hardlink member.\n' >&2; exit 1;
}

find "$hostile_stage" -mindepth 1 -delete
mkdir "$test_root/fifo-input"
printf 'safe\n' >"$test_root/fifo-input/$hostile_safe"
mkfifo "$test_root/fifo-input/$hostile_bad"
tar -C "$test_root/fifo-input" -czf "$test_root/fifo.tar.gz" .
if sh "$helper" "$test_root/fifo.tar.gz" "$hostile_live" "$hostile_stage" >/dev/null 2>&1; then
    printf 'WAL merge accepted a FIFO member.\n' >&2; exit 1;
fi
[[ ! -e $hostile_live/$hostile_safe ]] || {
    printf 'WAL merge published before rejecting a FIFO member.\n' >&2; exit 1;
}

find "$hostile_stage" -mindepth 1 -delete
mkdir "$test_root/directory-input"
printf 'safe\n' >"$test_root/directory-input/$hostile_safe"
mkdir "$test_root/directory-input/$hostile_bad"
tar -C "$test_root/directory-input" -czf "$test_root/directory.tar.gz" .
if sh "$helper" "$test_root/directory.tar.gz" "$hostile_live" "$hostile_stage" >/dev/null 2>&1; then
    printf 'WAL merge accepted a directory with a WAL filename.\n' >&2; exit 1;
fi
[[ ! -e $hostile_live/$hostile_safe ]] || {
    printf 'WAL merge published before rejecting a directory member.\n' >&2; exit 1;
}

find "$hostile_stage" -mindepth 1 -delete
mkdir "$test_root/duplicate-input"
printf 'duplicate\n' >"$test_root/duplicate-input/$hostile_bad"
tar -C "$test_root/duplicate-input" -czf "$test_root/duplicate.tar.gz" \
    "./$hostile_bad" "./$hostile_bad"
if sh "$helper" "$test_root/duplicate.tar.gz" "$hostile_live" "$hostile_stage" >/dev/null 2>&1; then
    printf 'WAL merge accepted a duplicate extraction target.\n' >&2; exit 1;
fi
[[ ! -e $hostile_live/$hostile_bad ]] || {
    printf 'WAL merge published before rejecting a duplicate target.\n' >&2; exit 1;
}

find "$hostile_stage" -mindepth 1 -delete
tar -C "$test_root/duplicate-input" -czf "$test_root/noncanonical.tar.gz" "$hostile_bad"
if sh "$helper" "$test_root/noncanonical.tar.gz" "$hostile_live" "$hostile_stage" >/dev/null 2>&1; then
    printf 'WAL merge accepted a member without the canonical ./ prefix.\n' >&2; exit 1;
fi
[[ ! -e $hostile_live/$hostile_bad ]] || {
    printf 'WAL merge published before rejecting a noncanonical member.\n' >&2; exit 1;
}

# A producer failure while building any validated control list must fail closed;
# POSIX pipelines without pipefail previously risked accepting partial output.
for failure_case in paste stage-find live-find; do
    producer_stage=$test_root/producer-$failure_case-stage
    producer_live=$test_root/producer-$failure_case-live
    mkdir "$producer_stage" "$producer_live"
    unset OSCAR_TEST_FAIL_PASTE OSCAR_TEST_FAIL_FIND_ROOT
    case $failure_case in
        paste) export OSCAR_TEST_FAIL_PASTE=1 ;;
        stage-find) export OSCAR_TEST_FAIL_FIND_ROOT=$producer_stage ;;
        live-find) export OSCAR_TEST_FAIL_FIND_ROOT=$producer_live ;;
    esac
    if sh "$helper" "$test_root/good.tar.gz" "$producer_live" "$producer_stage" >/dev/null 2>&1; then
        printf 'WAL merge accepted a failed %s control-list producer.\n' "$failure_case" >&2; exit 1;
    fi
    [[ ! -e $producer_live/$duplicate && ! -e $producer_live/$missing ]] || {
        printf 'WAL merge published after a failed %s control-list producer.\n' "$failure_case" >&2; exit 1;
    }
done
unset OSCAR_TEST_FAIL_PASTE OSCAR_TEST_FAIL_FIND_ROOT

# The initial empty-stage probe must also propagate a one-shot find failure;
# later successful scans must not turn that failed trust-boundary check into a
# successful merge.
initial_stage=$test_root/producer-initial-find-stage
initial_live=$test_root/producer-initial-find-live
mkdir "$initial_stage" "$initial_live"
export OSCAR_TEST_FAIL_FIND_ONCE_ROOT=$initial_stage
export OSCAR_TEST_FIND_ONCE_SENTINEL=$test_root/find-once.sentinel
if sh "$helper" "$test_root/good.tar.gz" "$initial_live" "$initial_stage" >/dev/null 2>&1; then
    printf 'WAL merge accepted a failed initial private-stage inspection.\n' >&2; exit 1;
fi
[[ ! -e $initial_live/$duplicate && ! -e $initial_live/$missing ]] || {
    printf 'WAL merge published after a failed initial private-stage inspection.\n' >&2; exit 1;
}
unset OSCAR_TEST_FAIL_FIND_ONCE_ROOT OSCAR_TEST_FIND_ONCE_SENTINEL

printf 'WAL restore merge tests passed.\n'
