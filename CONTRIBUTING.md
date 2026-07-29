# Contributing

Thanks for looking. This is a small, opinionated ops repo: Compose config, image
pins, scripts, docs. It ships **no upstream source**, so most feature requests and
bugs belong to [desplega-ai/agent-swarm](https://github.com/desplega-ai/agent-swarm)
rather than here. Good contributions here look like: a pin bump done correctly, a
doc that was wrong and now isn't, a script fix, a portability fix.

## The rules that actually matter

These are non-negotiable and mechanically checkable. A PR that breaks any of them
will be asked to change.

### 1. Every image is pinned by tag *and* digest

Every `*_IMAGE` line in `versions.env` must be `name:tag@sha256:<digest>`.

- Never `latest`. Never a bare tag. Never remove an existing digest.
- The count of `@sha256:` occurrences must equal the count of `*_IMAGE=` lines.

```bash
# Both numbers must match, and the grep must find nothing.
grep -cE '^[A-Z_]+_IMAGE=' versions.env
grep -c '@sha256:' versions.env
grep -n 'latest' versions.env
```

### 2. Every new or changed digest must be a multi-arch index that includes `linux/arm64`

This stack is developed on Apple Silicon and `scripts/verify.sh` fails if a running
image is not arm64. Pin the **index** digest (not a per-platform manifest digest),
confirm arm64 is in it, and **paste the evidence into the PR body**.

Verification is a registry API call — no Docker daemon needed. For ghcr.io:

```bash
TOKEN=$(curl -s "https://ghcr.io/token?scope=repository:desplega-ai/agent-swarm:pull&service=ghcr.io" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')

curl -s -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json" \
  "https://ghcr.io/v2/desplega-ai/agent-swarm/manifests/<TAG>" \
  | python3 -c 'import sys,json;m=json.load(sys.stdin);print("mediaType:",m.get("mediaType"));[print(" ",x["platform"].get("os")+"/"+x["platform"].get("architecture"),x["digest"]) for x in m.get("manifests",[])]'
```

A good result is an index `mediaType` with a `linux/arm64` entry listed. Use the
`Docker-Content-Digest` response header (or `docker buildx imagetools inspect`) for
the index digest itself. Docker Hub images (MinIO, Alpine) use the same flow
against `auth.docker.io` / `registry-1.docker.io`.

We deliberately do **not** automate this — human-pasted evidence is the policy.

### 3. API and worker images bump together

`AGENT_SWARM_IMAGE` and `AGENT_SWARM_WORKER_IMAGE` must always be the **exact same
version**. Never bump one alone.

### 4. agent-fs follows the release, never independently

Use the agent-fs version the target Agent Swarm release declares as its
compatibility baseline. Do not bump agent-fs on its own without a separate
compatibility test. See [docs/UPGRADES.md](docs/UPGRADES.md).

### 5. Preserve the trimmed-compose deltas

`compose.yaml` intentionally diverges from upstream's example in specific ways —
API volume scoped to `/app/data`, `MINIO_HOST_PORT` default 9002, loopback-only
published ports, no `platform`/`pull_policy`, explicit `MAX_CONCURRENT_TASKS`,
`YOLO=false`, inbound Slack/GitHub/Linear/Jira disabled, explicit `CAPABILITIES`.
The full list is in [docs/UPGRADES.md](docs/UPGRADES.md#review-before-upgrading).

Do not silently revert them by copying upstream's example forward. If an upstream
release adds a newly-**required** env var, add it to both `.env.example` and
`compose.yaml` and call it out in the PR body.

With any pin change, also update the version line in `README.md` and the deltas
list in `docs/UPGRADES.md`.

### 6. Never commit secrets

Never commit `.env`, `./encryption_key`, `backups/`, or any secret value. Do not
put real UUIDs, API keys, or agent IDs from a live deployment into docs, comments,
or PR bodies — use placeholders. `.gitignore` covers the files the scripts create;
keep it that way.

## Before you open a PR

```bash
# compose.yaml still parses (no Docker daemon required)
python3 -c 'import yaml;yaml.safe_load(open("compose.yaml"))'

# with a real .env on a host with Docker, the stronger check:
docker compose --env-file versions.env --env-file .env config -q

# scripts stay shellcheck-clean
shellcheck scripts/*.sh
```

If you changed anything about bring-up, run `make up && make verify` on a real
host and say so in the PR.

There is no CI yet, so these are on you. Don't use `--no-verify`.

## Conventions

- **Minimal diffs.** Change what the PR is about; skip drive-by reformatting.
- **Explain *why* in the commit message,** not just what.
- If you add an agent service, it needs a **new** stable UUID and its own volume,
  added to `AGENTS` in the `Makefile` and to the volume lists in
  `scripts/backup.sh` **and** `scripts/restore.sh`.
- Never force-push to `master`. The default branch is `master`, not `main`.
- Maintainers merge; PRs are not self-merged.

## A word of warning

This repo deploys a swarm of agents that execute code. If you are running the
stack while changing it, remember that an upgrade or restart tears down the very
containers doing the work. Host-side restarts are an operator action, run from the
host — never from inside a container in this stack.
