# Grok Wrapper Deployment Guide

## Architecture Overview

The Grok wrapper uses the **exact same pattern** as `claude-code-wrapper-local`:

```
OpenClaw Director
  ↓ selects litellm/grok-wrapper-local
LiteLLM (:4000)
  ↓ routes to http://grok-wrapper:8001/v1
grok-wrapper sandbox (FastAPI on :8001)
  ↓ spawns subprocess
Grok Build CLI (--single --output-format json)
  ↓ OAuth via ~/.grok/auth.json
xAI API (Grok subscription)
```

**Pattern match:** Just like `claude` CLI with OAuth, but for Grok.

## Quick Start

**Prerequisites:**
- Grok subscription (like Claude Pro/Max)
- Grok Build CLI installed and authenticated on host

1. **Authenticate on host** (one-time):
   ```bash
   # Install Grok Build CLI
   curl -fsSL https://x.ai/cli/install.sh | bash
   
   # Login via device-code OAuth
   grok login
   ```

2. **Sandbox already created** ✅ (`grok-wrapper` is Ready)

3. **Start the wrapper:**
   ```bash
   bootstrap/setup-grok-wrapper.sh
   ```

4. **Restart LiteLLM:**
   ```bash
   docker compose -f docker/compose.yml restart litellm
   ```

5. **Update director:**
   ```bash
   systemctl --user restart nemoclaw-director-control-ui
   ```

6. **Test:**
   ```bash
   LITELLM_KEY=$(cat ~/.secrets/litellm.env | grep LITELLM_MASTER_KEY | cut -d= -f2)
   curl -s http://localhost:4000/v1/chat/completions \
     -H "Authorization: Bearer ${LITELLM_KEY}" \
     -d '{"model":"grok-wrapper-local","messages":[{"role":"user","content":"Hi Grok!"}]}' \
     | python3 -m json.tool
   ```

7. **Use in OpenClaw:**
   - Open https://openclaw.lab.lan/
   - Select `litellm/grok-wrapper-local`
   - Chat with Grok!

## What Was Built

**Files:**
- `wrappers/grok-openai-wrapper/src/main.py` - FastAPI wrapper (spawns `grok --single`)
- `wrappers/grok-openai-wrapper/requirements.txt` - Python deps
- `openshell/policies/grok.yaml` - Network policy (allows api.x.ai + auth.x.ai)
- `bootstrap/setup-grok-wrapper.sh` - Setup script
- `bootstrap/sync-grok-credentials.sh` - OAuth credential sync

**Updates:**
- `litellm/config.yaml` - Added `grok-wrapper-local` + `grok-beta` routes
- `bootstrap/nemoclaw-director-probe.sh` - Adds grok model to director picker

**Sandbox:**
- `grok-wrapper` - OpenShell sandbox (Ready ✅)

## Dependencies

Inside the sandbox:
- **Python:** `fastapi`, `uvicorn`, `pydantic`
- **System:** `grok` CLI (installed via official xAI install script)

## How Grok CLI Works

The Grok Build CLI (https://x.ai/news/grok-build-cli) is xAI's official agent CLI, similar to Claude Code. Key features:

- **OAuth authentication** via device-code flow
- **Full agent capabilities** - file edits, tool use, sessions
- **Single-shot mode** via `--single` flag
- **JSON output** via `--output-format json`
- **Credentials stored** in `~/.grok/auth.json`

The wrapper spawns:
```bash
grok --single "<prompt>" --output-format json --cwd /tmp/grok-workspace --no-alt-screen
```

## Pattern Comparison

| Component | claude-code-wrapper | grok-wrapper |
|-----------|---------------------|--------------|
| Backend | api.anthropic.com | xAI (auth.x.ai OAuth) |
| Auth | OAuth/Pro | OAuth/Grok subscription |
| CLI | `claude` | `grok` |
| Auth file | `~/.claude/.credentials.json` | `~/.grok/auth.json` |
| Spawn method | `claude_agent_sdk.query()` | `subprocess.run([grok, --single])` |
| Wrapper port | 8000 | 8001 |
| Sandbox | `openshell-claude-revproxy` | `openshell-grok-wrapper` |
| Sync script | `sync-claude-credentials.sh` | `sync-grok-credentials.sh` |

## Troubleshooting

**Grok CLI not found:**
```bash
_SB=$(docker ps --filter 'name=openshell-grok-wrapper-' --format '{{.Names}}' | head -1)
docker exec "$_SB" /root/.grok/bin/grok --help
```

**Auth not synced:**
```bash
# Re-sync credentials
bootstrap/sync-grok-credentials.sh

# Verify in sandbox
docker exec "$_SB" cat /root/.grok/auth.json
```

**Wrapper health check:**
```bash
curl http://localhost:8001/health
# Should show: "grok_authenticated": true, "grok_binary": true
```

**Check logs:**
```bash
docker logs "$_SB" --tail 100 | grep -E "(grok|uvicorn|ERROR)"
```

**Model not in OpenClaw picker:**
```bash
# Re-run probe to patch director
systemctl --user restart nemoclaw-director-control-ui
sleep 5

# Verify model is in openclaw.json
docker exec openshell-director-* cat /sandbox/.openclaw/openclaw.json | \
  python3 -m json.tool | grep -B2 -A8 grok-wrapper-local
```

## OAuth Token Refresh

Like Claude Code, Grok OAuth tokens expire. To refresh:

```bash
# On host
grok login

# Sync to sandbox
bootstrap/sync-grok-credentials.sh

# Restart wrapper
bootstrap/setup-grok-wrapper.sh
```

## Next Steps

This pattern extends to any OAuth-authenticated agent CLI:
1. Authenticate CLI on host
2. Sync credentials to sandbox
3. Spawn CLI in single-shot mode
4. Wrap output in OpenAI format
5. Expose via LiteLLM

Future candidates:
- **Codex** (if GitHub releases OAuth CLI)
- **Gemini** (if Google releases agent CLI)
- **Any xAI model** via same Grok CLI
