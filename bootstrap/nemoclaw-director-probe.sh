#!/usr/bin/env bash
#
# bootstrap/nemoclaw-director-probe.sh
#
# Wrapper invoked by the systemd --user service nemoclaw-director-control-ui.service.
# Waits for the director sandbox to reach "Ready" phase, then runs
# `nemoclaw director connect --probe-only` (non-interactively) to establish
# the port forward for the Control UI on 18789 (so openclaw.lab.lan works).
#
# This must be re-run after every reboot and after every `nemoclaw director rebuild`
# (the recreate script will restart the service for you).
#
# The service is oneshot + RemainAfterExit, so "active (exited)" after success
# and will be restarted on failure or explicit restart.

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

# ── Persistent openclaw patches (CORS + auth) ────────────────────────────────
# These run on every probe invocation (boot + rebuild) so they survive
# nemoclaw director rebuild (which starts a fresh container from the image).
#
# 1. CORS: add https://openclaw.lab.lan to gateway.controlUi.allowedOrigins
#    and recompute .config-hash so the startup integrity check passes.
# 2. Auth wrapper: replace /usr/local/bin/openclaw with a shim that adds
#    --auth none to every "gateway run" invocation, so the Control UI at
#    openclaw.lab.lan never requires a token (safe on a local home network).
#
# After either change, openclaw must be killed; connect --probe-only (below)
# restarts it via SSH with the patched config and wrapper in place.
# openshell-sandbox (PID 1) does NOT auto-restart openclaw on its own.

_DIRECTOR_CONTAINER=$(docker ps --filter 'name=openshell-director-' --format '{{.Names}}' | head -1)
_NEED_RESTART=false

if [[ -n "$_DIRECTOR_CONTAINER" ]]; then

  # ── 1. CORS patch ───────────────────────────────────────────────────────────
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
  if echo "$_PATCH_RESULT" | grep -q "^patched:"; then
    _NEED_RESTART=true
  fi

  # ── 2. Provider rename: inference → litellm ─────────────────────────────────
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
  if echo "$_RENAME_RESULT" | grep -q "^patched:"; then
    _NEED_RESTART=true
  fi

  # ── 3b. Ensure litellm model is explicit in agents.defaults (for session picker)
  # We are stripping out anthropic / claude-cli / claude-agent providers for now.
  # Only keeping the working litellm (OpenAI-compatible via LiteLLM) path.
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
    # Only ensure litellm is explicitly listed (no claude-cli runtimes, no anthropic, no claude-agent)
    added = []
    if "litellm/claude-sonnet-4-6" not in models_cfg:
        models_cfg["litellm/claude-sonnet-4-6"] = {}
        added.append("litellm/claude-sonnet-4-6")
    # Clean up any old anthropic or claude-agent entries if present (user wants only litellm)
    for key in list(models_cfg.keys()):
        if key.startswith("anthropic/") or key.startswith("claude-agent/"):
            del models_cfg[key]
            added.append("removed:" + key)
    providers = data.setdefault("models", {}).setdefault("providers", {})
    # Remove anthropic and claude-agent providers if present
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
  if echo "$_CLICFG_RESULT" | grep -q "^patched:"; then
    _NEED_RESTART=true
  fi

  # (claude / anthropic / claude-agent sync + wrapper removed per user request.
  #   We are running with JUST the litellm provider for now.)
  #   The claude binary/credentials sync and the routing wrapper have been ripped out.

  # ── 4. Auth wrapper ─────────────────────────────────────────────────────────
  # Inject --auth none into every "openclaw gateway run" call so the Control UI
  # never demands a token. We write a minimal Node.js ESM shim directly into
  # /usr/local/lib/node_modules/openclaw/openclaw.mjs (the npm package entry
  # that /usr/local/bin/openclaw is symlinked to). The shim patches process.argv
  # and then imports ./dist/entry.js — no bash wrapper, no extension issues.
  #
  # Detection: presence of "inject --auth none" in openclaw.mjs.
  # After nemoclaw director rebuild the container starts from a fresh image,
  # restoring the original openclaw.mjs; the probe re-applies the shim.
  _OC_MJS=/usr/local/lib/node_modules/openclaw/openclaw.mjs
  if ! docker exec -u root "$_DIRECTOR_CONTAINER" \
       grep -q "inject --auth none --bind loopback" "$_OC_MJS" 2>/dev/null; then
    say "Writing openclaw --auth none shim (disables Control UI token prompt)..."
    docker exec -i -u root "$_DIRECTOR_CONTAINER" bash << 'DOCKERWRAP'
set -e
MPATH=/usr/local/lib/node_modules/openclaw/openclaw.mjs
cat > "$MPATH" << 'NODEEOF'
#!/usr/bin/env node
// Shim: inject --auth none --bind loopback into "openclaw gateway run" (no token required on local home network)
// --bind loopback is required because openclaw refuses bind=auto (0.0.0.0) when auth=none
const args = process.argv.slice(2);
if (args.length >= 2 && args[0] === "gateway" && args[1] === "run"
    && !args.includes("--auth") && !args.includes("--bind")) {
  process.argv = [...process.argv.slice(0, 2), "gateway", "run",
    "--auth", "none", "--bind", "loopback", ...args.slice(2)];
}
await import("./dist/entry.js");
NODEEOF
chmod 755 "$MPATH"
# Ensure /usr/local/bin/openclaw is the correct symlink (rebuild may restore a regular file)
if [ ! -L /usr/local/bin/openclaw ]; then
  rm -f /usr/local/bin/openclaw
  ln -s "$MPATH" /usr/local/bin/openclaw
fi
echo "shim written"
DOCKERWRAP
    _NEED_RESTART=true
    say "Auth shim installed."
  else
    say "Auth shim: already installed."
  fi

  # ── Restart if anything changed ─────────────────────────────────────────────
  if [[ "$_NEED_RESTART" == true ]]; then
    say "Killing openclaw so connect --probe-only restarts it with all patches applied..."
    docker exec "$_DIRECTOR_CONTAINER" pkill -x openclaw 2>/dev/null || true
    sleep 3
  fi

fi

say "Director Ready. Running nemoclaw director connect --probe-only to wire up 18789 forward..."
exec $NEMOCLAW director connect --probe-only
