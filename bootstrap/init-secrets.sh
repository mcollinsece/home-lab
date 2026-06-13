#!/usr/bin/env bash
#
# init-secrets.sh — populate ~/.secrets/ and Podman secrets after a clean-host rebuild.
#
# Run once after setup-host.sh, sourcing values from your password manager.
# Safe to re-run: Podman secrets are created with --replace; env files are overwritten.
#
# What it creates:
#   ~/.secrets/bedrock.env         — AWS keys for osbox --bedrock (OpenShell sandbox injection)
#   Podman secret: bedrock_aws_access_key_id
#   Podman secret: bedrock_aws_secret_access_key
#   Podman secret: bedrock_aws_region
#   Podman secret: anthropic_api_key   — for OpenClaw Quadlet (Secret= directive)
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

# ---- AWS Bedrock (Phase 3 — osbox --bedrock + OpenShell env injection) -----
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
ok "wrote .secrets/bedrock.env  (used by osbox --bedrock)"

printf '%s' "$AWS_ACCESS_KEY_ID"     | podman secret create --replace bedrock_aws_access_key_id     - >/dev/null
printf '%s' "$AWS_SECRET_ACCESS_KEY" | podman secret create --replace bedrock_aws_secret_access_key - >/dev/null
printf '%s' "$AWS_REGION"            | podman secret create --replace bedrock_aws_region             - >/dev/null
ok "Podman secrets: bedrock_aws_{access_key_id,secret_access_key,region}  (for Quadlet containers)"

# ---- Anthropic API key (optional — only if using direct API instead of claude-cli) ----
say "Anthropic API key (optional)"
printf '  OpenClaw defaults to the claude-cli backend (host claude login, no key needed).\n'
printf '  Only needed if you want direct Anthropic API access as the primary provider.\n'
printf '  Source: console.anthropic.com → API keys. Leave blank to skip.\n'
ask_secret "ANTHROPIC_API_KEY" ANTHROPIC_API_KEY

if [[ -n "${ANTHROPIC_API_KEY}" ]]; then
  printf '%s' "$ANTHROPIC_API_KEY" | podman secret create --replace anthropic_api_key - >/dev/null
  ok "Podman secret: anthropic_api_key"
else
  skip "no key entered — using claude-cli backend (claude login credentials)"
fi

# ---- Summary ---------------------------------------------------------------
printf '\n\033[1;32m=== Done ===\033[0m\n'
printf '  Secrets file:  %s/bedrock.env\n' "$SECRETS_DIR"
printf '  Podman secrets:\n'
podman secret ls --format '    {{.Name}}' 2>/dev/null || true
printf '\n  Next: cp openclaw/openclaw.env.example openclaw/openclaw.env\n'
printf '        systemctl --user start registry openclaw\n\n'
