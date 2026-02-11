#!/usr/bin/env bash
set -e

echo "=== Snapshotting Metabase ==="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SERVICE_DIR="$(dirname "$SCRIPT_DIR")"
STATE_DIR="$SERVICE_DIR/.state"
STATE_LOCATION="${STATE_LOCATION:-/.apps_data/metabase}"
WEBAPP_PORT="${WEBAPP_PORT:-8081}"

mkdir -p "$STATE_LOCATION"

# -------------------------------------------------------------------
# 0. If Metabase is running, trigger a sync to flush pending writes.
#    H2 in embedded mode may buffer writes; issuing an API call that
#    touches the DB helps ensure data is on disk before we copy.
# -------------------------------------------------------------------
MB_PID_FILE="$STATE_DIR/metabase.pid"
if [ -f "$MB_PID_FILE" ]; then
    MB_PID="$(cat "$MB_PID_FILE" 2>/dev/null || true)"
    if [ -n "$MB_PID" ] && kill -0 "$MB_PID" 2>/dev/null; then
        echo "Metabase is running (PID $MB_PID). Triggering sync before snapshot..."
        # Hit health endpoint to confirm API is responsive, then trigger sync
        if curl -sf "http://localhost:${WEBAPP_PORT}/api/health" > /dev/null 2>&1; then
            # A lightweight GET to exercise the DB connection and flush any buffers
            curl -sf "http://localhost:${WEBAPP_PORT}/api/session/properties" > /dev/null 2>&1 || true
            # Brief pause to allow H2 to flush
            sleep 2
            echo "Sync flush completed."
        else
            echo "WARNING: Metabase PID exists but API is not responding."
            echo "H2 snapshot may contain stale data."
        fi
    fi
fi

# -------------------------------------------------------------------
# 1. Export H2 database files
# -------------------------------------------------------------------
echo "Exporting H2 database to $STATE_LOCATION..."

# Clean stale H2 files at destination for deterministic round-trip
rm -f "$STATE_LOCATION"/metabase.db.* 2>/dev/null || true
rm -f "$STATE_LOCATION"/metabase.mv.db "$STATE_LOCATION"/metabase.trace.db 2>/dev/null || true

H2_EXPORTED=0
if ls "$STATE_DIR/metabase/metabase.db."* 1>/dev/null 2>&1; then
    cp -f "$STATE_DIR/metabase/metabase.db."* "$STATE_LOCATION/" 2>/dev/null || true
    H2_EXPORTED=1
    echo "H2 database files exported (db format)."
fi
if ls "$STATE_DIR/metabase/metabase.mv.db" 1>/dev/null 2>&1 || \
   ls "$STATE_DIR/metabase/metabase.trace.db" 1>/dev/null 2>&1; then
    cp -f "$STATE_DIR/metabase/metabase."* "$STATE_LOCATION/" 2>/dev/null || true
    H2_EXPORTED=1
    echo "H2 database files exported (mv/trace format)."
fi

if [ "$H2_EXPORTED" -eq 0 ]; then
    echo "WARNING: No H2 database files found at $STATE_DIR/metabase/"
    echo "Contents of $STATE_DIR/metabase/:"
    ls -la "$STATE_DIR/metabase/" 2>/dev/null || true
fi

# Verify exported files
H2_FILE_COUNT=0
H2_TOTAL_SIZE=0
for f in "$STATE_LOCATION"/metabase.*; do
    if [ -f "$f" ]; then
        FILE_SIZE="$(stat -f '%z' "$f" 2>/dev/null || stat -c '%s' "$f" 2>/dev/null || echo 0)"
        H2_FILE_COUNT=$((H2_FILE_COUNT + 1))
        H2_TOTAL_SIZE=$((H2_TOTAL_SIZE + FILE_SIZE))
    fi
done
echo "H2 verification: ${H2_FILE_COUNT} file(s), ${H2_TOTAL_SIZE} bytes total."

# -------------------------------------------------------------------
# 2. Export plugins (if any)
# -------------------------------------------------------------------
if [ -d "/opt/metabase/plugins" ] && [ "$(ls -A /opt/metabase/plugins 2>/dev/null)" ]; then
    echo "Exporting plugins..."
    mkdir -p "$STATE_LOCATION/plugins"
    cp -r /opt/metabase/plugins/* "$STATE_LOCATION/plugins/" 2>/dev/null || true
fi

# -------------------------------------------------------------------
# 3. Export Playwright storage state for pre-authenticated sessions.
# -------------------------------------------------------------------
if [ -f "$STATE_DIR/playwright/storageState.json" ]; then
    echo "Exporting Playwright storage state..."
    mkdir -p "$STATE_LOCATION/playwright"
    cp -f "$STATE_DIR/playwright/storageState.json" "$STATE_LOCATION/playwright/storageState.json"
    echo "Playwright storage state exported."
else
    echo "WARNING: No storageState.json found at $STATE_DIR/playwright/"
    echo "Pre-authenticated agent sessions will not be available after populate."
fi

echo ""
echo "=== Snapshot Complete ==="
echo "Data saved to: $STATE_LOCATION"
echo "  H2 database files: $H2_FILE_COUNT"
echo "  Playwright state:  $([ -f "$STATE_LOCATION/playwright/storageState.json" ] && echo 'yes' || echo 'no')"
echo ""
ls -la "$STATE_LOCATION/" 2>/dev/null || true
