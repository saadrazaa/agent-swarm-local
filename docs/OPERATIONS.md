# Operations

`make` is the supported interface — it always passes both env files and the fixed
project name. Run `make` (or `make help`) to list every target. This document
explains what those targets do and when the raw Compose commands matter.

If you prefer raw Compose, define the full invocation once:

```bash
alias dc='docker compose --env-file versions.env --env-file .env -p agent-swarm-local'
```

Omitting either `--env-file` leaves image pins or identity variables unset, which
fails in confusing ways. The services are `minio`, `minio-init`, `agent-fs`,
`agent-fs-viewer-init`, `api`, and the four agents `tars`, `chase`, `rocky`,
`einstein`.

## Bring-up

```bash
make up        # storage + API, then recreates the agents and the viewer one-shot
make verify    # health + agent-fs provider checks
```

Equivalent by hand — storage and API first, agents second:

```bash
dc up -d minio minio-init agent-fs api
./scripts/verify.sh                                 # health + agent-fs provider
dc up -d --force-recreate tars chase rocky einstein
```

`agent-fs` can take a few minutes on first boot while it downloads the local
embedding model — its health check has a long retry window; this is expected.
Compose blocks on the `service_healthy` dependencies, so ordering is automatic.

## Status and logs

```bash
make ps
make logs SERVICE=api
make logs SERVICE=agent-fs
dc logs --since 10m rocky
docker stats            # watch memory if the Docker VM is shared with other stacks
```

## Stop / start (never destroys data)

```bash
make stop      # stop everything; containers and volumes kept
make pause     # stop only the agents; storage + API stay up
make down      # remove containers, KEEP volumes (never passes -v)
```

**Restarting agents — always recreate, never plain `start`.** Agent containers are
stateless; their durable state lives in the `swarm_tars`, `swarm_chase`,
`swarm_rocky`, `swarm_rocky_codex`, `swarm_einstein`, `swarm_shared`, and
`swarm_logs` volumes. Their `/workspace` is container-local. A reused `/workspace`
(from `dc start`, `docker restart`, or a host reboot) makes the upstream
entrypoint take its "prepend to existing start-up.sh" branch, which leaves that
file root-owned and unreadable by the `worker` user — the container then
crash-loops on the startup script. Bringing a **fresh** container up avoids it:

```bash
make restart-agents        # dc up -d --force-recreate tars chase rocky einstein
```

Storage and API (`minio`, `agent-fs`, `api`) restart fine with plain `dc start`.

**After a host or Docker restart:** the agents auto-start with their old
filesystem and will crash-loop. Recover with `make restart-agents` — identity and
memory are preserved, they live in the volumes. This is a known upstream
entrypoint limitation.

Do **not** use `dc down -v` — that deletes named volumes (all memory and
identity). Plain `make down` removes containers but keeps volumes; the next
`make up` recreates them cleanly, which is also a valid way to restart.

## Concurrency model

- Concurrency is capped explicitly per agent in `compose.yaml`, because the
  `official/coder` template advertises `maxTasks: 3` and would otherwise apply:
  the lead `tars` runs up to **3** tasks; `chase`, `rocky`, and `einstein` run
  **1** each. That puts aggregate worker concurrency at **3**.
- Do not use `docker compose up --scale` — every agent needs a unique stable
  `AGENT_ID` and its own personal volume.
- Assign a task to a specific harness by that agent's stable UUID (Claude vs
  Codex); otherwise the first free eligible worker claims it. The queue provides
  backpressure once every worker is busy.
- To add throughput: add one explicitly-named agent service with a **new** stable
  UUID and a new personal volume, add both to `AGENTS` in the Makefile and to the
  volume lists in `scripts/backup.sh` and `scripts/restore.sh`, then re-check
  memory under real builds. For memory-heavy or browser tasks, stop one worker
  rather than letting Docker thrash.

## Identity is permanent

The `AGENT_ID`s in `.env` map 1:1 to personal volumes and must never be
regenerated — a new UUID orphans that agent's memory and identity. `bootstrap.sh`
refuses to overwrite an existing `.env` or `encryption_key` for exactly this
reason; it only ever *appends* variables added in later revisions. Changing
`TEMPLATE_ID` is not an upgrade mechanism.

## Git and provider credentials

`compose.yaml` passes **no** Git or GitHub variables to any service. Provider LLM
keys come from `.env`; everything else an agent needs — Git identity, GitHub
tokens, other integration credentials — is configured in the swarm's own global
config through the dashboard and stored encrypted in `swarm_api_data`.

When you give agents a GitHub token, use a fine-grained PAT restricted to an
explicit repo allowlist with contents plus pull-requests read/write (issues
optional). No admin, org, packages, environments, secrets, or workflow scopes.
Validate against a disposable repo first — `gh auth status`, a read, a branch
push, a PR create — and confirm the token never appears in logs. Agents create
branches and PRs; humans merge. Protect your default branches.

`GITHUB_DISABLE=true` on the API disables **inbound** webhooks only; an agent's
own token still clones, branches, pushes, and opens PRs. Inbound GitHub App
events are an optional later phase: they need a GitHub App, a webhook secret,
`GITHUB_DISABLE=false`, and a restricted public HTTPS route to
`/api/github/webhook` — never expose port 3013 directly.

## Dashboard (browser UI)

The dashboard is a single-page app (`apps/ui` in the upstream repo) that runs in
your browser and calls the API **directly**. There is no dashboard container. It
fully manages the swarm: create tasks, configure integrations, chat, memory, MCP
servers, schedules, workflows, API keys, budgets. The API's CORS echoes any origin
with credentials, so either option below reaches `http://127.0.0.1:3013`.

**Option A — hosted UI (zero setup):** `make dashboard` opens
`https://app.agent-swarm.dev`. In the gear/Settings menu add a connection: API URL
`http://127.0.0.1:3013`, API Key = `API_KEY` from `.env`. Or `make dashboard-link`
prints a one-click `?apiUrl=&apiKey=` URL (that URL embeds your key — treat it as
secret; the app strips the params after loading).

> Security note: the hosted page is served by desplega, so its JS runs with your
> operator key in the browser. The key grants full control (RBAC is off). If you'd
> rather not hand your key to a third-party-served page, use Option B.

**Option B — run the UI locally (key never leaves your machine):** requires
[bun](https://bun.sh) and a checkout of the upstream repo at the tag this stack is
pinned to (currently `v1.121.1` — keep it in step with `versions.env`):

```bash
git clone --depth 1 --branch v1.121.1 https://github.com/desplega-ai/agent-swarm /tmp/as-ui
cd /tmp/as-ui && bun install && cd apps/ui && bun run dev   # serves http://localhost:5274
# if the `portless` wrapper misbehaves: bunx vite --port 5274 --host 127.0.0.1
```

Then open `http://localhost:5274` and set the same connection. If you standardize
on the local UI, set `APP_URL=http://127.0.0.1:5274` in `.env` (unset defaults to
the hosted URL) so API-generated links such as HITL approval requests point there,
then recreate the API and run `make restart-agents` to apply.

The key is an operator secret either way — it is not stored in Git or the stack.

## Browsing agent-fs memory (live viewer)

`https://live.agent-fs.dev` is a stateless browser UI for inspecting an agent-fs
deployment. **Connect existing key** → Endpoint URL `http://127.0.0.1:7433`, API
Key = `AGENT_FS_VIEWER_KEY` from `.env`. `make agent-fs-viewer` prints both.

Why a dedicated key: agent-fs is multi-tenant, and every service (the API, each
agent) auto-registers a private identity whose key is generated server-side and
kept encrypted in the API — none of them is usable for browsing. So the stack
provisions a separate human **viewer** identity. `AGENT_FS_VIEWER_KEY` is a
permanent secret (bootstrap-generated, vault it like `API_KEY`), and the
`agent-fs-viewer-init` service (`scripts/agent-fs-viewer-init.mjs`) seeds it into
agent-fs and grants it access to every org/drive on each `up`. It only writes
`org_members`/`drive_members` rows — agent-fs exposes no invite API reachable
without an org-admin key — and nothing depends on it, so a failure never blocks
the swarm.

- **New agent orgs** (agents get a personal org the first time they use memory)
  are picked up on the next `make up`, or immediately via `make agent-fs-viewer`.
- **On upgrade:** if a new agent-fs version changes the identity schema, only
  `scripts/agent-fs-viewer-init.mjs` needs updating; the swarm is unaffected.
- Same third-party-trust caveat as the dashboard: the viewer's JS is
  desplega-served and runs with your viewer key in the browser.

## Health / verification

`make verify` (`./scripts/verify.sh`, read-only) checks infra health, that every
running image is arm64, that `minio-init` exited 0, and that
`/api/fs/capabilities` reports `agent-fs` rather than the built-in `local-fs`. It
exits non-zero on any failure and is invoked by `backup.sh` and `restore.sh`.

A `local-fs` result is the important one: it means agent memory is not persisting
to agent-fs. Check `make logs SERVICE=agent-fs`.

## Changing an agent's model

```bash
make set-model AGENT=<name|id> MODEL=<model-id>
```

Applies live through the API — no restart, no identity change.
