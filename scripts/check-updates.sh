#!/usr/bin/env bash
# check-updates.sh — READ-ONLY upgrade reconnaissance. Reports current pins,
# available upstream releases, and the paths to diff before an upgrade. It never
# edits versions.env, never pulls for deploy, and never touches running state.
# Follow docs/UPGRADES.md to actually perform an upgrade.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"
# shellcheck source=/dev/null
source "$REPO_DIR/versions.env"

REPO="desplega-ai/agent-swarm"

echo "=== Current pins (versions.env) ==="
grep -E '^(AGENT_SWARM|AGENT_FS|MINIO)' versions.env

CURRENT_TAG="$(sed -n 's#.*agent-swarm:\([0-9.]*\)@.*#\1#p' <<<"$AGENT_SWARM_IMAGE")"
echo
echo "Current Agent Swarm version: ${CURRENT_TAG:-unknown}"

echo
echo "=== Latest upstream releases ==="
if command -v gh >/dev/null 2>&1; then
  gh release list --repo "$REPO" --limit 10 2>&1 || echo "gh failed (auth?) — check https://github.com/$REPO/releases"
else
  echo "gh not installed — check https://github.com/$REPO/releases manually"
fi

echo
echo "=== ARM64 availability of currently pinned images ==="
for ref in "$AGENT_SWARM_IMAGE" "$AGENT_SWARM_WORKER_IMAGE" "$AGENT_FS_IMAGE" "$MINIO_IMAGE" "$MINIO_MC_IMAGE"; do
  name="${ref%@*}"
  if docker manifest inspect "$ref" 2>/dev/null | grep -q '"architecture": "arm64"'; then
    echo "  OK arm64: $name"
  else
    echo "  MISSING arm64 (or unreachable): $name"
  fi
done

echo
echo "=== Before upgrading, diff these upstream paths between the current and target tags ==="
cat <<'PATHS'
  docker-compose.example.yml
  .env.docker.example
  DEPLOYMENT.md
  Dockerfile
  Dockerfile.worker
  docker-entrypoint.sh
  src/be/migrations/
  docs-site/.../guides/deployment.mdx
  docs-site/.../guides/agent-fs-co-deployment.mdx
PATHS
echo
echo "Upgrade + rollback runbook: docs/UPGRADES.md. This script changed nothing."
