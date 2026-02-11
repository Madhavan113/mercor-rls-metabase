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

echo "=== Installing Metabase ==="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SERVICE_DIR="$(dirname "$SCRIPT_DIR")"

# -------------------------------------------------------------------
# 1. System dependencies
# -------------------------------------------------------------------
if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    # Linux / Production / Modal
    apt-get update
    apt-get install -y --no-install-recommends \
        nginx gettext-base curl ca-certificates \
        wget apt-transport-https gpg \
        python3
elif [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS / Local
    # We assume brew is installed. Warn if dependencies are missing.
    echo "Checking macOS dependencies..."
    if ! command -v nginx &> /dev/null; then
        echo "WARNING: nginx not found. Please run: brew install nginx"
    fi
    if ! command -v envsubst &> /dev/null; then
        echo "WARNING: envsubst not found. Please run: brew install gettext"
    fi
    if ! command -v java &> /dev/null; then
        echo "WARNING: java (JDK 21) not found. Please run: brew install openjdk@21"
    fi
    if ! command -v python3 &> /dev/null; then
        echo "WARNING: python3 not found."
    fi
fi

# -------------------------------------------------------------------
# 2. Install Eclipse Temurin JDK 21 (Linux only)
# -------------------------------------------------------------------
if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    echo "Installing JDK 21 (Eclipse Temurin)..."
    wget -qO - https://packages.adoptium.net/artifactory/api/gpg/key/public | gpg --dearmor -o /etc/apt/trusted.gpg.d/adoptium.gpg
    echo "deb https://packages.adoptium.net/artifactory/deb $(. /etc/os-release && echo "$VERSION_CODENAME") main" > /etc/apt/sources.list.d/adoptium.list
    apt-get update
    apt-get install -y --no-install-recommends temurin-21-jdk
fi

# Verify Java
java -version 2>&1 || { echo "ERROR: Java installation failed"; exit 1; }

# -------------------------------------------------------------------
# 3. Download Metabase JAR
# -------------------------------------------------------------------
DEFAULT_METABASE_VERSION="0.52.6"
METABASE_VERSION="${METABASE_VERSION:-$DEFAULT_METABASE_VERSION}"

# Conditional install path
if [[ "$OSTYPE" == "darwin"* ]]; then
    # Local: use .local directory to avoid permission issues
    METABASE_DIR="$SERVICE_DIR/.local/metabase"
else
    # Prod: use standard /opt
    METABASE_DIR="/opt/metabase"
fi

mkdir -p "$METABASE_DIR"

echo "Downloading Metabase JAR (version: $METABASE_VERSION)..."
echo "  Target: $METABASE_DIR/metabase.jar"

if [ "$METABASE_VERSION" = "latest" ]; then
    DOWNLOAD_URL="https://downloads.metabase.com/latest/metabase.jar"
else
    DOWNLOAD_URL="https://downloads.metabase.com/v${METABASE_VERSION}/metabase.jar"
fi

# Download logic
if [ -f "$METABASE_DIR/metabase.jar" ]; then
    echo "  JAR already exists, skipping download."
    # Optionally verify size or checksum here if needed
else
    for attempt in 1 2 3; do
        if curl -fsSL --retry 2 --retry-delay 5 "$DOWNLOAD_URL" -o "$METABASE_DIR/metabase.jar"; then
             JAR_SIZE=$(stat -f%z "$METABASE_DIR/metabase.jar" 2>/dev/null || stat -c%s "$METABASE_DIR/metabase.jar" 2>/dev/null || echo "0")
             if [ "$JAR_SIZE" -gt 1000000 ]; then
                 echo "  Download successful (${JAR_SIZE} bytes)"
                 break
             fi
        fi
        echo "  Attempt $attempt failed or file too small."
        [ "$attempt" -lt 3 ] && sleep 5
    done
fi

if [ ! -f "$METABASE_DIR/metabase.jar" ]; then
    echo "ERROR: Metabase JAR missing."
    exit 1
fi

# -------------------------------------------------------------------
# 4. Create state directories
# -------------------------------------------------------------------
mkdir -p "$SERVICE_DIR/.state/metabase"
mkdir -p "$SERVICE_DIR/.state/logs"
chmod -R 777 "$SERVICE_DIR/.state" 2>/dev/null || true
# chmod -R 777 "$METABASE_DIR" 2>/dev/null || true # Only if needed

if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    apt-get clean
    rm -rf /var/lib/apt/lists/*
fi

echo "=== Install Complete ==="
echo "Mode: $OSTYPE"
echo "Location: $METABASE_DIR"
