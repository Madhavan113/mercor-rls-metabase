#!/usr/bin/env bash
set -e

echo "=== Installing Metabase ==="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SERVICE_DIR="$(dirname "$SCRIPT_DIR")"

# -------------------------------------------------------------------
# 1. System dependencies
# -------------------------------------------------------------------
apt-get update
apt-get install -y --no-install-recommends \
    nginx gettext-base curl ca-certificates \
    wget apt-transport-https gpg \
    python3

# -------------------------------------------------------------------
# 2. Install Eclipse Temurin JDK 21
# -------------------------------------------------------------------
echo "Installing JDK 21 (Eclipse Temurin)..."
wget -qO - https://packages.adoptium.net/artifactory/api/gpg/key/public | gpg --dearmor -o /etc/apt/trusted.gpg.d/adoptium.gpg
echo "deb https://packages.adoptium.net/artifactory/deb $(. /etc/os-release && echo "$VERSION_CODENAME") main" > /etc/apt/sources.list.d/adoptium.list
apt-get update
apt-get install -y --no-install-recommends temurin-21-jdk

# Verify Java
java -version 2>&1 || { echo "ERROR: Java installation failed"; exit 1; }

# -------------------------------------------------------------------
# 3. Download Metabase JAR
# -------------------------------------------------------------------
# Use a pinned default for deterministic builds; allow override via env.
DEFAULT_METABASE_VERSION="0.52.6"
METABASE_VERSION="${METABASE_VERSION:-$DEFAULT_METABASE_VERSION}"
METABASE_DIR="/opt/metabase"
mkdir -p "$METABASE_DIR"

echo "Downloading Metabase JAR (version: $METABASE_VERSION)..."
if [ "$METABASE_VERSION" = "latest" ]; then
    echo "WARNING: latest is non-deterministic; prefer a pinned METABASE_VERSION."
    DOWNLOAD_URL="https://downloads.metabase.com/latest/metabase.jar"
else
    DOWNLOAD_URL="https://downloads.metabase.com/v${METABASE_VERSION}/metabase.jar"
fi

# Download with retry (up to 3 attempts for network resilience)
DOWNLOAD_OK=false
for attempt in 1 2 3; do
    echo "  Download attempt ${attempt}/3: $DOWNLOAD_URL"
    if curl -fsSL --retry 2 --retry-delay 5 "$DOWNLOAD_URL" -o "$METABASE_DIR/metabase.jar"; then
        # Verify the download produced a non-empty file
        JAR_SIZE=$(stat -c%s "$METABASE_DIR/metabase.jar" 2>/dev/null || stat -f%z "$METABASE_DIR/metabase.jar" 2>/dev/null || echo "0")
        if [ "$JAR_SIZE" -gt 1000000 ]; then
            echo "  Download successful (${JAR_SIZE} bytes)"
            DOWNLOAD_OK=true
            break
        else
            echo "  WARNING: Downloaded file too small (${JAR_SIZE} bytes), retrying..."
            rm -f "$METABASE_DIR/metabase.jar"
        fi
    else
        echo "  WARNING: Download attempt ${attempt} failed"
    fi
    [ "$attempt" -lt 3 ] && sleep 5
done

if [ "$DOWNLOAD_OK" != "true" ]; then
    echo "ERROR: Failed to download Metabase JAR after 3 attempts"
    exit 1
fi

# Verify JAR is a valid zip/jar archive
if ! file "$METABASE_DIR/metabase.jar" 2>/dev/null | grep -qi "zip\|jar\|java"; then
    echo "WARNING: JAR may not be a valid Java archive"
    file "$METABASE_DIR/metabase.jar" 2>/dev/null || true
fi

# -------------------------------------------------------------------
# 4. Create state directories
# -------------------------------------------------------------------
mkdir -p "$SERVICE_DIR/.state/metabase"
mkdir -p "$SERVICE_DIR/.state/logs"

# Set permissions (chmod, never chown -- chown fails on platform)
chmod -R 777 "$SERVICE_DIR/.state" 2>/dev/null || true
chmod -R 777 "$METABASE_DIR" 2>/dev/null || true

# -------------------------------------------------------------------
# 5. Clean up apt cache
# -------------------------------------------------------------------
apt-get clean
rm -rf /var/lib/apt/lists/*

echo "=== Metabase Install Complete ==="
echo "Java: $(java -version 2>&1 | head -1)"
echo "Metabase JAR: $METABASE_DIR/metabase.jar"
