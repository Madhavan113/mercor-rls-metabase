#!/usr/bin/env bash
set -e

echo "=== Populating Metabase ==="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SERVICE_DIR="$(dirname "$SCRIPT_DIR")"
STATE_DIR="$SERVICE_DIR/.state"
STATE_LOCATION="${STATE_LOCATION:-/.apps_data/metabase}"

if [ ! -d "$STATE_LOCATION" ]; then
    echo "No task data found at $STATE_LOCATION -- skipping"
    exit 0
fi

# -------------------------------------------------------------------
# 0. Guard: warn if Metabase is running (H2 files should not be
#    overwritten while the database engine has them open).
# -------------------------------------------------------------------
MB_PID_FILE="$STATE_DIR/metabase.pid"
if [ -f "$MB_PID_FILE" ]; then
    MB_PID="$(cat "$MB_PID_FILE" 2>/dev/null || true)"
    if [ -n "$MB_PID" ] && kill -0 "$MB_PID" 2>/dev/null; then
        echo "WARNING: Metabase appears to be running (PID $MB_PID)."
        echo "Overwriting H2 database files while Metabase is running may"
        echo "corrupt the database. Consider running 'mise run stop' first."
        echo "Proceeding anyway..."
    fi
fi

# -------------------------------------------------------------------
# 1. Restore H2 database files
# -------------------------------------------------------------------
echo "Restoring H2 database from $STATE_LOCATION..."
mkdir -p "$STATE_DIR/metabase"

H2_RESTORED=0
# Copy all metabase database files (try both naming conventions)
if ls "$STATE_LOCATION"/metabase.db.* 1>/dev/null 2>&1; then
    cp -f "$STATE_LOCATION"/metabase.db.* "$STATE_DIR/metabase/" 2>/dev/null || true
    H2_RESTORED=1
    echo "H2 database files restored (db format)."
fi
if ls "$STATE_LOCATION"/metabase.mv.db 1>/dev/null 2>&1 || \
   ls "$STATE_LOCATION"/metabase.trace.db 1>/dev/null 2>&1; then
    cp -f "$STATE_LOCATION"/metabase.* "$STATE_DIR/metabase/" 2>/dev/null || true
    H2_RESTORED=1
    echo "H2 database files restored (mv/trace format)."
fi

if [ "$H2_RESTORED" -eq 0 ]; then
    echo "WARNING: No H2 database files found in $STATE_LOCATION"
    echo "Contents of $STATE_LOCATION/:"
    ls -la "$STATE_LOCATION/" 2>/dev/null || true
fi

# Set permissions
chmod -R 777 "$STATE_DIR/metabase" 2>/dev/null || true

# Verify restored files exist and are non-empty
H2_FILE_COUNT=0
H2_TOTAL_SIZE=0
for f in "$STATE_DIR/metabase"/metabase.*; do
    if [ -f "$f" ]; then
        FILE_SIZE="$(stat -f '%z' "$f" 2>/dev/null || stat -c '%s' "$f" 2>/dev/null || echo 0)"
        H2_FILE_COUNT=$((H2_FILE_COUNT + 1))
        H2_TOTAL_SIZE=$((H2_TOTAL_SIZE + FILE_SIZE))
    fi
done
echo "H2 verification: ${H2_FILE_COUNT} file(s), ${H2_TOTAL_SIZE} bytes total."
if [ "$H2_FILE_COUNT" -eq 0 ]; then
    echo "WARNING: No H2 files present in $STATE_DIR/metabase/ after restore."
fi

# -------------------------------------------------------------------
# 2. Restore any additional assets
# -------------------------------------------------------------------
if [ -d "$STATE_LOCATION/plugins" ]; then
    echo "Restoring plugins..."
    mkdir -p /opt/metabase/plugins
    cp -r "$STATE_LOCATION/plugins/"* /opt/metabase/plugins/ 2>/dev/null || true
fi

# Restore pre-auth browser state for Playwright-based agents.
if [ -f "$STATE_LOCATION/playwright/storageState.json" ]; then
    echo "Restoring Playwright storage state..."
    mkdir -p "$STATE_DIR/playwright"
    cp -f "$STATE_LOCATION/playwright/storageState.json" "$STATE_DIR/playwright/storageState.json"
    chmod -R 777 "$STATE_DIR/playwright" 2>/dev/null || true
    echo "Playwright storage state restored."
else
    echo "WARNING: No Playwright storageState.json found in $STATE_LOCATION/playwright/"
    echo "Pre-authenticated agent sessions will not be available."
fi

echo ""
echo "=== Populate Complete ==="
echo "Restored from: $STATE_LOCATION"
echo "  H2 database files: $H2_FILE_COUNT"
echo "  Playwright state:  $([ -f "$STATE_DIR/playwright/storageState.json" ] && echo 'yes' || echo 'no')"
