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

    while IFS= read -r member || [ -n "$member" ]; do
        case "$member" in
            ''|..|/*|[A-Za-z]:*|../*|*/../*|*/..|*\\*)
                echo "$label archive contains an unsafe member name: $member" >&2
                return 1
                ;;
        esac
        if printf '%s' "$member" | LC_ALL=C grep -q '[[:cntrl:]]'; then
            echo "$label archive contains a control character in a member name" >&2
            return 1
        fi
        if [ "$label" = cold-archive ] || [ "$label" = wal-archive ]; then
            case "/$member/" in
                */.oscar-storage-root/*)
                    echo "$label archive must not contain a host-local storage-root identity marker" >&2
                    return 1
                    ;;
            esac
        fi
    done <"$names"

    # GNU tar, BusyBox tar, and bsdtar all begin verbose member rows with the
    # member type.  Only regular files and directories are restorable.  This
    # rejects links, devices, FIFOs, sockets, and unknown extension records.
    while IFS= read -r detail || [ -n "$detail" ]; do
        type=$(printf '%.1s' "$detail")
        case "$type" in
            -|d) ;;
            *)
                echo "$label archive contains a forbidden member type ($type)" >&2
                return 1
                ;;
        esac
    done <"$details"

    # Match each listed name with tar's corresponding type byte, normalize the
    # one conventional leading "./" and a directory's trailing slash, then
    # reject aliases, duplicate extraction targets, and file/parent conflicts.
    cut -c1 "$details" >"$types"
    [ "$(wc -l <"$types" | tr -d ' ')" = "$(wc -l <"$names" | tr -d ' ')" ] || {
        echo "$label archive listing/type counts do not agree" >&2
        return 1
    }
    : >"$records"
    paste "$types" "$names" | while IFS="$(printf '\t')" read -r type member || [ -n "$member" ]; do
        case "$member" in
            .|./) canonical=. ;;
            ./*) canonical=${member#./} ;;
            *) canonical=$member ;;
        esac
        case "$canonical" in
            ''|..|../*|*/../*|*/..|./*|*//*|*/./*|*/.|*\\*)
                echo "$label archive contains a noncanonical member name: $member" >&2
                exit 1
                ;;
        esac
        case "$canonical" in
            */)
                [ "$type" = d ] || {
                    echo "$label archive contains a file with a directory alias: $member" >&2
                    exit 1
                }
                canonical=${canonical%/}
                ;;
        esac
        [ "$canonical" != . ] || [ "$type" = d ] || {
            echo "$label archive contains a non-directory root alias" >&2
            exit 1
        }
        printf '%s\t%s\n' "$type" "$canonical" >>"$records"
    done || return 1
    awk -F '\t' -v label="$label" '
        {
            path=substr($0, index($0, FS) + 1)
            if (seen[path]++) {
                print label " archive contains duplicate or aliased member: " path > "/dev/stderr"
                bad=1
            }
            types[path]=$1
            paths[++count]=path
        }
        END {
            for (item=1; item<=count; item++) {
                path=paths[item]
                parent=path
                while (sub("/[^/]+$", "", parent)) {
                    if ((parent in types) && types[parent] != "d") {
                        print label " archive contains a file/directory prefix collision: " parent > "/dev/stderr"
                        bad=1
                    }
                }
            }
            exit bad
        }
    ' "$records" || return 1

    # Apply restore-target-specific schemas after canonicalization. These rules
    # prevent a cryptographically valid but structurally hostile payload from
    # reaching a live bind mount, while retaining the documented OSCAR and
    # PostgreSQL archive layouts.
    while IFS="$(printf '\t')" read -r type canonical || [ -n "$canonical" ]; do
        case "$label" in
            oscar-state)
                case "$canonical" in
                    archive|archive/*|backups|backups/*)
                        echo "oscar-state archive contains a reserved live-mount path: $canonical" >&2
                        return 1
                        ;;
                esac
                ;;
            cold-archive)
                if [ "$type" = d ]; then
                    case "$canonical" in
                        .|datasets|datasets/observations) ;;
                        datasets/observations/date=????-??-??) ;;
                        datasets/observations/date=????-??-??/profile=*)
                            profile=${canonical##*/profile=}
                            printf '%s\n' "$profile" | LC_ALL=C grep -Eq '^[A-Za-z0-9_-]+$' || {
                                echo "cold-archive directory has an invalid profile component: $canonical" >&2
                                return 1
                            }
                            ;;
                        *)
                            echo "cold-archive contains a directory outside the approved datasets layout: $canonical" >&2
                            return 1
                            ;;
                    esac
                else
                    printf '%s\n' "$canonical" | LC_ALL=C grep -Eq '^datasets/observations/date=[0-9]{4}-[0-9]{2}-[0-9]{2}/profile=[A-Za-z0-9_-]+/generation-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(parquet|schemas\.json\.gz|manifest\.json)$' || {
                        echo "cold-archive contains a file outside the approved generation-object layout: $canonical" >&2
                        return 1
                    }
                fi
                ;;
            wal-archive)
                if [ "$type" = d ]; then
                    [ "$canonical" = . ] || {
                        echo "wal-archive contains an unexpected directory: $canonical" >&2
                        return 1
                    }
                else
                    printf '%s\n' "$canonical" | LC_ALL=C grep -Eq '^([0-9A-F]{24}|[0-9A-F]{8}\.history|[0-9A-F]{24}\.[0-9A-F]{8}\.backup)$' || {
                        echo "wal-archive contains an invalid PostgreSQL archive filename: $canonical" >&2
                        return 1
                    }
                fi
                ;;
        esac
    done <"$records"

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
