#!/usr/bin/env bash
#
# bootstrap/setup-nemoclaw-director.sh
#
# Automates the creation (or recreation) of the "director" sandbox via nemoclaw
# using the documented non-interactive path (NEMOCLAW_PROVIDER + --non-interactive
# --fresh --yes). This bypasses the entire interactive wizard (provider menu,
# base URL, key, model, resource profile, web search, messaging channels 5/8 etc).
#
# Intended to be called from setup-host.sh (or manually) for reproducible
# Docker + NemoClaw + LiteLLM (compatible) director setup.
#
# Prerequisites (caller/setup-host.sh should ensure):
#   - Docker up, user in docker group
#   - ~/.config/openshell/gateway.env symlink to repo (OPENSHELL_DRIVERS=docker, BIND=0.0.0.0)
#   - .secrets/litellm.env with LITELLM_MASTER_KEY
#   - Docker DNS fix applied for container npm registry resolves during build
#   - No stale nemoclaw processes/locks
#
# The script:
#   1. Clears stale lock + any prior failed onboard-session.json (so --fresh is clean)
#   2. Cleans any leftover podman director containers
#   3. Exports non-interactive hints (NEMOCLAW_PROVIDER=custom for the
#      "Other OpenAI-compatible" path used by LiteLLM, plus endpoint/model/key)
#   4. Runs onboard --non-interactive --fresh --yes --recreate-sandbox --name director
#      with DOCKER_HOST forced (real Docker, not podman driver quirks)
#   5. Runs force rebuild + prints status (poll until healthy)
#
# After success:
#   - director sandbox exists (docker container, not podman)
#   - 18789 listener
#   - openclaw.lab.lan serves (via static traefik route)
#
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRETS_FILE="$REPO_DIR/.secrets/litellm.env"

say() { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }

if [[ ! -f "$SECRETS_FILE" ]]; then
  echo "ERROR: $SECRETS_FILE not found. Run init-secrets first." >&2
  exit 1
fi

LITELLM_KEY=$(grep -E '^LITELLM_MASTER_KEY=' "$SECRETS_FILE" | head -1 | cut -d= -f2- | tr -d '\r\n ')

if [[ -z "$LITELLM_KEY" ]]; then
  echo "ERROR: Could not read LITELLM_MASTER_KEY from $SECRETS_FILE" >&2
  exit 1
fi

say "Removing any stale nemoclaw onboard lock (and failed/early sessions, but preserving an in-flight 'sandbox' create)"
rm -f "$HOME/.nemoclaw/onboard.lock" 2>/dev/null || true
# Do not blindly delete the session during a long-running create.
# If the session is already at the "sandbox" step (in_progress), the gateway is
# doing the async CreateSandbox work. Clearing it would lose progress.
SKIP_ONBOARD=0
if [[ -f "$HOME/.nemoclaw/onboard-session.json" ]]; then
  # Use a single python invocation + process substitution for robustness.
  # Output two words: last_step status
  read -r last_step status < <(python3 - "$HOME/.nemoclaw/onboard-session.json" 2>/dev/null <<'PY' || echo "unknown unknown"
import json, sys
try:
    with open(sys.argv[1]) as f:
        s = json.load(f)
    ls = s.get("lastStepStarted") or s.get("last_step") or "unknown"
    st = s.get("status") or "unknown"
    print(ls, st)
except Exception:
    print("unknown unknown")
PY
)
  if [[ "$last_step" == "sandbox" && "$status" == "in_progress" ]]; then
    echo "  (in-flight sandbox create detected — leaving onboard-session.json in place; will skip re-onboard and go straight to rebuild)"
    SKIP_ONBOARD=1
  else
    rm -f "$HOME/.nemoclaw/onboard-session.json" 2>/dev/null || true
    SKIP_ONBOARD=0
  fi
fi

say "Ensuring podman director (if any) is cleaned (we want Docker)"
podman rm -f "$(podman ps -a --format '{{.Names}}' | grep -E '^openshell-director-' || true)" 2>/dev/null || true

# Resolve nemoclaw command (works in normal user shells and tool/CI environments without nemoclaw in PATH)
if command -v nemoclaw >/dev/null 2>&1; then
  NEMOCLAW="nemoclaw"
else
  NEMOCLAW="node $HOME/.nemoclaw/source/bin/nemoclaw.js"
fi

if [[ "${SKIP_ONBOARD:-0}" != "1" ]]; then
  say "Preparing non-interactive compatible (LiteLLM) provider selection via env vars (per https://github.com/NVIDIA/NemoClaw non-int docs)"
  export NEMOCLAW_PROVIDER=custom
  export NEMOCLAW_ENDPOINT_URL=http://localhost:4000/v1
  export NEMOCLAW_MODEL=claude-sonnet-4-6
  export COMPATIBLE_API_KEY="$LITELLM_KEY"
  export NEMOCLAW_SANDBOX_NAME=director
  export NEMOCLAW_RECREATE_SANDBOX=1
  export DOCKER_HOST=unix:///var/run/docker.sock

  # Allow Control UI (the web dashboard served at openclaw.lab.lan) to connect its WebSocket
  # back to the gateway. The browser sends Origin: https://openclaw.lab.lan (due to Traefik TLS).
  # Defaults only allow direct 127.0.0.1 origins. NEMOCLAW_CORS_ORIGIN is picked up during
  # sandbox creation/rebuild to set gateway.controlUi.allowedOrigins in the OpenClaw config.
  # After a change, hard-refresh the browser page and reload the gateway if needed.
  export NEMOCLAW_CORS_ORIGIN="https://openclaw.lab.lan,http://127.0.0.1:18789,https://127.0.0.1:18789"

  say "Running non-interactive onboard (NEMOCLAW_PROVIDER=custom + --fresh --yes --recreate-sandbox; this selects Other OpenAI-compatible, skips all wizard steps including 5/8 and resource profile)"
  $NEMOCLAW onboard --non-interactive --yes --fresh --name director --recreate-sandbox 2>&1 || {
    echo "WARNING: onboard exited non-zero (may be expected if previous partial state or during long create)."
    echo "         Check ~/.local/state/nemoclaw/openshell-docker-gateway/openshell-gateway.log for details."
    echo "         Continuing to rebuild attempt anyway."
  }
else
  export DOCKER_HOST=unix:///var/run/docker.sock
  export NEMOCLAW_CORS_ORIGIN="https://openclaw.lab.lan,http://127.0.0.1:18789,https://127.0.0.1:18789"
  echo "  (skipping onboard step because a sandbox create is already in progress in the gateway)"
fi

say "Patching compatible-endpoint provider URL (localhost → Docker bridge gateway IP)"
# nemoclaw onboard uses NEMOCLAW_ENDPOINT_URL=localhost:4000 (correct from the host for
# wizard validation). But the OpenShell sandbox proxy runs *inside* the director container —
# from there, 'localhost' is the container's own loopback, not the host, so every inference
# request to inference.local returns 503. We must update the provider to the Docker bridge
# gateway IP, which the container can reach and routes to LiteLLM on the host.
_BRIDGE_IP=$(docker network inspect openshell-docker \
  --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null | head -1 | tr -d ' ')
if [[ -z "$_BRIDGE_IP" ]]; then
  _BRIDGE_IP="172.19.0.1"
  echo "  WARNING: openshell-docker network not found yet (sandbox may still be creating) — using fallback ${_BRIDGE_IP}"
  echo "  If inference returns 503 later, re-run manually:"
  echo "    BRIDGE_IP=\$(docker network inspect openshell-docker --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}')"
  echo "    /usr/bin/openshell --gateway-endpoint http://127.0.0.1:8080 --gateway-insecure provider update compatible-endpoint --config \"OPENAI_BASE_URL=http://\${BRIDGE_IP}:4000/v1\" --credential \"COMPATIBLE_API_KEY=<litellm-key>\""
fi
echo "  Bridge IP: ${_BRIDGE_IP} → setting OPENAI_BASE_URL=http://${_BRIDGE_IP}:4000/v1"
if /usr/bin/openshell --gateway-endpoint http://127.0.0.1:8080 --gateway-insecure \
     provider update compatible-endpoint \
     --config "OPENAI_BASE_URL=http://${_BRIDGE_IP}:4000/v1" \
     --credential "COMPATIBLE_API_KEY=${LITELLM_KEY}" 2>&1; then
  echo "  compatible-endpoint patched: OPENAI_BASE_URL=http://${_BRIDGE_IP}:4000/v1"
else
  echo "  WARNING: provider update failed (gateway may not be ready yet; will retry after rebuild)"
fi

say "Running force rebuild (usually required to get past Error/Provisioning)"
DOCKER_HOST=unix:///var/run/docker.sock $NEMOCLAW director rebuild --yes --force 2>&1 || true

say "Re-applying provider URL patch post-rebuild (rebuild may restart the gateway)"
_BRIDGE_IP=$(docker network inspect openshell-docker \
  --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null | head -1 | tr -d ' ')
if [[ -z "$_BRIDGE_IP" ]]; then _BRIDGE_IP="172.19.0.1"; fi
/usr/bin/openshell --gateway-endpoint http://127.0.0.1:8080 --gateway-insecure \
  provider update compatible-endpoint \
  --config "OPENAI_BASE_URL=http://${_BRIDGE_IP}:4000/v1" \
  --credential "COMPATIBLE_API_KEY=${LITELLM_KEY}" 2>&1 \
  && echo "  compatible-endpoint confirmed: http://${_BRIDGE_IP}:4000/v1" \
  || echo "  (post-rebuild patch skipped — gateway not running; will be correct on next connect)"

say "Final director status (poll this repeatedly until Ready or Connected improves):"
DOCKER_HOST=unix:///var/run/docker.sock $NEMOCLAW director status 2>&1 || true

# Runtime patch for Control UI (Gateway Dashboard) at https://openclaw.lab.lan:
# - CORS / allowedOrigins (for the custom domain vs direct 127)
# - Disable device auth / insecure auth so the browser Control UI doesn't require a token or password by default.
# The NEMOCLAW_CORS_ORIGIN env ensures this for future full recreates (via the image's nemoclaw-start logic).
# For the live container we patch openclaw.json directly and restart the inner process.
echo ""
if docker ps --format '{{.Names}}' | grep -q 'openshell-director-'; then
  CONTAINER=$(docker ps --filter 'name=openshell-director-' --format '{{.Names}}' | head -1)
  echo "==> Applying runtime Control UI patches to $CONTAINER (origin + disable auth for dashboard)"
  docker exec -u root "$CONTAINER" python3 - <<'PY' 2>/dev/null || true
import json
import secrets
config_file = "/sandbox/.openclaw/openclaw.json"
try:
    with open(config_file) as f:
        cfg = json.load(f)
    cu = cfg.setdefault("gateway", {}).setdefault("controlUi", {})
    origins = cu.setdefault("allowedOrigins", [])
    for o in ["https://openclaw.lab.lan", "http://127.0.0.1:18789", "https://127.0.0.1:18789"]:
        if o not in origins:
            origins.append(o)
    cu["dangerouslyDisableDeviceAuth"] = True
    cu["allowInsecureAuth"] = True
    # Ensure a gateway token exists for Control UI auth (the dashboard WS requires it).
    # This avoids repeated "gateway token missing" prompts; the value can be pasted in the form if needed.
    auth = cfg.setdefault("auth", {})
    if not auth.get("token"):
        auth["token"] = secrets.token_urlsafe(32)
        print("Generated new gateway token (for the Control UI form if prompted).")
    with open(config_file, "w") as f:
        json.dump(cfg, f, indent=2)
    print("Patched controlUi:", {"allowedOrigins": origins, "dangerouslyDisableDeviceAuth": True, "allowInsecureAuth": True})
    print("auth.token present:", bool(auth.get("token")))
except Exception as e:
    print("Patch note:", e)
PY
  # Ensure the Control UI web server (the "gateway run" component) is running inside the sandbox on 18789.
  # This is what binds the port so the supervisor can forward/publish it to the host (making 18789 available for Traefik).
  # The main "openclaw" process is the agent; the gateway run serves the dashboard + /health.
  echo "==> Ensuring Control UI gateway run process is started inside $CONTAINER"
  docker exec -u sandbox "$CONTAINER" sh -c '
    pkill -f "gateway run" 2>/dev/null || true
    if ! ss -tlnp | grep -q 18789; then
      nohup /usr/local/bin/openclaw gateway run --port 18789 --allow-unconfigured > /tmp/gw.log 2>&1 &
      echo "Started gateway run in background (pid $!)"
    else
      echo "Already listening on 18789 inside"
    fi
  ' 2>/dev/null || true
  sleep 3
  # Restart the outer gateway to pick up the new internal listener and re-publish 18789 on the host.
  echo "==> Restarting outer openshell-gateway to publish 18789"
  systemctl --user restart openshell-gateway 2>/dev/null || true
  sleep 2
  echo "Control UI patches applied (origin + no-auth for dashboard)."
  echo "Hard-refresh https://openclaw.lab.lan in the browser and try Connect again."
  echo "If it still asks for a token, run inside the sandbox:"
  echo "  nemoclaw director connect"
  echo "  openclaw doctor --generate-gateway-token"
  echo "  (copy the token and paste it in the form)"
  echo "Or restart outer gateway: systemctl --user restart openshell-gateway"
fi

# (claude-agent sandbox creation removed per user request.
#   We are simplifying back to JUST the litellm provider for NemoClaw/OpenClaw.
#   The probe will clean up any old anthropic/claude-agent provider entries.)

# Install / enable the persistent probe service so that `nemoclaw director connect --probe-only`
# (the thing that actually starts the openclaw process inside the sandbox and wires up the
# 18789 forward) survives reboots and is automatically restarted after a director rebuild.
say "Installing/enabling persistent nemoclaw-director-control-ui.service (survives reboots + auto-restarted after rebuild)"
mkdir -p "$HOME/.config/systemd/user"
chmod +x "$REPO_DIR/bootstrap/nemoclaw-director-probe.sh"
ln -sfn "$REPO_DIR/systemd/user/nemoclaw-director-control-ui.service" \
        "$HOME/.config/systemd/user/nemoclaw-director-control-ui.service"
systemctl --user daemon-reload
systemctl --user enable --now nemoclaw-director-control-ui.service 2>/dev/null || true
# After a rebuild we want the probe to re-run so the forward is re-established.
systemctl --user restart nemoclaw-director-control-ui.service 2>/dev/null || true

echo ""
echo "Useful follow-up commands:"
echo "  nemoclaw director status"
echo "  ss -tlnp | grep 18789"
echo "  curl -k -H 'Host: openclaw.lab.lan' https://localhost/"
echo "  tail -f ~/.local/state/nemoclaw/openshell-docker-gateway/openshell-gateway.log | grep -E 'director|CreateSandbox|GetSandbox|error'"
echo "  systemctl --user status nemoclaw-director-control-ui"
echo ""
echo "When the sandbox is healthy, openclaw.lab.lan should stop returning 502."
