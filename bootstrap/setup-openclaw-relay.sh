#!/usr/bin/env bash
#
# setup-openclaw-relay.sh — expose the NemoClaw OpenClaw director at
# https://openclaw.lab.lan through Traefik.
#
# Why a relay: NemoClaw CLI 0.0.55 serves the dashboard via an SSH tunnel on the
# host loopback (127.0.0.1:18789) — OpenClaw does NOT listen on the sandbox
# container's network. So Traefik -> openclaw-director:18789 returns 502. This
# script bridges the gap with a socat relay on the ai-net gateway IP (the same
# fix the repo's git history used), repoints the Traefik file route at it, and
# patches openclaw.json so the lab hostname works in a browser.
#
# Replaces bootstrap/nemoclaw-director-probe.sh for the 0.0.55+ managed flow
# (that probe assumed a 'director'-named sandbox + in-container openclaw bind).
#
# Idempotent. Run after setup-nemoclaw.sh. Needs docker group (or `sg docker`).
#
#   bootstrap/setup-openclaw-relay.sh [--name <sandbox>] [--relay-port 18790]
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NEMO_NAME="my-assistant"
RELAY_PORT=18790
DASH_PORT=18789
AINET=ai-net
MODELS="claude-code-wrapper-local grok-wrapper-local"   # added to the OpenClaw picker
ORIGINS="https://openclaw.lab.lan http://openclaw.lab.lan"

while [ $# -gt 0 ]; do
  case "$1" in
    --name) NEMO_NAME="$2"; shift 2 ;;
    --relay-port) RELAY_PORT="$2"; shift 2 ;;
    -h|--help) echo "usage: setup-openclaw-relay.sh [--name <sandbox>] [--relay-port N]"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

say() { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

DIR=$(docker ps --filter "name=openshell-${NEMO_NAME}-" --format '{{.Names}}' | head -1)
[ -n "$DIR" ] || { echo "ERROR: director container openshell-${NEMO_NAME}-* not running. Run setup-nemoclaw.sh first." >&2; exit 1; }
say "Director container: $DIR"

# ── 1. ai-net gateway IP (Traefik reaches the host here) ───────────────────────
AINET_GW=$(docker network inspect "$AINET" -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null)
[ -n "$AINET_GW" ] || { echo "ERROR: could not determine $AINET gateway IP (is the network up?)" >&2; exit 1; }
say "ai-net gateway: $AINET_GW  (relay $AINET_GW:$RELAY_PORT -> 127.0.0.1:$DASH_PORT)"

# ── 2. socat relay as a persistent systemd --user service ──────────────────────
have socat || { say "Installing socat"; sudo apt-get install -y -qq socat; }
mkdir -p "$HOME/.config/systemd/user"
cat > "$HOME/.config/systemd/user/openclaw-socat-relay.service" <<EOF
[Unit]
Description=socat relay: ai-net ${AINET_GW}:${RELAY_PORT} -> OpenClaw SSH-tunnel 127.0.0.1:${DASH_PORT}
After=network.target

[Service]
Type=simple
# Wait for the ai-net bridge gateway IP to exist before binding.
ExecStartPre=/bin/sh -c 'for i in \$(seq 1 30); do ip addr show | grep -qw ${AINET_GW} && exit 0; sleep 2; done; exit 0'
ExecStart=/usr/bin/socat TCP-LISTEN:${RELAY_PORT},bind=${AINET_GW},fork,reuseaddr TCP:127.0.0.1:${DASH_PORT}
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload
systemctl --user enable --now openclaw-socat-relay.service
systemctl --user restart openclaw-socat-relay.service
say "socat relay: $(systemctl --user is-active openclaw-socat-relay.service)"

# ── 3. Traefik file route -> the relay ────────────────────────────────────────
cat > "$REPO_DIR/traefik/dynamic/openclaw-nemoclaw.yml" <<EOF
http:
  routers:
    openclaw:
      rule: "Host(\`openclaw.lab.lan\`)"
      entrypoints: [websecure]
      tls: {}
      service: openclaw
  services:
    openclaw:
      loadBalancer:
        servers:
          # NemoClaw 0.0.55 serves the dashboard via an SSH tunnel on the host
          # loopback; setup-openclaw-relay.sh bridges it to the ai-net gateway.
          - url: "http://${AINET_GW}:${RELAY_PORT}"
EOF
say "Traefik route -> http://${AINET_GW}:${RELAY_PORT} (file provider hot-reloads)"

# ── 4. openclaw.json: CORS origin + wrapper models in the picker ──────────────
say "Patching openclaw.json (CORS allowedOrigins + model picker)"
docker exec -i -u root "$DIR" env ORIGINS="$ORIGINS" MODELS="$MODELS" python3 - <<'PY'
import json, os, subprocess, sys
cfg="/sandbox/.openclaw/openclaw.json"; hf="/sandbox/.openclaw/.config-hash"
d=json.load(open(cfg)); changed=False
ao=d.setdefault("gateway",{}).setdefault("controlUi",{}).setdefault("allowedOrigins",[])
for o in os.environ["ORIGINS"].split():
    if o not in ao: ao.append(o); changed=True
provs=d.setdefault("models",{}).setdefault("providers",{})
# Use the provider the onboarder created (usually 'inference'); fall back to first.
pkey="inference" if "inference" in provs else (next(iter(provs), "inference"))
pmodels=provs.setdefault(pkey,{}).setdefault("models",[])
for mid in os.environ["MODELS"].split():
    if not any(m.get("id")==mid for m in pmodels):
        pmodels.append({"compat":{"supportsStore":False},"id":mid,"name":f"{pkey}/{mid}",
                        "reasoning":False,"input":["text"],
                        "cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0},
                        "contextWindow":131072,"maxTokens":64000}); changed=True
if not changed:
    print("openclaw.json: already-ok"); sys.exit(0)
json.dump(d, open(cfg,"w"), indent=2)
r=subprocess.run(["sh","-c","cd /sandbox/.openclaw && sha256sum openclaw.json"],capture_output=True,text=True)
open(hf,"w").write(r.stdout)
subprocess.run(["chown","sandbox:sandbox",cfg,hf]); subprocess.run(["chmod","660",cfg,hf])
print("openclaw.json: patched (origins + models:", os.environ["MODELS"], ")")
PY

# ── 5. Reload OpenClaw + verify ───────────────────────────────────────────────
export PATH="$HOME/.npm-global/bin:$HOME/.local/bin:$PATH"
say "Reloading director (nemoclaw $NEMO_NAME recover)"
nemoclaw "$NEMO_NAME" recover >/dev/null 2>&1 || true
sleep 3
CODE=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 -H 'Host: openclaw.lab.lan' https://localhost/ || true)
if [ "$CODE" = 200 ]; then
  say "openclaw.lab.lan -> 200 via Traefik. Done."
else
  echo "WARNING: openclaw.lab.lan returned $CODE (expected 200). Check the socat relay + tunnel:" >&2
  echo "  systemctl --user status openclaw-socat-relay; ss -tlnp | grep -E '1878[9]|${RELAY_PORT}'" >&2
  exit 1
fi
