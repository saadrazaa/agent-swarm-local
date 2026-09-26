# Upgrades & Rollback

## Policy

- Check monthly; upgrade for required features/fixes/security, not every release.
- Let a normal release soak 48–72h before adopting.
- Upgrade API and worker **together** to the exact same version.
- Treat the agent-fs version declared by the target Agent Swarm Compose tag as the
  compatibility baseline. Do not jump agent-fs independently (e.g. 0.9.0 → newer)
  without a separate compatibility test. This cuts both ways: leaving `AGENT_FS_IMAGE`
  *behind* the declared version is also an independent pin. When the declared version
  moves, it moves in the same PR as the API/worker pins. v1.155.1 declares agent-fs
  **0.13.9** (compose example `ghcr.io/desplega-ai/agent-fs:0.13.9` and
  `Dockerfile.worker`'s `ARG AGENT_FS_VERSION=0.13.9`); v1.129.0 declared 0.12.2 and
  v1.125.0 declared 0.9.0.
- Upgrade MinIO separately when possible.
- Pin the worker to the **plain** versioned tag, never the `-slim` sibling
  published alongside it since v1.123.1. Slim is upstream's CI/E2E image and
  drops `glab`, the build toolchain, Playwright/`qa-use`, the bundled Postgres
  and Redis servers, `sentry-cli`, `localtunnel`, `claude-bridge`, the
  context-mode harness hook plugins, and `vim`/`tmux`/`htop`/`tree`. The plain
  tag is `worker-full`, which is what this stack expects.
- Never auto-pull or deploy `latest`. `scripts/check-updates.sh` is read-only.
- Since v1.126.0 a worker/lead container **exits fatally** if `${MCP_BASE_URL}/health`
  is unreachable within `WORKER_API_READY_TIMEOUT_SECONDS` (default `90`). It is a
  bootstrap-only variable — it must be in the container environment, never in
  `swarm_config` — and this stack deliberately leaves it unset: every agent service
  already declares `depends_on: api: condition: service_healthy` plus
  `restart: unless-stopped`, which orders boot and self-heals a transient failure.
  Start agents against a genuinely down API and they now die instead of limping.
- **MinIO is pinned to Docker Hub references that are no longer anonymously
  pullable.** MinIO removed `minio/minio` and `minio/mc` from Docker Hub (both
  return HTTP 404 from `hub.docker.com/v2/repositories/…`, checked 2026-09-26).
  Upstream's v1.150.0 (PR #1499) repointed its example at
  `quay.io/minio/{minio,mc}`, but an anonymous quay token for those repos grants
  `actions: []` — so that mirror is not anonymously pullable either. This repo
  deliberately does **not** follow upstream here: a digest we cannot fetch to
  verify is a worse pin than one backed by a warm local cache. Consequences:
  treat the local MinIO images as irreplaceable (export them with `docker save`,
  never prune them), and scope `docker compose pull` to the services that
  actually changed so a dead MinIO reference cannot fail the step. Revisit when
  either registry serves these repos anonymously again, or move to an
  authenticated pull-through mirror.
- Since v1.129.0 `PAGE_SESSION_SECRET` no longer falls back to `API_KEY`. Left
  unset, the API generates 32 random bytes and persists them at
  `<dirname(DATABASE_PATH)>/.page-session-secret` — here `/app/data/.page-session-secret`,
  inside `swarm_api_data`, which `scripts/backup.sh` already captures. So no action
  is needed; but a `swarm_api_data` restore from a *different* backup generation
  invalidates live page sessions, and setting `PAGE_SESSION_SECRET` (or the new
  `PAGE_SESSION_SECRET_FILE`) explicitly is the only way to make them survive that.

## Review before upgrading

Create an upgrade branch in this repo. Inspect every release between current and
target, then diff these upstream paths between tags (use a throwaway upstream clone;
never mix upstream history into this repo):

```
docker-compose.example.yml   .env.docker.example   DEPLOYMENT.md
Dockerfile   Dockerfile.worker   docker-entrypoint.sh   src/be/migrations/
docs-site/.../guides/deployment.mdx
docs-site/.../guides/agent-fs-co-deployment.mdx
```

Look for: new/renamed required env vars; changed users/paths/ports/health checks/
mounts; DB migrations; worker harness/version changes; agent-fs compatibility;
secret-encryption changes; arm64 manifest availability.

Port only applicable changes into this trimmed `compose.yaml`. These are the
deltas this stack currently carries vs. the upstream example, so that re-diffs
stay meaningful. **Preserve every one of them** — a careless port-forward of the
upstream example silently reverts them:

- API volume scoped to `/app/data`; `/app/migrations` must stay image-owned.
  **No longer divergent as of v1.151.0** (PR #1529) — upstream's example moved
  from `swarm_api:/app` to `swarm_api_data:/app/data`, adopting what this repo
  carried first. Kept in this list so a future re-diff knows it is deliberate,
  not incidental.
- MinIO host port via `MINIO_HOST_PORT` (default 9002, not 9000).
- Loopback-only published ports; MinIO console 9001 unpublished.
- No `platform: linux/amd64`, no `pull_policy: always` (we pin arm64 by digest).
  Unchanged at v1.155.1: upstream still carries 14 `platform:` and 15
  `pull_policy:` entries.
- No `pids_limit: 1024` on the agent services. Upstream added it as a containment
  default; not adopted here, since this stack's containment story is the network
  boundary rather than per-container resource caps. Safe to adopt if wanted.
- `MAX_CONCURRENT_TASKS` set explicitly on **every** agent, because
  `official/coder` advertises `maxTasks: 3` and would otherwise apply. Current
  values (each set to its own template's default rather than left to the
  fallback): lead `tars` = `3`; workers `chase`, `rocky`, `igris`, `beru`
  (all coder) = `3` each; `einstein` and `socrates` (both researcher) = `2`
  each (aggregate worker concurrency 16). Update this line whenever a value
  changes. The variable appears **nowhere** in the upstream example (0
  occurrences at v1.155.1), so a diff cannot merge these away — but it also
  offers no upstream guidance when template defaults move.
- `YOLO=false`; inbound Slack/GitHub/Linear/Jira disabled.
- Explicit `RBAC_ENABLED: "false"` on the `api` service. This used to agree with
  upstream's default; since v1.151.0 (PR #1536, `src/rbac/admission.ts`) the
  unset default is **true** and the upstream example writes
  `${RBAC_ENABLED:-true}`. The explicit value is now the only thing keeping this
  single-operator stack out of RBAC — never drop it in a port-forward.
- Explicit `SEED_AUTOMATIONS_ENABLED` (default `false` via
  `${SEED_AUTOMATIONS_ENABLED:-false}`) on the `api` service. Upstream's shipped
  default is `true` (v1.149.1, `src/be/seed/automation-toggle.ts`), which creates
  **and enables** zero-config automations marked `autoEnableCandidate` —
  `daily-status-report` and `daily-swarm-update-check` — so they begin firing
  daily against the model budget on first boot. Defaulted off here so a pin bump
  never silently creates recurring spend on an unattended stack. The seeder only
  resolves `enabled` on create, so pre-existing schedules keep their state.
- `HEARTBEAT_CHECKLIST_DISABLE` left unset (the var exists but `Boolean(env)`
  parsing means any non-empty value, even `"false"`, disables the checklist).
- `STEERING_ENABLED` set **explicitly to `false`** on the `api` service and on all
  seven agents, via `${STEERING_ENABLED:-false}` so one `.env` line moves them
  together. It was introduced in v1.123.0 with an upstream default of off, and
  this stack expressed "steering disabled" by leaving it unset. **v1.151.0 (PR
  #1536, `src/utils/steering-enabled.ts` → `parseEnvFlag(env.STEERING_ENABLED,
  true)`) flipped that unset default to `true`**, so from v1.151.0 onward an
  unset variable means steering is ON. The explicit value preserves the stack's
  documented intent across the pin bump; set `STEERING_ENABLED=true` in `.env` to
  adopt upstream's new default deliberately. Its companion vars
  (`SLACK_THREAD_STEERING`, `CLAUDE_QUEUE_STEERING`) remain unset. Since v1.125.0
  the worker image also ships a root-owned `/etc/codex/requirements.toml`
  registering Codex lifecycle hooks — inert while `STEERING_ENABLED` is false,
  so `rocky` gets the file and no behaviour change.
- Explicit `CAPABILITIES` on the `api` service (since v1.121.1, which introduced
  capability-gated MCP tool registration) — set to the v1.119.1-equivalent tool
  surface plus `services`, since the new upstream default drops `services` and
  would otherwise silently disable register-service/PM2 discovery. Keep `kv` in
  that list: from v1.125.0 any MCP result over 10 KB is spilled to a 24h
  per-agent KV namespace and retrieved via `kv-get`, so dropping `kv` would make
  oversized tool results unreadable. Keep `skills` in it too: from v1.129.0 the
  ai-toolbox skill catalog is no longer baked into the worker image — the API
  seeds it into the DB at boot and serves it from there, so an API without the
  `skills` capability leaves every worker with only the image-baked `agent-fs`
  (and `qa-use`) skills, silently and with no error at the worker end.
- Worker auth via `ANTHROPIC_API_KEY`/`OPENAI_API_KEY` + `HARNESS_PROVIDER`.
  Largely **absorbed upstream**: the v1.155.1 example now ships a
  harness-provider credential block (`HARNESS_PROVIDER`, `MODEL_OVERRIDE`,
  `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `OPENROUTER_*`, `BEDROCK_AUTH_MODE`,
  `AWS_*`) on every agent service, so upstream has caught up to this delta rather
  than this stack diverging. Only the choice of credential remains local.
- `EMBEDDING_API_KEY: ${OPENAI_API_KEY:-}` on the `api` service (the upstream
  example passes no embedding key to the API). The memory embedding provider
  reads `EMBEDDING_API_KEY` then `OPENAI_API_KEY` from the API's environment;
  without one it silently stores NULL embeddings and memory-search runs
  keyword-only (`/api/memory/health` → `retrievalMode: "fallback"`). After
  enabling, backfill once with `POST /api/memory/re-embed`
  (see [OPERATIONS.md](OPERATIONS.md)).
- Share-link env on **every** agent service: `APP_URL`, `SWARM_URL`,
  `AGENT_FS_LIVE_URL` (defaults: hosted dashboard `https://app.agent-swarm.dev`,
  bare host `app.agent-swarm.dev`, hosted viewer `https://live.agent-fs.dev`).
  The upstream example sets only `SWARM_URL` on agents; without these, agents
  only see `MCP_BASE_URL=http://api:3013` and emit container-internal share
  links.

## Execution

Run this on the host, as the operator. Do not delegate the restart steps to an
agent running *inside* this stack — restarting the stack kills that agent
mid-flight.

1. Update full image references in `versions.env` on the upgrade branch.
2. Validate: `docker compose --env-file versions.env --env-file .env config -q`,
   confirm arm64 manifests, confirm no `latest`. See
   [CONTRIBUTING.md](../CONTRIBUTING.md) for the exact pin rules and how to get
   arm64 evidence from the registry API.
3. Pull the new images **without** starting them.
4. Let tasks finish or pause them gracefully.
5. Take and verify a full offline pre-upgrade backup (`scripts/backup.sh`).
6. Stop all seven agents (`make pause`), then API, agent-fs, MinIO.
7. Start MinIO/minio-init + agent-fs; verify storage health.
8. Start **API alone** — numbered SQL migrations run here (one transaction each;
   there is no down-migration framework, so a successful new API boot may change the
   DB even if a later smoke test fails).
9. Inspect logs for migration/checksum/encryption/provisioning/DB errors.
10. Verify API health and `/api/fs/capabilities` → `agent-fs`.
11. Confirm old attachments and memory are readable.
12. Write + semantically retrieve a unique new test artifact.
13. Start the agents (`make restart-agents`).
14. Confirm stable identities, harness assignments, aggregate worker concurrency
    matching the caps in `compose.yaml`, disposable tasks on both harnesses, and
    pause/resume.
15. Observe before merging the upgrade branch.
16. Merge the version/config change, update the README version line and the deltas
    list above, then take a new known-good backup.

## Rollback (image rollback + state restore)

1. Stop agents, API, agent-fs, MinIO.
2. Restore the previous committed `compose.yaml` + `versions.env`.
3. Restore the entire matching pre-upgrade volume set (`scripts/restore.sh`).
4. Restore the exact matching `.env` + `encryption_key`.
5. Start old storage → old API → old agents.
6. Run the full verification suite.

**Never** start an older API against a DB already touched by a newer API. **Never**
mix an old agent-fs DB with a new MinIO snapshot (or vice versa).

## When to fork (last resort)

Only when a persistent source-level patch is required (API/DB/provider adapter/auth/
integration/entrypoint) that no supported extension point can express and upstream
can't release in time — and you accept ownership of builds/tests/security/migrations/
multi-arch publishing. Prefer an upstream contribution. Keep `origin/main` a clean
upstream mirror, patches on a minimal `downstream/local` branch, tag images
`upstream-X.Y.Z-local.N`, and never edit an applied migration (add a forward one).
