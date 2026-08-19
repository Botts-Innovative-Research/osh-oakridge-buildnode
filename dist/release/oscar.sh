#!/bin/sh
set -eu
SCRIPT_PATH=$0
case $SCRIPT_PATH in */*) SCRIPT_PARENT=${SCRIPT_PATH%/*} ;; *) SCRIPT_PARENT=. ;; esac
SCRIPT_DIR=$(CDPATH= cd -- "$SCRIPT_PARENT" && pwd)
exec bash "$SCRIPT_DIR/oscar-setup.sh" "$@"
