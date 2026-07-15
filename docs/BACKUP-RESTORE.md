# Backup & Restore

Both databases (API + agent-fs) are SQLite in WAL mode, so copying live files is
unsafe. The scripts stop services in dependency order, archive named volumes
read-only with a pinned helper image, record a manifest + checksums, then restart
and verify.

**A backup that has not been restored is not trusted.** Run one full backup +
restore drill before storing real work, and a restore drill quarterly / whenever
the backup tooling changes.

## Critical restore set

- `swarm_api_data` — API DB (encrypted secrets live here)
- `agent_fs_data` — agent-fs metadata/embeddings DB
- `agent_fs_minio` — object storage
- `encryption_key` — without the exact key, `swarm_api_data` secrets are unrecoverable
- `.env`, `compose.yaml`, `versions.env`

Also archived: `swarm_shared`, `swarm_lead`, `swarm_worker_claude`,
`swarm_worker_codex`, `swarm_codex_home` (session/uncommitted artifacts). Logs are
optional. `swarm_api_data` + `agent_fs_data` + `agent_fs_minio` must be restored as
**one consistent set** — never mix an old DB with a newer MinIO snapshot.

## Backup

```bash
./scripts/backup.sh                 # -> backups/<UTC-timestamp>/
./scripts/backup.sh /path/to/dest   # explicit destination
```

`backup.sh`: single-flight lock; pauses agents (API stays up to record pause), then
stops API → agent-fs → MinIO; tars each volume read-only; copies config + version
pins; writes `MANIFEST.txt` (UTC time, deployment git commit, image refs/digests,
volume names, Docker arch) and `SHA256SUMS`; verifies each archive is listable;
restarts in dependency order; runs `verify.sh`.

The `.env` and `encryption_key` are copied as `*.SENSITIVE`. **Move them to an
encrypted, off-Docker destination and delete the plaintext copies afterwards** — the
script prints a reminder.

## Restore (destructive)

```bash
./scripts/restore.sh backups/<timestamp> --yes-destroy-current-state
```

`restore.sh` refuses without the confirmation flag, verifies the manifest + all
checksums **before** touching state, takes an emergency snapshot of current volumes,
brings containers down (keeping volumes; never `-v`), then clears and restores the
exact volume set, restores `.env`/`encryption_key`/`compose.yaml`/`versions.env`,
starts the backed-up image versions in order, runs a best-effort SQLite
`integrity_check` on both DBs, and runs `verify.sh`. The emergency snapshot is
retained under `backups/emergency-<timestamp>`.

## Retention

- Weekly snapshot: keep the latest 4.
- Pre-upgrade snapshot: keep the latest 2 plus the last known-good baseline.

## Never

- `docker compose down -v` in any normal/backup/upgrade/rollback flow.
- Storing `.env` or `encryption_key` in Git, agent-fs, swarm memory, a task prompt,
  or a shell trace.
- Trusting a backup you have not restored.
