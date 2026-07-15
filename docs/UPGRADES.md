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

Port only applicable changes into this trimmed `compose.yaml`. Note the v1.119.1
deltas already applied here vs. the upstream example, so re-diffs are meaningful:

- API volume scoped to `/app/data` (upstream example mounts all of `/app`).
- MinIO host port via `MINIO_HOST_PORT` (default 9002, not 9000).
- Loopback-only published ports; MinIO console 9001 unpublished.
- No `platform: linux/amd64`, no `pull_policy: always` (we pin arm64 by digest).
- `MAX_CONCURRENT_TASKS=1` set explicitly on both workers and the lead.
- `YOLO=false`; inbound Slack/GitHub/Linear/Jira disabled.
- `HEARTBEAT_CHECKLIST_DISABLE` omitted (does not exist in v1.119.1).
- Worker auth via `ANTHROPIC_API_KEY`/`OPENAI_API_KEY` + `HARNESS_PROVIDER`
  (upstream example uses `CLAUDE_CODE_OAUTH_TOKEN`).

## Execution

1. Update full image references in `versions.env` on the upgrade branch.
2. Validate: `docker compose --env-file versions.env --env-file .env config -q`,
   confirm arm64 manifests, confirm no `latest`.
3. Pull the new images **without** starting them.
4. Let tasks finish or pause them gracefully.
5. Take and verify a full offline pre-upgrade backup (`scripts/backup.sh`).
6. Stop lead + workers, then API, agent-fs, MinIO.
7. Start MinIO/minio-init + agent-fs; verify storage health.
8. Start **API alone** — numbered SQL migrations run here (one transaction each;
   there is no down-migration framework, so a successful new API boot may change the
   DB even if a later smoke test fails).
9. Inspect logs for migration/checksum/encryption/provisioning/DB errors.
10. Verify API health and `/api/fs/capabilities` → `agent-fs`.
11. Confirm old attachments and memory are readable.
12. Write + semantically retrieve a unique new test artifact.
13. Start lead + both workers.
14. Confirm stable identities, harness assignments, aggregate worker concurrency ≤2,
    disposable tasks on both harnesses, pause/resume.
15. Observe before merging the upgrade branch.
16. Merge the version/config change; take a new known-good backup.

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
