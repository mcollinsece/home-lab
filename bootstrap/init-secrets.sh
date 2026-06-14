#!/usr/bin/env bash
#
# init-secrets.sh — populate .secrets/ after a clean-host rebuild.
#
# Run once after setup-host.sh, sourcing values from your password manager.
# Safe to re-run: env files are overwritten. Secrets are consumed by Docker
# Compose via env_file directives (no Podman secrets or Docker Swarm needed).
#
# What it creates:
#   .secrets/bedrock.env       — AWS Bedrock credentials (for LiteLLM → Bedrock)
#   .secrets/litellm.env       — LiteLLM master key (gates all inbound requests)
set -euo pipefail

_SCRIPT_REAL="$(readlink -f "${BASH_SOURCE[0]}")"
REPO_DIR="$(cd "$(dirname "$_SCRIPT_REAL")/.." && pwd)"
SECRETS_DIR="$REPO_DIR/.secrets"

say()        { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
ok()         { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
ask()        { printf '\033[1;33m  ?\033[0m %s: ' "$1"; read -r "${2?}"; }
ask_secret() { printf '\033[1;33m  ?\033[0m %s: ' "$1"; read -rs "${2?}"; printf '\n'; }
skip()       { printf '\033[1;90m  –\033[0m skipped (%s)\n' "$*"; }

mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"

# ---- AWS Bedrock (LiteLLM → Bedrock routing; consumed only by litellm container) ---
say "AWS Bedrock credentials"
printf '  Source: IAM console → scoped user (bedrock:InvokeModel* only)\n'
ask        "AWS_ACCESS_KEY_ID"     AWS_ACCESS_KEY_ID
ask_secret "AWS_SECRET_ACCESS_KEY" AWS_SECRET_ACCESS_KEY
ask        "AWS_REGION (enter for us-east-1)" AWS_REGION
AWS_REGION="${AWS_REGION:-us-east-1}"

cat > "$SECRETS_DIR/bedrock.env" <<EOF
AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}
AWS_REGION=${AWS_REGION}
EOF
chmod 600 "$SECRETS_DIR/bedrock.env"
ok "wrote .secrets/bedrock.env  (consumed by docker/compose.yml litellm service)"

# ---- LiteLLM master key (auto-generated — gates all inbound requests) --------
say "LiteLLM master key"
printf '  Auto-generated (no manual input needed).\n'
printf '  This key is shared between LiteLLM and OpenShell inference routing.\n'
printf '  NemoClaw onboard: use this key as the OpenAI-compatible provider API key.\n'

LITELLM_MASTER_KEY="$(openssl rand -hex 32)"

cat > "$SECRETS_DIR/litellm.env" <<EOF
LITELLM_MASTER_KEY=${LITELLM_MASTER_KEY}
EOF
chmod 600 "$SECRETS_DIR/litellm.env"
ok "wrote .secrets/litellm.env"

# ---- Summary -----------------------------------------------------------------
printf '\n\033[1;32m=== Done ===\033[0m\n'
printf '  Secrets files:\n'
printf '    %s/bedrock.env\n' "$SECRETS_DIR"
printf '    %s/litellm.env\n' "$SECRETS_DIR"
printf '\n  Next:\n'
printf '    docker compose -f docker/compose.yml up -d\n'
printf '\n  NemoClaw onboard (OpenAI-compatible provider config):\n'
printf '    API key:  %s\n' "$LITELLM_MASTER_KEY"
printf '    Base URL: http://localhost:4000/v1\n'
printf '    Model:    claude-sonnet-4-6\n\n'
