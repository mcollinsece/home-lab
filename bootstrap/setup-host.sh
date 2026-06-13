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
# What it does NOT do (manual / sensitive — see docs/current/todos.md):
#   - AdGuard *.lab.lan wildcard (lives on the AdGuard LXC, not this host)
#   - Podman secrets / API credentials
#   - `claude login` (interactive OAuth)
#   - the local image registry (registry/ — not built yet)
set -euo pipefail

# ---- config ---------------------------------------------------------------
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE_MAJOR=22
OPENSHELL_VERSION="${OPENSHELL_VERSION:-v0.0.62}"   # pin; override to upgrade
SYSTEMD_USER_DIR="${HOME}/.config/containers/systemd"
OPENSHELL_CFG_DIR="${HOME}/.config/openshell"

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

# ---- 3. rootless plumbing (linger, podman socket, :80) --------------------
say "Rootless plumbing"
loginctl show-user "$USER" 2>/dev/null | grep -q 'Linger=yes' \
  || sudo loginctl enable-linger "$USER"
systemctl --user enable --now podman.socket
if [ ! -f /etc/sysctl.d/99-unprivileged-ports.conf ]; then
  echo 'net.ipv4.ip_unprivileged_port_start=80' | sudo tee /etc/sysctl.d/99-unprivileged-ports.conf
  sudo sysctl --system >/dev/null
fi

# ---- 4. Quadlet services (ai-net, traefik, portainer) ---------------------
say "Quadlet symlinks -> ${SYSTEMD_USER_DIR}"
mkdir -p "$SYSTEMD_USER_DIR"
while IFS= read -r unit; do
  ln -sfn "$unit" "$SYSTEMD_USER_DIR/$(basename "$unit")"
  echo "linked $(basename "$unit")"
done < <(find "$REPO_DIR"/networks "$REPO_DIR"/traefik "$REPO_DIR"/portainer \
              -name '*.network' -o -name '*.container' -o -name '*.volume' 2>/dev/null)
systemctl --user daemon-reload

# ---- 5. OpenShell (Phase 2) ----------------------------------------------
say "OpenShell ${OPENSHELL_VERSION}"
if have openshell && [ "$(openshell --version 2>/dev/null | awk '{print $2}')" = "${OPENSHELL_VERSION#v}" ]; then
  echo "openshell ${OPENSHELL_VERSION} present — skipping install"
else
  OPENSHELL_VERSION="$OPENSHELL_VERSION" \
    sh -c 'curl -LsSf https://raw.githubusercontent.com/NVIDIA/OpenShell/main/install.sh | sh'
fi

# ---- 6. OpenShell gateway config (Podman driver + 0.0.0.0 bind) ----------
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

# ---- 7. CLI tools (osbox — PATH-resident sandbox helper) -----------------
say "CLI tools -> ~/.local/bin"
mkdir -p "$HOME/.local/bin"
chmod +x "$REPO_DIR/bootstrap/osbox"
ln -sfn "$REPO_DIR/bootstrap/osbox" "$HOME/.local/bin/osbox"
echo "osbox -> $HOME/.local/bin/osbox"

say "Done. Next (see docs/current/todos.md):"
cat <<'EOF'
  - openshell sandbox create --name claude-code --no-auto-providers \
        --policy openshell/policies/claude-code.yaml -- claude   # then `claude login`
  - Start Quadlet services if not running:
        systemctl --user start traefik.service portainer.service
EOF
