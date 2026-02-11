#!/usr/bin/env bash
set -euo pipefail

echo "=== Seeding Metabase with Sample Data ==="

WEBAPP_PORT="${WEBAPP_PORT:-8081}"
BASE_URL="http://localhost:${WEBAPP_PORT}"
AUTH_HEADER=""
SAMPLE_DB_ID=""
DASH_CREATED_NEW=0
SEED_AUTH_RETRIES="${SEED_AUTH_RETRIES:-90}"
SEED_AUTH_RETRY_SLEEP="${SEED_AUTH_RETRY_SLEEP:-2}"
SEED_DB_LOOKUP_RETRIES="${SEED_DB_LOOKUP_RETRIES:-60}"
SEED_DB_LOOKUP_SLEEP="${SEED_DB_LOOKUP_SLEEP:-2}"
SEED_SYNC_WAIT="${SEED_SYNC_WAIT:-30}"

# Track seed outcomes for summary
SEED_WARNINGS=()

fail() {
    echo "ERROR: $1"
    exit 1
}

warn() {
    echo "WARNING: $1"
    SEED_WARNINGS+=("$1")
}

parse_session_id() {
    local raw_json="${1:-}"
    RAW_JSON="$raw_json" python3 - <<'PY'
import json
import os

raw = os.environ.get("RAW_JSON", "").strip()
if not raw:
    print("")
    raise SystemExit(0)

try:
    obj = json.loads(raw)
except Exception:
    print("")
    raise SystemExit(0)

if isinstance(obj, dict):
    value = obj.get("id", "")
    print(value if value is not None else "")
else:
    print("")
PY
}

parse_generic_id() {
    local raw_json="${1:-}"
    RAW_JSON="$raw_json" python3 - <<'PY'
import json
import os

raw = os.environ.get("RAW_JSON", "").strip()
if not raw:
    print("")
    raise SystemExit(0)

try:
    obj = json.loads(raw)
except Exception:
    print("")
    raise SystemExit(0)

def extract(o):
    if isinstance(o, dict):
        if "id" in o and o["id"] is not None:
            return str(o["id"])
        for key in ("data", "collection", "dashboard", "card"):
            v = o.get(key)
            result = extract(v)
            if result:
                return result
    elif isinstance(o, list):
        for item in o:
            result = extract(item)
            if result:
                return result
    return ""

print(extract(obj))
PY
}

find_sample_db_id() {
    local db_json="$1"
    RAW_JSON="$db_json" python3 - <<'PY'
import json
import os

try:
    data = json.loads(os.environ.get("RAW_JSON", ""))
except Exception:
    print("")
    raise SystemExit(0)

dbs = []
if isinstance(data, dict) and isinstance(data.get("data"), list):
    dbs = data["data"]
elif isinstance(data, list):
    dbs = data

for db in dbs:
    if not isinstance(db, dict):
        continue
    name = str(db.get("name", "")).lower()
    if "sample" in name:
        print(db.get("id", ""))
        raise SystemExit(0)

print("")
PY
}

list_database_names() {
    local db_json="$1"
    RAW_JSON="$db_json" python3 - <<'PY'
import json
import os

try:
    data = json.loads(os.environ.get("RAW_JSON", ""))
except Exception:
    print("")
    raise SystemExit(0)

dbs = []
if isinstance(data, dict) and isinstance(data.get("data"), list):
    dbs = data["data"]
elif isinstance(data, list):
    dbs = data

names = []
for db in dbs:
    if isinstance(db, dict):
        name = db.get("name")
        if name:
            names.append(str(name))

print(", ".join(names))
PY
}

find_card_id_by_name() {
    local target_name="$1"
    local cards_json
    cards_json="$(curl -sS -H "$AUTH_HEADER" "${BASE_URL}/api/card?f=all" || echo '[]')"

    RAW_JSON="$cards_json" python3 - "$target_name" <<'PY'
import json
import os
import sys

target = sys.argv[1]

try:
    data = json.loads(os.environ.get("RAW_JSON", ""))
except Exception:
    print("")
    raise SystemExit(0)

cards = []
if isinstance(data, dict) and isinstance(data.get("data"), list):
    cards = data["data"]
elif isinstance(data, list):
    cards = data

for card in cards:
    if not isinstance(card, dict):
        continue
    if card.get("name") == target and not card.get("archived", False):
        print(card.get("id", ""))
        raise SystemExit(0)

print("")
PY
}

find_collection_id_by_name() {
    local target_name="$1"
    local collections_json
    collections_json="$(curl -sS -H "$AUTH_HEADER" "${BASE_URL}/api/collection" || echo '[]')"

    RAW_JSON="$collections_json" python3 - "$target_name" <<'PY'
import json
import os
import sys

target = sys.argv[1]

try:
    data = json.loads(os.environ.get("RAW_JSON", ""))
except Exception:
    print("")
    raise SystemExit(0)

items = []
if isinstance(data, dict):
    if isinstance(data.get("data"), list):
        items.extend(data["data"])
    if isinstance(data.get("collections"), list):
        items.extend(data["collections"])
elif isinstance(data, list):
    items = data

for item in items:
    if not isinstance(item, dict):
        continue
    if item.get("name") == target and item.get("id") is not None:
        print(item["id"])
        raise SystemExit(0)

print("")
PY
}

find_dashboard_id_by_name() {
    local target_name="$1"
    local dashboards_json
    dashboards_json="$(curl -sS -H "$AUTH_HEADER" "${BASE_URL}/api/dashboard" || echo '[]')"

    RAW_JSON="$dashboards_json" python3 - "$target_name" <<'PY'
import json
import os
import sys

target = sys.argv[1]

try:
    data = json.loads(os.environ.get("RAW_JSON", ""))
except Exception:
    print("")
    raise SystemExit(0)

items = []
if isinstance(data, dict) and isinstance(data.get("data"), list):
    items = data["data"]
elif isinstance(data, list):
    items = data

for item in items:
    if not isinstance(item, dict):
        continue
    if item.get("name") == target and item.get("id") is not None:
        print(item["id"])
        raise SystemExit(0)

print("")
PY
}

get_or_create_collection() {
    local name="$1"
    local color="$2"
    local id

    id="$(find_collection_id_by_name "$name")"
    if [ -n "$id" ]; then
        echo "$id|existing"
        return 0
    fi

    local response
    response="$(curl -sS -X POST "${BASE_URL}/api/collection" \
        -H "$AUTH_HEADER" \
        -H "Content-Type: application/json" \
        -d "{\"name\":\"${name}\",\"color\":\"${color}\"}" || true)"
    id="$(parse_generic_id "$response")"

    if [ -z "$id" ]; then
        id="$(find_collection_id_by_name "$name")"
    fi

    if [ -z "$id" ]; then
        return 1
    fi

    echo "$id|created"
}

get_or_create_dashboard() {
    local name="$1"
    local description="$2"
    local id

    id="$(find_dashboard_id_by_name "$name")"
    if [ -n "$id" ]; then
        DASH_CREATED_NEW=0
        echo "$id"
        return 0
    fi

    local response
    response="$(curl -sS -X POST "${BASE_URL}/api/dashboard" \
        -H "$AUTH_HEADER" \
        -H "Content-Type: application/json" \
        -d "{\"name\":\"${name}\",\"description\":\"${description}\"}" || true)"
    id="$(parse_generic_id "$response")"

    if [ -z "$id" ]; then
        id="$(find_dashboard_id_by_name "$name")"
        DASH_CREATED_NEW=0
    else
        DASH_CREATED_NEW=1
    fi

    [ -n "$id" ] || return 1
    echo "$id"
}

upsert_native_card() {
    local name="$1"
    local display="$2"
    shift 2
    local queries=("$@")
    local existing_id
    local method
    local endpoint
    local mode

    existing_id="$(find_card_id_by_name "$name")"
    if [ -n "$existing_id" ]; then
        method="PUT"
        endpoint="/api/card/${existing_id}"
        mode="updated"
    else
        method="POST"
        endpoint="/api/card"
        mode="created"
    fi

    local sql
    for sql in "${queries[@]}"; do
        local payload
        payload="$(python3 - "$name" "$display" "$SAMPLE_DB_ID" "$sql" <<'PY'
import json
import sys

name = sys.argv[1]
display = sys.argv[2]
db_id = int(sys.argv[3])
sql = sys.argv[4]

print(json.dumps({
    "name": name,
    "display": display,
    "description": "Seeded by scripts/seed-data.sh",
    "collection_id": None,
    "dataset_query": {
        "type": "native",
        "native": {
            "query": sql
        },
        "database": db_id
    },
    "visualization_settings": {}
}))
PY
)"

        local response
        response="$(curl -sS -X "$method" "${BASE_URL}${endpoint}" \
            -H "$AUTH_HEADER" \
            -H "Content-Type: application/json" \
            -d "$payload" || true)"

        local card_id
        card_id="$(parse_generic_id "$response")"
        if [ -z "$card_id" ]; then
            card_id="$(find_card_id_by_name "$name")"
        fi

        if [ -n "$card_id" ]; then
            echo "$card_id|$mode"
            return 0
        fi
    done

    return 1
}

attach_cards_to_dashboard() {
    local dashboard_id="$1"
    local q1_id="$2"
    local q2_id="$3"

    local payload
    payload="$(python3 - "$q1_id" "$q2_id" <<'PY'
import json
import sys

q1_id = int(sys.argv[1])
q2_id = int(sys.argv[2])

print(json.dumps({
    "dashcards": [
        {
            "id": -1,
            "card_id": q1_id,
            "row": 0,
            "col": 0,
            "size_x": 8,
            "size_y": 6
        },
        {
            "id": -2,
            "card_id": q2_id,
            "row": 0,
            "col": 8,
            "size_x": 10,
            "size_y": 6
        }
    ]
}))
PY
)"

    curl -sS -X PUT "${BASE_URL}/api/dashboard/${dashboard_id}" \
        -H "$AUTH_HEADER" \
        -H "Content-Type: application/json" \
        -d "$payload" > /dev/null
}

echo "Authenticating as admin (with retries)..."
SESSION_ID=""
for i in $(seq 1 "$SEED_AUTH_RETRIES"); do
    SESSION_RESPONSE="$(curl -sS -X POST "${BASE_URL}/api/session" \
        -H "Content-Type: application/json" \
        -d '{"username":"admin@example.com","password":"Admin123!"}' || true)"
    SESSION_ID="$(parse_session_id "$SESSION_RESPONSE")"
    if [ -n "$SESSION_ID" ]; then
        echo "Authenticated after ${i} attempts."
        break
    fi
    sleep "$SEED_AUTH_RETRY_SLEEP"
done
[ -n "$SESSION_ID" ] || fail "Failed to authenticate to Metabase at ${BASE_URL}"

AUTH_HEADER="X-Metabase-Session: ${SESSION_ID}"

echo "Resolving Sample Database ID..."
DB_STATUS=""
for i in $(seq 1 "$SEED_DB_LOOKUP_RETRIES"); do
    DB_STATUS="$(curl -sS -H "$AUTH_HEADER" "${BASE_URL}/api/database" || true)"
    SAMPLE_DB_ID="$(find_sample_db_id "$DB_STATUS")"
    if [ -n "$SAMPLE_DB_ID" ]; then
        echo "Sample Database ID: $SAMPLE_DB_ID (resolved after ${i} attempts)"
        break
    fi
    sleep "$SEED_DB_LOOKUP_SLEEP"
done

if [ -z "$SAMPLE_DB_ID" ]; then
    DB_NAMES="$(list_database_names "$DB_STATUS")"
    fail "Sample database not found. Databases seen: ${DB_NAMES:-none}"
fi

# -------------------------------------------------------------------
# Trigger a sync on the Sample Database and wait for it to complete.
# This ensures that table metadata (ORDERS, PRODUCTS, etc.) is ready
# before we try to create native SQL questions against those tables.
# -------------------------------------------------------------------
echo "Triggering Sample Database sync..."
curl -sS -X POST "${BASE_URL}/api/database/${SAMPLE_DB_ID}/sync_schema" \
    -H "$AUTH_HEADER" > /dev/null 2>&1 || true

echo "Waiting ${SEED_SYNC_WAIT}s for sync to settle..."
for i in $(seq 1 "$SEED_SYNC_WAIT"); do
    SYNC_STATUS="$(curl -sS -H "$AUTH_HEADER" \
        "${BASE_URL}/api/database/${SAMPLE_DB_ID}" 2>/dev/null || echo '{}')"
    IS_SYNCING="$(echo "$SYNC_STATUS" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    # initial_sync_status becomes 'complete' once first sync finishes
    status = d.get('initial_sync_status', '')
    print('no' if status == 'complete' else 'yes')
except Exception:
    print('unknown')
" 2>/dev/null || echo "unknown")"

    if [ "$IS_SYNCING" = "no" ]; then
        echo "Sample Database sync complete after ${i}s."
        break
    fi
    if [ "$i" -eq "$SEED_SYNC_WAIT" ]; then
        warn "Sync did not confirm completion within ${SEED_SYNC_WAIT}s; proceeding anyway."
    fi
    sleep 1
done

echo "Upserting saved questions..."
if ! Q1_RESULT="$(upsert_native_card "Orders by Category" "bar" \
    "SELECT p.CATEGORY AS category, COUNT(*) AS order_count FROM ORDERS o JOIN PRODUCTS p ON o.PRODUCT_ID = p.ID GROUP BY p.CATEGORY ORDER BY order_count DESC" \
    "SELECT PRODUCT_ID AS category, COUNT(*) AS order_count FROM ORDERS GROUP BY PRODUCT_ID ORDER BY order_count DESC")"; then
    fail "Could not upsert 'Orders by Category'"
fi
Q1_ID="${Q1_RESULT%%|*}"
Q1_MODE="${Q1_RESULT##*|}"
echo "  ${Q1_MODE}: Orders by Category (ID: $Q1_ID)"

if ! Q2_RESULT="$(upsert_native_card "Revenue Over Time" "line" \
    "SELECT CREATED_AT AS created_at, SUM(TOTAL) AS revenue FROM ORDERS GROUP BY CREATED_AT ORDER BY CREATED_AT" \
    "SELECT ID AS created_at, TOTAL AS revenue FROM ORDERS ORDER BY ID")"; then
    fail "Could not upsert 'Revenue Over Time'"
fi
Q2_ID="${Q2_RESULT%%|*}"
Q2_MODE="${Q2_RESULT##*|}"
echo "  ${Q2_MODE}: Revenue Over Time (ID: $Q2_ID)"

if ! Q3_RESULT="$(upsert_native_card "Top Customers by Orders" "table" \
    "SELECT USER_ID AS customer_id, COUNT(*) AS order_count FROM ORDERS GROUP BY USER_ID ORDER BY order_count DESC LIMIT 10" \
    "SELECT PRODUCT_ID AS customer_id, COUNT(*) AS order_count FROM ORDERS GROUP BY PRODUCT_ID ORDER BY order_count DESC LIMIT 10")"; then
    fail "Could not upsert 'Top Customers by Orders'"
fi
Q3_ID="${Q3_RESULT%%|*}"
Q3_MODE="${Q3_RESULT##*|}"
echo "  ${Q3_MODE}: Top Customers by Orders (ID: $Q3_ID)"

echo "Ensuring Team Reports collection exists..."
COLLECTION_ID=""
COLLECTION_MODE="skipped"
if COLLECTION_RESULT="$(get_or_create_collection "Team Reports" "#509EE3")"; then
    COLLECTION_ID="${COLLECTION_RESULT%%|*}"
    COLLECTION_MODE="${COLLECTION_RESULT##*|}"
    echo "  ${COLLECTION_MODE}: Team Reports (ID: $COLLECTION_ID)"
else
    warn "Could not create or find collection 'Team Reports' (non-critical)"
fi

echo "Ensuring Sales Overview dashboard exists..."
DASH_ID=""
if DASH_ID="$(get_or_create_dashboard "Sales Overview" "Overview of sales metrics")"; then
    if [ "$DASH_CREATED_NEW" -eq 1 ]; then
        echo "  created: Sales Overview (ID: $DASH_ID)"
        echo "Attaching cards to new dashboard..."
        if attach_cards_to_dashboard "$DASH_ID" "$Q1_ID" "$Q2_ID"; then
            echo "  attached: Orders by Category + Revenue Over Time"
        else
            warn "Dashboard created but card attachment failed (non-critical)"
        fi
    else
        echo "  existing: Sales Overview (ID: $DASH_ID)"
        echo "  skipped: card attachment to avoid duplicate dashcards"
    fi
else
    warn "Could not create or find dashboard 'Sales Overview' (non-critical)"
fi

# -------------------------------------------------------------------
# Verify seeded questions are queryable
# -------------------------------------------------------------------
echo ""
echo "Verifying seeded questions are queryable..."
VERIFY_PASS=0
VERIFY_TOTAL=0
for CARD_ID_CHECK in "$Q1_ID" "$Q2_ID" "$Q3_ID"; do
    VERIFY_TOTAL=$((VERIFY_TOTAL + 1))
    VERIFY_RESP="$(curl -sS -X POST "${BASE_URL}/api/card/${CARD_ID_CHECK}/query" \
        -H "$AUTH_HEADER" \
        -H "Content-Type: application/json" 2>/dev/null || echo '{}')"
    ROW_COUNT="$(echo "$VERIFY_RESP" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    rows = d.get('data', {}).get('rows', [])
    print(len(rows))
except Exception:
    print(-1)
" 2>/dev/null || echo "-1")"
    if [ "$ROW_COUNT" -gt 0 ] 2>/dev/null; then
        echo "  card ${CARD_ID_CHECK}: OK (${ROW_COUNT} rows)"
        VERIFY_PASS=$((VERIFY_PASS + 1))
    else
        warn "card ${CARD_ID_CHECK} returned ${ROW_COUNT} rows (expected > 0)"
    fi
done
echo "  Verification: ${VERIFY_PASS}/${VERIFY_TOTAL} questions returned data."

echo ""
echo "=== Seed Data Complete ==="
echo "Questions:"
echo "  - Orders by Category ($Q1_MODE, id=$Q1_ID)"
echo "  - Revenue Over Time ($Q2_MODE, id=$Q2_ID)"
echo "  - Top Customers by Orders ($Q3_MODE, id=$Q3_ID)"
echo "Collection:"
if [ -n "$COLLECTION_ID" ]; then
    echo "  - Team Reports ($COLLECTION_MODE, id=$COLLECTION_ID)"
else
    echo "  - Team Reports (FAILED - see warnings)"
fi
echo "Dashboard:"
if [ -n "$DASH_ID" ]; then
    echo "  - Sales Overview (id=$DASH_ID)"
else
    echo "  - Sales Overview (FAILED - see warnings)"
fi

if [ "${#SEED_WARNINGS[@]}" -gt 0 ]; then
    echo ""
    echo "=== Warnings (${#SEED_WARNINGS[@]}) ==="
    for w in "${SEED_WARNINGS[@]}"; do
        echo "  - $w"
    done
fi

echo ""
echo "Access at: ${BASE_URL}"
echo "Login: admin@example.com / Admin123!"
