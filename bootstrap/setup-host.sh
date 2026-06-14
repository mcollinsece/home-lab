#!/usr/bin/env bash
#
# setup-host.sh — idempotent bootstrap for the home-lab VM (Debian 13).
#
# Reproduces the full host from a clean checkout. Safe to re-run: every step
# checks current state before changing anything. Run as the unprivileged service
# user (debian) — NOT root. Uses sudo only for system-level steps.
#
#   git clone <this repo> ~/home-lab && ~/home-lab/bootstrap/setup-host.sh
#
# What this script does NOT do (manual / sensitive — see docs/current/todos.md for the live list):
#   - AdGuard *.lab.lan wildcard (lives on the AdGuard LXC, not this host)
#   - API credentials (run: init-secrets)
#   - `claude login` (interactive OAuth — cannot be scripted)
#   - NemoClaw onboard + director provisioning troubleshoot (openclaw.lab.lan Bad Gateway is the top current item; status / rebuild / logs / 18789 / route curl)
#   - Post-nemoclaw dual-gateway steps (always restore the simple gateway.env symlink; recreate lab claude-code using explicit /usr/bin + --gateway-endpoint 17670 form — see the heredoc below and todos step 9)
#   - Install CA cert on client devices (see README.md § 'HTTPS / local CA trust')
#   - Full end-to-end repro verify after clean checkout (tracked in todos)
set -euo pipefail

# ---- config ------------------------------------------------------------------
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE_MAJOR=22
OPENSHELL_VERSION="${OPENSHELL_VERSION:-v0.0.62}"   # pin; override to upgrade
MKCERT_VERSION="v1.4.4"
COMPOSE_FILE="${REPO_DIR}/docker/compose.yml"
OPENSHELL_CFG_DIR="${HOME}/.config/openshell"
CERT_DIR="${REPO_DIR}/traefik/certs"
CA_DIR="${CERT_DIR}/ca"

say()  { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

if [ "$(id -u)" -eq 0 ]; then
  echo "Run as the service user (e.g. debian), not root." >&2; exit 1
fi

# ---- 1. base packages --------------------------------------------------------
say "Base packages"
if ! have curl || ! have git || ! have gpg; then
  sudo apt-get update -qq
  sudo apt-get install -y -qq curl git ca-certificates gnupg
else
  echo "curl/git/gnupg present — skipping"
fi

# ---- 2. Node.js (required by NemoClaw CLI) -----------------------------------
say "Node.js ${NODE_MAJOR}"
if have node && [ "$(node -v | sed 's/v\([0-9]*\).*/\1/')" -ge "$NODE_MAJOR" ]; then
  echo "node $(node -v) present — skipping"
else
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | sudo -E bash -
  sudo apt-get install -y -qq nodejs
fi
node -v; npm -v

# ---- 3. Docker Engine --------------------------------------------------------
say "Docker Engine"
if have docker && docker version >/dev/null 2>&1; then
  echo "docker $(docker version --format '{{.Server.Version}}' 2>/dev/null) present — skipping install"
else
  curl -fsSL https://get.docker.com | sudo sh
  echo "Docker Engine installed"
fi

# Add user to docker group (no-op if already a member).
if ! groups | grep -q '\bdocker\b'; then
  sudo usermod -aG docker "$USER"
  echo "Added $USER to docker group. A re-login is required for group membership"
  echo "to take effect in interactive shells. This script uses 'sudo docker' for now."
fi
sudo systemctl enable --now docker

# Use sudo docker if not yet in the docker group in this session.
if groups | grep -q '\bdocker\b'; then
  DOCKER="docker"
else
  DOCKER="sudo docker"
fi

# ---- 4. Linger (keeps OpenShell gateway alive after logout) ------------------
say "Linger for $USER"
loginctl show-user "$USER" 2>/dev/null | grep -q 'Linger=yes' \
  || sudo loginctl enable-linger "$USER"
echo "linger enabled"

# ---- 5. Docker daemon: insecure registry config ------------------------------
say "Docker daemon: insecure registry (registry.lab.lan:5000)"
DAEMON_JSON="/etc/docker/daemon.json"
if ! grep -q 'registry.lab.lan' "$DAEMON_JSON" 2>/dev/null; then
  sudo mkdir -p /etc/docker
  if [ -f "$DAEMON_JSON" ]; then
    python3 -c "
import json, sys
with open('${DAEMON_JSON}') as f:
    d = json.load(f)
d.setdefault('insecure-registries', [])
if 'registry.lab.lan:5000' not in d['insecure-registries']:
    d['insecure-registries'].append('registry.lab.lan:5000')
print(json.dumps(d, indent=2))
" | sudo tee "$DAEMON_JSON" >/dev/null
  else
    printf '{\n  "insecure-registries": ["registry.lab.lan:5000"]\n}\n' \
      | sudo tee "$DAEMON_JSON" >/dev/null
  fi
  sudo systemctl reload docker
  echo "insecure-registries updated in ${DAEMON_JSON}"
else
  echo "registry.lab.lan already in daemon.json — skipping"
fi

# ---- 6. /etc/hosts — registry.lab.lan loopback alias -------------------------
say "/etc/hosts entry for registry.lab.lan"
# The VM resolves DNS via the router, not AdGuard, so *.lab.lan does not resolve
# on the VM itself. A loopback entry lets `docker push registry.lab.lan:5000/...`
# reach the local registry container without AdGuard.
if ! grep -q 'registry.lab.lan' /etc/hosts; then
  echo '127.0.0.1  registry.lab.lan' | sudo tee -a /etc/hosts
  echo "added registry.lab.lan -> 127.0.0.1"
else
  echo "registry.lab.lan already in /etc/hosts"
fi

# ---- 7. OpenShell -----------------------------------------------------------
say "OpenShell ${OPENSHELL_VERSION}"
if have openshell && [ "$(openshell --version 2>/dev/null | awk '{print $2}')" = "${OPENSHELL_VERSION#v}" ]; then
  echo "openshell ${OPENSHELL_VERSION} present — skipping install"
else
  OPENSHELL_VERSION="$OPENSHELL_VERSION" \
    sh -c 'curl -LsSf https://raw.githubusercontent.com/NVIDIA/OpenShell/main/install.sh | sh'
fi

# ---- 8. OpenShell gateway config (Docker driver + 0.0.0.0 bind) --------------
say "OpenShell gateway config (Docker driver)"
mkdir -p "$OPENSHELL_CFG_DIR"
ln -sfn "$REPO_DIR/openshell/gateway.env" "$OPENSHELL_CFG_DIR/gateway.env"
systemctl --user restart openshell-gateway
sleep 2
if journalctl --user -u openshell-gateway --since "30 seconds ago" --no-pager 2>/dev/null \
     | grep -q 'compute driver driver=docker'; then
  echo "gateway up on Docker driver"
else
  echo "WARNING: gateway did not confirm Docker driver. Check:" >&2
  echo "         journalctl --user -u openshell-gateway --no-pager | tail -20" >&2
  echo "  (Also check: ss -tlnp | grep 17670  should be 0.0.0.0:17670)" >&2
fi

# ---- 9. mkcert + *.lab.lan wildcard TLS cert ---------------------------------
say "mkcert ${MKCERT_VERSION}"
MKCERT_BIN="${HOME}/.local/bin/mkcert"
mkdir -p "${HOME}/.local/bin"
if [ -x "$MKCERT_BIN" ] && "$MKCERT_BIN" -version 2>/dev/null | grep -qF "$MKCERT_VERSION"; then
  echo "mkcert ${MKCERT_VERSION} present — skipping"
else
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64)  MKCERT_ARCH="linux-amd64" ;;
    aarch64) MKCERT_ARCH="linux-arm64" ;;
    armv7l)  MKCERT_ARCH="linux-arm"   ;;
    *) echo "Unsupported arch for mkcert: $ARCH" >&2; exit 1 ;;
  esac
  curl -fsSL \
    "https://github.com/FiloSottile/mkcert/releases/download/${MKCERT_VERSION}/mkcert-${MKCERT_VERSION}-${MKCERT_ARCH}" \
    -o "$MKCERT_BIN"
  chmod +x "$MKCERT_BIN"
  echo "mkcert ${MKCERT_VERSION} installed to ${MKCERT_BIN}"
fi

say "*.lab.lan wildcard cert"
mkdir -p "$CA_DIR" "$CERT_DIR"
if [ ! -f "${CERT_DIR}/_wildcard.lab.lan-key.pem" ]; then
  CAROOT="$CA_DIR" "$MKCERT_BIN" -install
  CAROOT="$CA_DIR" "$MKCERT_BIN" \
    -cert-file "${CERT_DIR}/_wildcard.lab.lan.pem" \
    -key-file  "${CERT_DIR}/_wildcard.lab.lan-key.pem" \
    "*.lab.lan"
  echo ""
  echo "  ACTION REQUIRED: install the CA cert on each client device:"
  echo "    ${CA_DIR}/rootCA.pem"
  echo "  See README.md § 'HTTPS / local CA trust' for OS-specific commands."
  echo ""
else
  echo "Wildcard cert key present — skipping cert generation"
fi

# ---- 10. Non-secret runtime configs (auto-create from examples) ---------------
say "Non-secret env files"
if [ ! -f "${REPO_DIR}/litellm/litellm.env" ]; then
  cp "${REPO_DIR}/litellm/litellm.env.example" "${REPO_DIR}/litellm/litellm.env"
  echo "created litellm/litellm.env from example"
else
  echo "litellm/litellm.env present — skipping"
fi

# ---- 11. CLI tools (osbox, init-secrets — PATH-resident helpers) -------------
say "CLI tools -> ~/.local/bin"
mkdir -p "$HOME/.local/bin"
chmod +x "$REPO_DIR/bootstrap/osbox" "$REPO_DIR/bootstrap/init-secrets.sh"
ln -sfn "$REPO_DIR/bootstrap/osbox"           "$HOME/.local/bin/osbox"
ln -sfn "$REPO_DIR/bootstrap/init-secrets.sh" "$HOME/.local/bin/init-secrets"
echo "osbox        -> $HOME/.local/bin/osbox"
echo "init-secrets -> $HOME/.local/bin/init-secrets"

# ---- 12. Docker Compose services ---------------------------------------------
say "Docker Compose services"
SECRETS_READY=true
[ -f "${REPO_DIR}/.secrets/litellm.env" ]  || SECRETS_READY=false
[ -f "${REPO_DIR}/.secrets/bedrock.env" ]  || SECRETS_READY=false

if $SECRETS_READY; then
  $DOCKER compose -f "$COMPOSE_FILE" up -d --remove-orphans
  echo "All services started"
else
  echo "Secrets not yet populated — run 'init-secrets' first, then:"
  echo "  docker compose -f docker/compose.yml up -d"
fi

say "Done. Manual steps remaining (see docs/current/todos.md for the full current list, including post-nemoclaw director troubleshooting and lab claude-code recreate):"
cat <<'EOF'

  1. Credentials (cannot be scripted):
       init-secrets           # Bedrock keys + LiteLLM master key -> .secrets/*.env
       claude login           # interactive OAuth (needed for claude-cli backend in NemoClaw)

  2. Start Docker services (if secrets were not populated during this run):
       docker compose -f docker/compose.yml up -d

  3. Smoke-test LiteLLM:
       LITELLM_KEY=$(grep LITELLM_MASTER_KEY ~/home-lab/.secrets/litellm.env | cut -d= -f2)
       curl http://localhost:4000/v1/models -H "Authorization: Bearer ${LITELLM_KEY}"
       # Should return a model list including claude-sonnet-4-6

  4. Install the local CA cert on each client device (see README.md § 'HTTPS / local CA trust'):
       traefik/certs/ca/rootCA.pem

  5. NemoClaw — runs OpenClaw inside an OpenShell sandbox (NVIDIA-backed, interactive wizard):
       curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash
       # Installer launches `nemoclaw onboard`. Choose:
       #   Provider:   OpenAI-compatible
       #   API key:    $(grep LITELLM_MASTER_KEY ~/home-lab/.secrets/litellm.env | cut -d= -f2)
       #   Base URL:   http://localhost:4000/v1
       #   Model:      claude-sonnet-4-6
       # After onboard (and any director provisioning), access at http://127.0.0.1:18789 or via openclaw.lab.lan.
       # IMPORTANT: after nemoclaw, restore the simple gateway.env symlink (see below) and
       # recreate the lab claude-code sandbox using /usr/bin/openshell + explicit 17670 endpoint
       # (nemoclaw pins its own 0.0.44 CLI + gateway on 8080 and may overwrite .config).

  6. Wire OpenShell inference routing to LiteLLM (one-time, after litellm is running; use explicit lab gateway):
       LITELLM_KEY=$(grep LITELLM_MASTER_KEY ~/home-lab/.secrets/litellm.env | cut -d= -f2)
       /usr/bin/openshell --gateway-endpoint http://127.0.0.1:17670 --gateway-insecure provider create \
           --name litellm-local --type openai \
           --credential "OPENAI_API_KEY=${LITELLM_KEY}" \
           --config OPENAI_BASE_URL=http://localhost:4000/v1
       /usr/bin/openshell --gateway-endpoint http://127.0.0.1:17670 --gateway-insecure inference set --no-verify --provider litellm-local --model claude-sonnet-4-6
       /usr/bin/openshell --gateway-endpoint http://127.0.0.1:17670 --gateway-insecure inference get

  7. (Re)create claude-code sandbox on the lab gateway (post-nemoclaw / after any skew; uses inference.local):
       /usr/bin/openshell --gateway-endpoint http://127.0.0.1:17670 --gateway-insecure sandbox delete claude-code 2>/dev/null || true
       /usr/bin/openshell --gateway-endpoint http://127.0.0.1:17670 --gateway-insecure sandbox create --name claude-code --no-auto-providers \
           --policy ~/home-lab/openshell/policies/claude-code.yaml \
           --env ANTHROPIC_BASE_URL=https://inference.local \
           --env ANTHROPIC_API_KEY=unused \
           -- claude
       # Connect the same way (explicit endpoint). Inside: claude login if using subscription.

  8. (After nemoclaw) restore the simple lab gateway.env symlink (nemoclaw may write its full 8080 config):
       ln -sfn ~/home-lab/openshell/gateway.env ~/.config/openshell/gateway.env
       # (The repo version must stay the simple "driver=docker + BIND=0.0.0.0" one.)

  NOTE: Dual-gateway reality after nemoclaw:
  - Lab side (claude-code etc.): always use /usr/bin/openshell --gateway-endpoint http://127.0.0.1:17670 --gateway-insecure
    (or the https form) + restore the simple repo gateway.env symlink (step 8 above).
  - NemoClaw / director: uses its own 0.0.44 gateway (8080 + 10.89.0.1 lo alias + iptables workaround added in session
    for reachability). The 10.89 rules + alias can be cleaned once director is stable (see todos).
  - Top remaining: troubleshoot openclaw.lab.lan Bad Gateway (director Provisioning). Run in a TTY:
      nemoclaw director status
      nemoclaw director rebuild --yes
      tail -f ~/.local/state/nemoclaw/openshell-docker-gateway/openshell-gateway.log
      ss -tlnp | grep 18789
      curl -k -H 'Host: openclaw.lab.lan' https://localhost/
    (Pre-placed traefik/dynamic/openclaw-nemoclaw.yml does the route via file provider.)
  - See docs/current/todos.md (full list + "Verify full end-to-end reproducibility" after any setup-host changes)
    and bootstrap/TROUBLESHOOTING.md for director Bad Gateway, dual-gw gotchas, Traefik 1.24 skew + static dashboard,
    and 10.89 details.

  Any existing Podman-based OpenShell sandboxes are orphaned by the Docker driver switch.
  Recreate the lab ones using the explicit 17670 form above.

EOF
