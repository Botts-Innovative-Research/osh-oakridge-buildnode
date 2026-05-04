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
if [ -f "$ENV_FILE" ]; then
    set -a
    . "$ENV_FILE"
    set +a
    CONTAINER_NAME="${CONTAINER_NAME:-oscar-postgis-container}"
fi

echo "Monitor output: $OUT_DIR"
echo "Launch command: $LAUNCH_CMD"
echo "JVM match: $MATCH_EXPR"
echo "Container name: $CONTAINER_NAME"

if [ ! -x "$LAUNCH_CMD" ]; then
    echo "Error: launch command is not executable: $LAUNCH_CMD"
    exit 1
fi

if ! command -v jcmd >/dev/null 2>&1; then
    echo "Warning: jcmd not found. JFR/NMT snapshots will be skipped."
fi

LAUNCH_PID=""
PID=""
STOPPING=0

dump_once() {
    if [ -z "${PID:-}" ] || ! kill -0 "$PID" 2>/dev/null; then
        return 0
    fi

    local ts d
    ts="$(date +%Y%m%d-%H%M%S)"
    d="$OUT_DIR/$ts"
    mkdir -p "$d"

    echo "Collecting snapshot at $ts for PID $PID"

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

    echo "Stopping OSCAR stack..."

    final_dump

    if [ -n "${PID:-}" ] && kill -0 "$PID" 2>/dev/null; then
        echo "Stopping JVM PID $PID"
        kill "$PID" 2>/dev/null || true

        for _ in 1 2 3 4 5 6 7 8 9 10; do
            if ! kill -0 "$PID" 2>/dev/null; then
                break
            fi
            sleep 1
        done

        if kill -0 "$PID" 2>/dev/null; then
            echo "Force killing JVM PID $PID"
            kill -9 "$PID" 2>/dev/null || true
        fi
    fi

    if [ -n "${LAUNCH_PID:-}" ] && kill -0 "$LAUNCH_PID" 2>/dev/null; then
        echo "Stopping launcher PID $LAUNCH_PID"
        kill "$LAUNCH_PID" 2>/dev/null || true
    fi

    if command -v docker >/dev/null 2>&1; then
        if docker ps --format '{{.Names}}' | grep -Eq "^${CONTAINER_NAME}$"; then
            echo "Stopping container ${CONTAINER_NAME}"
            docker stop "${CONTAINER_NAME}" > "$OUT_DIR/docker-stop.txt" 2>&1 || true
        fi
    fi
}

on_signal() {
    echo "Received stop signal"
    stop_stack
    exit 0
}

on_exit() {
    final_dump
}

trap on_signal INT TERM
trap on_exit EXIT

echo "Starting OSCAR..."
"$LAUNCH_CMD" > "$OUT_DIR/launch.stdout.log" 2> "$OUT_DIR/launch.stderr.log" &
LAUNCH_PID=$!
echo "$LAUNCH_PID" > "$OUT_DIR/launcher-pid.txt"

echo "Waiting for JVM to appear..."
while true; do
    PID="$(pgrep -f "$MATCH_EXPR" | head -n 1 || true)"
    if [ -n "$PID" ]; then
        break
    fi

    if ! kill -0 "$LAUNCH_PID" 2>/dev/null; then
        echo "Launch process exited before JVM appeared."
        wait "$LAUNCH_PID" || true
        exit 1
    fi

    sleep 2
done

echo "Found JVM PID: $PID"
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
    echo "Starting JFR on PID $PID"
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

echo "JVM exited."
wait "$LAUNCH_PID" || true