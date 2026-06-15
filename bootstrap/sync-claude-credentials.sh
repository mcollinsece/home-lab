#!/usr/bin/env bash
# Copies the host's Claude OAuth credentials into the claude-revproxy sandbox
# so the claude-code-openai-wrapper can authenticate via Pro subscription.
#
# Run manually after: claude auth login (on host), or on a schedule.
# Future: wire as a systemd timer (e.g. hourly) to keep in sync.

set -euo pipefail

_SB=$(docker ps --filter 'name=openshell-claude-revproxy-' --format '{{.Names}}' | head -1)
if [[ -z "$_SB" ]]; then
  echo "ERROR: openshell-claude-revproxy sandbox not running (docker ps)"
  exit 1
fi

_SRC="$HOME/.claude/.credentials.json"
if [[ ! -f "$_SRC" ]]; then
  echo "ERROR: $HOME/.claude/.credentials.json not found — run: claude auth login"
  exit 1
fi

docker exec "$_SB" mkdir -p /root/.claude
docker cp "$_SRC" "$_SB":/root/.claude/.credentials.json

echo "Synced credentials to $_SB:/root/.claude/.credentials.json"
docker exec "$_SB" claude auth status 2>/dev/null | grep -E 'loggedIn|subscriptionType'
