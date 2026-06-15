#!/usr/bin/env bash
# Starts the claude-code-openai-wrapper inside the openshell-claude-revproxy sandbox
# and connects the sandbox to ai-net so LiteLLM can reach it.
#
# Run after: reboot, sandbox rebuild, or wrapper crash.
# LiteLLM routes claude-code-wrapper-local → http://claude-code-wrapper:8000/v1

set -euo pipefail

say() { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }

_SB=$(docker ps --filter 'name=openshell-claude-revproxy-' --format '{{.Names}}' | head -1)
if [[ -z "$_SB" ]]; then
  echo "ERROR: openshell-claude-revproxy sandbox not running."
  echo "Recreate with: /usr/bin/openshell --gateway-endpoint http://127.0.0.1:17670 --gateway-insecure sandbox create claude-revproxy"
  exit 1
fi
say "Sandbox: $_SB"

# ── 1. Sync credentials ────────────────────────────────────────────────────────
say "Syncing Claude OAuth credentials..."
"$(dirname "$0")/sync-claude-credentials.sh"

# ── 2. Connect sandbox to ai-net (idempotent) ──────────────────────────────────
say "Connecting sandbox to ai-net (alias: claude-code-wrapper)..."
if docker network inspect ai-net --format '{{range .Containers}}{{.Name}} {{end}}' | grep -q "$_SB"; then
  say "ai-net: already connected."
else
  docker network connect --alias claude-code-wrapper ai-net "$_SB"
  say "ai-net: connected."
fi

# ── 3. Copy wrapper code to sandbox ───────────────────────────────────────────
_UV_BIN="/sandbox/.uv/python/cpython-3.14.3-linux-x86_64-gnu/bin"
_WRAPPER_DIR="/sandbox/wrapper"

say "Copying wrapper code to sandbox..."
docker exec "$_SB" mkdir -p "$_WRAPPER_DIR"
docker cp "$(dirname "$0")/../wrappers/claude-code-openai-wrapper/src" "$_SB:$_WRAPPER_DIR/"
docker cp "$(dirname "$0")/../wrappers/claude-code-openai-wrapper/requirements.txt" "$_SB:$_WRAPPER_DIR/"

# ── 4. Install wrapper deps if missing ────────────────────────────────────────
if ! docker exec "$_SB" "$_UV_BIN/python3" -c "import fastapi, uvicorn, claude_agent_sdk" 2>/dev/null; then
  say "Installing wrapper Python dependencies..."
  docker exec "$_SB" "$_UV_BIN/python3" -m pip install --quiet --break-system-packages \
    -r "$_WRAPPER_DIR/requirements.txt"
else
  say "Wrapper deps: already installed."
fi

# ── 5. Start wrapper ───────────────────────────────────────────────────────────
say "Starting claude-code-openai-wrapper (OAuth / Pro subscription)..."
docker exec "$_SB" pkill -f uvicorn 2>/dev/null || true
sleep 2
docker exec -d \
  -e CLAUDE_CODE_AUTH_METHOD=cli \
  -e API_KEY=claude-code-internal-revproxy-key-2026 \
  -e RATE_LIMIT_ENABLED=false \
  -e CLAUDE_CWD=/tmp \
  -e "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$_UV_BIN" \
  "$_SB" \
  "$_UV_BIN/uvicorn" src.main:app --host 0.0.0.0 --port 8000 --app-dir /sandbox/wrapper

say "Waiting for wrapper to be ready..."
for i in {1..20}; do
  if docker exec "$_SB" ss -tlnp 2>/dev/null | grep -q ':8000'; then
    say "Wrapper listening on :8000"
    break
  fi
  sleep 1
done

if ! docker exec "$_SB" ss -tlnp 2>/dev/null | grep -q ':8000'; then
  echo "WARNING: wrapper did not start within 20s"
  exit 1
fi

say "Done. LiteLLM → claude-code-wrapper:8000 → Claude Code (OAuth)"
