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
if [ -f "$LATEST_DIR/jvm-pid.txt" ]; then
    PID="$(cat "$LATEST_DIR/jvm-pid.txt" 2>/dev/null || true)"
fi

LIVE_PID=""
LIVE_PID="$(pgrep -f 'com.botts.impl.security.SensorHubWrapper' | head -n 1 || true)"

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

    echo "=== FIRST SNAPSHOT SUMMARY ==="
    echo "First snapshot: ${FIRST_SNAP:-<none>}"
    if [ -n "${FIRST_SNAP:-}" ] && [ -f "$FIRST_SNAP/proc-status.txt" ]; then
        grep -E 'VmRSS|VmSwap|Threads' "$FIRST_SNAP/proc-status.txt" || true
    fi
    if [ -n "${FIRST_SNAP:-}" ] && [ -f "$FIRST_SNAP/nmt-summary.txt" ]; then
        grep '^Total:' "$FIRST_SNAP/nmt-summary.txt" || true
    fi
    if [ -n "${FIRST_SNAP:-}" ] && [ -f "$FIRST_SNAP/gc-heap-info.txt" ]; then
        echo "--- GC heap info ---"
        cat "$FIRST_SNAP/gc-heap-info.txt" || true
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
    if [ -n "${LAST_SNAP:-}" ] && [ -f "$LAST_SNAP/gc-heap-info.txt" ]; then
        echo "--- GC heap info ---"
        cat "$LAST_SNAP/gc-heap-info.txt" || true
    fi
    echo

    echo "=== RECENT TREND (LAST 20 SNAPSHOTS) ==="
    for d in $(find "$LATEST_DIR" -maxdepth 1 -mindepth 1 -type d | sort | tail -n 20); do
        printf "%s " "$(basename "$d")"
        if [ -f "$d/proc-status.txt" ]; then
            grep -E 'VmRSS|VmSwap|Threads' "$d/proc-status.txt" | tr '\n' ' '
        fi
        if [ -f "$d/nmt-summary.txt" ]; then
            grep '^Total:' "$d/nmt-summary.txt" | tr '\n' ' '
        fi
        echo
    done
    echo

    echo "=== LAUNCH LOG TAIL ==="
    if [ -f "$LATEST_DIR/launch.stdout.log" ]; then
        echo "--- launch.stdout.log (last 50 lines) ---"
        tail -n 50 "$LATEST_DIR/launch.stdout.log" || true
    fi
    echo
    if [ -f "$LATEST_DIR/launch.stderr.log" ]; then
        echo "--- launch.stderr.log (last 50 lines) ---"
        tail -n 50 "$LATEST_DIR/launch.stderr.log" || true
    fi
    echo

    echo "=== QUICK READ ==="
    FIRST_RSS=""
    LAST_RSS=""
    FIRST_SWAP=""
    LAST_SWAP=""
    FIRST_THREADS=""
    LAST_THREADS=""

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

    echo "First RSS:     ${FIRST_RSS:-n/a}"
    echo "Latest RSS:    ${LAST_RSS:-n/a}"
    echo "First VmSwap:  ${FIRST_SWAP:-n/a}"
    echo "Latest VmSwap: ${LAST_SWAP:-n/a}"
    echo "First Threads: ${FIRST_THREADS:-n/a}"
    echo "Latest Threads:${LAST_THREADS:-n/a}"
    echo
    echo "Interpretation guide:"
    echo "- Healthy: RSS, VmSwap, and thread count rise at startup and then flatten."
    echo "- Suspicious: RSS, VmSwap, or thread count keep climbing hour after hour."
    echo "- Swap alone is not failure; sustained si/so activity and shrinking available memory are more concerning."
} > "$OUT_FILE"

echo "Wrote report to: $OUT_FILE"