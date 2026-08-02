# agent-swarm-local

A trimmed, single-operator, loopback-only Docker Compose deployment of
[desplega-ai/agent-swarm](https://github.com/desplega-ai/agent-swarm), pinned at
**v1.125.0** with **agent-fs 0.9.0**. Persistent agent memory is provided by
agent-fs backed by a local MinIO. Everything runs on your host; nothing is
exposed beyond `127.0.0.1`.

> **Unofficial.** This is a community deployment configuration. It is not
> affiliated with, endorsed by, or supported by desplega.ai. Agent Swarm,
> agent-fs, and their images are upstream projects; this repo only pins and
> configures them. For product bugs, go upstream.

## What this is

- A `compose.yaml` with fixed project and volume names, so moving the repo never
  silently creates a second empty set of volumes.
- Image pins as `tag@sha256:<digest>` in `versions.env` — no `latest`, ever.
- Operational scripts: bootstrap, verify, backup, restore, upgrade recon.
- Docs for running, upgrading, and recovering the stack.

## What this is not

- **Not a fork.** There is no upstream source in this repo and no source
  modification. It consumes upstream release images; customization happens
  through profiles, templates, skills, MCP, workflows, and env — never by
  carrying patches. See [docs/UPGRADES.md](docs/UPGRADES.md).
- **Not multi-user.** `RBAC_ENABLED=false` and a single operator API key.
- **Not internet-facing.** No reverse proxy, no TLS, no inbound webhooks. All
  published ports bind loopback.
- **Not production infrastructure.** No HA, no monitoring, no alerting. Backups
  are a script you run.

## Architecture

```
your browser / API client --> 127.0.0.1:3013 --> api (swarm_api_data:/app/data)
                                                  |
                                                  +-- agent-fs (agent_fs_data:/data)
                                                        |
                                                        +-- MinIO (agent_fs_minio:/data, S3)

API-coordinated agents (outbound LLM + Git only), each with its own volume:
  tars      lead        Claude   official/lead
  chase     coder       Claude   official/coder
  rocky     coder       Codex    official/coder
  einstein  researcher  Claude   official/researcher
  igris     coder       Claude   official/coder
  beru      coder       Claude   official/coder
  socrates  researcher  Claude   official/researcher
                                        \--> shared workspace (swarm_shared)
```

Who each agent is, and where its personality actually lives:
[docs/AGENTS.md](docs/AGENTS.md).

Ten long-running containers (`minio`, `agent-fs`, `api`, and the seven agents)
plus two one-shots (`minio-init`, `agent-fs-viewer-init`). Only the control plane
and persistence run locally — LLM inference and Git are outbound calls.

## Platform support

Built and verified on **Apple Silicon (arm64) with Docker Desktop.** Every pinned
digest is a multi-arch index, but **only `linux/arm64` is verified** — `amd64` is
untested here and `scripts/verify.sh` actively fails if a running image is not
arm64. It will likely work on an amd64 Linux host after relaxing that check, but
nobody has tried; treat it as unsupported rather than broken.

## Prerequisites

- **Docker Desktop** (or equivalent) with ≥6 CPUs, ≥8 GB RAM allocated to the VM,
  and ≥35–40 GB free disk. If you run other heavy Compose stacks on the same
  Docker VM, budget ≥10–12 GB or stop them while the swarm runs — two concurrent
  agent builds plus the embedding model will thrash a smaller VM.
- **Host tools:** `openssl`, `uuidgen`, `curl`, `python3`, `make`. Optional:
  `gh` (upgrade recon), `shellcheck` (contributors).
- **Three free loopback ports:** 3013 (API), 7433 (agent-fs diagnostics), and one
  for MinIO's S3 API — `MINIO_HOST_PORT`, default **9002** so it does not collide
  with another local MinIO on 9000. Set it to 9000 if that port is free.
- **An encrypted, off-device destination** for recovery copies of `.env` and
  `encryption_key`, and for backups. Losing `encryption_key` makes every secret
  stored in the API database permanently unrecoverable.
- **Provider credentials:** an Anthropic API key *or* a Claude Code OAuth token
  (for the six Claude agents), and an OpenAI API key (for the Codex worker and
  for the API's memory embeddings — without it, semantic memory search silently
  degrades to keyword matching).

## Quick start

```bash
# 1. Generate secrets + permanent identity. Idempotent: it never overwrites an
#    existing .env or encryption_key, and backfills newly-added keys.
./scripts/bootstrap.sh

# 2. Paste your provider credentials into the generated .env:
#      ANTHROPIC_API_KEY *or* CLAUDE_CODE_OAUTH_TOKEN   (exactly one)
#      OPENAI_API_KEY
#    See .env.example for what every variable does.

# 3. Store recovery copies of .env and encryption_key in an encrypted vault.

# 4. Bring the stack up (storage + API first, then the agents).
make up

# 5. Confirm it's actually healthy.
make verify
```

First boot takes a few minutes: agent-fs downloads a local embedding model before
it starts listening, and its health check has a deliberately long retry window.

Then connect a dashboard — `make dashboard` for the hosted UI, or run the UI
locally so your key never leaves your machine. Both options and their tradeoffs
are in [docs/OPERATIONS.md](docs/OPERATIONS.md#dashboard-browser-ui).

Git/GitHub credentials for the agents are **not** in `.env` — set them in the
swarm's own global config through the dashboard, which stores them encrypted.

## Day-to-day operation

Every Compose invocation must pass both env files and the fixed project name. The
Makefile does that for you; run `make` to list targets.

| Command | What it does |
|---|---|
| `make up` | Start storage + API, then recreate the agents |
| `make verify` | Read-only health, arch, and agent-fs provider checks |
| `make ps` / `make logs SERVICE=api` | Status / tail logs |
| `make pause` | Stop only the agents; storage + API stay up |
| `make stop` | Stop everything, keep containers and volumes |
| `make down` | Remove containers, **keep** volumes (never uses `-v`) |
| `make restart-agents` | Recreate just the agents — the fix for a crash-loop |
| `make agents` | List registered agents with role, harness, and status |
| `make set-model AGENT=<name> MODEL=<id>` | Change an agent's model live, no restart |
| `make backup` / `make restore BACKUP=…` | Consistent offline backup / destructive restore |
| `make pull` / `make pins` / `make arch` | Pull pinned images / show refs / show running arch |

Raw Compose, if you need it:

```bash
docker compose --env-file versions.env --env-file .env -p agent-swarm-local ps
```

> **Never run `docker compose down -v`.** It deletes the named volumes — all agent
> memory and identity. Plain `down` (no `-v`) is safe. Backups and restores use
> explicit, checksum-verified volume operations instead.

Details: [docs/OPERATIONS.md](docs/OPERATIONS.md) ·
[docs/AGENTS.md](docs/AGENTS.md) ·
[docs/BACKUP-RESTORE.md](docs/BACKUP-RESTORE.md) ·
[docs/UPGRADES.md](docs/UPGRADES.md)

## What you're trusting

Be clear-eyed about what this stack does before you run it:

- **The agents execute code and reach the network.** They run with a coding
  harness inside their containers and make outbound calls to LLM providers and
  Git hosts. `YOLO=false` is set, but the containment story here is the network
  boundary and the container, not a sandbox you should bet secrets on.
- **Loopback-only is the perimeter.** Published ports (3013, 7433,
  `MINIO_HOST_PORT`) bind `127.0.0.1`; MinIO's console (9001) and the agent
  containers publish nothing. There is no authentication story beyond the single
  `API_KEY`, so do not put this behind a tunnel or reverse proxy casually.
- **`API_KEY` is total control.** RBAC is off. Anything holding that key owns the
  swarm. `make dashboard-link` embeds it in a URL — convenient and secret.
- **The hosted dashboard and agent-fs viewer are third-party-served pages** that
  run with your key in *your* browser. That's a real trust decision; both have
  local alternatives documented in [docs/OPERATIONS.md](docs/OPERATIONS.md).
- **MinIO uses random root credentials** (never `minioadmin`), generated by
  `bootstrap.sh`.
- **`encryption_key` encrypts secrets at rest** in `swarm_api_data`. Back it up
  encrypted and off-device.
- **Give agents scoped credentials.** If you hand them a GitHub token, use a
  fine-grained PAT limited to an explicit repo allowlist with only contents and
  pull-requests read/write. Protect your default branches; let humans merge.

## Current pins

| Component | Reference |
|---|---|
| API | `ghcr.io/desplega-ai/agent-swarm:1.125.0` |
| Worker | `ghcr.io/desplega-ai/agent-swarm-worker:1.125.0` |
| agent-fs | `ghcr.io/desplega-ai/agent-fs:0.9.0` |
| MinIO | `minio/minio:RELEASE.2025-09-07T16-13-09Z` |
| MinIO client | `minio/mc:RELEASE.2025-08-13T08-35-41Z` |
| Backup helper | `alpine:3.20` |

Full `tag@sha256:<digest>` references are in `versions.env`; each index was
verified to include `linux/arm64` when it was pinned. `./scripts/check-updates.sh`
is read-only upgrade reconnaissance. To actually upgrade, follow
[docs/UPGRADES.md](docs/UPGRADES.md) — API and worker images always move together
to the identical version, and agent-fs follows the version the target release
declares.

## Troubleshooting

**An agent container is crash-looping (often after a host or Docker reboot).**
This is the one you'll hit. Worker containers must be *recreated*, not started —
on a reused `/workspace`, the upstream entrypoint takes its "prepend to existing
start-up.sh" branch and leaves that file root-owned and unreadable by the
`worker` user. Durable state lives in volumes, so recreating is lossless:

```bash
make restart-agents
```

**`make verify` reports `local-fs` instead of `agent-fs`.** The API fell back to
its built-in filesystem, so agent memory is not persisting to agent-fs. Check
`make logs SERVICE=agent-fs` — usually agent-fs is unhealthy or still pulling its
embedding model on first boot.

**agent-fs never becomes healthy.** First boot downloads an embedding model; give
it several minutes. If it persists, check that MinIO is healthy and that
`minio-init` exited 0 (`make verify` checks both).

**Compose errors about an empty or missing variable.** You almost certainly ran
`docker compose` without both env files, or with an `.env` predating a new
variable. Use the Makefile, and re-run `./scripts/bootstrap.sh` — it backfills
newly-added keys without touching existing identity.

**An agent has no identity / a duplicate agent appeared.** Agent IDs in `.env` map
1:1 to personal volumes and are permanent. Never regenerate them; a new UUID
orphans that agent's memory.

## Known limitations

- Worker restart requires recreate (upstream entrypoint behaviour) — see above.
- The dashboard is not part of this stack; run it on demand.
- `HEARTBEAT_CHECKLIST_DISABLE` is left unset deliberately. Upstream parses it as
  `Boolean(env)`, so *any* non-empty value — even `"false"` — disables the
  checklist.
- Agent concurrency is capped explicitly in `compose.yaml`, matching each
  agent's own template default: the lead (`tars`) runs up to 3 tasks; coder
  workers (`chase`, `rocky`, `igris`, `beru`) run 3 each; researcher
  workers (`einstein`, `socrates`) run 2 each. Do not use
  `docker compose up --scale`; every agent needs a unique stable `AGENT_ID` and
  its own volume.
- Only arm64 is verified — see [Platform support](#platform-support).

## Layout

```
compose.yaml        trimmed stack (fixed project + volume names, loopback ports)
versions.env        image tag+digest pins (arm64-verified)
Makefile            operator shortcuts (always passes both env files)
.env                secrets + permanent identity (git-ignored, mode 600)
.env.example        reference for every variable compose.yaml consumes
encryption_key      secrets-encryption key (git-ignored, mode 600, Compose secret)
scripts/            bootstrap · verify · backup · restore · check-updates · set-model
docs/               AGENTS · OPERATIONS · BACKUP-RESTORE · UPGRADES
backups/            local staging only (git-ignored)
```

## Getting help

Open an issue on this repository for problems with *this deployment config*. For
bugs in Agent Swarm or agent-fs themselves, use
[desplega-ai/agent-swarm](https://github.com/desplega-ai/agent-swarm) — this repo
ships no upstream source and cannot fix them. Security reports:
[SECURITY.md](SECURITY.md).

Contributions are welcome, but this repo has strict, non-obvious rules about
image pinning and arm64 verification. Read
[CONTRIBUTING.md](CONTRIBUTING.md) first.

## License

[MIT](LICENSE).
