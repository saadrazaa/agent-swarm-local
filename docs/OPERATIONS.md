# Operations

All commands run from the repo root and pass both env files. Define once:

```bash
alias dc='docker compose --env-file versions.env --env-file .env -p agent-swarm-local'
```

## Bring-up (dependency order)

Storage + API first, then agents:

```bash
dc up -d minio minio-init agent-fs api
./scripts/verify.sh          # confirms health + agent-fs provider
dc up -d lead worker-claude worker-codex
```

`agent-fs` can take a few minutes on first boot while it downloads the local
embedding model — its health check has a long retry window; this is expected.

## Status and logs

```bash
dc ps
dc logs -f api
dc logs -f agent-fs
dc logs --since 10m worker-codex
docker stats            # watch memory; this VM is ~7.8 GiB and shared
```

## Stop / start (never destroys data)

```bash
dc stop                                    # stop all (safe; keeps volumes)
dc stop lead worker-claude worker-codex    # pause only agents
```

**Restarting agents — always recreate, never plain `start`.** Worker containers
are stateless; their durable state lives in the `swarm_worker_*`, `swarm_shared`,
`swarm_logs`, and `swarm_codex_home` volumes. Their `/workspace` is container-local.
A reused `/workspace` (from `dc start` / `docker restart` / a host reboot) makes the
upstream entrypoint take its "prepend to existing start-up.sh" branch, which leaves
that file root-owned and unreadable by the `worker` user — the container then
crash-loops on the startup script. Bringing a **fresh** container up avoids it:

```bash
# Correct way to (re)start agents:
dc up -d --force-recreate lead worker-claude worker-codex
```

Storage/API (`minio`, `agent-fs`, `api`) restart fine with plain `dc start`.

**After a host / Docker Desktop reboot:** the workers auto-start with their old
filesystem and will crash-loop. Recover with the `--force-recreate` command above
(identity and memory are preserved — they live in the volumes). This is a known
upstream-entrypoint limitation; see README.

Do **not** use `dc down -v` — that deletes named volumes (all memory + identity).
Plain `dc down` (no `-v`) removes containers but keeps volumes; the next `up`
recreates them cleanly (also a valid restart).

## Concurrency model

- Two worker services exist; that is the structural ceiling. `MAX_CONCURRENT_TASKS=1`
  on each worker caps aggregate worker concurrency at two. The lead is also capped
  at one and coordinates rather than counting as an execution worker.
- Do not use `docker compose up --scale` — every agent needs a unique stable
  `AGENT_ID` and its own personal volume.
- Assign a task to a specific harness by that agent's stable UUID (Claude vs Codex);
  otherwise the first free eligible worker claims it. The queue provides backpressure
  once both workers are busy.
- To add throughput later: add one explicitly-named worker service with a **new**
  stable UUID and a new personal volume, then re-check memory under real builds.
  For memory-heavy/browser tasks, stop one worker rather than letting Docker thrash.

## Identity is permanent

`AGENT_ID`s (in `.env`) map 1:1 to personal volumes and must never be regenerated.
`bootstrap.sh` refuses to overwrite an existing `.env`/`encryption_key` for exactly
this reason. Changing `TEMPLATE_ID` is not an upgrade mechanism.

## GitHub for workers

- One fine-grained PAT (`GITHUB_WORKER_TOKEN`), restricted to an explicit repo
  allowlist, contents + pull-requests read/write (issues r/w optional). No admin/
  org/packages/environments/secrets/workflow scopes.
- Passed only to `worker-claude` and `worker-codex`. Agents create branches + PRs;
  humans merge. Protect default branches.
- Validate against a disposable repo first: `gh auth status`, read, branch push, PR
  create from each worker. Confirm the token never appears in logs.
- Inbound GitHub App events are a later, optional phase (needs a GitHub App, webhook
  secret, `GITHUB_DISABLE=false`, and a restricted public HTTPS route to
  `/api/github/webhook` — never expose 3013 directly).

## Dashboard (browser UI — not part of this stack)

The dashboard is a single-page app (`apps/ui` in the upstream repo) that runs in
your browser and calls the API **directly**. There is no dashboard container. It
fully manages the swarm: create tasks, configure integrations, chat, memory, MCP
servers, schedules, workflows, API keys, budgets. The API's CORS echoes any origin
with credentials, so either option below reaches `http://127.0.0.1:3013`.

**Option A — hosted UI (zero setup):** `make dashboard` opens
`https://app.agent-swarm.dev`. In the gear/Settings menu add a connection: API URL
`http://127.0.0.1:3013`, API Key = `API_KEY` from `.env`. Or `make dashboard-link`
prints a one-click `?apiUrl=&apiKey=` URL (that URL embeds your key — treat as
secret; the app strips the params after loading).

> Security note: the hosted page is served by desplega, so its JS runs with your
> operator key in the browser. The key grants full control (RBAC is off). If you'd
> rather not hand your key to a third-party-served page, use Option B.

**Option B — run the UI locally (key never leaves your machine):** requires
[bun](https://bun.sh) and a checkout of the upstream repo at the pinned tag:

```bash
git clone --depth 1 --branch v1.119.1 https://github.com/desplega-ai/agent-swarm /tmp/as-ui
cd /tmp/as-ui && bun install && cd apps/ui && bun run dev   # serves http://localhost:5274
# if the `portless` wrapper misbehaves: bunx vite --port 5274 --host 127.0.0.1
```

Then open `http://localhost:5274` and set the same connection. If you standardize
on the local UI, set `APP_URL=http://127.0.0.1:5274` in `.env` (default is the
hosted URL) so API-generated links (e.g. HITL approval requests) point there, and
`make restart-agents` / recreate the API to apply.

The key is an operator secret either way — it is not stored in Git or the stack.

## Health / verification

`./scripts/verify.sh` (read-only) checks infra health, image arch = arm64,
`minio-init` exit 0, and that `/api/fs/capabilities` reports `agent-fs` (not
`local-fs`). It exits non-zero on any failure and is invoked by backup/restore.
