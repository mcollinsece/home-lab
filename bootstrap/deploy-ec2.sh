#!/usr/bin/env bash
#
# deploy-ec2.sh — one-shot, idempotent deploy of the full home-lab stack on an
# AWS EC2 instance (Debian 13). Encodes every lesson from the 2026-06 EC2 bring-up.
#
# Order matters and is deliberate:
#   1. setup-host.sh            (Docker, Node, OpenShell 0.0.62 lab gateway, mkcert, tools)
#   2. init-secrets             (--instance-role by default: Bedrock via IMDS, no static keys)
#   3. docker compose up        (Traefik, Portainer, Registry, LiteLLM) + smoke test
#   4. OpenShell provider/inference -> LiteLLM
#   5. Claude Code wrapper      (needs host `claude login` already done)
#   6. Grok wrapper             (needs host `grok login` already done; --skip-grok to skip)
#   7. NemoClaw director        (installs OpenShell 0.0.44; AFTER wrappers on purpose)
#   8. OpenClaw relay           (openclaw.lab.lan via socat + Traefik route)
#   9. Reboot-autostart units   (wrappers + director recover + cred-sync timers)
#  10. Verify
#
# Wrappers are created BEFORE NemoClaw so the plain `openshell` CLI still targets the
# 0.0.62 lab gateway (NemoClaw later installs a 0.0.44 CLI/gateway that shadows it).
#
# Run as the service user (debian), NOT root:
#   bootstrap/deploy-ec2.sh [--static-keys] [--skip-grok] [--region us-east-1]
#
# Prereqs you must do yourself (cannot be scripted): `claude login` (and `grok login`
# unless --skip-grok) on the host; EC2 IMDS hop limit 2 + bedrock-runtime VPC-endpoint
# SG open on 443 (see docs/cloud/aws-ec2-provisioning.md).
set -euo pipefail

[ "$(id -u)" -ne 0 ] || { echo "ERROR: run as the service user (debian), not root." >&2; exit 1; }

# This shell may not have the docker group active yet (group membership needs a
# fresh login). Re-exec the whole script once under `sg docker` so every bare
# `docker` call (here and in sub-scripts) works natively. Done before arg parsing
# so "$@" is still intact. sudo still works (other groups stay supplementary).
if ! id -nG | grep -qw docker && command -v sg >/dev/null 2>&1; then
  exec sg docker -c "$(printf '%q ' "$0" "$@")"
fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="$REPO_DIR/docker/compose.yml"
SECRETS_MODE="--instance-role"   # default for EC2; --static-keys flips to interactive keys
SKIP_GROK=false
REGION=us-east-1
NEMO_NAME="my-assistant"
NEMO_MODEL="claude-code-wrapper-local"

while [ $# -gt 0 ]; do
  case "$1" in
    --static-keys) SECRETS_MODE=""; shift ;;
    --skip-grok)   SKIP_GROK=true; shift ;;
    --region)      REGION="$2"; shift 2 ;;
    -h|--help)     sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

say()  { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  ! \033[0m%s\n' "$*"; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

LITELLM_KEY() { grep LITELLM_MASTER_KEY "$REPO_DIR/.secrets/litellm.env" | cut -d= -f2; }

# Create an OpenShell lab-gateway sandbox if its container isn't already running.
# `sandbox create` stays attached when no command is given, so run it detached,
# wait for Ready, then leave it (the container persists with restart: unless-stopped).
ensure_sandbox() {
  local name="$1" policy="$2"
  if docker ps --filter "name=openshell-${name}-" --format '{{.Names}}' | grep -q .; then
    ok "sandbox '$name' container already present"; return 0
  fi
  say "Creating sandbox '$name' (first create pulls the base image; can take minutes)"
  /usr/bin/openshell sandbox create --name "$name" --no-auto-providers \
    --policy "$REPO_DIR/openshell/policies/${policy}" >/tmp/osh-create-$name.log 2>&1 &
  local pid=$!
  local t=0
  until /usr/bin/openshell sandbox list 2>/dev/null | grep -E "^${name}[[:space:]]|[[:space:]]${name}[[:space:]]" | grep -q Ready; do
    kill -0 "$pid" 2>/dev/null || true
    sleep 5; t=$((t+5)); [ "$t" -ge 600 ] && { warn "sandbox '$name' not Ready after 600s; see /tmp/osh-create-$name.log"; break; }
  done
  kill "$pid" 2>/dev/null || true     # detach the (idle, attached) create process
  docker ps --filter "name=openshell-${name}-" --format '{{.Names}}' | grep -q . \
    && ok "sandbox '$name' running" || die "sandbox '$name' failed to start"
}

# ── 1. Host setup ─────────────────────────────────────────────────────────────
say "[1/10] Host setup (setup-host.sh)"
"$REPO_DIR/bootstrap/setup-host.sh"

# ── 2. Secrets ────────────────────────────────────────────────────────────────
say "[2/10] Secrets"
if [ -f "$REPO_DIR/.secrets/litellm.env" ] && [ -f "$REPO_DIR/.secrets/bedrock.env" ]; then
  ok ".secrets present — skipping init-secrets"
else
  # shellcheck disable=SC2086
  "$REPO_DIR/bootstrap/init-secrets.sh" $SECRETS_MODE --region="$REGION"
fi
[ -f "$REPO_DIR/litellm/litellm.env" ] || cp "$REPO_DIR/litellm/litellm.env.example" "$REPO_DIR/litellm/litellm.env"

# ── 3. Docker Compose services ────────────────────────────────────────────────
say "[3/10] Docker Compose services"
docker compose -f "$COMPOSE_FILE" up -d --remove-orphans
say "Waiting for LiteLLM (:4000)…"
t=0; until curl -fsS -o /dev/null "http://localhost:4000/v1/models" -H "Authorization: Bearer $(LITELLM_KEY)" 2>/dev/null; do
  sleep 3; t=$((t+3)); [ "$t" -ge 90 ] && die "LiteLLM did not become ready on :4000"
done
ok "LiteLLM models: $(curl -fsS "http://localhost:4000/v1/models" -H "Authorization: Bearer $(LITELLM_KEY)" | grep -o '"id":"[^"]*"' | wc -l) registered"

# ── 4. OpenShell inference provider ───────────────────────────────────────────
say "[4/10] OpenShell inference provider -> LiteLLM"
if /usr/bin/openshell provider list 2>/dev/null | grep -q litellm-local; then
  ok "provider litellm-local exists"
else
  /usr/bin/openshell provider create --name litellm-local --type openai \
    --credential "OPENAI_API_KEY=$(LITELLM_KEY)" \
    --config "OPENAI_BASE_URL=http://localhost:4000/v1"
fi
/usr/bin/openshell inference set --no-verify --provider litellm-local --model claude-sonnet-4-6 >/dev/null
ok "inference.local -> litellm-local / claude-sonnet-4-6"

# ── 5. Bedrock reachability (informational) ───────────────────────────────────
say "[5/10] Bedrock reachability check"
if curl -s -o /dev/null --max-time 8 "https://bedrock-runtime.${REGION}.amazonaws.com/" 2>/dev/null; then
  ok "bedrock-runtime endpoint reachable"
else
  warn "bedrock-runtime.${REGION} not reachable — open 443 on its VPC-endpoint SG"
  warn "and set IMDS hop limit 2 (see docs/cloud/aws-ec2-provisioning.md). Non-fatal; wrappers still work."
fi

# ── 6. Claude Code wrapper ────────────────────────────────────────────────────
say "[6/10] Claude Code wrapper"
[ -f "$HOME/.claude/.credentials.json" ] || die "No ~/.claude/.credentials.json — run 'claude login' on the host first."
ensure_sandbox claude-revproxy claude-code.yaml
"$REPO_DIR/bootstrap/setup-claude-revproxy.sh"

# ── 7. Grok wrapper ───────────────────────────────────────────────────────────
if [ "$SKIP_GROK" = true ]; then
  say "[7/10] Grok wrapper — skipped (--skip-grok)"
else
  say "[7/10] Grok wrapper"
  [ -f /tmp/grok-install.sh ] || curl -fsSL https://x.ai/cli/install.sh -o /tmp/grok-install.sh
  have grok || bash /tmp/grok-install.sh
  [ -f "$HOME/.grok/auth.json" ] || die "No ~/.grok/auth.json — run 'grok login' on the host (or pass --skip-grok)."
  ensure_sandbox grok-wrapper grok.yaml
  "$REPO_DIR/bootstrap/setup-grok-wrapper.sh"
fi

# ── 8. NemoClaw director ──────────────────────────────────────────────────────
say "[8/10] NemoClaw director"
"$REPO_DIR/bootstrap/setup-nemoclaw.sh" --name "$NEMO_NAME" --model "$NEMO_MODEL"

# ── 9. OpenClaw relay (openclaw.lab.lan) ──────────────────────────────────────
say "[9/10] OpenClaw relay + Traefik route"
"$REPO_DIR/bootstrap/setup-openclaw-relay.sh" --name "$NEMO_NAME"

# ── 10. Reboot-autostart + verify ─────────────────────────────────────────────
say "[10/10] Reboot-autostart units"
"$REPO_DIR/bootstrap/install-autostart-services.sh" --name "$NEMO_NAME"

say "Verification"
K="$(LITELLM_KEY)"
for m in bedrock/us.anthropic.claude-sonnet-4-6 claude-code-wrapper-local $([ "$SKIP_GROK" = true ] || echo grok-wrapper-local); do
  c=$(curl -s --max-time 90 -o /dev/null -w '%{http_code}' http://localhost:4000/v1/chat/completions \
        -H "Authorization: Bearer $K" -H 'Content-Type: application/json' \
        -d "{\"model\":\"$m\",\"messages\":[{\"role\":\"user\",\"content\":\"ok\"}],\"max_tokens\":15}")
  [ "$c" = 200 ] && ok "model $m -> 200" || warn "model $m -> $c"
done
oc=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 8 -H 'Host: openclaw.lab.lan' https://localhost/ || true)
[ "$oc" = 200 ] && ok "openclaw.lab.lan -> 200" || warn "openclaw.lab.lan -> $oc"

say "Done. Install the CA cert (traefik/certs/ca/rootCA.pem) on clients; set up DNS:"
echo "  Route53 private zone: deploy cloudformation/route53-lab-dns.yaml (admin creds) — see docs/cloud/route53-dns.md"
