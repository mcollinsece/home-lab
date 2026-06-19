#!/usr/bin/env bash
# Starts the grok-openai-wrapper inside the openshell-grok-wrapper sandbox
# Similar to setup-claude-revproxy.sh but for Grok Build CLI

set -euo pipefail

say() { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }

_SB=$(docker ps --filter 'name=openshell-grok-wrapper-' --format '{{.Names}}' | head -1)
if [[ -z "$_SB" ]]; then
  echo "ERROR: openshell-grok-wrapper sandbox not running."
  echo "Create with: openshell sandbox create --name grok-wrapper --no-auto-providers --policy ~/home-lab/openshell/policies/grok.yaml"
  exit 1
fi
say "Sandbox: $_SB"

# ── 1. Sync Grok OAuth credentials ─────────────────────────────────────────────
if [[ ! -f ~/.grok/auth.json ]]; then
  echo ""
  echo "Grok not authenticated on host. Run: grok login"
  echo "Then re-run this script."
  exit 1
fi

say "Syncing Grok OAuth credentials..."
"$(dirname "$0")/sync-grok-credentials.sh"

# ── 2. Install Grok CLI in sandbox ─────────────────────────────────────────────
say "Installing Grok Build CLI in sandbox..."
if docker exec "$_SB" test -f /root/.grok/bin/grok; then
  say "Grok CLI: already installed."
else
  # Copy install script and run it
  docker cp /tmp/grok-install.sh "$_SB:/tmp/grok-install.sh"
  docker exec "$_SB" bash /tmp/grok-install.sh
  say "Grok CLI: installed."
fi

# ── 3. Connect sandbox to ai-net (idempotent) ──────────────────────────────────
say "Connecting sandbox to ai-net (alias: grok-wrapper)..."
if docker network inspect ai-net --format '{{range .Containers}}{{.Name}} {{end}}' | grep -q "$_SB"; then
  say "ai-net: already connected."
else
  docker network connect --alias grok-wrapper ai-net "$_SB"
  say "ai-net: connected."
fi

# ── 4. Install wrapper code and deps ───────────────────────────────────────────
_UV_BIN="/sandbox/.uv/python/cpython-3.14.3-linux-x86_64-gnu/bin"
_WRAPPER_DIR="/sandbox/grok-wrapper"

say "Copying wrapper code to sandbox..."
docker exec "$_SB" mkdir -p "$_WRAPPER_DIR/src"
docker cp "$(dirname "$0")/../wrappers/grok-openai-wrapper/src/main.py" "$_SB:$_WRAPPER_DIR/src/main.py"
docker cp "$(dirname "$0")/../wrappers/grok-openai-wrapper/requirements.txt" "$_SB:$_WRAPPER_DIR/requirements.txt"

if ! docker exec "$_SB" "$_UV_BIN/python3" -c "import fastapi, uvicorn" 2>/dev/null; then
  say "Installing wrapper Python dependencies..."
  docker exec "$_SB" "$_UV_BIN/python3" -m pip install --quiet --break-system-packages \
    -r "$_WRAPPER_DIR/requirements.txt"
else
  say "Wrapper deps: already installed."
fi

# ── 5. Start wrapper ───────────────────────────────────────────────────────────
say "Starting grok-openai-wrapper (Grok OAuth / subscription)..."
docker exec "$_SB" pkill -f "uvicorn.*grok" 2>/dev/null || true
sleep 2
docker exec -d \
  -e API_KEY=grok-internal-revproxy-key-2026 \
  -e GROK_BIN=/root/.grok/bin/grok \
  -e GROK_CWD=/tmp/grok-workspace \
  -e "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$_UV_BIN:/root/.grok/bin" \
  "$_SB" \
  "$_UV_BIN/uvicorn" src.main:app --host 0.0.0.0 --port 8001 --app-dir "$_WRAPPER_DIR"

say "Waiting for wrapper to be ready..."
for i in {1..20}; do
  if docker exec "$_SB" ss -tlnp 2>/dev/null | grep -q ':8001'; then
    say "Wrapper listening on :8001"
    break
  fi
  sleep 1
done

if ! docker exec "$_SB" ss -tlnp 2>/dev/null | grep -q ':8001'; then
  echo "WARNING: wrapper did not start within 20s"
  exit 1
fi

say "Done. LiteLLM → grok-wrapper:8001 → Grok Build CLI (OAuth subscription)"
