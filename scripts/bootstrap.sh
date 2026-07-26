#!/usr/bin/env bash
# bootstrap.sh — generate local secrets and permanent identity for the
# agent-swarm-local deployment.
#
# Idempotent by design: it NEVER regenerates or overwrites an existing .env or
# encryption_key. Agent IDs and the encryption key are permanent identity —
# regenerating them orphans agent memory and makes stored secrets unrecoverable.
#
# Provider credentials (ANTHROPIC_API_KEY, OPENAI_API_KEY, GITHUB_WORKER_TOKEN,
# GITHUB_EMAIL, GITHUB_NAME) are read from the environment if pre-set, otherwise
# left blank for you to paste into .env afterwards.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

ENV_FILE="$REPO_DIR/.env"
KEY_FILE="$REPO_DIR/encryption_key"

need() { command -v "$1" >/dev/null 2>&1 || { echo "error: required tool '$1' not found in PATH" >&2; exit 1; }; }
need openssl
need uuidgen

# --- encryption_key (permanent; never overwrite) ----------------------------
if [[ -f "$KEY_FILE" ]]; then
  echo "encryption_key already exists — leaving it untouched."
else
  ( umask 177; openssl rand -base64 32 > "$KEY_FILE" )
  chmod 600 "$KEY_FILE"
  echo "generated encryption_key (mode 600)."
fi

# --- .env (permanent identity; never overwrite) ------------------------------
if [[ -f "$ENV_FILE" ]]; then
  echo ".env already exists — leaving it untouched (identity is permanent)."
  # Backfill secrets introduced after this .env was created. Idempotent: only
  # appends a key when it is entirely absent, never overwrites an existing one.
  if ! grep -q '^AGENT_FS_VIEWER_KEY=' "$ENV_FILE"; then
    printf 'AGENT_FS_VIEWER_KEY=af_%s\n' "$(openssl rand -hex 32)" >> "$ENV_FILE"
    echo "  backfilled AGENT_FS_VIEWER_KEY (agent-fs live-viewer access)."
  fi
  grep -q '^AGENT_FS_VIEWER_EMAIL=' "$ENV_FILE" || echo 'AGENT_FS_VIEWER_EMAIL=viewer@local' >> "$ENV_FILE"
  echo "Edit .env directly to set or update provider credentials."
  exit 0
fi

api_key="$(openssl rand -hex 32)"
minio_user="swarmadmin_$(openssl rand -hex 4)"
minio_pass="$(openssl rand -base64 36 | tr -d '/+=' | cut -c1-40)"
lead_id="$(uuidgen)"
claude_id="$(uuidgen)"
codex_id="$(uuidgen)"
viewer_key="af_$(openssl rand -hex 32)"

( umask 177; cat > "$ENV_FILE" <<EOF
API_KEY=${api_key}
MINIO_ROOT_USER=${minio_user}
MINIO_ROOT_PASSWORD=${minio_pass}
MINIO_HOST_PORT=${MINIO_HOST_PORT:-9002}
LEAD_AGENT_ID=${lead_id}
CLAUDE_WORKER_AGENT_ID=${claude_id}
CODEX_WORKER_AGENT_ID=${codex_id}
AGENT_FS_VIEWER_KEY=${viewer_key}
AGENT_FS_VIEWER_EMAIL=viewer@local
ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}
OPENAI_API_KEY=${OPENAI_API_KEY:-}
GITHUB_WORKER_TOKEN=${GITHUB_WORKER_TOKEN:-}
GITHUB_EMAIL=${GITHUB_EMAIL:-}
GITHUB_NAME=${GITHUB_NAME:-}
EOF
)
chmod 600 "$ENV_FILE"
echo "generated .env (mode 600)."

missing=0
for v in ANTHROPIC_API_KEY OPENAI_API_KEY GITHUB_WORKER_TOKEN GITHUB_EMAIL GITHUB_NAME; do
  if ! grep -q "^${v}=." "$ENV_FILE"; then
    echo "  TODO: set ${v} in .env before starting agents (Phase 3)."
    missing=1
  fi
done
[[ $missing -eq 0 ]] && echo "all provider credentials populated."

echo
echo "Next: store recovery copies of .env and encryption_key in an encrypted"
echo "vault, then run scripts/verify.sh after 'docker compose up'."
