# packages/

Package / CLI requirements that **every agent** must have. There is no "package"
primitive in the swarm — this is delivered through the swarm's **global setup
script**, which every worker runs **as root on boot**.

`global-setup.sh` is the single source of truth. `swarm-sync` (the
`swarm-config-init` service on `make up`, or `make packages-sync`) pushes its
contents into the swarm's `globalSetupScript` config; each worker then runs it on
its next boot.

## Adding a requirement

Edit [`global-setup.sh`](global-setup.sh). It must stay **idempotent** — it re-runs
on every worker boot, so it has to be a fast no-op when everything is already
installed, and hit the network only when something is missing:

- System package → add to the `apt_ensure …` line.
- Global npm tool → `command -v <bin> >/dev/null || npm i -g <pkg>`.
- Python tool → `command -v <bin> >/dev/null || pip install --break-system-packages <pkg>`.
- Downloaded binary → guard on the target path, then `curl -fsSL … -o … && chmod +x …`.

Already in the base image (don't re-install): node, npm, bun, python3, pip, git,
gh, glab, jq, curl, make, gcc, claude, codex, pm2.

## Rules

- **No secrets** — this file is committed.
- Root-level installs only here; the script runs as root before the agent starts.
- A failed step **warns but does not brick boot** (`STARTUP_SCRIPT_STRICT=false`).
  Flip that env to `true` once the script is trusted if you want fail-fast.

## Apply changes

```bash
make packages-sync
make restart-agents
```
