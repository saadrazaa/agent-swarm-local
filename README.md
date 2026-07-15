# agent-swarm-local

Trimmed, single-user, loopback-only Docker deployment of
[desplega-ai/agent-swarm](https://github.com/desplega-ai/agent-swarm) pinned at
**v1.119.1** with **agent-fs 0.9.0**, for Apple Silicon. Persistent agent memory
is provided by agent-fs backed by a local MinIO.

This repository contains **only** Compose config, version pins, operational
scripts, and docs. There is no upstream fork and no source modification — see
[docs/UPGRADES.md](docs/UPGRADES.md) and the fork policy in the implementation
plan. Consume upstream release images; customize via profiles/templates/skills/
MCP/workflows/env, not by carrying source.

## Architecture

```
local API client / dashboard --> 127.0.0.1:3013 --> API (swarm_api_data:/app/data)
                                                      |
                                                      +-- agent-fs (agent_fs_data:/data)
                                                              |
                                                              +-- MinIO (agent_fs_minio:/data, S3)
API-coordinated agents (outbound LLM + Git only):
  lead (Claude) · worker-claude (Claude) · worker-codex (Codex)   -> shared workspace
```

Six long-running containers + one-shot `minio-init`. Only the control plane and
persistence run locally; LLM inference and Git are outbound calls.

## Prerequisites

- Docker Desktop (Apple Silicon / arm64), ≥6 CPUs, ≥8 GB RAM (10 GB recommended
  if two builds run at once — see the memory note below), ≥35–40 GB free disk.
- `openssl`, `uuidgen`, `shellcheck`, `curl`, `gh` (for GitHub checks) on the host.
- An **encrypted, off-device** destination for recovery copies of `.env` and
  `encryption_key`, and for backups.

### Host-specific deviations from the base plan

- **MinIO host port is `9002`, not `9000`.** Port 9000 on this machine is already
  taken by the `client-monorepo` dev stack's MinIO. The published S3 port is set
  by `MINIO_HOST_PORT` in `.env` (default 9002); signed object URLs use it. If you
  free 9000, set `MINIO_HOST_PORT=9000`. Ports 3013 (API) and 7433 (agent-fs) are
  unchanged and were free.
- **Memory pressure:** Docker's VM is ~7.8 GiB and the `client-monorepo` stack is
  already running in it. Before Phase 2+ bring-up, either raise Docker to ≥10–12 GB
  or stop `client-monorepo` while the swarm runs. Two coder builds + the embedding
  model can otherwise thrash this VM.

## Layout

```
compose.yaml        trimmed stack (fixed project + volume names, loopback ports)
versions.env        image tag+digest pins (all arm64-verified)
.env                secrets + permanent identity (git-ignored, mode 600)
encryption_key      secrets-encryption key (git-ignored, mode 600, Compose secret)
scripts/            bootstrap · verify · backup · restore · check-updates
docs/               OPERATIONS · BACKUP-RESTORE · UPGRADES
backups/            local staging only (git-ignored)
```

## Quick start

```bash
# 1. Generate secrets + permanent identity (idempotent; never regenerates).
./scripts/bootstrap.sh
# 2. Paste real provider credentials into .env:
#    ANTHROPIC_API_KEY, OPENAI_API_KEY, GITHUB_WORKER_TOKEN, GITHUB_EMAIL, GITHUB_NAME
# 3. Store recovery copies of .env and encryption_key in an encrypted vault.

# Always pass BOTH env files:
docker compose --env-file versions.env --env-file .env up -d minio minio-init agent-fs api
./scripts/verify.sh
docker compose --env-file versions.env --env-file .env up -d lead worker-claude worker-codex
```

Stop everything without destroying data:

```bash
docker compose --env-file versions.env --env-file .env stop
```

**Never** run `docker compose down -v` — it deletes the named volumes (all memory
and identity). Backups/restores use explicit, checksum-verified volume ops instead.

## Current pins

| Component | Reference |
|---|---|
| API | `ghcr.io/desplega-ai/agent-swarm:1.119.1` |
| Worker | `ghcr.io/desplega-ai/agent-swarm-worker:1.119.1` |
| agent-fs | `ghcr.io/desplega-ai/agent-fs:0.9.0` |
| MinIO | `minio/minio:RELEASE.2025-09-07T16-13-09Z` |
| MinIO client | `minio/mc:RELEASE.2025-08-13T08-35-41Z` |

Full tag+digest references are in `versions.env`; every index was verified to
include `linux/arm64`.

## Security posture

- All published ports bind `127.0.0.1` only (3013, 7433, `MINIO_HOST_PORT`).
  MinIO console 9001 and agent ports are not published.
- MinIO uses random root credentials (never `minioadmin`).
- `RBAC_ENABLED=false` (single operator key). Inbound Slack/GitHub/Linear/Jira
  disabled; `GITHUB_DISABLE=true` disables only inbound webhooks — worker
  `GITHUB_TOKEN` clone/branch/push/PR operations still work.
- The GitHub PAT is passed only to `worker-claude` and `worker-codex`.
- `encryption_key` encrypts secrets in `swarm_api_data`. **Lose it and every
  stored secret is unrecoverable.** Back it up encrypted, off-device.

## Status / known limitations

- **Phase 0 (discovery):** done. arm64, 6 CPUs, ~7.8 GiB RAM; ports 3013/7433 free;
  9000 in use (→ 9002); no prior swarm install; 218 GiB free disk.
- **Phase 1 (scaffold + static validation):** done. shellcheck clean, `compose
  config` valid, images digest-pinned (no `latest`), no amd64/pull_policy, secrets
  git-ignored.
- **Phase 2+ (bring-up, agents, memory tests, backup drill):** pending. Requires
  the two host decisions above (port already defaulted to 9002; confirm memory) and
  the provider credentials in `.env`. Phase 4 must **empirically confirm** that
  `MAX_CONCURRENT_TASKS=1` overrides the `official/coder` template's `maxTasks:3`
  (source docs don't state the precedence; the 3-task test verifies aggregate
  worker concurrency never exceeds 2).
- `HEARTBEAT_CHECKLIST_DISABLE` from the plan does not exist in v1.119.1 and was
  omitted.
- The dashboard is not part of this stack; run it on-demand (see
  [docs/OPERATIONS.md](docs/OPERATIONS.md)).

## Conductor boundary

This repo and its Docker volumes are persistent infrastructure and live **outside**
any Conductor workspace (workspaces are disposable task-branch worktrees). Do not
bind-mount a Conductor workspace into a worker. Agent Swarm uses its own container
workspaces and opens PRs for review in Conductor.
