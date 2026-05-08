#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${PROJECT_DIR:-$SCRIPT_DIR}"
LAUNCH_CMD="${LAUNCH_CMD:-$PROJECT_DIR/launch-all.sh}"
MATCH_EXPR="${MATCH_EXPR:-com.botts.impl.security.SensorHubWrapper}"
INTERVAL="${INTERVAL:-60}"
MAX_WAIT_SECONDS="${MAX_WAIT_SECONDS:-300}"
OUT_DIR="${OUT_DIR:-$PROJECT_DIR/oscar-monitor-$(date +%Y%m%d-%H%M%S)}"
JFR_NAME="${JFR_NAME:-oscar}"
JFR_MAX_AGE="${JFR_MAX_AGE:-4h}"
JFR_MAX_SIZE="${JFR_MAX_SIZE:-1g}"
ENV_FILE="${ENV_FILE:-$PROJECT_DIR/.env}"
ATTACH_TO_EXISTING="${ATTACH_TO_EXISTING:-0}"
FORCE_RESTART="${FORCE_RESTART:-0}"

STATE_DIR="$PROJECT_DIR/.monitor-state"
MONITOR_LOCK_DIR="$STATE_DIR/lock"
MONITOR_PID_FILE="$STATE_DIR/monitor.pid"
ACTIVE_MONITOR_FILE="$STATE_DIR/active-monitor-dir.txt"
STATUS_FILE="$PROJECT_DIR/monitor.last-status"
ERROR_FILE="$PROJECT_DIR/monitor.last-error"

CONTAINER_NAME="oscar-postgis-container"
DB_NAME="gis"
DB_USER="postgres"
DB_PASSWORD="postgres"
DB_CSV=""

LAUNCH_PID=""
PID=""
STOPPING=0
USE_EXISTING=0
MONITOR_LOCK_OWNED=0
FINAL_STATUS_WRITTEN=0

log() {
    printf '%s %s\n' "$(date -Is)" "$*"
}

write_status() {
    printf '%s %s\n' "$(date -Is)" "$*" > "$STATUS_FILE"
}

write_error() {
    printf '%s %s\n' "$(date -Is)" "$*" > "$ERROR_FILE"
}

clear_error() {
    : > "$ERROR_FILE"
}

finalize_status() {
    write_status "$*"
    FINAL_STATUS_WRITTEN=1
}

require_cmd() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: required command not found: $cmd" >&2
        write_error "Missing required command: $cmd"
        finalize_status "FAILED missing_dependency command=$cmd"
        exit 1
    fi
}

get_java_major() {
    java -version 2>&1 | awk -F'"' '/version/ { split($2, v, "."); print v[1]; exit }'
}

check_dependencies() {
    require_cmd bash
    require_cmd java
    require_cmd docker
    require_cmd pgrep

    local java_major
    java_major="$(get_java_major || true)"
    if [[ -z "$java_major" || ! "$java_major" =~ ^[0-9]+$ || "$java_major" -lt 21 ]]; then
        echo "Error: Java 21 or newer is required to run OSCAR monitoring." >&2
        write_error "Java 21 or newer is required to run OSCAR monitoring."
        finalize_status "FAILED java_too_old"
        exit 1
    fi

    if ! command -v jcmd >/dev/null 2>&1; then
        log "Warning: jcmd not found. JFR/NMT snapshots will be skipped."
    fi
}

read_monitor_pid() {
    if [ -f "$MONITOR_PID_FILE" ]; then
        tr -d '[:space:]' < "$MONITOR_PID_FILE"
    fi
}

is_monitor_pid_running() {
    local pid="$1"
    [ -n "$pid" ] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    ps -p "$pid" -o args= 2>/dev/null | grep -Fq "monitor-oscar.sh"
}

remove_monitor_state() {
    rm -f "$MONITOR_PID_FILE" "$ACTIVE_MONITOR_FILE"
    if [ -d "$MONITOR_LOCK_DIR" ]; then
        rmdir "$MONITOR_LOCK_DIR" 2>/dev/null || rm -rf "$MONITOR_LOCK_DIR" 2>/dev/null || true
    fi
}

release_monitor_lock() {
    if [ "$MONITOR_LOCK_OWNED" -eq 1 ]; then
        local current_pid=""
        current_pid="$(read_monitor_pid || true)"
        if [ "$current_pid" = "$$" ] || [ -z "$current_pid" ]; then
            remove_monitor_state
        fi
        MONITOR_LOCK_OWNED=0
    fi
}

refuse_existing_monitor() {
    local existing_pid="$1"
    local existing_dir=""
    if [ -f "$ACTIVE_MONITOR_FILE" ]; then
        existing_dir="$(cat "$ACTIVE_MONITOR_FILE" 2>/dev/null || true)"
    fi

    echo "Error: Another monitor-oscar.sh instance is already running with PID $existing_pid." >&2
    if [ -n "$existing_dir" ]; then
        echo "Active monitor output: $existing_dir" >&2
    fi
    echo "Run ./stop-all.sh or ./monitor-oscar.sh stop before starting another monitor." >&2

    if [ -n "$existing_dir" ]; then
        write_error "Duplicate monitor start refused. Existing monitor PID=$existing_pid output=$existing_dir"
        finalize_status "FAILED duplicate_monitor existing_pid=$existing_pid output=$existing_dir"
    else
        write_error "Duplicate monitor start refused. Existing monitor PID=$existing_pid"
        finalize_status "FAILED duplicate_monitor existing_pid=$existing_pid"
    fi
    exit 1
}

preflight_existing_monitor() {
    local existing_pid=""
    existing_pid="$(read_monitor_pid || true)"
    if [ -n "$existing_pid" ] && is_monitor_pid_running "$existing_pid"; then
        refuse_existing_monitor "$existing_pid"
    fi
    if [ -n "$existing_pid" ] || [ -d "$MONITOR_LOCK_DIR" ] || [ -f "$ACTIVE_MONITOR_FILE" ]; then
        log "Removing stale OSCAR monitor state."
        remove_monitor_state
    fi
}

acquire_monitor_lock() {
    local existing_pid=""
    mkdir -p "$STATE_DIR"

    if mkdir "$MONITOR_LOCK_DIR" 2>/dev/null; then
        echo "$$" > "$MONITOR_PID_FILE"
        MONITOR_LOCK_OWNED=1
        return 0
    fi

    sleep 1
    existing_pid="$(read_monitor_pid || true)"
    if [ -n "$existing_pid" ] && is_monitor_pid_running "$existing_pid"; then
        refuse_existing_monitor "$existing_pid"
    fi

    log "Removing stale OSCAR monitor lock state."
    remove_monitor_state
    if ! mkdir "$MONITOR_LOCK_DIR" 2>/dev/null; then
        echo "Error: Could not acquire OSCAR monitor lock at $MONITOR_LOCK_DIR" >&2
        write_error "Could not acquire OSCAR monitor lock at $MONITOR_LOCK_DIR"
        finalize_status "FAILED lock_acquire path=$MONITOR_LOCK_DIR"
        exit 1
    fi

    echo "$$" > "$MONITOR_PID_FILE"
    MONITOR_LOCK_OWNED=1
}

find_existing_oscar_pid() {
    pgrep -f "$MATCH_EXPR" | head -n 1 || true
}

find_all_existing_oscar_pids() {
    pgrep -f "$MATCH_EXPR" || true
}

stop_existing_oscar() {
    local pids="$1"
    if [ -z "$pids" ]; then
        return 0
    fi

    log "Stopping existing OSCAR instance(s): $pids"
    kill $pids 2>/dev/null || true

    local waited=0
    while [ "$waited" -lt 15 ]; do
        sleep 1
        waited=$((waited + 1))
        if [ -z "$(find_all_existing_oscar_pids)" ]; then
            return 0
        fi
    done

    log "Force killing existing OSCAR instance(s): $pids"
    kill -9 $pids 2>/dev/null || true
    sleep 1

    if [ -n "$(find_all_existing_oscar_pids)" ]; then
        echo "Error: unable to stop existing OSCAR instance(s)." >&2
        write_error "Unable to stop existing OSCAR instance(s): $pids"
        finalize_status "FAILED existing_oscar_stop pids=$pids"
        exit 1
    fi
}

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

    if ! docker ps --format '{{.Names}}' | grep -Eq "^${CONTAINER_NAME}$"; then
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

    docker ps --filter "name=$CONTAINER_NAME" > "$d/docker-ps.txt" 2>&1 || true
    docker logs --tail 100 "$CONTAINER_NAME" > "$d/docker-logs-tail.txt" 2>&1 || true
    collect_db_snapshot "$d"
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

    if docker ps --format '{{.Names}}' | grep -Eq "^${CONTAINER_NAME}$"; then
        log "Stopping container ${CONTAINER_NAME}"
        docker stop "$CONTAINER_NAME" > "$OUT_DIR/docker-stop.txt" 2>&1 || true
    fi
}

on_signal() {
    log "Received stop signal"
    write_status "STOPPING signal_received monitor_pid=$$ output=$OUT_DIR"
    stop_stack
    finalize_status "STOPPED signal monitor_pid=$$ output=$OUT_DIR"
    exit 0
}

on_exit() {
    local ec="$?"
    final_dump
    if [ "$FINAL_STATUS_WRITTEN" -eq 0 ]; then
        if [ "$ec" -eq 0 ]; then
            if [ "$STOPPING" -eq 1 ]; then
                finalize_status "STOPPED monitor_pid=$$ output=$OUT_DIR"
            elif [ -n "${PID:-}" ]; then
                finalize_status "EXITED jvm_pid=$PID monitor_pid=$$ output=$OUT_DIR"
            else
                finalize_status "EXITED monitor_pid=$$ output=$OUT_DIR"
            fi
        else
            finalize_status "FAILED exit_code=$ec monitor_pid=$$ output=$OUT_DIR"
        fi
    fi
    release_monitor_lock
}

if [ "${1:-}" = "stop" ]; then
    mkdir -p "$STATE_DIR"
    monitor_pid="$(read_monitor_pid || true)"
    active_dir=""
    if [ -f "$ACTIVE_MONITOR_FILE" ]; then
        active_dir="$(cat "$ACTIVE_MONITOR_FILE" 2>/dev/null || true)"
    fi

    if [ -n "$monitor_pid" ] && is_monitor_pid_running "$monitor_pid"; then
        write_status "STOP_REQUESTED monitor_pid=$monitor_pid output=$active_dir"
        clear_error
        kill "$monitor_pid" 2>/dev/null || true
        echo "OSCAR monitor stop requested for PID $monitor_pid."
        exit 0
    fi

    remove_monitor_state
    write_status "STOP_REQUESTED no_active_monitor"
    clear_error
    echo "OSCAR monitor is not running."
    exit 0
fi

trap on_signal INT TERM
trap on_exit EXIT

mkdir -p "$STATE_DIR"
write_status "STARTING monitor_pid=$$ output=$OUT_DIR"
clear_error

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

check_dependencies
preflight_existing_monitor
acquire_monitor_lock
mkdir -p "$OUT_DIR"
echo "$OUT_DIR" > "$ACTIVE_MONITOR_FILE"

DB_CSV="$OUT_DIR/db-connection-trend.csv"
echo 'timestamp,total_sessions,active,idle,idle_in_transaction,max_connections,superuser_reserved_connections,failed_psql' > "$DB_CSV"

log "Monitor output: $OUT_DIR"
log "Launch command: $LAUNCH_CMD"
log "JVM match: $MATCH_EXPR"
log "Container name: $CONTAINER_NAME"
log "Database: $DB_NAME user=$DB_USER"
write_status "RUNNING monitor_pid=$$ output=$OUT_DIR"

if [ ! -x "$LAUNCH_CMD" ] && [ "$ATTACH_TO_EXISTING" != "1" ]; then
    echo "Error: launch command is not executable: $LAUNCH_CMD" >&2
    write_error "Launch command is not executable: $LAUNCH_CMD"
    finalize_status "FAILED launch_not_executable path=$LAUNCH_CMD"
    exit 1
fi

existing_pids="$(find_all_existing_oscar_pids)"
if [ -n "$existing_pids" ]; then
    if [ "$ATTACH_TO_EXISTING" = "1" ]; then
        PID="$(printf '%s\n' "$existing_pids" | head -n 1)"
        USE_EXISTING=1
        log "Attaching monitor to existing OSCAR PID $PID"
        clear_error
        write_status "RUNNING attached monitor_pid=$$ jvm_pid=$PID output=$OUT_DIR"
    elif [ "$FORCE_RESTART" = "1" ]; then
        log "Existing OSCAR instance found: $existing_pids"
        stop_existing_oscar "$existing_pids"
    else
        echo "OSCAR is already running with PID(s): $existing_pids" >&2
        echo "Set ATTACH_TO_EXISTING=1 to monitor the running instance, or FORCE_RESTART=1 to replace it." >&2
        write_error "OSCAR is already running with PID(s): $existing_pids"
        finalize_status "FAILED oscar_already_running pids=$existing_pids"
        exit 1
    fi
fi

if [ "$USE_EXISTING" = "0" ]; then
    log "Starting OSCAR..."
    write_status "WAITING_FOR_JVM monitor_pid=$$ output=$OUT_DIR"
    "$LAUNCH_CMD" > "$OUT_DIR/launch.stdout.log" 2> "$OUT_DIR/launch.stderr.log" &
    LAUNCH_PID=$!
    echo "$LAUNCH_PID" > "$OUT_DIR/launcher-pid.txt"

    waited=0
    while true; do
        PID="$(find_existing_oscar_pid)"
        if [ -n "$PID" ]; then
            break
        fi
        if ! kill -0 "$LAUNCH_PID" 2>/dev/null; then
            write_error "Launch process exited before OSCAR JVM appeared. Check $OUT_DIR/launch.stdout.log and $OUT_DIR/launch.stderr.log"
            finalize_status "FAILED launch_exited_before_jvm output=$OUT_DIR"
            exit 1
        fi
        if [ "$waited" -ge "$MAX_WAIT_SECONDS" ]; then
            log "Timed out waiting for JVM after ${MAX_WAIT_SECONDS}s"
            write_error "Timed out waiting for JVM after ${MAX_WAIT_SECONDS}s. Check $OUT_DIR/launch.stdout.log and $OUT_DIR/launch.stderr.log"
            finalize_status "FAILED wait_for_jvm_timeout output=$OUT_DIR"
            exit 1
        fi
        sleep 2
        waited=$((waited + 2))
    done
else
    : > "$OUT_DIR/launch.stdout.log"
    : > "$OUT_DIR/launch.stderr.log"
fi

log "Found JVM PID: $PID"
echo "$PID" > "$OUT_DIR/jvm-pid.txt"
write_status "RUNNING monitor_pid=$$ jvm_pid=$PID output=$OUT_DIR"
clear_error

{
    echo "Timestamp: $(date -Is)"
    echo "Monitor PID: $$"
    echo "Launcher PID: ${LAUNCH_PID:-}"
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
    write_status "RUNNING monitor_pid=$$ jvm_pid=$PID output=$OUT_DIR"
done

log "JVM exited."
if [ -n "$LAUNCH_PID" ]; then
    wait "$LAUNCH_PID" || true
fi
finalize_status "EXITED jvm_pid=$PID monitor_pid=$$ output=$OUT_DIR"
