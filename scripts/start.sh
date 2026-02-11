#!/usr/bin/env bash
set -e

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

echo "=== Starting Metabase ==="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SERVICE_DIR="$(dirname "$SCRIPT_DIR")"
STATE_DIR="$SERVICE_DIR/.state"
if [[ "$OSTYPE" == "darwin"* ]]; then
    METABASE_JAR="$SERVICE_DIR/.local/metabase/metabase.jar"
else
    METABASE_JAR="/opt/metabase/metabase.jar"
fi

WEBAPP_PORT="${WEBAPP_PORT:-8081}"
BACKEND_PORT="${BACKEND_PORT:-3000}"

if [ ! -f "$METABASE_JAR" ]; then
    echo "ERROR: Metabase JAR not found at $METABASE_JAR"
    echo "Run: mise run install"
    exit 1
fi

mkdir -p "$STATE_DIR/metabase" "$STATE_DIR/logs" "$STATE_DIR/playwright"
chmod -R 777 "$STATE_DIR" 2>/dev/null || true

# -------------------------------------------------------------------
# 0. Clean up stale processes from previous runs
# -------------------------------------------------------------------
echo "Checking for stale processes..."
if [ -f "$STATE_DIR/metabase.pid" ]; then
    OLD_PID=$(cat "$STATE_DIR/metabase.pid")
    if kill -0 "$OLD_PID" 2>/dev/null; then
        echo "  Killing stale Metabase process (PID: $OLD_PID)..."
        kill "$OLD_PID" 2>/dev/null || true
        sleep 2
        kill -0 "$OLD_PID" 2>/dev/null && kill -9 "$OLD_PID" 2>/dev/null || true
    fi
    rm -f "$STATE_DIR/metabase.pid"
fi
# Also kill any orphaned Metabase processes on our port
if command -v fuser > /dev/null 2>&1; then
    fuser -k "${BACKEND_PORT}/tcp" 2>/dev/null || true
fi
# Stop any stale nginx
nginx -s stop 2>/dev/null || true
sleep 1

# -------------------------------------------------------------------
# 1. Metabase Environment Variables
# -------------------------------------------------------------------
export MB_DB_TYPE="h2"
export MB_DB_FILE="$STATE_DIR/metabase/metabase"
export MB_JETTY_PORT="$BACKEND_PORT"
export MB_ENCRYPTION_SECRET_KEY="bua_metabase_fixed_secret_key_0123456789abcdef"
export MB_SITE_URL="${MB_SITE_URL:-http://localhost:${WEBAPP_PORT}}"
export MB_PASSWORD_COMPLEXITY="weak"
export MB_CHECK_FOR_UPDATES="false"
export MB_ANON_TRACKING_ENABLED="false"
export MB_SEND_NEW_SSO_USER_ADMIN_EMAIL="false"
export MB_ENABLE_EMBEDDING="true"
export MB_SESSION_COOKIES="true"
export MB_REDIRECT_ALL_REQUESTS_TO_HTTPS="false"

# -------------------------------------------------------------------
# 2. Start Metabase
# -------------------------------------------------------------------
echo "Starting Metabase on internal port ${BACKEND_PORT}..."
nohup java --add-opens java.base/java.nio=ALL-UNNAMED \
    -jar "$METABASE_JAR" > "$STATE_DIR/logs/metabase.log" 2>&1 &
MB_PID=$!
echo "$MB_PID" > "$STATE_DIR/metabase.pid"
echo "Metabase PID: $MB_PID"

# -------------------------------------------------------------------
# 3. Start Nginx
# -------------------------------------------------------------------
COOKIE_SECURE="${COOKIE_SECURE:-true}"
if [ -z "${COOKIE_SAMESITE:-}" ]; then
    if [ "$COOKIE_SECURE" = "true" ]; then
        COOKIE_SAMESITE="none"
    else
        COOKIE_SAMESITE="lax"
    fi
fi
if [ "$COOKIE_SECURE" = "true" ]; then
    COOKIE_SECURE_FLAG="secure"
else
    COOKIE_SECURE_FLAG=""
fi
STUDIO_FRAME_ANCESTORS="${STUDIO_FRAME_ANCESTORS:-'self' https://studio.mercor.com https://dev.studio.mercor.com https://demo.studio.mercor.com}"

export WEBAPP_PORT BACKEND_PORT COOKIE_SAMESITE COOKIE_SECURE_FLAG STUDIO_FRAME_ANCESTORS

# Detect mime.types path
if [[ "$OSTYPE" == "darwin"* ]]; then
    if [ -f "/opt/homebrew/etc/nginx/mime.types" ]; then
        export NGINX_MIME_TYPES_PATH="/opt/homebrew/etc/nginx/mime.types"
    elif [ -f "/usr/local/etc/nginx/mime.types" ]; then
        export NGINX_MIME_TYPES_PATH="/usr/local/etc/nginx/mime.types"
    else
        export NGINX_MIME_TYPES_PATH="/etc/nginx/mime.types"
    fi
else
    export NGINX_MIME_TYPES_PATH="/etc/nginx/mime.types"
fi

echo "Starting nginx on port ${WEBAPP_PORT}..."
# Ensure NGINX_MIME_TYPES_PATH is exported if not already
if [ -z "$NGINX_MIME_TYPES_PATH" ]; then
    export NGINX_MIME_TYPES_PATH="/etc/nginx/mime.types"
fi

envsubst '${WEBAPP_PORT} ${BACKEND_PORT} ${COOKIE_SAMESITE} ${COOKIE_SECURE_FLAG} ${STUDIO_FRAME_ANCESTORS} ${NGINX_MIME_TYPES_PATH}' \
    < "$SERVICE_DIR/config/nginx.conf" > /tmp/nginx.conf

mkdir -p /tmp/client_temp /tmp/proxy_temp_path /tmp/fastcgi_temp /tmp/uwsgi_temp /tmp/scgi_temp
nginx -t -c /tmp/nginx.conf
nginx -c /tmp/nginx.conf

# -------------------------------------------------------------------
# 4. Health Checks
# -------------------------------------------------------------------
echo "Waiting for Metabase backend to be ready on port ${BACKEND_PORT}..."
BACKEND_READY=false
for i in $(seq 1 180); do
    if curl -sf "http://localhost:${BACKEND_PORT}/api/health" > /dev/null 2>&1; then
        echo "Metabase backend healthy after ${i}s."
        BACKEND_READY=true
        break
    fi

    # Check if the Metabase process is still alive
    if [ -f "$STATE_DIR/metabase.pid" ]; then
        MB_PID=$(cat "$STATE_DIR/metabase.pid")
        if ! kill -0 "$MB_PID" 2>/dev/null; then
            echo "ERROR: Metabase process died during startup"
            echo "--- Last 50 lines of metabase.log ---"
            tail -n 50 "$STATE_DIR/logs/metabase.log" 2>/dev/null || true
            exit 1
        fi
    fi

    # Progress indicator every 30 seconds
    if [ $((i % 30)) -eq 0 ]; then
        echo "  Still waiting... (${i}s elapsed)"
        # Show the last log line for debugging slow starts
        tail -n 1 "$STATE_DIR/logs/metabase.log" 2>/dev/null || true
    fi

    if [ "$i" -eq 180 ]; then
        echo "ERROR: Metabase backend failed to start after 180 seconds"
        echo "--- Last 50 lines of metabase.log ---"
        tail -n 50 "$STATE_DIR/logs/metabase.log" 2>/dev/null || true
        echo "--- Last 20 lines of nginx_error.log ---"
        tail -n 20 /tmp/nginx_error.log 2>/dev/null || true
        exit 1
    fi
    sleep 1
done

# Verify nginx is proxying correctly through WEBAPP_PORT
echo "Verifying nginx proxy on port ${WEBAPP_PORT}..."
for i in $(seq 1 15); do
    if curl -sf "http://localhost:${WEBAPP_PORT}/api/health" > /dev/null 2>&1; then
        echo "Nginx proxy verified after ${i}s."
        break
    fi
    if [ "$i" -eq 15 ]; then
        echo "WARNING: Nginx proxy health check failed -- backend may still be accessible directly"
        echo "--- Last 20 lines of nginx_error.log ---"
        tail -n 20 /tmp/nginx_error.log 2>/dev/null || true
        echo "--- Last 20 lines of nginx_access.log ---"
        tail -n 20 /tmp/nginx_access.log 2>/dev/null || true
    fi
    sleep 1
done

echo "=== Metabase started ==="
echo "App URL: http://localhost:${WEBAPP_PORT}"
echo "Login: admin@example.com / Admin123!"
