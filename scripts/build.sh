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

echo "=== Building Metabase ==="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SERVICE_DIR="$(dirname "$SCRIPT_DIR")"
STATE_DIR="$SERVICE_DIR/.state"
PLAYWRIGHT_STATE_PATH="$STATE_DIR/playwright/storageState.json"
if [[ "$OSTYPE" == "darwin"* ]]; then
    METABASE_JAR="$SERVICE_DIR/.local/metabase/metabase.jar"
else
    METABASE_JAR="/opt/metabase/metabase.jar"
fi
MB_PID=""

if [ ! -f "$METABASE_JAR" ]; then
    echo "ERROR: Metabase JAR not found at $METABASE_JAR"
    echo "Run: mise run install"
    exit 1
fi

mkdir -p "$STATE_DIR/metabase" "$STATE_DIR/logs" "$(dirname "$PLAYWRIGHT_STATE_PATH")"
chmod -R 777 "$STATE_DIR" 2>/dev/null || true

cleanup() {
    if [ -n "${MB_PID:-}" ] && kill -0 "$MB_PID" 2>/dev/null; then
        kill "$MB_PID" 2>/dev/null || true
        for i in $(seq 1 30); do
            if ! kill -0 "$MB_PID" 2>/dev/null; then
                return
            fi
            if [ "$i" -eq 30 ]; then
                kill -9 "$MB_PID" 2>/dev/null || true
                return
            fi
            sleep 1
        done
    fi
}

trap cleanup EXIT

# -------------------------------------------------------------------
# 1. Start Metabase to initialize H2 database + run setup wizard
# -------------------------------------------------------------------
echo "Starting Metabase for initial setup..."

export MB_DB_TYPE="h2"
export MB_DB_FILE="$STATE_DIR/metabase/metabase"
export MB_JETTY_PORT="3000"
export MB_ENCRYPTION_SECRET_KEY="bua_metabase_fixed_secret_key_0123456789abcdef"
export MB_PASSWORD_COMPLEXITY="weak"
export MB_CHECK_FOR_UPDATES="false"
export MB_ANON_TRACKING_ENABLED="false"
export MB_SEND_NEW_SSO_USER_ADMIN_EMAIL="false"

java --add-opens java.base/java.nio=ALL-UNNAMED \
    -jar "$METABASE_JAR" > "$STATE_DIR/logs/metabase-build.log" 2>&1 &
MB_PID=$!

echo "Metabase PID: $MB_PID"

# Wait for Metabase to be ready (up to 180 seconds)
echo "Waiting for Metabase to initialize..."
for i in $(seq 1 180); do
    if curl -sf "http://localhost:3000/api/health" > /dev/null 2>&1; then
        echo "Metabase is healthy after ${i}s"
        break
    fi
    if ! kill -0 $MB_PID 2>/dev/null; then
        echo "ERROR: Metabase process died during initialization"
        tail -n 100 "$STATE_DIR/logs/metabase-build.log" 2>/dev/null || true
        exit 1
    fi
    if [ $i -eq 180 ]; then
        echo "ERROR: Metabase failed to start after 180 seconds"
        tail -n 100 "$STATE_DIR/logs/metabase-build.log" 2>/dev/null || true
        kill $MB_PID 2>/dev/null || true
        exit 1
    fi
    sleep 1
done

# -------------------------------------------------------------------
# 2. Wait for setup to be possible
# -------------------------------------------------------------------
echo "Checking setup status..."
SETUP_TOKEN=""
for i in $(seq 1 30); do
    SETUP_STATUS=$(curl -sf "http://localhost:3000/api/session/properties" 2>/dev/null || echo "{}")
    HAS_SETUP=$(echo "$SETUP_STATUS" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    token = data.get('setup-token', '')
    print(token if token else 'DONE')
except:
    print('WAIT')
" 2>/dev/null || echo "WAIT")

    if [ "$HAS_SETUP" = "DONE" ]; then
        echo "Setup already completed."
        break
    elif [ "$HAS_SETUP" = "WAIT" ]; then
        echo "  Waiting for setup API... (${i}/30)"
        sleep 2
    else
        echo "Got setup token: ${HAS_SETUP:0:8}..."
        SETUP_TOKEN="$HAS_SETUP"
        break
    fi
done

# -------------------------------------------------------------------
# 3. Run automated setup via API
# -------------------------------------------------------------------
if [ -n "$SETUP_TOKEN" ]; then
    echo "Running Metabase setup wizard via API..."

    SETUP_RESPONSE=$(curl -sf -X POST "http://localhost:3000/api/setup" \
        -H "Content-Type: application/json" \
        -d '{
            "token": "'"$SETUP_TOKEN"'",
            "user": {
                "email": "admin@example.com",
                "password": "Admin123!",
                "first_name": "Admin",
                "last_name": "User",
                "site_name": "Metabase BUA"
            },
            "prefs": {
                "site_name": "Metabase BUA",
                "site_locale": "en",
                "allow_tracking": false
            }
        }' 2>&1) || true

    echo "Setup response: ${SETUP_RESPONSE:0:200}"
else
    echo "Setup was already completed (no setup token available)."
fi

# -------------------------------------------------------------------
# 4. Verify admin login and generate Playwright storage state
# -------------------------------------------------------------------
echo "Verifying admin login..."
LOGIN_HEADERS="$(mktemp)"
LOGIN_BODY="$(mktemp)"
curl -sS -D "$LOGIN_HEADERS" -o "$LOGIN_BODY" \
    -X POST "http://localhost:3000/api/session" \
    -H "Content-Type: application/json" \
    -d '{"username": "admin@example.com", "password": "Admin123!"}' || true

SESSION_ID=$(python3 - "$LOGIN_BODY" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        payload = json.load(f)
    print(payload.get("id", ""))
except Exception:
    print("")
PY
)

if [ -z "$SESSION_ID" ]; then
    echo "ERROR: Unable to log in as admin@example.com after setup."
    echo "Login response:"
    cat "$LOGIN_BODY" 2>/dev/null || true
    rm -f "$LOGIN_HEADERS" "$LOGIN_BODY"
    exit 1
fi

echo "Generating Playwright storage state..."
python3 - "$LOGIN_HEADERS" "$SESSION_ID" "$PLAYWRIGHT_STATE_PATH" <<'PY'
import json
import sys
import time

headers_path = sys.argv[1]
session_id = sys.argv[2]
output_path = sys.argv[3]

cookies = []
with open(headers_path, "r", encoding="utf-8", errors="ignore") as f:
    for line in f:
        if not line.lower().startswith("set-cookie:"):
            continue

        raw_cookie = line.split(":", 1)[1].strip()
        parts = [part.strip() for part in raw_cookie.split(";") if part.strip()]
        if not parts or "=" not in parts[0]:
            continue

        name, value = parts[0].split("=", 1)
        cookie = {
            "name": name,
            "value": value,
            "domain": "localhost",
            "path": "/",
            "expires": -1,
            "httpOnly": False,
            "secure": False,
            "sameSite": "Lax",
        }

        for part in parts[1:]:
            lower = part.lower()
            if lower == "secure":
                cookie["secure"] = True
            elif lower == "httponly":
                cookie["httpOnly"] = True
            elif lower.startswith("path="):
                cookie["path"] = part.split("=", 1)[1] or "/"
            elif lower.startswith("domain="):
                cookie["domain"] = part.split("=", 1)[1] or "localhost"
            elif lower.startswith("max-age="):
                try:
                    cookie["expires"] = int(time.time()) + int(part.split("=", 1)[1])
                except Exception:
                    pass
            elif lower.startswith("samesite="):
                value = part.split("=", 1)[1].strip().lower()
                if value == "none":
                    cookie["sameSite"] = "None"
                elif value == "strict":
                    cookie["sameSite"] = "Strict"
                else:
                    cookie["sameSite"] = "Lax"

        cookies.append(cookie)

# Fallback cookie if Metabase returns no Set-Cookie header.
if not any(cookie.get("name") == "metabase.SESSION" for cookie in cookies):
    cookies.append(
        {
            "name": "metabase.SESSION",
            "value": session_id,
            "domain": "localhost",
            "path": "/",
            "expires": -1,
            "httpOnly": True,
            "secure": True,
            "sameSite": "None",
        }
    )

with open(output_path, "w", encoding="utf-8") as f:
    json.dump({"cookies": cookies, "origins": []}, f, indent=2)
PY

rm -f "$LOGIN_HEADERS" "$LOGIN_BODY"

# -------------------------------------------------------------------
# 5. Stop Metabase
# -------------------------------------------------------------------
echo "Stopping Metabase build instance..."
cleanup
trap - EXIT

# -------------------------------------------------------------------
# 6. Verify H2 database + storage state were created
# -------------------------------------------------------------------
echo "Verifying H2 database..."
if ls "$STATE_DIR/metabase/metabase.db."* 1>/dev/null 2>&1 || \
   ls "$STATE_DIR/metabase/metabase."* 1>/dev/null 2>&1; then
    echo "H2 database files found:"
    ls -la "$STATE_DIR/metabase/" 2>/dev/null || true
else
    echo "WARNING: H2 database files not found at expected location"
    echo "Contents of $STATE_DIR/metabase/:"
    ls -la "$STATE_DIR/metabase/" 2>/dev/null || true
fi

if [ -f "$PLAYWRIGHT_STATE_PATH" ]; then
    echo "Playwright storage state created at: $PLAYWRIGHT_STATE_PATH"
else
    echo "WARNING: storage state was not created."
fi

echo "=== Metabase Build Complete ==="
echo "Admin user: admin@example.com / Admin123!"
