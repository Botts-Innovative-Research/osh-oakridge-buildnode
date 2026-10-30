#!/bin/sh
set -eu

# Validate a tar.gz payload before a privileged restore extracts it.  Listing the
# archive is intentionally separate from extraction: no archive-controlled path
# is ever materialized while these checks run.
validate_storage_archive() (
    label=$1
    archive=$2
    scratch_root=${TMPDIR:-/tmp}
    work=
    work_created=false
    cleanup_validation_scratch() {
        if [ "$work_created" = true ]; then
            case "$work" in
                "$scratch_root"/oscar-tar-validation.*)
                    [ ! -L "$work" ] && [ -d "$work" ] && rm -rf -- "$work"
                    ;;
            esac
        fi
    }
    work=$(mktemp -d "$scratch_root/oscar-tar-validation.XXXXXX") || {
        echo "$label archive validator cannot create its private scratch directory: $scratch_root" >&2
        return 1
    }
    work_created=true
    names=$work/names
    details=$work/details
    sorted_names=$work/names.sorted
    sorted_expected=$work/expected.sorted
    expected=$work/expected
    types=$work/types
    records=$work/records
    trap cleanup_validation_scratch EXIT
    trap 'exit 1' HUP INT TERM

    [ -f "$archive" ] || {
        echo "$label archive is missing or is not a regular file: $archive" >&2
        return 1
    }
    tar -tzf "$archive" >"$names"
    tar -tvzf "$archive" >"$details"
    [ -s "$names" ] && [ -s "$details" ] || {
        echo "$label archive has no members" >&2
        return 1
    }

    # Extract only the leading member-type column and drop the verbose listing
    # immediately so multi-hundred-thousand-member state backups stay well
    # within the bounded 256 MiB validator scratch tmpfs.
    cut -c1 "$details" >"$types"
    rm -f -- "$details"

    if LC_ALL=C grep -q '[[:cntrl:]]' "$names"; then
        echo "$label archive contains a control character in a member name" >&2
        return 1
    fi

    # GNU tar, BusyBox tar, and bsdtar all begin verbose member rows with the
    # member type. Only regular files and directories are restorable. This
    # rejects links, devices, FIFOs, sockets, and unknown extension records.
    bad_type=$(LC_ALL=C grep -v '^[-d]$' "$types" | head -n 1 || true)
    if [ -n "$bad_type" ]; then
        echo "$label archive contains a forbidden member type ($bad_type)" >&2
        return 1
    fi

    [ "$(wc -l <"$types" | tr -d ' ')" = "$(wc -l <"$names" | tr -d ' ')" ] || {
        echo "$label archive listing/type counts do not agree" >&2
        return 1
    }

    # Validate raw names, canonicalize paths, reject duplicate/aliased entries
    # and file/directory prefix collisions, and enforce target-specific layouts
    # in a single streaming C/awk pass without per-member shell process forks.
    : >"$records"
    paste "$types" "$names" | LC_ALL=C awk -F '\t' -v label="$label" -v records_file="$records" '
        BEGIN {
            hex4 = "[0-9a-f][0-9a-f][0-9a-f][0-9a-f]"
            hex8 = hex4 hex4
            hex12 = hex8 hex4
            uuid_re = hex8 "-" hex4 "-" hex4 "-" hex4 "-" hex12
            cold_file_re = "^datasets/observations/date=[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/profile=[A-Za-z0-9_-]+/generation-" uuid_re "\\.(parquet|schemas\\.json\\.gz|manifest\\.json)$"
            uhex8 = "[0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F]"
            uhex24 = uhex8 uhex8 uhex8
            wal_file_re = "^(" uhex24 "|" uhex8 "\\.history|" uhex24 "\\." uhex8 "\\.backup)$"
            emit_records = (label == "deployment-secrets" || label == "release-config")
        }
        function fail(msg) {
            print msg > "/dev/stderr"
            failed = 1
            exit 1
        }
        {
            type = $1
            member = (length($0) >= 2) ? substr($0, 3) : ""

            if (member == "" || member == ".." || substr(member, 1, 1) == "/" ||
                member ~ /^[A-Za-z]:/ || substr(member, 1, 3) == "../" ||
                index(member, "/../") > 0 ||
                (length(member) >= 3 && substr(member, length(member) - 2) == "/..") ||
                index(member, "\\") > 0) {
                fail(label " archive contains an unsafe member name: " member)
            }
            if ((label == "cold-archive" || label == "wal-archive") &&
                index("/" member "/", "/.oscar-storage-root/") > 0) {
                fail(label " archive must not contain a host-local storage-root identity marker")
            }

            if (member == "." || member == "./") {
                canonical = "."
            } else if (substr(member, 1, 2) == "./") {
                canonical = substr(member, 3)
            } else {
                canonical = member
            }

            if (canonical == "" || canonical == ".." ||
                substr(canonical, 1, 3) == "../" ||
                index(canonical, "/../") > 0 ||
                (length(canonical) >= 3 && substr(canonical, length(canonical) - 2) == "/..") ||
                substr(canonical, 1, 2) == "./" ||
                index(canonical, "//") > 0 ||
                index(canonical, "/./") > 0 ||
                (length(canonical) >= 2 && substr(canonical, length(canonical) - 1) == "/.") ||
                index(canonical, "\\") > 0) {
                fail(label " archive contains a noncanonical member name: " member)
            }

            if (substr(canonical, length(canonical), 1) == "/") {
                if (type != "d") {
                    fail(label " archive contains a file with a directory alias: " member)
                }
                canonical = substr(canonical, 1, length(canonical) - 1)
            }
            if (canonical == "." && type != "d") {
                fail(label " archive contains a non-directory root alias")
            }

            if (seen[canonical]++) {
                fail(label " archive contains duplicate or aliased member: " canonical)
            }
            types[canonical] = type
            paths[++count] = canonical

            if (label == "oscar-state") {
                if (canonical == "archive" || substr(canonical, 1, 8) == "archive/" ||
                    canonical == "backups" || substr(canonical, 1, 8) == "backups/") {
                    fail("oscar-state archive contains a reserved live-mount path: " canonical)
                }
            } else if (label == "cold-archive") {
                if (type == "d") {
                    if (canonical == "." || canonical == "datasets" || canonical == "datasets/observations" ||
                        canonical ~ /^datasets\/observations\/date=....-..-..$/) {
                        # approved directory
                    } else if (canonical ~ /^datasets\/observations\/date=....-..-..\/profile=/) {
                        profile = canonical
                        sub(/^datasets\/observations\/date=....-..-..\/profile=/, "", profile)
                        if (profile !~ /^[A-Za-z0-9_-]+$/) {
                            fail("cold-archive directory has an invalid profile component: " canonical)
                        }
                    } else {
                        fail("cold-archive contains a directory outside the approved datasets layout: " canonical)
                    }
                } else if (canonical !~ cold_file_re) {
                    fail("cold-archive contains a file outside the approved generation-object layout: " canonical)
                }
            } else if (label == "wal-archive") {
                if (type == "d") {
                    if (canonical != ".") {
                        fail("wal-archive contains an unexpected directory: " canonical)
                    }
                } else if (canonical !~ wal_file_re) {
                    fail("wal-archive contains an invalid PostgreSQL archive filename: " canonical)
                }
            }

            if (emit_records) {
                printf "%s\t%s\n", type, canonical > records_file
            }
        }
        END {
            if (failed) {
                exit failed
            }
            for (item = 1; item <= count; item++) {
                path = paths[item]
                parent = path
                while (sub("/[^/]+$", "", parent)) {
                    if ((parent in types) && types[parent] != "d") {
                        print label " archive contains a file/directory prefix collision: " parent > "/dev/stderr"
                        bad = 1
                    }
                }
            }
            if (emit_records) {
                close(records_file)
            }
            exit bad
        }
    ' || return 1

    if [ "$label" = deployment-secrets ]; then
        cat >"$expected" <<'EOF'
.env
secrets
secrets/backup-key.txt
secrets/oscar-admin-password.txt
secrets/oscar-db-password.txt
secrets/postgres-bootstrap-password.txt
tls
tls/server.crt
tls/server.key
EOF
        cut -f2- "$records" | LC_ALL=C sort >"$sorted_names"
        LC_ALL=C sort "$expected" >"$sorted_expected"
        if ! cmp -s "$sorted_names" "$sorted_expected"; then
            echo 'deployment-secrets archive does not contain exactly the approved credential files' >&2
            return 1
        fi
    fi

    if [ "$label" = release-config ]; then
        cat >"$expected" <<'EOF'
.dockerignore
.env.example
DEPLOYMENT.md
QUICKSTART.md
compose.yaml
docker/gateway/default.conf
docker/oscar/archive-object-helper.sh
docker/oscar/atomic-publish.c
docker/oscar/Dockerfile
docker/oscar/entrypoint.sh
oscar-setup.ps1
oscar-setup.sh
oscar-storage.ps1
oscar-storage.sh
oscar.bat
oscar.sh
postgis/Dockerfile
postgis/archive-wal.sh
postgis/merge-wal-restore.sh
postgis/prepare-restore.sh
postgis/init-app-role.sh
postgis/init-extensions.sql
validate-storage-archive.sh
EOF
        cut -f2- "$records" | LC_ALL=C sort >"$sorted_names"
        LC_ALL=C sort "$expected" >"$sorted_expected"
        if ! cmp -s "$sorted_names" "$sorted_expected"; then
            echo 'release-config archive does not contain exactly the approved release files' >&2
            return 1
        fi
    fi

    cleanup_validation_scratch
    work_created=false
    trap - EXIT HUP INT TERM
)

if [ "${0##*/}" = validate-storage-archive.sh ]; then
    [ "$#" -ge 2 ] && [ $(($# % 2)) -eq 0 ] || {
        echo 'usage: validate-storage-archive.sh LABEL ARCHIVE [LABEL ARCHIVE ...]' >&2
        exit 2
    }
    while [ "$#" -gt 0 ]; do
        validate_storage_archive "$1" "$2"
        shift 2
    done
fi
