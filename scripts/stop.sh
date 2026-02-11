#!/usr/bin/env bash
set -e

echo "=== Stopping Metabase ==="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SERVICE_DIR="$(dirname "$SCRIPT_DIR")"
STATE_DIR="$SERVICE_DIR/.state"

# -------------------------------------------------------------------
# 1. Stop Metabase
# -------------------------------------------------------------------
if [ -f "$STATE_DIR/metabase.pid" ]; then
    MB_PID=$(cat "$STATE_DIR/metabase.pid")
    echo "Stopping Metabase (PID: $MB_PID)..."
    kill "$MB_PID" 2>/dev/null || true

    # Wait for clean shutdown (up to 30s)
    for i in $(seq 1 30); do
        if ! kill -0 "$MB_PID" 2>/dev/null; then
            echo "Metabase stopped cleanly after ${i}s"
            break
        fi
        if [ $i -eq 30 ]; then
            echo "Force killing Metabase..."
            kill -9 "$MB_PID" 2>/dev/null || true
        fi
        sleep 1
    done
    rm -f "$STATE_DIR/metabase.pid"
else
    echo "No Metabase PID file found, killing any java processes..."
    pkill -f "/opt/metabase/metabase.jar" 2>/dev/null || true
fi

# -------------------------------------------------------------------
# 2. Stop Nginx
# -------------------------------------------------------------------
echo "Stopping nginx..."
nginx -s stop 2>/dev/null || true
sleep 1
# Force kill any remaining nginx workers
pkill nginx 2>/dev/null || true

# -------------------------------------------------------------------
# 3. Verify all processes stopped
# -------------------------------------------------------------------
STILL_RUNNING=false
if pgrep -f "/opt/metabase/metabase.jar" > /dev/null 2>&1; then
    echo "WARNING: Metabase java process still running after stop"
    STILL_RUNNING=true
fi
if pgrep nginx > /dev/null 2>&1; then
    echo "WARNING: nginx process still running after stop"
    STILL_RUNNING=true
fi

if [ "$STILL_RUNNING" = "true" ]; then
    echo "Attempting force cleanup..."
    pkill -9 -f "/opt/metabase/metabase.jar" 2>/dev/null || true
    pkill -9 nginx 2>/dev/null || true
    sleep 1
fi

echo "=== Metabase stopped ==="
