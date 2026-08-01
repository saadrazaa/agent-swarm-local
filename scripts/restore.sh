#!/usr/bin/env bash
# restore.sh — restore the agent-swarm-local deployment from a backup produced
# by scripts/backup.sh. DESTRUCTIVE: it clears and replaces the named volumes.
#
# Usage:
#   scripts/restore.sh <backup-dir> --yes-destroy-current-state
#
# Never run `docker compose down -v` anywhere in normal ops — this script clears
# volumes explicitly and only as one consistent, checksum-verified set.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

PROJECT="agent-swarm-local"
LOCK="$REPO_DIR/.op.lock"
CONFIRM_FLAG="--yes-destroy-current-state"

VOLUMES=(
  swarm_api_data
  agent_fs_data
  agent_fs_minio
  swarm_shared
  swarm_tars
  swarm_chase
  swarm_rocky
  swarm_rocky_codex
  swarm_einstein
  swarm_igris
  swarm_beru
  swarm_socrates
)

log() { echo "[restore] $*"; }
die() { echo "[restore] ERROR: $*" >&2; exit 1; }

SRC="${1:-}"
CONFIRM="${2:-}"
[[ -n "$SRC" ]] || die "usage: restore.sh <backup-dir> $CONFIRM_FLAG"
[[ -d "$SRC" ]] || die "backup dir not found: $SRC"
[[ "$CONFIRM" == "$CONFIRM_FLAG" ]] || die "refusing without explicit $CONFIRM_FLAG"
[[ -f "$SRC/MANIFEST.txt" ]] || die "no MANIFEST.txt in $SRC"
[[ -f "$SRC/SHA256SUMS" ]] || die "no SHA256SUMS in $SRC"

# Load HELPER_IMAGE from the backup's own pinned versions.env when present.
if [[ -f "$SRC/versions.env" ]]; then
  # shellcheck source=/dev/null
  source "$SRC/versions.env"
else
  # shellcheck source=/dev/null
  source "$REPO_DIR/versions.env"
fi

# Single-flight lock.
if ! ( set -o noclobber; : > "$LOCK" ) 2>/dev/null; then
  die "another backup/restore holds $LOCK"
fi
trap 'rm -f "$LOCK"' EXIT

# 2. Verify all checksums BEFORE touching any state.
log "verifying checksums"
( cd "$SRC" && shasum -a 256 -c SHA256SUMS ) || die "checksum verification failed — aborting"
log "manifest:"; sed 's/^/    /' "$SRC/MANIFEST.txt"

DC=(docker compose --env-file versions.env --env-file .env -p "$PROJECT")

# 3. Emergency snapshot of current volumes (so a bad restore is itself reversible).
EMERG="$REPO_DIR/backups/emergency-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$EMERG"
log "emergency snapshot -> $EMERG"
"${DC[@]}" stop tars chase rocky einstein igris beru socrates api agent-fs minio minio-init || true
for vol in "${VOLUMES[@]}"; do
  if docker volume inspect "$vol" >/dev/null 2>&1; then
    docker run --rm -v "$vol":/src:ro -v "$EMERG":/backup "$HELPER_IMAGE" \
      tar czf "/backup/${vol}.tar.gz" -C /src . || log "WARNING: could not snapshot $vol"
  fi
done

# 4. Bring containers down (KEEP volumes; no -v).
"${DC[@]}" down || true

# 5. Clear + restore each named volume as one set.
for vol in "${VOLUMES[@]}"; do
  arc="$SRC/${vol}.tar.gz"
  [[ -f "$arc" ]] || { log "WARNING: no archive for $vol in backup — leaving as-is"; continue; }
  log "restoring volume $vol"
  docker volume rm "$vol" >/dev/null 2>&1 || true
  docker volume create "$vol" >/dev/null
  docker run --rm -v "$vol":/dst -v "$SRC":/backup:ro "$HELPER_IMAGE" \
    sh -c "cd /dst && tar xzf /backup/${vol}.tar.gz" || die "failed to restore $vol"
done

# 6. Restore matching config + secrets.
[[ -f "$SRC/compose.yaml" ]] && cp "$SRC/compose.yaml" "$REPO_DIR/compose.yaml"
[[ -f "$SRC/versions.env" ]] && cp "$SRC/versions.env" "$REPO_DIR/versions.env"
if [[ -f "$SRC/env.SENSITIVE" ]]; then cp "$SRC/env.SENSITIVE" "$REPO_DIR/.env"; chmod 600 "$REPO_DIR/.env"; fi
if [[ -f "$SRC/encryption_key.SENSITIVE" ]]; then cp "$SRC/encryption_key.SENSITIVE" "$REPO_DIR/encryption_key"; chmod 600 "$REPO_DIR/encryption_key"; fi

# 7. Start the backed-up image versions in dependency order.
log "starting stack"
"${DC[@]}" up -d minio
"${DC[@]}" up -d minio-init
"${DC[@]}" up -d agent-fs
"${DC[@]}" up -d api
"${DC[@]}" up -d tars chase rocky einstein igris beru socrates

# 8. Best-effort SQLite integrity check on any restored SQLite DBs.
log "SQLite integrity check (best-effort)"
for vol in swarm_api_data agent_fs_data; do
  docker run --rm -v "$vol":/d:ro "$HELPER_IMAGE" sh -c '
    apk add --no-cache -q sqlite >/dev/null 2>&1 || { echo "sqlite unavailable (offline?) — skipping"; exit 0; }
    found=0
    for f in $(find /d -type f 2>/dev/null); do
      if head -c 16 "$f" 2>/dev/null | grep -q "SQLite format 3"; then
        found=1; echo "  $f: $(sqlite3 "$f" "PRAGMA integrity_check;" 2>&1 | head -1)"
      fi
    done
    if [ "$found" = 0 ]; then echo "  no SQLite DB files found in '"$vol"'"; fi
    exit 0
  ' || log "WARNING: integrity check could not run for $vol"
done

# 9. Full verification.
log "running verify.sh"
bash "$REPO_DIR/scripts/verify.sh" || log "WARNING: verify.sh reported problems after restore"

log "DONE. Emergency snapshot retained at $EMERG"
