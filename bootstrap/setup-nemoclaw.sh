#!/usr/bin/env bash
#
# setup-nemoclaw.sh — install NemoClaw and onboard the OpenClaw director
# NON-INTERACTIVELY against the local LiteLLM (OpenAI-compatible) endpoint.
#
# Encodes the lessons from the 2026-06 EC2 deploy (NemoClaw CLI 0.0.55):
#   - `binutils` (`strings`) is required by the installer's credential-rewrite check.
#   - For a LiteLLM/OpenAI-compatible endpoint use NEMOCLAW_PROVIDER=custom
#     (NOT `openai`, which hardcodes api.openai.com and 401s). The key goes in
#     COMPATIBLE_API_KEY and the URL in NEMOCLAW_ENDPOINT_URL (NOT
#     NEMOCLAW_INFERENCE_BASE_URL).
#   - onboard names the sandbox via --name (default: my-assistant).
#   - onboard installs its own OpenShell 0.0.44 (user-local) and CLOBBERS the lab
#     gateway.env via the ~/.config/openshell/gateway.env symlink — we restore it.
#
# Idempotent: re-running with an existing healthy director just `recover`s it.
# Must run as the service user (debian) with docker group active OR via `sg docker`.
#
#   bootstrap/setup-nemoclaw.sh [--model <id>] [--name <sandbox>]
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NEMO_MODEL="claude-code-wrapper-local"   # must already exist in LiteLLM
NEMO_NAME="my-assistant"
LITELLM_BASE="http://localhost:4000/v1"

while [ $# -gt 0 ]; do
  case "$1" in
    --model) NEMO_MODEL="$2"; shift 2 ;;
    --name)  NEMO_NAME="$2"; shift 2 ;;
    -h|--help) echo "usage: setup-nemoclaw.sh [--model <id>] [--name <sandbox>]"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

say() { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

export PATH="$HOME/.npm-global/bin:$HOME/.local/bin:$PATH"

LITELLM_KEY="$(grep LITELLM_MASTER_KEY "$REPO_DIR/.secrets/litellm.env" | cut -d= -f2)"
[ -n "$LITELLM_KEY" ] || { echo "ERROR: LITELLM_MASTER_KEY not found in .secrets/litellm.env" >&2; exit 1; }

# ── 0. binutils (installer needs `strings`) ────────────────────────────────────
if ! have strings; then
  say "Installing binutils (provides 'strings', required by the NemoClaw installer)"
  sudo apt-get install -y -qq binutils
fi

restore_gateway_env() {
  # onboard overwrites the repo gateway.env (via the symlink) with NemoClaw's 8080
  # config. The LAB gateway (17670, mTLS) must keep the simple driver+bind file.
  if grep -qE 'SERVER_PORT=8080|DISABLE_TLS' "$REPO_DIR/openshell/gateway.env" 2>/dev/null; then
    say "Restoring lab openshell/gateway.env (NemoClaw clobbered it)"
    git -C "$REPO_DIR" checkout -- openshell/gateway.env 2>/dev/null || cat > "$REPO_DIR/openshell/gateway.env" <<'EOF'
OPENSHELL_DRIVERS=docker
OPENSHELL_BIND_ADDRESS=0.0.0.0
EOF
  fi
}

# ── 1. Install NemoClaw CLI (idempotent) ──────────────────────────────────────
if have nemoclaw; then
  say "NemoClaw CLI present: $(nemoclaw --version 2>/dev/null | head -1)"
else
  say "Installing NemoClaw (non-interactive)"
  curl -fsSL https://www.nvidia.com/nemoclaw.sh | env \
    NEMOCLAW_NON_INTERACTIVE=1 \
    NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE=1 \
    NEMOCLAW_NO_EXPRESS=1 \
    bash
fi
restore_gateway_env

# ── 2. Onboard the director (idempotent) ──────────────────────────────────────
if nemoclaw "$NEMO_NAME" status 2>/dev/null | grep -q 'Phase:.*Ready'; then
  say "Director '$NEMO_NAME' already onboarded — recovering"
  nemoclaw "$NEMO_NAME" recover || true
else
  say "Onboarding NemoClaw director '$NEMO_NAME' against LiteLLM ($NEMO_MODEL)"
  env \
    NEMOCLAW_PROVIDER=custom \
    NEMOCLAW_MODEL="$NEMO_MODEL" \
    NEMOCLAW_ENDPOINT_URL="$LITELLM_BASE" \
    NEMOCLAW_INFERENCE_BASE_URL="$LITELLM_BASE" \
    COMPATIBLE_API_KEY="$LITELLM_KEY" \
    NEMOCLAW_POLICY_MODE=suggested \
    nemoclaw onboard --non-interactive --fresh --no-gpu --no-sandbox-gpu \
      --no-ollama-autostart --yes --yes-i-accept-third-party-software \
      --name "$NEMO_NAME"
fi
restore_gateway_env

# ── 3. Verify ─────────────────────────────────────────────────────────────────
say "Verifying OpenClaw dashboard on :18789"
if curl -s -o /dev/null -w '%{http_code}' --max-time 8 http://127.0.0.1:18789/ | grep -q 200; then
  say "Director ready: http://127.0.0.1:18789  (sandbox: $NEMO_NAME, model: $NEMO_MODEL)"
  echo "Next: bootstrap/setup-openclaw-relay.sh --name $NEMO_NAME  (expose openclaw.lab.lan via Traefik)"
else
  echo "WARNING: OpenClaw dashboard not 200 on :18789 — check: nemoclaw $NEMO_NAME status" >&2
  exit 1
fi
