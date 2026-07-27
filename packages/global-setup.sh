#!/usr/bin/env bash
# global-setup.sh — the swarm's global setup script (single source of truth).
#
# swarm-sync pushes this file's contents into the swarm's `globalSetupScript`
# config. Every worker runs it AS ROOT on boot, before the agent starts, so this
# is where system packages / CLIs that all agents need get installed.
#
# CONTRACT: idempotent and fast. It re-runs on every worker boot, so it must be a
# near-instant no-op once everything is present, and must only touch the network
# when something is actually missing. No secrets here — this file is committed.
#
# The base worker image (Ubuntu 24.04) already ships: node, npm, bun, python3,
# pip, git, gh, glab, jq, curl, make, gcc, plus claude/codex/pm2. Declare only the
# gaps below.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

log() { echo "[global-setup] $*"; }

# Install any missing apt packages in one batch (no-op + no apt-get update when
# all are already present).
apt_ensure() {
  local missing=()
  for pkg in "$@"; do
    dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
  done
  if ((${#missing[@]})); then
    log "apt install: ${missing[*]}"
    apt-get update -qq
    apt-get install -y --no-install-recommends "${missing[@]}"
  fi
}

# ── System packages every agent needs ────────────────────────────────────────
# Common CLI gaps in the base image. Extend this list as needs emerge.
apt_ensure ripgrep fd-find

# ── binance-cli (prerequisite for the binance-trading skill) ─────────────────
# The official Binance CLI, an npm global package (needs Node ≥18 — present in the
# base image). Installed to /usr/local/bin, which is on the worker user's PATH.
# Runtime auth (the read-only Ed25519 profile / BINANCE_* env + PEM) is deployment
# config, not installed here — see the binance-trading skill's references/setup-auth.md.
if ! command -v binance-cli >/dev/null 2>&1; then
  log "installing @binance/binance-cli (npm -g)"
  npm install -g @binance/binance-cli
fi

log "done"
