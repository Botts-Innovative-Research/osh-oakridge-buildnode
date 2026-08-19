#!/usr/bin/env bash
set -Eeuo pipefail

script_path=${BASH_SOURCE[0]}
case $script_path in */*) script_parent=${script_path%/*} ;; *) script_parent=. ;; esac
repository_root=$(CDPATH= cd -- "$script_parent" && pwd)
cd "$repository_root"

command -v node >/dev/null 2>&1 || { printf 'ERROR: Node.js is required to build OSCAR.\n' >&2; exit 1; }
command -v npm >/dev/null 2>&1 || { printf 'ERROR: npm is required to build OSCAR.\n' >&2; exit 1; }

(
    cd web/oscar-viewer
    npm ci
    npm run build
)

./gradlew build -x test -x osgi

compgen -G 'build/distributions/oscar-*.zip' >/dev/null || {
    printf 'ERROR: The OSCAR connected release ZIP was not produced.\n' >&2
    exit 1
}

printf 'OSCAR connected release created in build/distributions.\n'
