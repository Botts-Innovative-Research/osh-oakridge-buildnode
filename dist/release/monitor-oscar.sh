#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${PROJECT_DIR:-$SCRIPT_DIR}"
LAUNCH_CMD="${LAUNCH_CMD:-$PROJECT_DIR/launch-all.sh}"
MATCH_EXPR="${MATCH_EXPR:-com.botts.impl.security.SensorHubWrapper}"
INTERVAL="${INTERVAL:-60}"
OUT_DIR="${OUT_DIR:-$PROJECT_DIR/oscar-monitor-$(date +%Y%m%d-%H%M%S)}"
JFR_NAME="${JFR_NAME:-oscar}"
JFR_MAX_AGE="${JFR_MAX_AGE:-4h}"
JFR_MAX_SIZE="${JFR_MAX_SIZE:-1g}"
ENV_FILE="${ENV_FILE:-$PROJECT_DIR/.env}"

mkdir -p "$OUT_DIR"

CONTAINER_NAME="oscar-postgis-container"
DB_NAME="gis"
DB_USER="postgres"
DB_PASSWORD="postgres"
if [ -f "$ENV_FILE" ]; then
    set -a
    . "$ENV_FILE"
    set +a
    CONTAINER_NAME="${CONTAINER_NAME:-oscar-postgis-container}"
    DB_NAME="${DB_NAME:-gis}"
    DB_USER="${DB_USER:-postgres}"
    DB_PASSWORD="${DB_PASSWORD:-postgres}"
fi

DB_CSV="$OUT_DIR/db-connection-trend.csv"
echo 'timestamp,total_sessions,active,idle,idle_in_transaction,max_connections,superuser_reserved_connections,failed_psql' > "$DB_CSV"

log() {
    printf '%s %s\n' "$(date -Is)" "$*"
}

log "Monitor output: $OUT_DIR"
log "Launch command: $LAUNCH_CMD"
log "JVM match: $MATCH_EXPR"
log "Container name: $CONTAINER_NAME"
log "Database: $DB_NAME user=$DB_USER"

if [ ! -x "$LAUNCH_CMD" ]; then
    echo "Error: launch command is not executable: $LAUNCH_CMD"
    exit 1
fi

if ! command -v jcmd >/dev/null 2>&1; then
    log "Warning: jcmd not found. JFR/NMT snapshots will be skipped."
fi

LAUNCH_PID=""
PID=""
STOPPING=0

run_db_query() {
    local sql="$1"
    docker exec -e PGPASSWORD="$DB_PASSWORD" "$CONTAINER_NAME" \
        psql -U "$DB_USER" -d "$DB_NAME" -At -c "$sql"
}

collect_db_snapshot() {
    local d="$1"
    local ts failed total active idle idle_tx max_conn super_reserved
    ts="$(date -Is)"
    failed=0

    if ! command -v docker >/dev/null 2>&1 || ! docker ps --format '{{.Names}}' | grep -Eq "^${CONTAINER_NAME}$"; then
        echo "Container ${CONTAINER_NAME} not running" > "$d/db-error.txt"
        echo "$ts,,,,,,,1" >> "$DB_CSV"
        return 0
    fi

    if run_db_query "show max_connections;" > "$d/db-max-connections.txt" 2> "$d/db-error.txt"; then
        run_db_query "show superuser_reserved_connections;" > "$d/db-superuser-reserved-connections.txt" 2>> "$d/db-error.txt" || failed=1
        run_db_query "select count(*) from pg_stat_activity;" > "$d/db-total-sessions.txt" 2>> "$d/db-error.txt" || failed=1
        run_db_query "select coalesce(state,'<null>'), count(*) from pg_stat_activity group by state order by count(*) desc;" > "$d/db-by-state.txt" 2>> "$d/db-error.txt" || failed=1
        run_db_query "select coalesce(application_name,'<null>'), coalesce(usename,'<null>'), coalesce(client_addr::text,'<null>'), coalesce(state,'<null>'), count(*) from pg_stat_activity group by application_name, usename, client_addr, state order by count(*) desc limit 20;" > "$d/db-by-app.txt" 2>> "$d/db-error.txt" || failed=1
        run_db_query "select pid, usename, application_name, client_addr, state, backend_start, xact_start, query_start, wait_event_type, wait_event, left(query,120) from pg_stat_activity order by backend_start;" > "$d/db-activity-detail.txt" 2>> "$d/db-error.txt" || failed=1
    else
        failed=1
    fi

    max_conn=""
    super_reserved=""
    total=""
    active=""
    idle=""
    idle_tx=""

    [ -f "$d/db-max-connections.txt" ] && max_conn="$(tr -d '[:space:]' < "$d/db-max-connections.txt" | tail -n 1)"
    [ -f "$d/db-superuser-reserved-connections.txt" ] && super_reserved="$(tr -d '[:space:]' < "$d/db-superuser-reserved-connections.txt" | tail -n 1)"
    [ -f "$d/db-total-sessions.txt" ] && total="$(tr -d '[:space:]' < "$d/db-total-sessions.txt" | tail -n 1)"
    if [ -f "$d/db-by-state.txt" ]; then
        active="$(awk -F'|' '$1=="active" {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}' "$d/db-by-state.txt" | tail -n 1)"
        idle="$(awk -F'|' '$1=="idle" {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}' "$d/db-by-state.txt" | tail -n 1)"
        idle_tx="$(awk -F'|' '$1=="idle in transaction" {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}' "$d/db-by-state.txt" | tail -n 1)"
    fi
    echo "$ts,${total:-},${active:-0},${idle:-0},${idle_tx:-0},${max_conn:-},${super_reserved:-},$failed" >> "$DB_CSV"
}

dump_once() {
    if [ -z "${PID:-}" ] || ! kill -0 "$PID" 2>/dev/null; then
        return 0
    fi

    local ts d
    ts="$(date +%Y%m%d-%H%M%S)"
    d="$OUT_DIR/$ts"
    mkdir -p "$d"

    log "Collecting snapshot at $ts for PID $PID"

    ps -p "$PID" -o pid,ppid,user,%cpu,%mem,vsz,rss,etimes,cmd > "$d/ps.txt" 2>&1 || true
    [ -r "/proc/$PID/status" ] && cat "/proc/$PID/status" > "$d/proc-status.txt" 2>&1 || true
    [ -r "/proc/$PID/smaps_rollup" ] && cat "/proc/$PID/smaps_rollup" > "$d/smaps_rollup.txt" 2>&1 || true

    command -v pmap >/dev/null 2>&1 && pmap -x "$PID" > "$d/pmap-x.txt" 2>&1 || true
    command -v free >/dev/null 2>&1 && free -h > "$d/free.txt" 2>&1 || true
    [ -r /proc/meminfo ] && cat /proc/meminfo > "$d/meminfo.txt" 2>&1 || true
    [ -r /proc/swaps ] && cat /proc/swaps > "$d/swaps.txt" 2>&1 || true
    vmstat 1 5 > "$d/vmstat.txt" 2>&1 || true

    if command -v jcmd >/dev/null 2>&1; then
        jcmd "$PID" VM.native_memory summary > "$d/nmt-summary.txt" 2>&1 || true
        jcmd "$PID" GC.heap_info > "$d/gc-heap-info.txt" 2>&1 || true
        jcmd "$PID" Thread.print > "$d/thread-print.txt" 2>&1 || true
        jcmd "$PID" JFR.check > "$d/jfr-check.txt" 2>&1 || true
    fi

    if command -v docker >/dev/null 2>&1; then
        docker ps --filter "name=$CONTAINER_NAME" > "$d/docker-ps.txt" 2>&1 || true
        docker logs --tail 100 "$CONTAINER_NAME" > "$d/docker-logs-tail.txt" 2>&1 || true
        collect_db_snapshot "$d"
    fi
}

final_dump() {
    if [ -n "${PID:-}" ] && kill -0 "$PID" 2>/dev/null; then
        dump_once
        if command -v jcmd >/dev/null 2>&1; then
            jcmd "$PID" JFR.dump name="$JFR_NAME" filename="$OUT_DIR/${JFR_NAME}-final.jfr" \
                > "$OUT_DIR/jfr-dump-final.txt" 2>&1 || true
        fi
    fi
}

stop_stack() {
    if [ "$STOPPING" -eq 1 ]; then
        return 0
    fi
    STOPPING=1

    log "Stopping OSCAR stack..."
    final_dump

    if [ -n "${PID:-}" ] && kill -0 "$PID" 2>/dev/null; then
        log "Stopping JVM PID $PID"
        kill "$PID" 2>/dev/null || true
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            if ! kill -0 "$PID" 2>/dev/null; then
                break
            fi
            sleep 1
        done
        if kill -0 "$PID" 2>/dev/null; then
            log "Force killing JVM PID $PID"
            kill -9 "$PID" 2>/dev/null || true
        fi
    fi

    if [ -n "${LAUNCH_PID:-}" ] && kill -0 "$LAUNCH_PID" 2>/dev/null; then
        log "Stopping launcher PID $LAUNCH_PID"
        kill "$LAUNCH_PID" 2>/dev/null || true
    fi

    if command -v docker >/dev/null 2>&1; then
        if docker ps --format '{{.Names}}' | grep -Eq "^${CONTAINER_NAME}$"; then
            log "Stopping container ${CONTAINER_NAME}"
            docker stop "$CONTAINER_NAME" > "$OUT_DIR/docker-stop.txt" 2>&1 || true
        fi
    fi
}

on_signal() {
    log "Received stop signal"
    stop_stack
    exit 0
}

on_exit() {
    final_dump
}

trap on_signal INT TERM
trap on_exit EXIT

log "Starting OSCAR..."
"$LAUNCH_CMD" > "$OUT_DIR/launch.stdout.log" 2> "$OUT_DIR/launch.stderr.log" &
LAUNCH_PID=$!
echo "$LAUNCH_PID" > "$OUT_DIR/launcher-pid.txt"

log "Waiting for JVM to appear..."
while true; do
    PID="$(pgrep -f "$MATCH_EXPR" | head -n 1 || true)"
    if [ -n "$PID" ]; then
        break
    fi
    if ! kill -0 "$LAUNCH_PID" 2>/dev/null; then
        log "Launch process exited before JVM appeared."
        wait "$LAUNCH_PID" || true
        exit 1
    fi
    sleep 2
done

log "Found JVM PID: $PID"
echo "$PID" > "$OUT_DIR/jvm-pid.txt"

{
    echo "Timestamp: $(date -Is)"
    echo "Launcher PID: $LAUNCH_PID"
    echo "JVM PID: $PID"
    echo
    echo "Command line:"
    tr '\0' ' ' < "/proc/$PID/cmdline"
    echo
} > "$OUT_DIR/process-info.txt"

if command -v jcmd >/dev/null 2>&1; then
    log "Starting JFR on PID $PID"
    jcmd "$PID" JFR.start \
        name="$JFR_NAME" \
        settings=profile \
        disk=true \
        maxage="$JFR_MAX_AGE" \
        maxsize="$JFR_MAX_SIZE" \
        filename="$OUT_DIR/${JFR_NAME}.jfr" \
        > "$OUT_DIR/jfr-start.txt" 2>&1 || true

    jcmd "$PID" VM.native_memory baseline \
        > "$OUT_DIR/nmt-baseline.txt" 2>&1 || true
fi

dump_once

while kill -0 "$PID" 2>/dev/null; do
    sleep "$INTERVAL"
    dump_once
done

log "JVM exited."
wait "$LAUNCH_PID" || true
