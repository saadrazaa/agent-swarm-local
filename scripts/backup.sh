#!/usr/bin/env bash
# backup.sh — consistent offline backup of the agent-swarm-local deployment.
#
# Both SQLite databases (API + agent-fs) run in WAL mode, so copying live files
# is unsafe. This script stops services in dependency order, archives the named
# volumes read-only with a pinned helper image, records a manifest + checksums,
# then restarts and verifies. A backup that has not been restored is not
# trusted — see scripts/restore.sh and docs/BACKUP-RESTORE.md.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

# shellcheck source=/dev/null
source "$REPO_DIR/versions.env"

PROJECT="agent-swarm-local"
DC=(docker compose --env-file versions.env --env-file .env -p "$PROJECT")
LOCK="$REPO_DIR/.op.lock"

# Volumes that make up the critical + full restore set.
VOLUMES=(
  swarm_api_data
  agent_fs_data
  agent_fs_minio
  swarm_shared
  swarm_lead
  swarm_worker_claude
  swarm_worker_codex
  swarm_codex_home
)

log() { echo "[backup] $*"; }
die() { echo "[backup] ERROR: $*" >&2; exit 1; }

[[ -f "$REPO_DIR/.env" ]] || die ".env not found — run scripts/bootstrap.sh first."
[[ -f "$REPO_DIR/encryption_key" ]] || die "encryption_key not found."

# 1-2. Single-flight lock; refuse if a backup/restore is already running.
if ! ( set -o noclobber; : > "$LOCK" ) 2>/dev/null; then
  die "another backup/restore holds $LOCK — refusing to run concurrently."
fi
trap 'rm -f "$LOCK"' EXIT

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
DEST="${1:-$REPO_DIR/backups/$STAMP}"
mkdir -p "$DEST"
[[ -d "$DEST" && -w "$DEST" ]] || die "destination not writable: $DEST"
log "destination: $DEST"

restart_stack() {
  log "restarting stack in dependency order"
  "${DC[@]}" up -d minio
  "${DC[@]}" up -d minio-init
  "${DC[@]}" up -d agent-fs
  "${DC[@]}" up -d api
  # Agents MUST be recreated, not merely started: /workspace is container-local
  # and the upstream entrypoint's "prepend to existing start-up.sh" branch leaves
  # that file root-owned/unreadable on a reused filesystem, crash-looping the
  # worker. A fresh container takes the working "create new" path (mode 755).
  "${DC[@]}" up -d --force-recreate lead worker-claude worker-codex
}
# Best-effort restart even if a later step fails, so we never leave the stack down.
trap 'rm -f "$LOCK"; restart_stack || true' EXIT

# 3. Pause agents first (API stays up briefly to record the pause), then 4. stop
# API -> agent-fs -> minio so both databases flush cleanly.
log "stopping lead + workers"
"${DC[@]}" stop lead worker-claude worker-codex
log "stopping api"
"${DC[@]}" stop api
log "stopping agent-fs"
"${DC[@]}" stop agent-fs
log "stopping minio"
"${DC[@]}" stop minio minio-init

# 5. Archive each named volume read-only with the pinned helper image.
for vol in "${VOLUMES[@]}"; do
  if docker volume inspect "$vol" >/dev/null 2>&1; then
    log "archiving volume $vol"
    docker run --rm \
      -v "$vol":/src:ro \
      -v "$DEST":/backup \
      "$HELPER_IMAGE" \
      tar czf "/backup/${vol}.tar.gz" -C /src . \
      || die "failed to archive $vol"
  else
    log "WARNING: volume $vol does not exist yet — skipping"
  fi
done

# 6-7. Copy config + version pins. .env and encryption_key are sensitive: they
# are copied here for convenience but MUST be moved to an encrypted, off-Docker
# destination and removed from any plaintext staging afterwards.
cp compose.yaml versions.env "$DEST/"
cp .env "$DEST/env.SENSITIVE"
cp encryption_key "$DEST/encryption_key.SENSITIVE"
chmod 600 "$DEST/env.SENSITIVE" "$DEST/encryption_key.SENSITIVE"

# 8. Manifest.
GIT_COMMIT="$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || echo 'uncommitted')"
ARCH="$(docker info --format '{{.Architecture}}' 2>/dev/null || echo 'unknown')"
{
  echo "backup_utc=$STAMP"
  echo "deployment_git_commit=$GIT_COMMIT"
  echo "docker_architecture=$ARCH"
  echo "project=$PROJECT"
  echo "volumes=${VOLUMES[*]}"
  echo "AGENT_SWARM_IMAGE=$AGENT_SWARM_IMAGE"
  echo "AGENT_SWARM_WORKER_IMAGE=$AGENT_SWARM_WORKER_IMAGE"
  echo "AGENT_FS_IMAGE=$AGENT_FS_IMAGE"
  echo "MINIO_IMAGE=$MINIO_IMAGE"
  echo "MINIO_MC_IMAGE=$MINIO_MC_IMAGE"
} > "$DEST/MANIFEST.txt"

# 9. Checksums + verify every archive is listable.
( cd "$DEST" && shasum -a 256 ./*.tar.gz > SHA256SUMS )
for vol in "${VOLUMES[@]}"; do
  [[ -f "$DEST/${vol}.tar.gz" ]] || continue
  tar tzf "$DEST/${vol}.tar.gz" >/dev/null || die "archive not listable: ${vol}.tar.gz"
done
log "checksums written and archives verified listable"

# 10. Restart handled by the EXIT trap. 11. Verify once back up.
trap 'rm -f "$LOCK"' EXIT
restart_stack
log "running verify.sh"
bash "$REPO_DIR/scripts/verify.sh" || log "WARNING: verify.sh reported problems — inspect before trusting this backup"

log "DONE. Move $DEST/*.SENSITIVE to an encrypted off-device store, then delete the plaintext copies here."
