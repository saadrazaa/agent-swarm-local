# Upgrades & Rollback

## Policy

- Check monthly; upgrade for required features/fixes/security, not every release.
- Let a normal release soak 48–72h before adopting.
- Upgrade API and worker **together** to the exact same version.
- Treat the agent-fs version declared by the target Agent Swarm Compose tag as the
  compatibility baseline. Do not jump agent-fs independently (e.g. 0.9.0 → newer)
  without a separate compatibility test.
- Upgrade MinIO separately when possible.
- Never auto-pull or deploy `latest`. `scripts/check-updates.sh` is read-only.

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

- API volume scoped to `/app/data` (upstream example mounts all of `/app`);
  `/app/migrations` must stay image-owned.
- MinIO host port via `MINIO_HOST_PORT` (default 9002, not 9000).
- Loopback-only published ports; MinIO console 9001 unpublished.
- No `platform: linux/amd64`, no `pull_policy: always` (we pin arm64 by digest).
- `MAX_CONCURRENT_TASKS` set explicitly on **every** agent, because
  `official/coder` advertises `maxTasks: 3` and would otherwise apply. Current
  values (each set to its own template's default rather than left to the
  fallback): lead `tars` = `3`; workers `chase`, `rocky`, `igris`, `beru`
  (all coder) = `3` each; `einstein` and `socrates` (both researcher) = `2`
  each (aggregate worker concurrency 16). Update this line whenever a value
  changes.
- `YOLO=false`; inbound Slack/GitHub/Linear/Jira disabled.
- `HEARTBEAT_CHECKLIST_DISABLE` left unset (the var exists but `Boolean(env)`
  parsing means any non-empty value, even `"false"`, disables the checklist).
- `STEERING_ENABLED` left unset (introduced in v1.123.0, upstream default off):
  task steering stays disabled on API and workers. Its companion vars
  (`SLACK_THREAD_STEERING`, `CLAUDE_QUEUE_STEERING`) are also unset; enable
  deliberately, never via a port-forward of the upstream example.
- Explicit `CAPABILITIES` on the `api` service (since v1.121.1, which introduced
  capability-gated MCP tool registration) — set to the v1.119.1-equivalent tool
  surface plus `services`, since the new upstream default drops `services` and
  would otherwise silently disable register-service/PM2 discovery.
- Worker auth via `ANTHROPIC_API_KEY`/`OPENAI_API_KEY` + `HARNESS_PROVIDER`
  (upstream example uses `CLAUDE_CODE_OAUTH_TOKEN`).
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
