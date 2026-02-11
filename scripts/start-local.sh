#!/usr/bin/env bash
set -e

# =============================================================================
# Local Development Mode (macOS / Host)
# =============================================================================
# Runs Metabase locally with a custom Nginx config that bypasses some
# production constraints (like SSL) but enforces iframe security headers.
#
# Usage: ./scripts/start-local.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SERVICE_DIR="$(dirname "$SCRIPT_DIR")"
STATE_DIR="$SERVICE_DIR/.state"

# Default ports for local dev
WEBAPP_PORT="${WEBAPP_PORT:-8081}"
BACKEND_PORT="${BACKEND_PORT:-3000}"
TEST_PORT="${TEST_PORT:-8888}"

# macOS Java detection (Homebrew)
if [[ "$OSTYPE" == "darwin"* ]]; then
    if [ -z "$JAVA_HOME" ] && [ -d "/opt/homebrew/opt/openjdk@21" ]; then
        export JAVA_HOME="/opt/homebrew/opt/openjdk@21"
        export PATH="$JAVA_HOME/bin:$PATH"
    elif [ -z "$JAVA_HOME" ] && [ -d "/usr/local/opt/openjdk@21" ]; then
        export JAVA_HOME="/usr/local/opt/openjdk@21"
        export PATH="$JAVA_HOME/bin:$PATH"
    fi
fi

# Local Metabase location (from updated install.sh)
METABASE_JAR="$SERVICE_DIR/.local/metabase/metabase.jar"

if [ ! -f "$METABASE_JAR" ]; then
    echo "ERROR: Metabase JAR not found at $METABASE_JAR"
    echo "Run: ./scripts/install.sh"
    exit 1
fi

mkdir -p "$STATE_DIR/metabase" "$STATE_DIR/logs"
chmod -R 777 "$STATE_DIR" 2>/dev/null || true

# cleanup function
cleanup() {
    echo ""
    echo "=== Shutting down... ==="
    if [ -n "$MB_PID" ]; then kill "$MB_PID" 2>/dev/null || true; fi
    if [ -n "$NGINX_PID" ]; then kill "$NGINX_PID" 2>/dev/null || true; fi
    if [ -n "$TEST_PID" ]; then kill "$TEST_PID" 2>/dev/null || true; fi
    nginx -s stop 2>/dev/null || true
    echo "Done."
}
trap cleanup EXIT

# -------------------------------------------------------------------
# 1. Start Metabase
# -------------------------------------------------------------------
echo "=== Starting Metabase (Local) ==="
export MB_DB_TYPE="h2"
export MB_DB_FILE="$STATE_DIR/metabase/metabase"
export MB_JETTY_PORT="$BACKEND_PORT"
export MB_ENCRYPTION_SECRET_KEY="bua_metabase_fixed_secret_key_0123456789abcdef"
export MB_SITE_URL="${MB_SITE_URL:-http://localhost:${WEBAPP_PORT}}"
export MB_PASSWORD_COMPLEXITY="weak"
export MB_CHECK_FOR_UPDATES="false"
export MB_ANON_TRACKING_ENABLED="false"
export MB_ENABLE_EMBEDDING="true"
export MB_SESSION_COOKIES="true"
# Local dev doesn't enforce HTTPS redirect
export MB_REDIRECT_ALL_REQUESTS_TO_HTTPS="false"

nohup java --add-opens java.base/java.nio=ALL-UNNAMED \
    -jar "$METABASE_JAR" > "$STATE_DIR/logs/metabase.log" 2>&1 &
MB_PID=$!
echo "Metabase PID: $MB_PID"

# -------------------------------------------------------------------
# 2. Start Nginx
# -------------------------------------------------------------------
echo "=== Starting Nginx (Local Config) ==="
COOKIE_SECURE="${COOKIE_SECURE:-false}" # Local is HTTP
if [ "$COOKIE_SECURE" = "true" ]; then
    COOKIE_SAMESITE="none"
    COOKIE_SECURE_FLAG="secure"
else
    # Lax needed for HTTP local testing usually, but we want to simulate iframe
    COOKIE_SAMESITE="lax"
    COOKIE_SECURE_FLAG=""
fi
# Use quotes correctly for CSP value
STUDIO_FRAME_ANCESTORS="${STUDIO_FRAME_ANCESTORS:-'self' http://localhost:${TEST_PORT}}"

export WEBAPP_PORT BACKEND_PORT COOKIE_SAMESITE COOKIE_SECURE_FLAG STUDIO_FRAME_ANCESTORS

# Use envsubst with listed variables to avoid substituting $host etc
envsubst '${WEBAPP_PORT} ${BACKEND_PORT} ${COOKIE_SAMESITE} ${COOKIE_SECURE_FLAG} ${STUDIO_FRAME_ANCESTORS}' \
    < "$SERVICE_DIR/config/nginx-local.conf" > /tmp/nginx-local.conf

nginx -c /tmp/nginx-local.conf &
NGINX_PID=$!
echo "Nginx started on port $WEBAPP_PORT"

# -------------------------------------------------------------------
# 3. Start Test Harness
# -------------------------------------------------------------------
echo "=== Starting Test Harness ==="
python3 -m http.server "$TEST_PORT" --directory "$SERVICE_DIR" --bind 127.0.0.1 > /dev/null 2>&1 &
TEST_PID=$!
echo "Test Harness running at http://localhost:$TEST_PORT/test-iframe.html"

# -------------------------------------------------------------------
# 4. Wait
# -------------------------------------------------------------------
echo "Waiting for Metabase health..."
for i in {1..60}; do
    if curl -s "http://localhost:${BACKEND_PORT}/api/health" > /dev/null; then
        echo "Metabase is UP!"
        break
    fi
    echo -n "."
    sleep 2
done

echo ""
echo "==========================================================="
echo "  Metabase App:   http://localhost:$WEBAPP_PORT"
echo "  Test Harness:   http://localhost:$TEST_PORT/test-iframe.html"
echo "==========================================================="
echo "Press Ctrl+C to stop."

wait
