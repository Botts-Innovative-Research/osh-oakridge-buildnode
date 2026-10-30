#!/usr/bin/env bash
set -Eeuo pipefail

script_path=${BASH_SOURCE[0]}
repo_root=$(CDPATH= cd -- "${script_path%/*}/.." && pwd -P)
fixture="$repo_root/tools/test-fixtures/DuckDBNativeTempSmoke.java"
duckdb_jar=${1:-}
probe_image=${OSCAR_JAVA_PROBE_IMAGE:-eclipse-temurin:21.0.10_7-jre-noble@sha256:420374e45e8e9dce3057e768c87a3e8ba58e815049511d8df95ca88a041ec82b}
test_root=$(mktemp -d "$repo_root/.duckdb-native-test.XXXXXX")
fixture_root="$test_root/fixture"

cleanup() {
    case $test_root in
        "$repo_root"/.duckdb-native-test.*)
            chmod -R u+w "$test_root" 2>/dev/null || true
            rm -rf "$test_root"
            ;;
    esac
}
trap cleanup EXIT

command -v docker >/dev/null 2>&1 || {
    printf 'Docker is required for the DuckDB native-temp integration test.\n' >&2
    exit 1
}
command -v javac >/dev/null 2>&1 || {
    printf 'JDK 21 javac is required for the DuckDB native-temp integration test.\n' >&2
    exit 1
}
docker info >/dev/null

if [[ -z $duckdb_jar ]]; then
    duckdb_jar=$(find "$repo_root/build/install/oscar/osh-node-oscar/lib" -maxdepth 1 \
        -type f -name 'duckdb_jdbc-*.jar' -print -quit 2>/dev/null || true)
fi
[[ -n $duckdb_jar && -f $duckdb_jar ]] || {
    printf 'Pass a DuckDB JDBC JAR or run ./gradlew installRelDist first.\n' >&2
    exit 1
}

mkdir "$fixture_root"
javac --release 21 -d "$fixture_root" "$fixture"
cp -- "$duckdb_jar" "$fixture_root/duckdb.jar"
# Docker Desktop virtualizes bind-mount permissions, while a native Linux
# daemon enforces the host modes. Let the deliberately unrelated container UID
# traverse this read-only fixture without making it host-writable.
find "$fixture_root" -type f -exec chmod 0444 {} +
find "$fixture_root" -type d -exec chmod 0555 {} +
docker image inspect "$probe_image" >/dev/null 2>&1 || docker pull "$probe_image" >/dev/null

container_arguments=(
    run --rm --network none --read-only --cap-drop ALL
    --security-opt no-new-privileges --user 10001:10001
    --tmpfs /tmp:rw,noexec,nosuid,nodev,mode=1777
)

baseline_log="$test_root/noexec-baseline.log"
if docker "${container_arguments[@]}" \
    --volume "$fixture_root:/test:ro" \
    --entrypoint java "$probe_image" \
    -Doscar.data.tmpdir=/tmp -cp '/test:/test/duckdb.jar' \
    DuckDBNativeTempSmoke /tmp /tmp >"$baseline_log" 2>&1; then
    printf 'DuckDB unexpectedly loaded its JNI library from noexec /tmp.\n' >&2
    exit 1
fi
grep -Eq 'UnsatisfiedLinkError|failed to map segment|Operation not permitted' "$baseline_log" || {
    printf 'DuckDB baseline failed for an unexpected reason:\n' >&2
    sed -n '1,80p' "$baseline_log" >&2
    exit 1
}

docker "${container_arguments[@]}" \
    --tmpfs /run/oscar-native:rw,exec,nosuid,nodev,size=256m,mode=0700,uid=10001,gid=10001 \
    --volume "$fixture_root:/test:ro" \
    --entrypoint java "$probe_image" \
    -Djava.io.tmpdir=/run/oscar-native -Doscar.data.tmpdir=/tmp \
    -cp '/test:/test/duckdb.jar' \
    DuckDBNativeTempSmoke /run/oscar-native /tmp

printf 'DuckDB JNI failed on noexec /tmp and loaded from the managed native tmpfs.\n'
