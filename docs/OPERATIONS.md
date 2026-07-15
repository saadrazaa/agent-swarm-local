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
dc stop                 # stop all
dc start                # start all
dc stop lead worker-claude worker-codex   # pause only agents
```

Do **not** use `dc down -v` — that deletes named volumes (all memory + identity).
Plain `dc down` (no `-v`) removes containers but keeps volumes; bring-up recreates
them.

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

## Dashboard (on-demand, not a service)

The UI is intentionally not an always-running container. Run it locally only when
needed, pinned, pointed at `http://127.0.0.1:3013` with the operator `API_KEY`
(treat that browser-local key as a secret). Document the exact pinned command here
once chosen.

## Health / verification

`./scripts/verify.sh` (read-only) checks infra health, image arch = arm64,
`minio-init` exit 0, and that `/api/fs/capabilities` reports `agent-fs` (not
`local-fs`). It exits non-zero on any failure and is invoked by backup/restore.
