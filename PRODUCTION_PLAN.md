# Metabase BUA - Parallel Execution Plan (Current State)

This document is the execution source of truth for parallel agent work on
`mercor-rls-metabase`. It is aligned with the **actual repository state** as of
this revision.

## Why this update exists

Previous planning content drifted from implementation (for example, references to
"latest" Metabase JAR and TODO modal testing). This file resolves that drift so
multiple agents can work without stepping on each other or reintroducing regressions.

## Current Baseline

| Field | Value |
|---|---|
| App | Metabase |
| Pinned Default Version | `0.52.6` (override via `METABASE_VERSION`) |
| Public Port | `WEBAPP_PORT=8081` |
| Internal Port | `BACKEND_PORT=3000` |
| Runtime State | `.state/` |
| Snapshot State | `STATE_LOCATION=/.apps_data/metabase` |
| Modal Test Script | `scripts/test-modal-sandbox.sh` (implemented) |

## Non-Negotiable Platform Rules

1. Port `8080` is never used by the app service.
2. `WEBAPP_PORT` remains the public UI port env var name.
3. `STATE_LOCATION` remains the task snapshot env var name.
4. Runtime data lives in `.state`, not directly in `STATE_LOCATION`.
5. Use `chmod`; do not add `chown` in lifecycle scripts.

## Runtime Contracts (Do Not Break)

- `scripts/install.sh`
  - Installs nginx + JDK 21.
  - Downloads Metabase JAR with pinned default `0.52.6`.
- `scripts/build.sh`
  - Initializes Metabase setup/admin user.
  - Creates `.state/playwright/storageState.json` for pre-auth flow.
- `scripts/start.sh`
  - Starts Metabase + nginx using `.state`.
  - Runs nginx `-t` validation and health checks (up to 180s).
- `scripts/populate.sh` / `scripts/snapshot.sh`
  - Move H2 db + Playwright storage state between `.state` and `STATE_LOCATION`.
- `config/nginx.conf`
  - Handles iframe hardening, forwarded host/proto mapping, cookie flags,
    and redirect rewriting.

## Parallel Workstreams

Run these in parallel after Gate 0.

### Gate 0 (Sequential, Required First)

- Validate baseline before parallel edits:
  - `bash -n scripts/*.sh`
  - Confirm `arco.toml` invariants.
  - Confirm `mise.toml` contains `[env] STATE_LOCATION`.

---

### Workstream A - Runtime Core

**Owner:** Runtime agent  
**Files:** `scripts/install.sh`, `scripts/build.sh`, `scripts/start.sh`,
`scripts/stop.sh`, `config/nginx.conf`

**Allowed changes:**
- Startup reliability, health checks, stricter failure logging.
- Backward-compatible environment defaults only.

**Not allowed:**
- Renaming/removing `WEBAPP_PORT` or `STATE_LOCATION`.
- Moving runtime state from `.state` to `STATE_LOCATION`.

**Acceptance checks:**
- `bash -n` passes for all edited shell scripts.
- Nginx template renders and validates (`nginx -t -c /tmp/nginx.conf` via start flow).

---

### Workstream B - State/Auth/Seed

**Owner:** Data/auth agent  
**Files:** `scripts/seed-data.sh`, `scripts/populate.sh`, `scripts/snapshot.sh`

**Allowed changes:**
- Improve idempotency and robustness of seed creation.
- Ensure snapshot/populate round-trip remains deterministic.

**Not allowed:**
- Editing `scripts/start.sh` or `config/nginx.conf` without explicit handoff.

**Acceptance checks:**
- `mise run snapshot` exports H2 + `playwright/storageState.json`.
- `mise run populate` restores both cleanly.
- Seed script does not hard-fail on non-critical optional resources.

---

### Workstream C - Task Suite

**Owner:** Task-design agent  
**Files:** `tasks/*.md`

**Allowed changes:**
- Clarify prompts and expected outcomes.
- Keep archetype coverage: Setup/Config + Routine Execution.

**Not allowed:**
- Coupling task text to fragile internal IDs.

**Acceptance checks:**
- Each task contains `Archetype`, `Prompt`, `Expected Result`, `Seed Data Required`.
- Task dependencies between files are explicit and minimal.

---

### Workstream D - Docs & Operational Readiness

**Owner:** Docs agent  
**Files:** `README.md`, `CHECKLIST.md`, this `PRODUCTION_PLAN.md`

**Allowed changes:**
- Keep docs synchronized with actual script behavior and env contracts.
- Update runbooks and validation steps.

**Acceptance checks:**
- No references to deprecated flow (e.g. modal TODO, "latest" as required default).
- Localdev validation section includes Proxy + XSite workflow.

---

### Workstream E - CI/Remote Validation

**Owner:** CI agent  
**Files:** `.github/workflows/test-modal-sandbox.yml`, `scripts/test-modal-sandbox.sh`

**Allowed changes:**
- CI reliability improvements compatible with starter workflow interface.

**Not allowed:**
- Breaking workflow input names or required secret names:
  - `MODAL_TOKEN_ID`
  - `MODAL_TOKEN_SECRET`
  - `BIOME_REPO_TOKEN`

**Acceptance checks:**
- Script still supports:
  - `--biome-dir`
  - `--no-cache`
  - `--app-name`
  - `--timeout`
  - `--seed-data`
  - `--env`
- Workflow summary extraction still finds sandbox/webapp URLs in logs.

## Merge Order and Dependencies

1. Merge Workstream A first (runtime contract owner).
2. Merge Workstream B next (depends on A contracts).
3. Merge Workstream C and D in parallel once A is stable.
4. Merge Workstream E after A is stable; can run in parallel with B/C/D.

## Collision Prevention Rules

- Only one owner edits each file group at a time.
- If a cross-boundary change is needed:
  1. Open handoff note in PR description.
  2. Merge owner branch first.
  3. Rebase dependent branch and continue.
- Avoid "drive-by" edits in foreign workstream files.

## End-to-End Validation (Final Gate)

Run in order:

```bash
mise run install
mise run build
mise run start
mise run seed
mise run snapshot
mise run populate
```

Then validate local embedding with localdev harness:

```bash
# from mercor-rls-bua-localdev
pnpm run-with-app -- /path/to/mercor-rls-metabase
```

Required pass signals:
- Iframe loads (no CSP/X-Frame blocking).
- Session survives in Proxy + XSite mode.
- No redirect leaks to internal host/port.
- Seeded questions/dashboards visible.

## Parallel Assignment Checklist

- [ ] Runtime owner assigned
- [ ] Data/auth owner assigned
- [ ] Task owner assigned
- [ ] Docs owner assigned
- [ ] CI owner assigned
- [ ] Owners acknowledge file boundaries
- [ ] Final gate owner assigned

---

This plan intentionally prioritizes deterministic execution and low merge conflict
risk over broad exploratory changes.
