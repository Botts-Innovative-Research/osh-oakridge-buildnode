#!/usr/bin/env bash
set -Eeuo pipefail

# Exercise the Docker Compose layer with two disposable, deliberately
# unlabelled volumes. Setup/adoption ownership is covered by
# test-storage-scripts.sh; this test proves that the external-volume model does
# not ask Compose to reconcile or replace those immutable resources.

command -v docker >/dev/null 2>&1 || {
    printf 'Docker is required for the Compose volume-preservation test.\n' >&2
    exit 1
}
docker info >/dev/null
docker compose version >/dev/null

probe_image=${OSCAR_COMPOSE_PROBE_IMAGE:-ubuntu:24.04@sha256:008173c23f95b170204355c12626cb5a965d779a7e1283b09e9cffbb1bf33ca3}
probe_id="$$-${RANDOM:-0}"
project="oscar-volume-preservation-$probe_id"
state_volume="${project}-state"
postgres_volume="${project}-postgres"
state_created=false
postgres_created=false

compose_model=$(printf '%s\n' \
    'services:' \
    '  probe:' \
    "    image: $probe_image" \
    '    command: ["sh", "-eu", "-c", "test -f /state/canary; test -f /postgres/canary; sleep 300"]' \
    '    volumes:' \
    '      - state:/state' \
    '      - postgres:/postgres' \
    'volumes:' \
    '  state:' \
    '    external: true' \
    "    name: $state_volume" \
    '  postgres:' \
    '    external: true' \
    "    name: $postgres_volume")

cleanup() {
    printf '%s\n' "$compose_model" |
        docker compose --project-name "$project" --file - down --remove-orphans >/dev/null 2>&1 || true
    $state_created && docker volume rm "$state_volume" >/dev/null 2>&1 || true
    $postgres_created && docker volume rm "$postgres_volume" >/dev/null 2>&1 || true
}

docker image inspect "$probe_image" >/dev/null 2>&1 || docker pull "$probe_image" >/dev/null
for volume in "$state_volume" "$postgres_volume"; do
    if docker volume inspect "$volume" >/dev/null 2>&1; then
        printf 'Refusing to reuse pre-existing test volume: %s\n' "$volume" >&2
        exit 1
    fi
done
if docker network inspect "${project}_default" >/dev/null 2>&1 ||
   docker container inspect "${project}-probe-1" >/dev/null 2>&1 ||
   docker ps -aq --filter "label=com.docker.compose.project=$project" | grep -q .; then
    printf 'Refusing to reuse pre-existing Compose test resources for project %s.\n' "$project" >&2
    exit 1
fi
trap cleanup EXIT
docker volume create "$state_volume" >/dev/null
state_created=true
docker volume create "$postgres_volume" >/dev/null
postgres_created=true

for volume in "$state_volume" "$postgres_volume"; do
    docker run --rm --network none --volume "$volume:/data" "$probe_image" \
        sh -eu -c 'printf preserved >/data/canary'
done

state_identity_before=$(docker volume inspect --format '{{.Name}}|{{.CreatedAt}}|{{.Mountpoint}}|{{json .Labels}}' "$state_volume")
postgres_identity_before=$(docker volume inspect --format '{{.Name}}|{{.CreatedAt}}|{{.Mountpoint}}|{{json .Labels}}' "$postgres_volume")

compose_output=$(printf '%s\n' "$compose_model" |
    docker compose --project-name "$project" --file - up --detach --no-build --pull never 2>&1)
printf '%s\n' "$compose_output"

container_name="${project}-probe-1"
container_before=$(docker container inspect --format '{{.Id}}' "$container_name")
ordinary_output=$(printf '%s\n' "$compose_model" |
    docker compose --project-name "$project" --file - up --detach --no-build --pull never 2>&1)
container_after_ordinary=$(docker container inspect --format '{{.Id}}' "$container_name")
[[ $container_after_ordinary == "$container_before" ]] || {
    printf 'Ordinary Compose up unexpectedly recreated an unchanged service.\n' >&2
    exit 1
}

recreate_output=$(printf '%s\n' "$compose_model" |
    docker compose --project-name "$project" --file - up --detach --force-recreate --no-build --pull never 2>&1)
container_after_recreate=$(docker container inspect --format '{{.Id}}' "$container_name")
[[ $container_after_recreate != "$container_before" ]] || {
    printf 'Compose --force-recreate retained the old service container.\n' >&2
    exit 1
}

if printf '%s\n%s\n%s\n' "$compose_output" "$ordinary_output" "$recreate_output" | grep -Eqi \
    'volume[^[:cntrl:]]*(does not match|doesn.t match|will be (recreated|removed)|data loss)|data[^[:cntrl:]]*(will be lost|loss)|already exists[^[:cntrl:]]*not created'; then
    printf 'Compose offered to reconcile or recreate an adopted data volume.\n' >&2
    exit 1
fi

state_identity_after=$(docker volume inspect --format '{{.Name}}|{{.CreatedAt}}|{{.Mountpoint}}|{{json .Labels}}' "$state_volume")
postgres_identity_after=$(docker volume inspect --format '{{.Name}}|{{.CreatedAt}}|{{.Mountpoint}}|{{json .Labels}}' "$postgres_volume")
[[ $state_identity_after == "$state_identity_before" ]] || {
    printf 'Compose changed the state-volume identity.\n' >&2
    exit 1
}
[[ $postgres_identity_after == "$postgres_identity_before" ]] || {
    printf 'Compose changed the PostgreSQL-volume identity.\n' >&2
    exit 1
}

for volume in "$state_volume" "$postgres_volume"; do
    docker run --rm --network none --volume "$volume:/data:ro" "$probe_image" \
        sh -eu -c 'test "$(cat /data/canary)" = preserved'
done

printf 'Compose recreated only the requested service container and preserved both adopted external volumes.\n'
