#!/usr/bin/env bash
#
# bootstrap/nemoclaw-director-probe.sh
#
# Wrapper invoked by the systemd --user service nemoclaw-director-control-ui.service.
# Waits for the director sandbox to reach "Ready" phase, then:
#   1. Applies persistent openclaw.json patches (CORS, litellm-only provider)
#   2. Writes a pass-through openclaw shim (config drives auth/bind)
#   3. Connects the director Docker container to ai-net (alias: openclaw-director)
#      so Traefik can reach it directly — no SSH tunnel or socat needed
#   4. Starts openclaw gateway as the sandbox user inside the director container
#      (NODE_TLS_REJECT_UNAUTHORIZED=0 required: OpenShell proxy presents a self-signed
#       "OpenShell Sandbox CA" cert for inference.local that Node.js rejects by default)
#
# Traefik static route (traefik/dynamic/openclaw-nemoclaw.yml) points to
# http://openclaw-director:18789 — stable across director rebuilds.
#
# Re-run this service after: nemoclaw director rebuild, reboot, or openclaw crash.

set -euo pipefail

say() { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }

# Resolve nemoclaw regardless of PATH (systemd user services may not have ~/.npm-global/bin)
if command -v nemoclaw >/dev/null 2>&1; then
  NEMOCLAW=nemoclaw
else
  NEMOCLAW="node $HOME/.nemoclaw/source/bin/nemoclaw.js"
fi

say "Waiting for director sandbox to reach Phase: Ready (timeout 5m)..."
for _ in {1..60}; do
  if $NEMOCLAW director status 2>/dev/null | grep -q "Phase:.*Ready"; then
    break
  fi
  sleep 5
done

if ! $NEMOCLAW director status 2>/dev/null | grep -q "Phase:.*Ready"; then
  echo "ERROR: director never reached Ready phase. See:"
  echo "  nemoclaw director status"
  echo "  journalctl --user -u nemoclaw-director-control-ui -xe"
  exit 1
fi

# ── Find director Docker container ─────────────────────────────────────────────
_DIRECTOR_CONTAINER=$(docker ps --filter 'name=openshell-director-' --format '{{.Names}}' | head -1)
if [[ -z "$_DIRECTOR_CONTAINER" ]]; then
  echo "ERROR: director Docker container not found (docker ps)."
  exit 1
fi
say "Director container: $_DIRECTOR_CONTAINER"

# ── Persistent openclaw patches (CORS) ──────────────────────────────────────────
# Patch /sandbox/.openclaw/openclaw.json (sandbox user's home is /sandbox).
# The probe uses docker exec -u root to write the files, then fixes ownership.
# The hash file is updated after each write so openclaw's startup integrity check passes.

# ── 1. CORS patch ───────────────────────────────────────────────────────────────
say "Patching openclaw.json allowedOrigins for openclaw.lab.lan (CORS fix)..."
_PATCH_RESULT=$(docker exec -i -u root "$_DIRECTOR_CONTAINER" python3 - << 'PY'
import json, subprocess, sys
cfg = "/sandbox/.openclaw/openclaw.json"
hf  = "/sandbox/.openclaw/.config-hash"
try:
    with open(cfg) as f:
        data = json.load(f)
    cu = data.setdefault("gateway", {}).setdefault("controlUi", {})
    origins = cu.setdefault("allowedOrigins", [])
    needed = ["https://openclaw.lab.lan", "http://127.0.0.1:18789"]
    added = [o for o in needed if o not in origins]
    for o in added:
        origins.append(o)
    if added:
        with open(cfg, "w") as f:
            json.dump(data, f, indent=2)
        r = subprocess.run(
            ["sh", "-c", "cd /sandbox/.openclaw && sha256sum openclaw.json"],
            capture_output=True, text=True
        )
        if r.returncode != 0:
            print("hash-error: " + r.stderr.strip(), file=sys.stderr)
            sys.exit(1)
        with open(hf, "w") as f:
            f.write(r.stdout)
        subprocess.run(["chown", "sandbox:sandbox", hf])
        subprocess.run(["chmod", "660", hf])
        print("patched: " + str(added))
    else:
        print("already-ok")
except Exception as e:
    print("error: " + str(e), file=sys.stderr)
    sys.exit(1)
PY
2>&1) || true
say "CORS patch: ${_PATCH_RESULT}"

# ── 2. Provider rename: inference → litellm ─────────────────────────────────────
say "Renaming inference provider to litellm in openclaw.json..."
_RENAME_RESULT=$(docker exec -i -u root "$_DIRECTOR_CONTAINER" python3 - << 'PY'
import json, subprocess, sys
cfg = "/sandbox/.openclaw/openclaw.json"
hf  = "/sandbox/.openclaw/.config-hash"
try:
    with open(cfg) as f:
        data = json.load(f)
    providers = data.setdefault("models", {}).setdefault("providers", {})
    if "litellm" in providers:
        print("already-ok")
        sys.exit(0)
    if "inference" not in providers:
        print("skip: no inference provider")
        sys.exit(0)
    providers["litellm"] = providers.pop("inference")
    for m in providers["litellm"].get("models", []):
        if m.get("name") == "inference/claude-sonnet-4-6":
            m["name"] = "litellm/claude-sonnet-4-6"
    try:
        p = data["agents"]["defaults"]["model"]["primary"]
        if p == "inference/claude-sonnet-4-6":
            data["agents"]["defaults"]["model"]["primary"] = "litellm/claude-sonnet-4-6"
    except (KeyError, TypeError):
        pass
    with open(cfg, "w") as f:
        json.dump(data, f, indent=2)
    r = subprocess.run(
        ["sh", "-c", "cd /sandbox/.openclaw && sha256sum openclaw.json"],
        capture_output=True, text=True
    )
    with open(hf, "w") as f:
        f.write(r.stdout)
    subprocess.run(["chown", "sandbox:sandbox", hf])
    subprocess.run(["chmod", "660", hf])
    print("patched: renamed inference → litellm")
except Exception as e:
    print("error: " + str(e), file=sys.stderr)
    sys.exit(1)
PY
2>&1) || true
say "Provider rename: ${_RENAME_RESULT}"

# ── 3a. Ensure claude-code-wrapper-local model is in providers.litellm.models ──────
say "Ensuring claude-code-wrapper-local model entry in openclaw.json litellm provider..."
docker exec -i -u root "$_DIRECTOR_CONTAINER" python3 - << 'PY'
import json, subprocess, sys
cfg = "/sandbox/.openclaw/openclaw.json"
hf  = "/sandbox/.openclaw/.config-hash"
try:
    with open(cfg) as f:
        data = json.load(f)
    provider_models = data.setdefault("models", {}).setdefault("providers", {}).setdefault("litellm", {}).setdefault("models", [])
    new_id = "claude-code-wrapper-local"
    if any(m.get("id") == new_id for m in provider_models):
        print("already-ok")
        sys.exit(0)
    provider_models.append({
        "compat": {"supportsStore": False},
        "id": new_id,
        "name": "litellm/claude-code-wrapper-local",
        "reasoning": False,
        "input": ["text"],
        "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0},
        "contextWindow": 131072,
        "maxTokens": 64000
    })
    with open(cfg, "w") as f:
        json.dump(data, f, indent=2)
    r = subprocess.run(["sh", "-c", "cd /sandbox/.openclaw && sha256sum openclaw.json"],
                       capture_output=True, text=True)
    with open(hf, "w") as f:
        f.write(r.stdout)
    subprocess.run(["chown", "sandbox:sandbox", hf])
    subprocess.run(["chmod", "660", hf])
    print("added claude-code-wrapper-local to litellm provider models")
except Exception as e:
    print("error: " + str(e), file=sys.stderr)
PY

# ── 3b. Ensure grok-wrapper-local model is in providers.litellm.models ──────────
say "Ensuring grok-wrapper-local model entry in openclaw.json litellm provider..."
docker exec -i -u root "$_DIRECTOR_CONTAINER" python3 - << 'PY'
import json, subprocess, sys
cfg = "/sandbox/.openclaw/openclaw.json"
hf  = "/sandbox/.openclaw/.config-hash"
try:
    with open(cfg) as f:
        data = json.load(f)
    provider_models = data.setdefault("models", {}).setdefault("providers", {}).setdefault("litellm", {}).setdefault("models", [])
    new_id = "grok-wrapper-local"
    if any(m.get("id") == new_id for m in provider_models):
        print("already-ok")
        sys.exit(0)
    provider_models.append({
        "compat": {"supportsStore": False},
        "id": new_id,
        "name": "litellm/grok-wrapper-local",
        "reasoning": True,
        "input": ["text", "image"],
        "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0},
        "contextWindow": 131072,
        "maxTokens": 65536
    })
    with open(cfg, "w") as f:
        json.dump(data, f, indent=2)
    r = subprocess.run(["sh", "-c", "cd /sandbox/.openclaw && sha256sum openclaw.json"],
                       capture_output=True, text=True)
    with open(hf, "w") as f:
        f.write(r.stdout)
    subprocess.run(["chown", "sandbox:sandbox", hf])
    subprocess.run(["chmod", "660", hf])
    print("added grok-wrapper-local to litellm provider models")
except Exception as e:
    print("error: " + str(e), file=sys.stderr)
PY

# ── 3. Litellm-only model config ────────────────────────────────────────────────
say "Ensuring litellm model entry is explicit for session picker (no anthropic/claude-agent)..."
_CLICFG_RESULT=$(docker exec -i -u root "$_DIRECTOR_CONTAINER" python3 - << 'PY'
import json, subprocess, sys
cfg = "/sandbox/.openclaw/openclaw.json"
hf  = "/sandbox/.openclaw/.config-hash"
try:
    with open(cfg) as f:
        data = json.load(f)
    defaults = data.setdefault("agents", {}).setdefault("defaults", {})
    models_cfg = defaults.setdefault("models", {})
    added = []
    for mname in ["litellm/claude-sonnet-4-6", "litellm/claude-code-wrapper-local", "litellm/grok-wrapper-local"]:
        if mname not in models_cfg:
            models_cfg[mname] = {}
            added.append(mname)
    # Remove any old anthropic or claude-agent entries
    for key in list(models_cfg.keys()):
        if key.startswith("anthropic/") or key.startswith("claude-agent/"):
            del models_cfg[key]
            added.append("removed:" + key)
    providers = data.setdefault("models", {}).setdefault("providers", {})
    for bad in ["anthropic", "claude-agent"]:
        if bad in providers:
            del providers[bad]
            added.append("removed-provider:" + bad)
    if not added:
        print("already-ok")
        sys.exit(0)
    with open(cfg, "w") as f:
        json.dump(data, f, indent=2)
    r = subprocess.run(
        ["sh", "-c", "cd /sandbox/.openclaw && sha256sum openclaw.json"],
        capture_output=True, text=True
    )
    with open(hf, "w") as f:
        f.write(r.stdout)
    subprocess.run(["chown", "sandbox:sandbox", hf])
    subprocess.run(["chmod", "660", hf])
    print("patched: " + str(added))
except Exception as e:
    print("error: " + str(e), file=sys.stderr)
    sys.exit(1)
PY
2>&1) || true
say "litellm-only model config: ${_CLICFG_RESULT}"

# ── 4. Pass-through openclaw shim ───────────────────────────────────────────────
# The shim at /usr/local/lib/node_modules/openclaw/openclaw.mjs just passes through
# to dist/entry.js without forcing --auth none or --bind loopback.
# Config drives auth (token + dangerouslyDisableDeviceAuth) and bind (auto = 0.0.0.0 in container).
_OC_MJS=/usr/local/lib/node_modules/openclaw/openclaw.mjs
if ! docker exec -u root "$_DIRECTOR_CONTAINER" \
     grep -q "pass-through" "$_OC_MJS" 2>/dev/null; then
  say "Writing pass-through openclaw shim..."
  docker exec -i -u root "$_DIRECTOR_CONTAINER" python3 - << 'PY'
content = '''#!/usr/bin/env node
// Shim: pass-through — config drives auth (token + dangerouslyDisableDeviceAuth) and bind (auto=0.0.0.0 in container)
await import("./dist/entry.js");
'''
with open('/usr/local/lib/node_modules/openclaw/openclaw.mjs', 'w') as f:
    f.write(content)
import os, subprocess
os.chmod('/usr/local/lib/node_modules/openclaw/openclaw.mjs', 0o755)
# Ensure /usr/local/bin/openclaw is a symlink to openclaw.mjs
r = subprocess.run(['test', '-L', '/usr/local/bin/openclaw'], capture_output=True)
if r.returncode != 0:
    subprocess.run(['rm', '-f', '/usr/local/bin/openclaw'])
    subprocess.run(['ln', '-s', '/usr/local/lib/node_modules/openclaw/openclaw.mjs', '/usr/local/bin/openclaw'])
print('shim written')
PY
else
  say "Pass-through shim: already installed."
fi

# ── 5. Connect director to ai-net (alias: openclaw-director) ────────────────────
# Traefik routes http://openclaw-director:18789 → director container (stable alias).
# No SSH tunnel or socat needed.
say "Connecting director to ai-net (alias: openclaw-director)..."
if docker network inspect ai-net --format '{{range .Containers}}{{.Name}} {{end}}' | grep -q "$_DIRECTOR_CONTAINER"; then
  say "ai-net: already connected."
else
  docker network disconnect ai-net "$_DIRECTOR_CONTAINER" 2>/dev/null || true
  docker network connect --alias openclaw-director ai-net "$_DIRECTOR_CONTAINER"
  say "ai-net: connected (alias openclaw-director)."
fi

# ── 6. Kill any stale SSH tunnel or socat (legacy from Tailscale era) ───────────
pkill -f 'socat TCP-LISTEN:18789' 2>/dev/null || true
pkill -f 'openshell ssh-proxy.*18789\|ssh.*18789.*sandbox' 2>/dev/null || true

# ── 7. Start openclaw gateway inside the director container ─────────────────────
# Run as sandbox user with HOME=/sandbox so it reads /sandbox/.openclaw/openclaw.json.
# Config uses token auth + dangerouslyDisableDeviceAuth (no prompt needed for UI).
# Container environment makes openclaw default to bind=auto (0.0.0.0).
say "Starting openclaw gateway inside director (as sandbox, HOME=/sandbox)..."
# Kill any existing openclaw process in the director
docker exec -u root "$_DIRECTOR_CONTAINER" pkill -x openclaw 2>/dev/null || true
sleep 2
docker exec -d -e HOME=/sandbox -e NODE_TLS_REJECT_UNAUTHORIZED=0 -u sandbox "$_DIRECTOR_CONTAINER" openclaw gateway run --port 18789

say "Waiting for openclaw gateway to be ready on port 18789..."
for i in {1..30}; do
  if docker exec -u root "$_DIRECTOR_CONTAINER" ss -tlnp 2>/dev/null | grep -q ':18789'; then
    say "openclaw gateway is listening on :18789 inside director."
    break
  fi
  sleep 1
done

if ! docker exec -u root "$_DIRECTOR_CONTAINER" ss -tlnp 2>/dev/null | grep -q ':18789'; then
  echo "WARNING: openclaw gateway did not start within 30s. Check logs in director."
fi

say "Probe complete. openclaw.lab.lan → Traefik → openclaw-director:18789"
say "  (no SSH tunnel or socat; director is on ai-net with alias openclaw-director)"
