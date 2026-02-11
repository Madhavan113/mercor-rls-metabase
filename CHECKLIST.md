# Pre-Ship Checklist -- Metabase BUA

Walk through every item before pushing to GitHub.

## Platform Invariants

- [x] `WEBAPP_PORT` used for public entrypoint (8081)
- [x] `STATE_LOCATION` used for task data (`/.apps_data/metabase`)
- [x] Port 8080 not used anywhere
- [x] `mise.toml` includes `[env]` with `STATE_LOCATION`
- [x] `arco.toml` has correct `name`, `version`, `env_base`, and runtime env block

## Iframe Hardening (config/nginx.conf)

- [x] `proxy_hide_header X-Frame-Options` (strips Metabase DENY header)
- [x] `proxy_hide_header Content-Security-Policy` (strips upstream CSP)
- [x] `proxy_hide_header Content-Security-Policy-Report-Only` (strips report-only CSP)
- [x] `add_header Content-Security-Policy "frame-ancestors ..."` (adds Studio CSP)
- [x] `proxy_cookie_flags ~ samesite=none secure` (cross-site cookies)
- [x] `proxy_set_header Host`, `X-Forwarded-Host`, `X-Forwarded-Proto` set
- [x] `absolute_redirect off` (prevents redirect leaks)
- [x] `proxy_redirect` rule rewrites localhost redirects to forwarded host/proto

## Application

- [x] Metabase version pinned to `0.52.6` (override via `METABASE_VERSION`)
- [x] App base URL is runtime-configurable (`MB_SITE_URL` can be overridden)
- [x] Secrets deferred to runtime, set in start.sh (`MB_ENCRYPTION_SECRET_KEY`)
- [x] Fixed secret key never rotates (session persistence across restarts)
- [x] Admin user created in build.sh via setup wizard API
- [x] Health check endpoint works: `/api/health` through nginx
- [x] start.sh cleans up stale processes before launching (PID file + fuser)
- [x] stop.sh uses graceful shutdown (SIGTERM → 30s → SIGKILL)
- [x] nginx config validated with `nginx -t` before starting

## State Management

- [x] populate.sh restores H2 database from `STATE_LOCATION`
- [x] snapshot.sh exports H2 database to `STATE_LOCATION`
- [x] build.sh generates `.state/playwright/storageState.json`
- [x] snapshot/populate round-trip includes Playwright storage state
- [x] snapshot/populate round-trip includes plugins (if present)
- [x] Round-trip test: snapshot -> wipe -> populate -> verify

## Smoke Test

- [ ] App loads in iframe (local harness, Proxy + XSite mode)
- [ ] Login persists inside iframe after page reload
- [ ] No localhost links visible in the UI
- [ ] Sample Database is accessible and queries work
- [ ] Saved questions and dashboards render correctly

## Tasks

- [x] 5 task files in `tasks/` directory
- [x] Tasks cover Setup/Config and Routine Execution archetypes
- [x] Each task has Archetype, Prompt, Expected Result, Seed Data Required

## CI / Remote Validation

- [x] `.github/workflows/foundry-service-sync.yml` present (release sync)
- [x] `.github/workflows/test-modal-sandbox.yml` present (Modal sandbox CI)
- [x] `scripts/test-modal-sandbox.sh` supports required flags (`--biome-dir`, `--no-cache`, `--app-name`, `--timeout`, `--seed-data`, `--env`)
- [ ] Modal sandbox test passes end-to-end (requires GitHub secrets)

## Documentation

- [x] README covers architecture, ports, env vars, quick start, troubleshooting
- [x] README documents CI/Modal sandbox workflow
- [x] README documents all Metabase-specific runtime variables
- [x] README documents seed script tuning variables
- [x] PRODUCTION_PLAN.md reflects current baseline and workstream boundaries
