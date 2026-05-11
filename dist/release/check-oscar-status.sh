#!/bin/bash
set -euo pipefail

BASE_DIR="${1:-.}"
LATEST_DIR="${2:-}"
OUT_FILE="${3:-}"

cd "$BASE_DIR"

if [ -z "$LATEST_DIR" ]; then
    LATEST_DIR="$(ls -td oscar-monitor-* 2>/dev/null | head -n 1 || true)"
fi

if [ -z "$LATEST_DIR" ] || [ ! -d "$LATEST_DIR" ]; then
    echo "Error: no oscar-monitor-* directory found."
    exit 1
fi

if [ -z "$OUT_FILE" ]; then
    OUT_FILE="oscar-status-$(date +%Y%m%d-%H%M%S).txt"
fi

FIRST_SNAP="$(find "$LATEST_DIR" -maxdepth 1 -mindepth 1 -type d | sort | head -n 1 || true)"
LAST_SNAP="$(find "$LATEST_DIR" -maxdepth 1 -mindepth 1 -type d | sort | tail -n 1 || true)"
PID=""
[ -f "$LATEST_DIR/jvm-pid.txt" ] && PID="$(cat "$LATEST_DIR/jvm-pid.txt" 2>/dev/null || true)"
LIVE_PID="$(pgrep -f 'com.botts.impl.security.SensorHubWrapper' | head -n 1 || true)"

extract_db_metric() {
    local file="$1" default="$2"
    if [ -f "$file" ]; then
        tr -d '[:space:]' < "$file" | tail -n 1
    else
        echo "$default"
    fi
}

calc_slots() {
    local max="$1" reserved="$2"
    if [[ "$max" =~ ^[0-9]+$ ]] && [[ "$reserved" =~ ^[0-9]+$ ]]; then
        echo $((max - reserved))
    fi
}

{
    echo "OSCAR STATUS REPORT"
    echo "Generated: $(date -Is)"
    echo "Base directory: $(pwd)"
    echo "Monitor directory: $LATEST_DIR"
    echo "Output file: $OUT_FILE"
    echo

    echo "=== PROCESS STATUS ==="
    echo "PID from monitor: ${PID:-<none>}"
    echo "Live OSCAR PID:   ${LIVE_PID:-<none>}"
    echo
    pgrep -af monitor-oscar.sh || true
    pgrep -af 'com.botts.impl.security.SensorHubWrapper' || true
    echo
    docker ps --filter name=oscar-postgis-container || true
    echo

    echo "=== SYSTEM MEMORY ==="
    free -h || true
    echo
    echo "--- vmstat (5 samples) ---"
    vmstat 1 5 || true
    echo

    if [ -n "${LIVE_PID:-}" ] && [ -r "/proc/$LIVE_PID/status" ]; then
        echo "=== LIVE JVM /proc STATUS ==="
        grep -E 'Name|State|VmSize|VmRSS|VmSwap|Threads' "/proc/$LIVE_PID/status" || true
        echo
    fi

    if [ -n "${LIVE_PID:-}" ] && [ -r "/proc/$LIVE_PID/smaps_rollup" ]; then
        echo "=== LIVE JVM SMAPS ROLLUP ==="
        cat "/proc/$LIVE_PID/smaps_rollup" || true
        echo
    fi

    if [ -n "${LIVE_PID:-}" ] && command -v jcmd >/dev/null 2>&1; then
        echo "=== LIVE JVM JFR STATUS ==="
        jcmd "$LIVE_PID" JFR.check || true
        echo
        echo "=== LIVE JVM GC HEAP INFO ==="
        jcmd "$LIVE_PID" GC.heap_info || true
        echo
        echo "=== LIVE JVM NATIVE MEMORY SUMMARY ==="
        jcmd "$LIVE_PID" VM.native_memory summary || true
        echo
    fi

    echo "=== LIVE POSTGRES STATUS ==="
    if docker ps --format '{{.Names}}' | grep -Eq '^oscar-postgis-container$'; then
        if [ -f "$LAST_SNAP/db-max-connections.txt" ]; then
            echo "max_connections: $(extract_db_metric "$LAST_SNAP/db-max-connections.txt" n/a)"
        fi
        if [ -f "$LAST_SNAP/db-superuser-reserved-connections.txt" ]; then
            echo "superuser_reserved_connections: $(extract_db_metric "$LAST_SNAP/db-superuser-reserved-connections.txt" n/a)"
        fi
        if [ -f "$LAST_SNAP/db-total-sessions.txt" ]; then
            echo "total_sessions: $(extract_db_metric "$LAST_SNAP/db-total-sessions.txt" n/a)"
        fi
        if [ -f "$LAST_SNAP/db-by-state.txt" ]; then
            echo
            echo "--- db-by-state ---"
            cat "$LAST_SNAP/db-by-state.txt" || true
        fi
        if [ -f "$LAST_SNAP/db-by-app.txt" ]; then
            echo
            echo "--- db-by-app ---"
            cat "$LAST_SNAP/db-by-app.txt" || true
        fi
        if [ -f "$LAST_SNAP/db-activity-detail.txt" ]; then
            echo
            echo "--- db-activity-detail (first 40 lines) ---"
            head -n 40 "$LAST_SNAP/db-activity-detail.txt" || true
        fi
        if [ -f "$LAST_SNAP/db-error.txt" ]; then
            echo
            echo "--- db-error ---"
            cat "$LAST_SNAP/db-error.txt" || true
        fi
    else
        echo "Postgres container is not running."
    fi
    echo

    echo "=== FIRST SNAPSHOT SUMMARY ==="
    echo "First snapshot: ${FIRST_SNAP:-<none>}"
    if [ -n "${FIRST_SNAP:-}" ] && [ -f "$FIRST_SNAP/proc-status.txt" ]; then
        grep -E 'VmRSS|VmSwap|Threads' "$FIRST_SNAP/proc-status.txt" || true
    fi
    if [ -n "${FIRST_SNAP:-}" ] && [ -f "$FIRST_SNAP/nmt-summary.txt" ]; then
        grep '^Total:' "$FIRST_SNAP/nmt-summary.txt" || true
    fi
    if [ -n "${FIRST_SNAP:-}" ] && [ -f "$FIRST_SNAP/db-total-sessions.txt" ]; then
        echo "db total sessions: $(extract_db_metric "$FIRST_SNAP/db-total-sessions.txt" n/a)"
    fi
    echo

    echo "=== LATEST SNAPSHOT SUMMARY ==="
    echo "Latest snapshot: ${LAST_SNAP:-<none>}"
    if [ -n "${LAST_SNAP:-}" ] && [ -f "$LAST_SNAP/proc-status.txt" ]; then
        grep -E 'VmRSS|VmSwap|Threads' "$LAST_SNAP/proc-status.txt" || true
    fi
    if [ -n "${LAST_SNAP:-}" ] && [ -f "$LAST_SNAP/nmt-summary.txt" ]; then
        grep '^Total:' "$LAST_SNAP/nmt-summary.txt" || true
    fi
    if [ -n "${LAST_SNAP:-}" ] && [ -f "$LAST_SNAP/db-total-sessions.txt" ]; then
        echo "db total sessions: $(extract_db_metric "$LAST_SNAP/db-total-sessions.txt" n/a)"
    fi
    echo

    echo "=== RECENT TREND (LAST 20 SNAPSHOTS) ==="
    for d in $(find "$LATEST_DIR" -maxdepth 1 -mindepth 1 -type d | sort | tail -n 20); do
        printf "%s " "$(basename "$d")"
        [ -f "$d/proc-status.txt" ] && grep -E 'VmRSS|VmSwap|Threads' "$d/proc-status.txt" | tr '\n' ' '
        [ -f "$d/nmt-summary.txt" ] && grep '^Total:' "$d/nmt-summary.txt" | tr '\n' ' '
        if [ -f "$d/db-total-sessions.txt" ]; then
            printf "db_total=%s " "$(extract_db_metric "$d/db-total-sessions.txt" n/a)"
        fi
        if [ -f "$d/db-by-state.txt" ]; then
            printf "db_active=%s " "$(awk -F'|' '$1=="active" {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}' "$d/db-by-state.txt" | tail -n 1)"
            printf "db_idle=%s " "$(awk -F'|' '$1=="idle" {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}' "$d/db-by-state.txt" | tail -n 1)"
            printf "db_idle_tx=%s " "$(awk -F'|' '$1=="idle in transaction" {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}' "$d/db-by-state.txt" | tail -n 1)"
        fi
        if [ -f "$d/db-error.txt" ] && [ -s "$d/db-error.txt" ]; then
            printf "db_error=yes "
        fi
        echo
    done
    echo

    if [ -f "$LATEST_DIR/db-connection-trend.csv" ]; then
        echo "=== DB CONNECTION TREND CSV (LAST 40 LINES) ==="
        tail -n 40 "$LATEST_DIR/db-connection-trend.csv" || true
        echo
    fi

    echo "=== LOG TAILS ==="
    [ -f "$LATEST_DIR/launch.stdout.log" ] && { echo '--- launch.stdout.log (last 50 lines) ---'; tail -n 50 "$LATEST_DIR/launch.stdout.log"; echo; }
    [ -f "$LATEST_DIR/launch.stderr.log" ] && { echo '--- launch.stderr.log (last 50 lines) ---'; tail -n 50 "$LATEST_DIR/launch.stderr.log"; echo; }
    [ -f "$LAST_SNAP/docker-logs-tail.txt" ] && { echo '--- postgres docker logs (last captured 100 lines) ---'; tail -n 100 "$LAST_SNAP/docker-logs-tail.txt"; echo; }

    echo "=== QUICK READ ==="
    FIRST_RSS=""; LAST_RSS=""; FIRST_SWAP=""; LAST_SWAP=""; FIRST_THREADS=""; LAST_THREADS=""
    FIRST_DB_TOTAL=""; LAST_DB_TOTAL=""; FIRST_MAX=""; LAST_MAX=""; FIRST_RESERVED=""; LAST_RESERVED=""

    if [ -n "${FIRST_SNAP:-}" ] && [ -f "$FIRST_SNAP/proc-status.txt" ]; then
        FIRST_RSS="$(grep '^VmRSS:' "$FIRST_SNAP/proc-status.txt" | awk '{print $2 " " $3}' || true)"
        FIRST_SWAP="$(grep '^VmSwap:' "$FIRST_SNAP/proc-status.txt" | awk '{print $2 " " $3}' || true)"
        FIRST_THREADS="$(grep '^Threads:' "$FIRST_SNAP/proc-status.txt" | awk '{print $2}' || true)"
    fi
    if [ -n "${LAST_SNAP:-}" ] && [ -f "$LAST_SNAP/proc-status.txt" ]; then
        LAST_RSS="$(grep '^VmRSS:' "$LAST_SNAP/proc-status.txt" | awk '{print $2 " " $3}' || true)"
        LAST_SWAP="$(grep '^VmSwap:' "$LAST_SNAP/proc-status.txt" | awk '{print $2 " " $3}' || true)"
        LAST_THREADS="$(grep '^Threads:' "$LAST_SNAP/proc-status.txt" | awk '{print $2}' || true)"
    fi
    [ -n "${FIRST_SNAP:-}" ] && FIRST_DB_TOTAL="$(extract_db_metric "$FIRST_SNAP/db-total-sessions.txt" n/a)"
    [ -n "${LAST_SNAP:-}" ] && LAST_DB_TOTAL="$(extract_db_metric "$LAST_SNAP/db-total-sessions.txt" n/a)"
    [ -n "${FIRST_SNAP:-}" ] && FIRST_MAX="$(extract_db_metric "$FIRST_SNAP/db-max-connections.txt" n/a)"
    [ -n "${LAST_SNAP:-}" ] && LAST_MAX="$(extract_db_metric "$LAST_SNAP/db-max-connections.txt" n/a)"
    [ -n "${FIRST_SNAP:-}" ] && FIRST_RESERVED="$(extract_db_metric "$FIRST_SNAP/db-superuser-reserved-connections.txt" n/a)"
    [ -n "${LAST_SNAP:-}" ] && LAST_RESERVED="$(extract_db_metric "$LAST_SNAP/db-superuser-reserved-connections.txt" n/a)"

    echo "First RSS:     ${FIRST_RSS:-n/a}"
    echo "Latest RSS:    ${LAST_RSS:-n/a}"
    echo "First VmSwap:  ${FIRST_SWAP:-n/a}"
    echo "Latest VmSwap: ${LAST_SWAP:-n/a}"
    echo "First Threads: ${FIRST_THREADS:-n/a}"
    echo "Latest Threads:${LAST_THREADS:-n/a}"
    echo "First DB total sessions:  ${FIRST_DB_TOTAL:-n/a}"
    echo "Latest DB total sessions: ${LAST_DB_TOTAL:-n/a}"
    echo "First DB usable client slots: $(calc_slots "$FIRST_MAX" "$FIRST_RESERVED")"
    echo "Latest DB usable client slots: $(calc_slots "$LAST_MAX" "$LAST_RESERVED")"
    echo
    echo "Interpretation guide:"
    echo "- Healthy memory: RSS, VmSwap, and thread count rise at startup and then flatten."
    echo "- Healthy DB: total sessions rise at startup and then plateau well below usable client slots."
    echo "- Suspicious DB: total sessions keep climbing, idle sessions pile up, or db_error shows too many clients already."
} > "$OUT_FILE"

echo "Wrote report to: $OUT_FILE"
