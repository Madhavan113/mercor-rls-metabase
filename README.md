# Metabase BUA (Browser-Use App)

Open-source Business Intelligence tool packaged as a browser-use app for the
Mercor Intelligence RL Studio platform.

| Field | Value |
|---|---|
| Upstream | https://github.com/metabase/metabase |
| Version | v0.52.6 (pinned default, override via `METABASE_VERSION`) |
| Stack | Java 21 (JAR), H2 embedded database |
| License | AGPL-3.0 |

## Architecture

```
Port 8081 (WEBAPP_PORT)    Port 3000 (BACKEND_PORT)
     |                          |
  [NGINX]  ---- proxy --->  [METABASE JAR]
  iframe hardening              |
  cookie rewriting         [H2 Database]
                           (app metadata)
                                |
                           [Sample Database]
                           (query data, ships with Metabase)
```

### Services

| Service | Port | Description |
|---|---|---|
| Nginx | 8081 | Public entrypoint, iframe hardening, cookie rewriting |
| Metabase | 3000 | Java/Clojure BI application (Jetty server) |

### State

| Location | Content |
|---|---|
| `.state/metabase/` | H2 application database (users, questions, dashboards) |
| `.state/logs/` | Application and nginx logs |
| `.state/playwright/storageState.json` | Pre-auth browser session state |
| `STATE_LOCATION` | Snapshot export path (default: `/.apps_data/metabase`) |

## Quick Start

```bash
mise run install   # Install Java 21, download Metabase JAR, install nginx
mise run build     # Initialize H2 database, run setup wizard, create admin user
mise run start     # Start Metabase + nginx
mise run seed      # Create sample questions, dashboards, and collections
mise run snapshot  # Export DB + Playwright storage state to STATE_LOCATION
```

Open http://localhost:8081 in your browser.

## Local Iframe Validation (Required)

Validate embedding behavior with the local harness in **Proxy + XSite** mode,
which simulates the Studio cross-site cookie/iframe environment.

```bash
# Option 1 — let the harness run the full lifecycle:
# From mercor-rls-bua-localdev:
pnpm run-with-app -- /path/to/mercor-rls-metabase

# Option 2 — if Metabase is already running (mise run start):
# From mercor-rls-bua-localdev:
pnpm quickstart
# Then open http://localhost:3000, enter http://localhost:8081 as the app URL
```

Walk through the debugging checklist (`DEBUGGING_CHECKLIST.md` in localdev):

1. **Iframe loads** — no blank screen, no CSP/X-Frame-Options blocking
2. **Cookies survive in XSite mode** — `SameSite=None; Secure` in Set-Cookie headers
3. **Headers correct** — `X-Frame-Options` removed, CSP includes `frame-ancestors`,
   `Host` / `X-Forwarded-Host` / `X-Forwarded-Proto` are set
4. **No localhost leaks** — Location headers in redirects point through the proxy,
   not directly to `localhost:3000`
5. **Auth persists inside iframe** — log in, navigate, reload; session survives

If it works in Proxy + XSite mode, it is the best local signal it will embed
cleanly in Studio.

## Default Credentials

| Role | Email | Password |
|---|---|---|
| Admin | admin@example.com | Admin123! |

## Environment Variables

### Platform Variables (arco.toml / mise.toml)

| Variable | Default | Description |
|---|---|---|
| `WEBAPP_PORT` | 8081 | Nginx public port |
| `BACKEND_PORT` | 3000 | Metabase internal port |
| `STATE_LOCATION` | `/.apps_data/metabase` | Snapshot export location |
| `COOKIE_SECURE` | true | Enable secure cookies |
| `COOKIE_SAMESITE` | none | Cookie SameSite attribute |
| `STUDIO_FRAME_ANCESTORS` | (Studio URLs) | CSP frame-ancestors value |
| `METABASE_VERSION` | 0.52.6 | Metabase version to download (set in install.sh; override to pin a different release) |

### Metabase Runtime Variables (set in start.sh)

| Variable | Value | Purpose |
|---|---|---|
| `MB_JETTY_PORT` | `$BACKEND_PORT` (3000) | Internal Jetty port |
| `MB_DB_TYPE` | h2 | Application database type |
| `MB_DB_FILE` | `.state/metabase/metabase` | H2 database file path |
| `MB_ENCRYPTION_SECRET_KEY` | (fixed, never rotated) | Fixed encryption key for session persistence |
| `MB_SITE_URL` | `http://localhost:${WEBAPP_PORT}` | External URL (override via `MB_SITE_URL` env var) |
| `MB_PASSWORD_COMPLEXITY` | weak | Allow simple passwords for dev/test |
| `MB_ENABLE_EMBEDDING` | true | Enable iframe embedding |
| `MB_SESSION_COOKIES` | true | Use session cookies (no persistent cookies) |
| `MB_REDIRECT_ALL_REQUESTS_TO_HTTPS` | false | Disable forced HTTPS redirect (nginx handles proto) |
| `MB_SEND_NEW_SSO_USER_ADMIN_EMAIL` | false | Suppress admin notification emails |
| `MB_CHECK_FOR_UPDATES` | false | Disable update checks |
| `MB_ANON_TRACKING_ENABLED` | false | Disable telemetry |

### Seed Script Variables (optional, for seed-data.sh tuning)

| Variable | Default | Purpose |
|---|---|---|
| `SEED_AUTH_RETRIES` | 90 | Max retries waiting for auth API readiness |
| `SEED_AUTH_RETRY_SLEEP` | 2 | Seconds between auth retries |
| `SEED_DB_LOOKUP_RETRIES` | 60 | Max retries waiting for Sample Database |
| `SEED_DB_LOOKUP_SLEEP` | 2 | Seconds between database lookup retries |
| `SEED_SYNC_WAIT` | 30 | Seconds to wait for database sync to complete |

## Lifecycle Scripts

| Script | Purpose |
|---|---|
| `scripts/install.sh` | Install Java 21 (Temurin), download Metabase JAR v0.52.6, install nginx |
| `scripts/build.sh` | Initialize H2 database, complete setup wizard via API, generate `storageState.json` |
| `scripts/start.sh` | Start Metabase + nginx with health checks (180s backend + 15s proxy timeout) |
| `scripts/stop.sh` | Graceful shutdown (SIGTERM → 30s wait → SIGKILL) of Metabase + nginx |
| `scripts/seed-data.sh` | Create sample questions, dashboards, collections via Metabase API |
| `scripts/populate.sh` | Restore H2 database + Playwright state + plugins from `STATE_LOCATION` |
| `scripts/snapshot.sh` | Export H2 database + Playwright state + plugins to `STATE_LOCATION` |

### JVM Notes

Metabase is launched with `--add-opens java.base/java.nio=ALL-UNNAMED` to work
around module access restrictions in Java 21. This flag is set in both `build.sh`
and `start.sh`.

## Sample Tasks (5)

| Task | Archetype | Description |
|---|---|---|
| 01 | Routine | Create a saved question with the query builder |
| 02 | Routine | Build a dashboard with filters |
| 03 | Setup/Config | Configure admin settings and database |
| 04 | Routine | Write and save a SQL query |
| 05 | Setup/Config | Organize content with collections |

## CI / Remote Validation (Optional)

The repository includes a Modal sandbox CI workflow that tests in a
Studio-identical environment without requiring a full release cycle.

**Prerequisites:** GitHub secrets `MODAL_TOKEN_ID`, `MODAL_TOKEN_SECRET`,
and `BIOME_REPO_TOKEN` must be configured on the repository.

**Trigger:** Run "Test on Modal Sandbox" from the GitHub Actions tab
(`.github/workflows/test-modal-sandbox.yml`).

**Local usage:**

```bash
export MODAL_TOKEN_ID="ak-..."
export MODAL_TOKEN_SECRET="as-..."
bash scripts/test-modal-sandbox.sh --biome-dir /path/to/biome [options]
```

Supported flags: `--biome-dir`, `--no-cache`, `--app-name`, `--timeout`,
`--seed-data`, `--env`. See `scripts/test-modal-sandbox.sh` header for details.

After the sandbox is running, paste the Webapp URL from the job summary into
the iframe tester at `https://rls-bua-playground.fly.dev/`.

## Troubleshooting

### Metabase won't start
- Check Java is installed: `java -version` (need JDK 21+)
- Check JAR exists: `ls -la /opt/metabase/metabase.jar`
- Check logs: `tail -f .state/logs/metabase.log`
- The backend health check waits up to **180 seconds** before failing; Metabase
  on first boot can take 60-120s on slow hardware
- If the process dies during startup, `start.sh` prints the last 50 lines of the
  log automatically

### Stale processes from previous runs
- `start.sh` cleans up stale Metabase processes via PID file (`.state/metabase.pid`)
  and `fuser` on the backend port before starting
- `stop.sh` uses graceful shutdown (SIGTERM) with a 30-second wait, then SIGKILL
- If manual cleanup is needed: `pkill -f "/opt/metabase/metabase.jar"` and
  `nginx -s stop`

### Blank iframe in Studio
- Verify nginx strips X-Frame-Options: check response headers
- Verify CSP frame-ancestors includes Studio domains
- Check `config/nginx.conf` has `proxy_hide_header X-Frame-Options`

### Login loop in iframe
- Verify cookies have `SameSite=None; Secure` attributes
- Check nginx `proxy_cookie_flags` directive
- Verify `MB_ENCRYPTION_SECRET_KEY` is set (fixed, never rotated)
- Verify `snapshot.sh` exported and `populate.sh` restored `playwright/storageState.json`

### Setup wizard appears instead of login
- `build.sh` may not have completed setup successfully
- Re-run: `mise run build` (will attempt setup again)
- Or manually complete setup at http://localhost:8081/setup

### Queries time out
- Increase `proxy_read_timeout` in `config/nginx.conf`
- Default is 300s (5 minutes)
- Check Metabase logs for query execution details

### Seed data script fails
- The seed script waits for Metabase to be ready (auth API + Sample Database sync)
  using configurable retries (see "Seed Script Variables" above)
- If the Sample Database is not synced yet, increase `SEED_SYNC_WAIT`
- The script prints a summary of warnings at the end; non-critical failures
  (e.g. optional dashboard features) produce warnings, not hard errors
