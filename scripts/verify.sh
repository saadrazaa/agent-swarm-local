#!/usr/bin/env bash
# verify.sh — READ-ONLY health + integrity checks for the running stack.
# Exits non-zero if any check fails (backup.sh/restore.sh rely on this).
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR" || exit 1

DC=(docker compose --env-file versions.env --env-file .env -p agent-swarm-local)

# Pull only the values we need (avoid sourcing .env — some values contain spaces).
API_KEY="$(grep -E '^API_KEY=' .env | cut -d= -f2-)"

fail=0
note() { echo "[verify] $*"; }
bad()  { echo "[verify] FAIL: $*" >&2; fail=1; }

img_arch() {
  local cid="$1" img
  img="$(docker inspect -f '{{.Image}}' "$cid" 2>/dev/null)" || return
  docker image inspect -f '{{.Architecture}}/{{.Os}}' "$img" 2>/dev/null
}

# --- infra service health + architecture ------------------------------------
for s in minio agent-fs api; do
  cid="$("${DC[@]}" ps -q "$s" 2>/dev/null)"
  if [[ -z "$cid" ]]; then bad "$s is not running"; continue; fi
  state="$(docker inspect -f '{{.State.Status}}' "$cid")"
  health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid")"
  arch="$(img_arch "$cid")"
  note "$s: state=$state health=$health arch=$arch"
  [[ "$health" == "healthy" || "$health" == "none" ]] || bad "$s health=$health"
  [[ "$state"  == "running" ]] || bad "$s state=$state"
  [[ "$arch"   == arm64/* ]] || bad "$s not arm64 ($arch)"
done

# --- minio-init one-shot exited 0 -------------------------------------------
cid="$("${DC[@]}" ps -aq minio-init 2>/dev/null)"
if [[ -n "$cid" ]]; then
  ec="$(docker inspect -f '{{.State.ExitCode}}' "$cid")"
  note "minio-init exit code: $ec"
  [[ "$ec" == "0" ]] || bad "minio-init exit code $ec"
else
  note "minio-init container not found (already reaped?) — skipping exit check"
fi

# --- agent-fs is the active provider (not the built-in local-fs) ------------
if [[ -n "$API_KEY" ]]; then
  resp="$(curl -fsS -H "Authorization: Bearer ${API_KEY}" http://127.0.0.1:3013/api/fs/capabilities 2>/dev/null)" || resp=""
  if [[ -z "$resp" ]]; then
    bad "GET /api/fs/capabilities returned nothing (API up? key correct?)"
  elif echo "$resp" | grep -q 'local-fs'; then
    bad "capabilities reports local-fs, expected agent-fs: $resp"
  elif echo "$resp" | grep -q 'agent-fs'; then
    note "capabilities providerId: agent-fs"
  else
    bad "unexpected capabilities response: $resp"
  fi
else
  bad "API_KEY not found in .env"
fi

if [[ $fail -eq 0 ]]; then
  note "ALL CHECKS PASSED"
else
  note "one or more checks FAILED"
fi
exit "$fail"
