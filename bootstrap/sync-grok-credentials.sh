#!/usr/bin/env bash
# Sync Grok OAuth credentials from host to sandbox
# Similar to sync-claude-credentials.sh but for Grok

set -euo pipefail

say() { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }

_SB=$(docker ps --filter 'name=openshell-grok-wrapper-' --format '{{.Names}}' | head -1)
if [[ -z "$_SB" ]]; then
  echo "ERROR: openshell-grok-wrapper sandbox not running."
  exit 1
fi

if [[ ! -f ~/.grok/auth.json ]]; then
  echo "ERROR: ~/.grok/auth.json not found."
  echo "Run 'grok login' on the host first."
  exit 1
fi

say "Syncing Grok OAuth credentials to sandbox..."
say "Host: ~/.grok/auth.json → Sandbox: /root/.grok/auth.json"

# Create .grok directory in sandbox
docker exec "$_SB" mkdir -p /root/.grok

# Copy auth.json
docker cp ~/.grok/auth.json "$_SB:/root/.grok/auth.json"

# Set proper permissions
docker exec "$_SB" chmod 600 /root/.grok/auth.json

say "Credentials synced."
