#!/bin/bash
set -e

# =============================================================================
# Modal Sandbox Testing Script
# =============================================================================
# Builds and runs this service on a Modal sandbox with HTTPS tunnels.
# Mimics the exact production environment (playground) without requiring
# the full CI/release cycle or heavy local Docker builds.
#
# The image is built remotely on Modal's infrastructure using
# modal.Image.from_dockerfile(), so no local Docker build is needed.
#
# Usage:
#   ./scripts/test-modal-sandbox.sh --biome-dir /path/to/biome [options]
#
# Options:
#   --biome-dir DIR     Path to biome repo checkout (required)
#   --no-cache          Force rebuild without Modal cache
#   --app-name NAME     Modal app name (default: bua-test)
#   --timeout SECS      Sandbox timeout in seconds (default: 3600 = 1hr)
#   -s, --seed-data     Path to seed data directory or .tar.gz archive
#   --env ENV           Modal environment (default: rl-studio-apps)
#
# Environment variables:
#   MODAL_TOKEN_ID      Modal API token ID (required)
#   MODAL_TOKEN_SECRET  Modal API token secret (required)
#
# Example (local):
#   export MODAL_TOKEN_ID="ak-..."
#   export MODAL_TOKEN_SECRET="as-..."
#   ./scripts/test-modal-sandbox.sh --biome-dir ../../biome
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICE_DIR="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Parse arguments
BIOME_DIR=""
FORCE_BUILD=false
MODAL_APP_NAME="bua-test"
SANDBOX_TIMEOUT=3600
SEED_DATA=""
MODAL_ENVIRONMENT="rl-studio-apps"

while [[ $# -gt 0 ]]; do
    case $1 in
        --biome-dir)
            BIOME_DIR="$2"
            shift 2
            ;;
        --no-cache)
            FORCE_BUILD=true
            shift
            ;;
        --app-name)
            MODAL_APP_NAME="$2"
            shift 2
            ;;
        --timeout)
            SANDBOX_TIMEOUT="$2"
            shift 2
            ;;
        --seed-data|-s)
            SEED_DATA="$2"
            shift 2
            ;;
        --env)
            MODAL_ENVIRONMENT="$2"
            shift 2
            ;;
        -*)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Validate required args / env
if [ -z "$BIOME_DIR" ]; then
    echo "Usage: $0 --biome-dir /path/to/biome [options]"
    echo ""
    echo "Builds this service on Modal and runs it as a sandbox with HTTPS tunnels."
    echo ""
    echo "Required:"
    echo "  --biome-dir DIR     Path to biome repo (for platform builder)"
    echo ""
    echo "Options:"
    echo "  --no-cache          Force rebuild (ignore Modal image cache)"
    echo "  --app-name NAME     Modal app name (default: bua-test)"
    echo "  --timeout SECS      Sandbox timeout in seconds (default: 3600)"
    echo "  -s, --seed-data     Path to seed data (dir or .tar.gz)"
    echo "  --env ENV           Modal environment (default: rl-studio-apps)"
    echo ""
    echo "Environment variables:"
    echo "  MODAL_TOKEN_ID      Modal API token ID (required)"
    echo "  MODAL_TOKEN_SECRET  Modal API token secret (required)"
    exit 1
fi

BIOME_DIR="$(cd "$BIOME_DIR" && pwd)"

if [ -z "$MODAL_TOKEN_ID" ] || [ -z "$MODAL_TOKEN_SECRET" ]; then
    log_error "MODAL_TOKEN_ID and MODAL_TOKEN_SECRET must be set"
    exit 1
fi

export MODAL_TOKEN_ID
export MODAL_TOKEN_SECRET

# Validate paths
if [ ! -f "$SERVICE_DIR/arco.toml" ] || [ ! -f "$SERVICE_DIR/mise.toml" ]; then
    log_error "arco.toml or mise.toml not found in $SERVICE_DIR"
    exit 1
fi

if [ ! -d "$BIOME_DIR/rl-studio/server" ]; then
    log_error "biome repo not found at $BIOME_DIR (missing rl-studio/server)"
    exit 1
fi

SERVICE_NAME="$(basename "$SERVICE_DIR")"
log_info "Testing service on Modal: $SERVICE_NAME"
log_info "Modal app: $MODAL_APP_NAME | Environment: $MODAL_ENVIRONMENT"
log_info "Biome: $BIOME_DIR"

# =============================================================================
# Step 1: Create build context
# =============================================================================
BUILD_DIR="$SERVICE_DIR/.build-cache/modal"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

log_info "Creating build context in $BUILD_DIR..."

# Copy runner from biome
cp -r "$BIOME_DIR/archipelago/environment/runner" "$BUILD_DIR/runner"
cp "$BIOME_DIR/archipelago/environment/pyproject.toml" "$BUILD_DIR/pyproject.toml"
cp "$BIOME_DIR/archipelago/environment/uv.lock" "$BUILD_DIR/uv.lock"

# Copy service with normalized name
cd "$BIOME_DIR/rl-studio/server"
NORMALIZED_NAME=$(uv run python -c "
import sys
sys.path.insert(0, '.')
from packages.arco.parser import parse_arco
from packages.arco.utils.helpers import normalize_service_name
with open('$SERVICE_DIR/arco.toml') as f:
    arco_toml = f.read()
with open('$SERVICE_DIR/mise.toml') as f:
    mise_toml = f.read()
arco = parse_arco(mise_toml, arco_toml)
print(normalize_service_name(arco.name))
" 2>/dev/null || true)

if [ -z "$NORMALIZED_NAME" ]; then
    NORMALIZED_NAME="$SERVICE_NAME"
fi

log_info "Service: $SERVICE_NAME -> $NORMALIZED_NAME"
mkdir -p "$BUILD_DIR/services/$NORMALIZED_NAME"
rsync -a --delete --exclude='.git' --exclude='.build-cache' "$SERVICE_DIR/" "$BUILD_DIR/services/$NORMALIZED_NAME/"

log_success "Build context created"

# =============================================================================
# Step 2: Generate Dockerfile + start.sh (single Python invocation)
# =============================================================================
log_info "Generating Dockerfile and start.sh..."

cd "$BIOME_DIR/rl-studio/server"

GENERATOR="$BUILD_DIR/_generate_build_artifacts.py"
cat > "$GENERATOR" << 'GENEOF'
"""
Generate Dockerfile and start.sh for the platform build.

Uses importlib to load report_engine submodules without triggering
the top-level report_engine.__init__ which requires all production
environment variables (postgres, redis, dagster, etc.).
"""
import importlib
import importlib.util
import sys
import types
from pathlib import Path
from datetime import datetime, UTC

sys.path.insert(0, ".")

# ---- Stub modules to avoid import side effects ----
#
# report_engine.__init__ imports dagster definitions which cascade into
# Settings() validation requiring 60+ env vars we don't have in CI.
#
# Strategy:
#   1. Stub the report_engine *package hierarchy* so __init__.py never runs.
#   2. Stub specific leaf modules that trigger Settings() or are unused.
#   3. Load the actual leaf modules we need (db, dockerfile_builder, build,
#      docker, linux_identities) via importlib from their file paths.
#   4. Let everything else (utils.postgres, models.*, packages.*) import
#      normally from the filesystem.
# ---- helpers ----

_dummy = type("_Dummy", (), {"__init__": lambda *a, **kw: None})

def _stub(name, attrs=None):
    """Register a stub module in sys.modules."""
    mod = types.ModuleType(name)
    mod.__path__ = [name.replace(".", "/")]
    for k, v in (attrs or {}).items():
        setattr(mod, k, v)
    sys.modules[name] = mod
    return mod

def _load(name, filepath):
    """Load a real module from a file path, registering it in sys.modules."""
    spec = importlib.util.spec_from_file_location(name, filepath)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod

# ---- 1. report_engine package hierarchy (prevent __init__.py execution) ----
for pkg in [
    "report_engine",
    "report_engine.defs",
    "report_engine.defs.platform_image",
    "report_engine.defs.platform_image.utils",
    "report_engine.utils",
    "report_engine.resources",
]:
    _stub(pkg)

# ---- 2a. report_engine leaf stubs (imported by build.py but unused here) ----
_stub("report_engine.resources.github", {"GithubResource": _dummy})
_stub("report_engine.resources.s3", {"S3Resource": _dummy})
_stub("report_engine.defs.platform_image.utils.github_build", {
    "PlatformImageBuildInput": _dummy,
    "TargetPlatform": _dummy,
    "run_platform_image_build": lambda *a, **kw: None,
})
_stub("report_engine.utils.assets", {"ReportEngineAsset": _dummy})
_stub("report_engine.utils.s3", {
    "PathS3Upload": _dummy,
    "get_report_engine_s3_key": lambda *a, **kw: "",
    "is_dry_run_from_tags": lambda *a, **kw: False,
    "upload_to_s3": lambda *a, **kw: None,
})
_stub("report_engine.utils.s3_keys", {
    "get_report_engine_artifact_key": lambda *a, **kw: "",
})

# ---- 2b. utils leaf stubs (trigger Settings() at import time) ----
# NOTE: we do NOT stub the `utils` package itself -- it is a namespace
# package and db.py needs `from utils.postgres import ...` to resolve
# naturally from the filesystem.
_stub("utils.settings", {
    "get_settings": lambda: None,
    "Environment": _dummy,
})
_stub("utils.constants.constants", {"REPORT_ARTIFACTS_BUCKET": "dummy"})

# ---- 2c. Third-party / top-level stubs ----
_stub("dagster", {"AssetExecutionContext": _dummy})

# ---- 3. Load the real leaf modules we need ----
_load("report_engine.utils.linux_identities",
      "report_engine/utils/linux_identities.py")
_load("report_engine.utils.docker",
      "report_engine/utils/docker.py")
db_mod = _load("report_engine.defs.platform_image.utils.db",
               "report_engine/defs/platform_image/utils/db.py")
df_mod = _load("report_engine.defs.platform_image.utils.dockerfile_builder",
               "report_engine/defs/platform_image/utils/dockerfile_builder.py")
build_mod = _load("report_engine.defs.platform_image.utils.build",
                  "report_engine/defs/platform_image/utils/build.py")

ServiceWithPlatformConfig = db_mod.ServiceWithPlatformConfig
build_platform_dockerfile = df_mod.build_platform_dockerfile
render_dockerfile = df_mod.render_dockerfile
_generate_start_script = build_mod._generate_start_script

# ---- 4. Normal safe imports ----
from packages.arco.parser import parse_arco
from packages.arco.utils.helpers import normalize_service_name
from packages.arco.utils.mcp_ports import assign_ports
from models.db.services import Service

import os
BUILD_DIR = os.environ["BUILD_DIR"]

# ---- Collect services (single pass) ----
svc_configs = []
service_arcos = []
services_dir = Path(BUILD_DIR) / "services"

for service_dir in sorted(services_dir.iterdir()):
    if not service_dir.is_dir():
        continue
    arco_path = service_dir / "arco.toml"
    mise_path = service_dir / "mise.toml"
    if not arco_path.exists() or not mise_path.exists():
        continue
    with open(arco_path) as f:
        arco_toml = f.read()
    with open(mise_path) as f:
        mise_toml = f.read()
    arco = parse_arco(mise_toml, arco_toml)
    server_dir = normalize_service_name(arco.name)
    now = datetime.now(UTC)
    mock_service = Service(
        service_id=f"svc_local_{service_dir.name}",
        version=1,
        service_name=arco.name,
        service_description=f"Modal test: {arco.name}",
        archipelago_config=arco,
        created_by="user_local",
        updated_by="user_local",
        created_at=now,
        updated_at=now,
        commit=None,
    )
    svc_configs.append(ServiceWithPlatformConfig(service=mock_service, env=None, secrets=None))
    service_arcos.append((server_dir, arco))
    print(f"  Added service: {arco.name}")

# ---- Generate Dockerfile ----
dockerfile = build_platform_dockerfile(svc_configs)
dockerfile_content = render_dockerfile(dockerfile)
with open(f"{BUILD_DIR}/Dockerfile", "w") as f:
    f.write(dockerfile_content)
print(f"Dockerfile generated for {len(svc_configs)} service(s)")

# ---- Generate start.sh ----
port_assignments = assign_ports(service_arcos, reserved_ports={8080})
start_script = _generate_start_script(svc_configs, port_assignments, runner_port=8080)
with open(f"{BUILD_DIR}/start.sh", "w") as f:
    f.write(start_script)
print("start.sh generated")
GENEOF

export BUILD_DIR="$BUILD_DIR"
uv run python "$GENERATOR" || { log_error "Failed to generate Dockerfile / start.sh"; exit 1; }

chmod +x "$BUILD_DIR/start.sh"
log_success "Dockerfile and start.sh generated"

# =============================================================================
# Step 4: Build image on Modal + create sandbox + get tunnel URLs
# =============================================================================
log_info "Building image on Modal and creating sandbox..."
log_info "Image will be built remotely on Modal's infrastructure (no local Docker needed)"

cd "$BIOME_DIR/rl-studio/server"

# Write the Python orchestrator to a temp file (avoids quoting hell)
ORCHESTRATOR="$BUILD_DIR/_modal_orchestrator.py"
cat > "$ORCHESTRATOR" << 'PYEOF'
"""
Modal sandbox orchestrator.

Builds the Docker image on Modal's infra, creates a sandbox with HTTPS tunnels,
waits for the app to be healthy, and prints tunnel URLs.
"""

import asyncio
import json
import os
import sys
import time

sys.path.insert(0, ".")

import modal

from packages.arco.parser import parse_arco
from packages.arco.utils.helpers import normalize_service_name
from packages.arco.utils.mcp_ports import (
    assign_ports,
    get_mcp_port,
    get_webapp_port,
    is_mcp_service,
    is_webapp_service,
)

# Read config from environment
BUILD_DIR = os.environ["BUILD_DIR"]
MODAL_APP_NAME = os.environ["MODAL_APP_NAME"]
MODAL_ENVIRONMENT = os.environ["MODAL_ENVIRONMENT"]
SANDBOX_TIMEOUT = int(os.environ["SANDBOX_TIMEOUT"])
FORCE_BUILD = os.environ.get("FORCE_BUILD", "false") == "true"
SEED_DATA = os.environ.get("SEED_DATA", "")

from pathlib import Path


def collect_services():
    """Parse all services in the build context."""
    service_arcos = []
    services_dir = Path(BUILD_DIR) / "services"

    for service_dir in sorted(services_dir.iterdir()):
        if not service_dir.is_dir():
            continue
        arco_path = service_dir / "arco.toml"
        mise_path = service_dir / "mise.toml"
        if not arco_path.exists() or not mise_path.exists():
            continue
        with open(arco_path) as f:
            arco_toml = f.read()
        with open(mise_path) as f:
            mise_toml = f.read()
        arco = parse_arco(mise_toml, arco_toml)
        server_dir = normalize_service_name(arco.name)
        service_arcos.append((server_dir, arco))

    return service_arcos


async def main():
    service_arcos = collect_services()
    port_assignments = assign_ports(service_arcos, reserved_ports={8080})

    # Detect webapp ports (for HTTPS tunnel exposure)
    webapp_ports = []
    for server_dir, arco in service_arcos:
        if is_webapp_service(arco):
            port = get_webapp_port(port_assignments, server_dir)
            if port:
                webapp_ports.append(port)

    # Detect MCP ports
    mcp_configs = {}
    for server_dir, arco in service_arcos:
        if is_mcp_service(arco):
            mcp_port = get_mcp_port(port_assignments, server_dir)
            if mcp_port:
                mcp_configs[server_dir] = {
                    "transport": "http",
                    "url": f"http://localhost:{mcp_port}/mcp",
                }

    # Always expose runner port (8080) + webapp ports
    encrypted_ports = [8080] + webapp_ports
    print(f"Webapp ports: {webapp_ports}")
    print(f"MCP configs: {json.dumps(mcp_configs)}")
    print(f"Encrypted ports (HTTPS tunnels): {encrypted_ports}")

    # ---- Modal app lookup ----
    print(f"\nLooking up Modal app: {MODAL_APP_NAME} (env: {MODAL_ENVIRONMENT})...")
    app = await modal.App.lookup.aio(
        MODAL_APP_NAME,
        environment_name=MODAL_ENVIRONMENT,
        create_if_missing=True,
    )
    print(f"Modal app ready: {app.app_id}")

    # ---- Build image from Dockerfile on Modal ----
    print("\nBuilding image from Dockerfile on Modal (remote build)...")
    print(f"  Dockerfile: {BUILD_DIR}/Dockerfile")
    print(f"  Context dir: {BUILD_DIR}")

    image = modal.Image.from_dockerfile(
        f"{BUILD_DIR}/Dockerfile",
        context_dir=BUILD_DIR,
        force_build=FORCE_BUILD,
    )

    # Force Modal to show build logs in stdout
    print("\nBuilding image (with logs enabled)...")
    with modal.enable_output():
        image.build(app)
    print("Image build complete.")

    # ---- Create sandbox ----
    print(f"\nCreating sandbox (timeout={SANDBOX_TIMEOUT}s, ports={encrypted_ports})...")
    sandbox = await modal.Sandbox.create.aio(
        app=app,
        image=image,
        timeout=SANDBOX_TIMEOUT,
        cpu=(1, 6),
        memory=(1024, 8000),
        encrypted_ports=encrypted_ports,
    )

    sandbox_id = sandbox.object_id
    print(f"Sandbox created: {sandbox_id}")

    # ---- Get tunnel URLs ----
    print("Waiting for tunnels...")
    tunnels = await sandbox.tunnels.aio(timeout=120)

    tunnel_map = {}
    for port, tunnel in tunnels.items():
        tunnel_map[port] = tunnel.url
        print(f"  Port {port} -> {tunnel.url}")

    runner_url = tunnel_map.get(8080, "")

    # ---- Wait for runner health ----
    if runner_url:
        import httpx

        print(f"\nWaiting for runner health at {runner_url}/health ...")
        start = time.time()
        async with httpx.AsyncClient(timeout=10.0, verify=False) as client:
            for i in range(180):  # up to 6 min
                try:
                    resp = await client.get(f"{runner_url}/health")
                    if resp.status_code == 200:
                        elapsed = time.time() - start
                        print(f"Runner healthy after {elapsed:.1f}s")
                        break
                except Exception:
                    pass
                await asyncio.sleep(2)
            else:
                print("WARNING: Runner may not be ready after 360s")

            # ---- Configure MCP servers ----
            if mcp_configs:
                print(f"\nConfiguring {len(mcp_configs)} MCP server(s)...")
                try:
                    resp = await client.post(
                        f"{runner_url}/apps",
                        json={"mcpServers": mcp_configs},
                        timeout=60.0,
                    )
                    print(f"MCP config response: {resp.status_code} - {resp.text[:200]}")
                except Exception as e:
                    print(f"MCP config failed: {e}")

            # ---- Populate with seed data ----
            if SEED_DATA:
                print(f"\nPopulating with seed data from: {SEED_DATA}")
                import tarfile
                import tempfile

                seed_dir = SEED_DATA
                if os.path.isfile(SEED_DATA):
                    seed_dir = tempfile.mkdtemp()
                    with tarfile.open(SEED_DATA, "r:gz") as tar:
                        tar.extractall(seed_dir)

                for subsystem in [".apps_data", "filesystem"]:
                    sub_path = os.path.join(seed_dir, subsystem)
                    if os.path.isdir(sub_path):
                        print(f"  Populating {subsystem}...")
                        tar_path = tempfile.mktemp(suffix=".tar.gz")
                        with tarfile.open(tar_path, "w:gz") as tar:
                            for item in os.listdir(sub_path):
                                tar.add(
                                    os.path.join(sub_path, item),
                                    arcname=item,
                                )
                        with open(tar_path, "rb") as f:
                            resp = await client.post(
                                f"{runner_url}/data/populate",
                                params={"subsystem": subsystem},
                                files={"archive": ("archive.tar.gz", f, "application/gzip")},
                                timeout=120.0,
                            )
                        print(f"    {subsystem}: {resp.status_code} - {resp.text[:200]}")
                        os.unlink(tar_path)

    # ---- Print results ----
    print()
    print("=" * 70)
    print("  SANDBOX READY - HTTPS TUNNELS ACTIVE")
    print("=" * 70)
    print()
    print(f"  Sandbox ID:  {sandbox_id}")
    print(f"  Runner URL:  {runner_url}")
    print()

    if webapp_ports:
        print("  Webapp URLs (use these in iframe tester):")
        for port in webapp_ports:
            url = tunnel_map.get(port, "N/A")
            print(f"    Port {port}: {url}")
        print()

    print(f"  Timeout: {SANDBOX_TIMEOUT}s ({SANDBOX_TIMEOUT // 60}min)")
    print()
    print("  Useful commands:")
    print(f"    modal sandbox logs {sandbox_id}")
    print(f"    modal sandbox terminate {sandbox_id}")
    print()

    # Save sandbox info
    info_file = os.path.join(BUILD_DIR, "sandbox-info.json")
    with open(info_file, "w") as f:
        json.dump(
            {
                "sandbox_id": sandbox_id,
                "runner_url": runner_url,
                "webapp_tunnels": {
                    str(p): tunnel_map.get(p, "") for p in webapp_ports
                },
                "mcp_configs": mcp_configs,
            },
            f,
            indent=2,
        )
    print(f"  Info saved to: {info_file}")

    print()
    print("=" * 70)
    print("  Press ENTER to terminate sandbox (or Ctrl+C)")
    print("  Sandbox will auto-terminate after timeout if left running.")
    print("=" * 70)

    try:
        await asyncio.get_event_loop().run_in_executor(None, input)
        print("\nTerminating sandbox...")
        await sandbox.terminate.aio()
        print("Sandbox terminated.")
    except (EOFError, KeyboardInterrupt):
        print("\nDetached - sandbox remains running until timeout.")
        print(f"To terminate manually: modal sandbox terminate {sandbox_id}")


asyncio.run(main())
PYEOF

# Pass config via environment variables to avoid quoting issues
export BUILD_DIR="$BUILD_DIR"
export MODAL_APP_NAME="$MODAL_APP_NAME"
export MODAL_ENVIRONMENT="$MODAL_ENVIRONMENT"
export SANDBOX_TIMEOUT="$SANDBOX_TIMEOUT"
export FORCE_BUILD="$( [ "$FORCE_BUILD" = true ] && echo true || echo false )"
export SEED_DATA="$SEED_DATA"

# Run the orchestrator
uv run python "$ORCHESTRATOR"

log_success "Done!"
