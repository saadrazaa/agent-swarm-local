#!/usr/bin/env bash
# Set an agent's runtime model live — no restart, takes effect on its next task.
# Resolves the agent by name or UUID, preserves its current harness, and sets the
# model with allow_custom_model=true. The custom flag is required because the
# Claude agents authenticate via CLAUDE_CODE_OAUTH_TOKEN (subscription), not an
# API key, so the dashboard/adapter otherwise gates model selection as "missing
# credential". Any models.dev id the API knows is accepted (e.g. claude-opus-5).
#
# Usage: scripts/set-model.sh <agent-name-or-id> <model-id>
#   make set-model AGENT=T.A.R.S MODEL=claude-opus-5
set -euo pipefail

AGENT="${1:?usage: set-model.sh <agent-name-or-id> <model-id>}"
MODEL="${2:?usage: set-model.sh <agent-name-or-id> <model-id>}"
API_CONTAINER="agent-swarm-local-api-1"

docker exec -i -e SM_AGENT="$AGENT" -e SM_MODEL="$MODEL" "$API_CONTAINER" python3 - <<'PY'
import json
import os
import urllib.request

key = os.environ["API_KEY"]
base = "http://localhost:3013"


def call(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        base + path,
        data=data,
        method=method,
        headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req) as resp:
        return json.load(resp)


query = os.environ["SM_AGENT"].lower()
agents = call("GET", "/api/agents")["agents"]
match = [a for a in agents if a["id"].lower() == query or a["name"].lower() == query]
if not match:
    raise SystemExit("agent not found: " + os.environ["SM_AGENT"])

agent = match[0]
call(
    "PATCH",
    "/api/agents/%s/runtime" % agent["id"],
    {
        "harness_provider": agent["harnessProvider"],
        "model": os.environ["SM_MODEL"],
        "allow_custom_model": True,
    },
)
print("OK: %s (%s) -> %s" % (agent["name"], agent["harnessProvider"], os.environ["SM_MODEL"]))
PY
