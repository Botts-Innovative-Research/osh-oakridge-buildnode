#!/usr/bin/env bash
set -Eeuo pipefail

script_path=${BASH_SOURCE[0]}
case $script_path in */*) script_parent=${script_path%/*} ;; *) script_parent=. ;; esac
tools_dir=$(CDPATH= cd -- "$script_parent" && pwd)
project_dir=$(CDPATH= cd -- "$tools_dir/.." && pwd)
build_dir="$project_dir/build"
force=false

usage() {
    cat <<'EOF'
Reset local Docker containers/images and remove this project's build directory.

Usage:
  tools/reset-docker-build.sh [--force]

Options:
  --force    Run without an interactive confirmation prompt.
  --help     Show this help text.

This removes every Docker container and image visible to the current Docker
context. It does not remove Docker volumes.
EOF
}

while (($#)); do
    case "$1" in
        --force) force=true; shift ;;
        --help|-h) usage; exit 0 ;;
        *) printf 'ERROR: Unknown option: %s\n' "$1" >&2; usage >&2; exit 1 ;;
    esac
done

require_docker() {
    command -v docker >/dev/null 2>&1 || {
        printf 'ERROR: Docker CLI is not available.\n' >&2
        exit 1
    }
    docker info >/dev/null 2>&1 || {
        printf 'ERROR: Docker Engine is not ready or the current user cannot access it.\n' >&2
        exit 1
    }
}

confirm_reset() {
    $force && return 0
    printf 'This will remove ALL Docker containers and images in the current Docker context.\n' >&2
    printf 'It will also remove: %s\n' "$build_dir" >&2
    read -r -p 'Type RESET to continue: ' response
    [[ $response == RESET ]] || {
        printf 'Reset cancelled.\n' >&2
        exit 0
    }
}

remove_containers() {
    local containers
    containers=$(docker ps -aq | sort -u)
    if [[ -n $containers ]]; then
        docker rm -f $containers
    else
        printf 'No Docker containers to remove.\n'
    fi
}

remove_images() {
    local images
    images=$(docker images -aq | sort -u)
    if [[ -n $images ]]; then
        docker rmi -f $images
    else
        printf 'No Docker images to remove.\n'
    fi
}

remove_build_dir() {
    if [[ -d $build_dir ]]; then
        rm -rf "$build_dir"
        printf 'Removed %s\n' "$build_dir"
    else
        printf 'No build directory to remove: %s\n' "$build_dir"
    fi
}

require_docker
confirm_reset

remove_containers
remove_images
remove_build_dir

printf 'Docker containers/images and project build directory reset complete.\n'
