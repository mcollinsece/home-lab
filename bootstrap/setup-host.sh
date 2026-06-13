#!/usr/bin/env bash
#
# setup-host.sh — idempotent bootstrap for the home-lab VM (Debian 13, rootless).
#
# Reproduces the full host from a clean checkout. Safe to re-run: every step
# checks current state before changing anything. Run as the unprivileged service
# user (debian) — NOT root. Uses sudo only for the few system-level steps.
#
#   git clone <this repo> ~/home-lab && ~/home-lab/bootstrap/setup-host.sh
#
# What this script does NOT do (manual / sensitive — see docs/current/todos.md):
#   - AdGuard *.lab.lan wildcard (lives on the AdGuard LXC, not this host)
#   - Podman secrets / API credentials (run: init-secrets)
#   - `claude login` (interactive OAuth — cannot be scripted)
#   - cp openclaw/openclaw.env.example openclaw/openclaw.env
#   - Install CA cert on client devices (see README.md § 'HTTPS / local CA trust')
#   - Start services: systemctl --user start traefik portainer registry openclaw
set -euo pipefail

# ---- config ---------------------------------------------------------------
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE_MAJOR=22
OPENSHELL_VERSION="${OPENSHELL_VERSION:-v0.0.62}"   # pin; override to upgrade
MKCERT_VERSION="v1.4.4"
SYSTEMD_USER_DIR="${HOME}/.config/containers/systemd"
OPENSHELL_CFG_DIR="${HOME}/.config/openshell"
CERT_DIR="${REPO_DIR}/traefik/certs"
CA_DIR="${CERT_DIR}/ca"

say()  { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

if [ "$(id -u)" -eq 0 ]; then
  echo "Run as the service user (e.g. debian), not root." >&2; exit 1
fi

# ---- 1. base packages -----------------------------------------------------
say "Base packages"
if ! have curl || ! have git || ! have gpg; then
  sudo apt-get update -qq
  sudo apt-get install -y -qq curl git ca-certificates gnupg
else
  echo "curl/git/gnupg present — skipping"
fi

# ---- 2. Node.js (Phase 1) -------------------------------------------------
say "Node.js ${NODE_MAJOR}"
if have node && [ "$(node -v | sed 's/v\([0-9]*\).*/\1/')" -ge "$NODE_MAJOR" ]; then
  echo "node $(node -v) present — skipping"
else
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | sudo -E bash -
  sudo apt-get install -y -qq nodejs
fi
node -v; npm -v

# ---- 3. rootless plumbing (linger, podman socket, :80/:443) ---------------
say "Rootless plumbing"
loginctl show-user "$USER" 2>/dev/null | grep -q 'Linger=yes' \
  || sudo loginctl enable-linger "$USER"
systemctl --user enable --now podman.socket
# Allows binding ports 80 and 443 without root (443 is above 80 so also covered).
if [ ! -f /etc/sysctl.d/99-unprivileged-ports.conf ]; then
  echo 'net.ipv4.ip_unprivileged_port_start=80' | sudo tee /etc/sysctl.d/99-unprivileged-ports.conf
  sudo sysctl --system >/dev/null
fi

# ---- 4. Quadlet services (ai-net, traefik, portainer, registry, openclaw) -
say "Quadlet symlinks -> ${SYSTEMD_USER_DIR}"
mkdir -p "$SYSTEMD_USER_DIR"
while IFS= read -r unit; do
  ln -sfn "$unit" "$SYSTEMD_USER_DIR/$(basename "$unit")"
  echo "linked $(basename "$unit")"
done < <(find "$REPO_DIR"/networks "$REPO_DIR"/traefik "$REPO_DIR"/portainer \
              "$REPO_DIR"/registry "$REPO_DIR"/openclaw \
              -name '*.network' -o -name '*.container' -o -name '*.volume' 2>/dev/null)
systemctl --user daemon-reload

# ---- 5. OpenShell (Phase 2) -----------------------------------------------
say "OpenShell ${OPENSHELL_VERSION}"
if have openshell && [ "$(openshell --version 2>/dev/null | awk '{print $2}')" = "${OPENSHELL_VERSION#v}" ]; then
  echo "openshell ${OPENSHELL_VERSION} present — skipping install"
else
  OPENSHELL_VERSION="$OPENSHELL_VERSION" \
    sh -c 'curl -LsSf https://raw.githubusercontent.com/NVIDIA/OpenShell/main/install.sh | sh'
fi

# ---- 6. OpenShell gateway config (Podman driver + 0.0.0.0 bind) -----------
say "OpenShell gateway config"
mkdir -p "$OPENSHELL_CFG_DIR"
ln -sfn "$REPO_DIR/openshell/gateway.env" "$OPENSHELL_CFG_DIR/gateway.env"
systemctl --user restart openshell-gateway
sleep 2
if journalctl --user -u openshell-gateway --since "30 seconds ago" --no-pager 2>/dev/null \
     | grep -q 'compute driver driver=podman'; then
  echo "gateway up on Podman driver"
else
  echo "WARNING: gateway did not report the Podman driver. See bootstrap/TROUBLESHOOTING.md" >&2
  echo "         (check: ss -tlnp | grep 17670  should be 0.0.0.0:17670, not 127.0.0.1)" >&2
fi

# ---- 7. Podman registries config (trust registry.lab.lan as insecure HTTP) -
say "Podman registries config"
mkdir -p "$HOME/.config/containers"
REGS_CONF="$HOME/.config/containers/registries.conf"
if ! grep -q 'registry.lab.lan' "$REGS_CONF" 2>/dev/null; then
  cat >> "$REGS_CONF" <<'REGSEOF'

[[registry]]
location = "registry.lab.lan"
insecure = true
REGSEOF
  echo "added registry.lab.lan insecure registry"
else
  echo "registry.lab.lan already configured"
fi

# ---- 8. /etc/hosts — registry.lab.lan loopback alias ----------------------
say "/etc/hosts entry for registry.lab.lan"
# The VM resolves DNS via the router, not AdGuard, so *.lab.lan does not resolve
# on the VM itself. A loopback entry lets `podman build/push registry.lab.lan/...`
# reach the local registry container without AdGuard.
if ! grep -q 'registry.lab.lan' /etc/hosts; then
  echo '127.0.0.1  registry.lab.lan' | sudo tee -a /etc/hosts
  echo "added registry.lab.lan -> 127.0.0.1"
else
  echo "registry.lab.lan already in /etc/hosts"
fi

# ---- 9. mkcert + *.lab.lan wildcard TLS cert ------------------------------
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
# The private key is gitignored — its absence on a clean checkout means we need
# to generate a fresh CA and cert. A new CA means clients must re-install rootCA.pem.
if [ ! -f "${CERT_DIR}/_wildcard.lab.lan-key.pem" ]; then
  CAROOT="$CA_DIR" "$MKCERT_BIN" -install
  CAROOT="$CA_DIR" "$MKCERT_BIN" \
    -cert-file "${CERT_DIR}/_wildcard.lab.lan.pem" \
    -key-file  "${CERT_DIR}/_wildcard.lab.lan-key.pem" \
    "*.lab.lan"
  echo "New CA and wildcard cert generated."
  echo ""
  echo "  ACTION REQUIRED: install the CA cert on each client device:"
  echo "    ${CA_DIR}/rootCA.pem"
  echo "  See README.md § 'HTTPS / local CA trust' for OS-specific commands."
  echo ""
else
  echo "Wildcard cert key present — skipping cert generation"
fi

# ---- 10. OpenClaw state volume + openclaw.json ----------------------------
say "OpenClaw state volume config"
# Create the volume if it doesn't exist yet (the Quadlet also creates it on first
# start, but we need it now to pre-seed the config before OpenClaw runs).
podman volume inspect systemd-openclaw-state >/dev/null 2>&1 \
  || podman volume create systemd-openclaw-state

OPENCLAW_DATA="$(podman volume inspect systemd-openclaw-state --format '{{.Mountpoint}}')"
OPENCLAW_JSON="${OPENCLAW_DATA}/openclaw.json"

if podman unshare sh -c "[ -f '${OPENCLAW_JSON}' ]" 2>/dev/null; then
  echo "openclaw.json present — skipping"
else
  podman unshare bash -c "cat > '${OPENCLAW_JSON}'" << 'OCJSON'
{
  "gateway": {
    "mode": "local",
    "controlUi": {
      "allowedOrigins": [
        "http://localhost:18789",
        "http://127.0.0.1:18789",
        "https://openclaw.lab.lan"
      ],
      "allowInsecureAuth": false
    }
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "claude-cli/claude-sonnet-4-6",
        "fallbacks": ["amazon-bedrock/us.anthropic.claude-sonnet-4-6"]
      },
      "cliBackends": {
        "claude-cli": {
          "command": "/usr/local/bin/claude"
        }
      }
    }
  }
}
OCJSON
  echo "openclaw.json written to state volume"
fi

# ---- 11. OpenClaw custom image (bakes claude + openshell CLIs) ------------
say "OpenClaw custom image"
if podman image exists registry.lab.lan/openclaw:latest 2>/dev/null; then
  echo "registry.lab.lan/openclaw:latest present — skipping build"
else
  echo "Starting registry and building OpenClaw image (this takes a few minutes)..."
  systemctl --user start registry
  # Wait up to 30s for registry to accept connections.
  n=0
  until curl -sf http://registry.lab.lan:5000/v2/ >/dev/null 2>&1 || [ "$n" -ge 15 ]; do
    sleep 2; n=$((n + 1))
  done
  if ! curl -sf http://registry.lab.lan:5000/v2/ >/dev/null 2>&1; then
    echo "WARNING: registry did not become ready; skipping image build." >&2
    echo "         Start the registry manually and re-run: systemctl --user start registry" >&2
  else
    podman build \
      --build-arg OPENSHELL_VERSION="$OPENSHELL_VERSION" \
      -t registry.lab.lan/openclaw:latest \
      "${REPO_DIR}/openclaw/"
    podman push --tls-verify=false registry.lab.lan/openclaw:latest
    echo "OpenClaw image built and pushed to local registry"
  fi
fi

# ---- 12. CLI tools (osbox, init-secrets — PATH-resident helpers) ----------
say "CLI tools -> ~/.local/bin"
mkdir -p "$HOME/.local/bin"
chmod +x "$REPO_DIR/bootstrap/osbox" "$REPO_DIR/bootstrap/init-secrets.sh"
ln -sfn "$REPO_DIR/bootstrap/osbox"           "$HOME/.local/bin/osbox"
ln -sfn "$REPO_DIR/bootstrap/init-secrets.sh" "$HOME/.local/bin/init-secrets"
echo "osbox        -> $HOME/.local/bin/osbox"
echo "init-secrets -> $HOME/.local/bin/init-secrets"

say "Done. Manual steps remaining (see docs/current/todos.md):"
cat <<'EOF'

  1. Credentials (cannot be scripted):
       init-secrets                     # Bedrock keys -> Podman secrets + .secrets/
       claude login                     # interactive OAuth for Claude Code sandboxes

  2. OpenClaw runtime config:
       cp openclaw/openclaw.env.example openclaw/openclaw.env
       # Defaults are fine; OPENCLAW_GATEWAY_TOKEN is already set.

  3. Install the local CA on each client device — see README.md § 'HTTPS / local CA trust':
       traefik/certs/ca/rootCA.pem
       (macOS: sudo security add-trusted-cert -d -r trustRoot \
                  -k /Library/Keychains/System.keychain traefik/certs/ca/rootCA.pem)

  4. Start services:
       systemctl --user start traefik portainer registry openclaw

  5. First-time OpenClaw device pairing (after services start):
       - Open https://openclaw.lab.lan in browser
       - Enter token from openclaw/openclaw.env (OPENCLAW_GATEWAY_TOKEN)
       - Approve device: podman exec openclaw openclaw devices approve <requestId>
       - Settings -> Gateway -> OpenShell -> URL: http://host.containers.internal:17670

  6. First Claude Code sandbox (if not already created):
       openshell sandbox create --name claude-code --no-auto-providers \
           --policy openshell/policies/claude-code.yaml -- claude
EOF
