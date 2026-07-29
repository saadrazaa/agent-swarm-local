## What and why

<!-- What changes, and why it's needed. Link any upstream release notes. -->

## Checklist

Delete sections that don't apply, but don't delete a box just because it failed —
say so instead. Rules and commands: [CONTRIBUTING.md](../CONTRIBUTING.md).

### Always

- [ ] `python3 -c 'import yaml;yaml.safe_load(open("compose.yaml"))'` passes
- [ ] `shellcheck scripts/*.sh` is clean (if scripts changed)
- [ ] No `.env`, `encryption_key`, `backups/`, secret value, or real deployment
      UUID committed — placeholders only
- [ ] Minimal diff; no drive-by reformatting

### If any image pin changed

- [ ] Every `*_IMAGE` line is `name:tag@sha256:<digest>` — no `latest`, no bare tag
- [ ] Count of `@sha256:` lines == count of `*_IMAGE=` lines
- [ ] `AGENT_SWARM_IMAGE` and `AGENT_SWARM_WORKER_IMAGE` are the **same** version
- [ ] agent-fs matches the version the target agent-swarm release declares (not
      bumped independently)
- [ ] Each new/changed digest is a multi-arch **index** including `linux/arm64`,
      with registry-API evidence pasted below
- [ ] Trimmed-compose deltas in `docs/UPGRADES.md` all still present
- [ ] Any newly-**required** upstream env var added to both `.env.example` and
      `compose.yaml`, and called out in this PR body
- [ ] `README.md` version line and the `docs/UPGRADES.md` deltas list updated

#### arm64 evidence

<!--
Paste the registry manifest output per changed image. Must show an index
mediaType and a linux/arm64 entry. See CONTRIBUTING.md for the exact command.
-->

```
```

### If bring-up behaviour changed

- [ ] `make up && make verify` run on a real host — paste the `verify` output
- [ ] Upgrade steps in `docs/UPGRADES.md` still accurate

## Operator notes

<!--
Anything the operator must do by hand on the host: pre-upgrade backup, migration
watch, .env backfill (`./scripts/bootstrap.sh`), restart ordering. Restarts are an
operator action on the host — not something an agent in this stack should run.
-->
