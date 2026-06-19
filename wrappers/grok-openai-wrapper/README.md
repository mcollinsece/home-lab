# Grok OpenAI Wrapper

FastAPI server that exposes **Grok Build CLI** as an OpenAI-compatible endpoint.

## How It Works

This wrapper uses the exact same pattern as `claude-code-openai-wrapper`:

```
LiteLLM (OpenAI format)
  ↓ http://grok-wrapper:8001/v1
FastAPI Wrapper (this code)
  ↓ spawns subprocess
Grok Build CLI (official xAI CLI)
  ↓ OAuth via ~/.grok/auth.json
xAI API (Grok subscription)
```

The Grok Build CLI is authenticated via OAuth (device-code flow) and the credentials are stored in `~/.grok/auth.json`. The wrapper spawns `grok --single` as a subprocess and returns the output in OpenAI format.

## Architecture Benefits

- **Same pattern as claude-code-wrapper**: Proven, battle-tested approach
- **OAuth authentication**: Uses Grok subscription (no API keys needed)
- **Isolated in sandbox**: Runs in OpenShell sandbox with network policy
- **Full agent capabilities**: Grok Build CLI has tools, file edits, sessions
- **LiteLLM integration**: Director sees it as just another model

## Running in OpenShell Sandbox

The wrapper runs inside `openshell-grok-wrapper` sandbox with:
- Network policy allowing `api.x.ai` and `auth.x.ai` egress
- Connected to Docker `ai-net` with alias `grok-wrapper`
- Grok Build CLI installed at `/root/.grok/bin/grok`
- OAuth credentials synced from host to `/root/.grok/auth.json`

## Setup

1. **Authenticate on host:**
```bash
# Install Grok Build CLI (if not already installed)
curl -fsSL https://x.ai/cli/install.sh | bash

# Login (device-code OAuth flow)
grok login
```

2. **Create the sandbox:**
```bash
openshell sandbox create --name grok-wrapper --no-auto-providers \
  --policy ~/home-lab/openshell/policies/grok.yaml
```

3. **Start the wrapper:**
```bash
bootstrap/setup-grok-wrapper.sh
```

The script will:
- Sync OAuth credentials from host to sandbox
- Install Grok Build CLI in sandbox
- Install Python dependencies (`fastapi`, `uvicorn`, etc.)
- Start FastAPI wrapper
- Connect sandbox to `ai-net`

## Environment Variables

- `API_KEY`: Internal auth for LiteLLM → wrapper (default: `grok-internal-revproxy-key-2026`)
- `GROK_BIN`: Path to grok binary (default: `/root/.grok/bin/grok`)
- `GROK_CWD`: Working directory for agent (default: `/tmp/grok-workspace`)
- `PORT`: Wrapper server port (default: 8001)

## Testing

```bash
# Health check
curl http://localhost:8001/health

# Via LiteLLM
LITELLM_KEY=$(cat ~/home-lab/.secrets/litellm.env | grep LITELLM_MASTER_KEY | cut -d= -f2)
curl -s http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer ${LITELLM_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model":"grok-wrapper-local","messages":[{"role":"user","content":"What is 2+2?"}]}' \
  | python3 -m json.tool
```

## Model Mapping

- `grok-wrapper-local` → Grok (appears in OpenClaw picker)
- `grok-beta` → Grok (alias)

## Dependencies

**Python:**
- `fastapi` - web framework
- `uvicorn` - ASGI server
- `pydantic` - data validation

**System:**
- `grok` - Grok Build CLI (installed via https://x.ai/cli/install.sh)

## Grok CLI Usage

The wrapper uses these Grok CLI flags:
- `--single <prompt>` or `-p <prompt>` - Non-interactive mode
- `--output-format json` - Structured JSON output
- `--cwd <path>` - Working directory
- `--no-alt-screen` - Disable TUI

## Comparison to claude-code-wrapper

| Feature | claude-code-wrapper | grok-wrapper |
|---------|---------------------|--------------|
| Backend | api.anthropic.com | xAI (via auth.x.ai OAuth) |
| Auth method | OAuth/Pro subscription | OAuth/Grok subscription |
| CLI | `claude` | `grok` |
| Auth file | `~/.claude/.credentials.json` | `~/.grok/auth.json` |
| CLI mode | via `claude_agent_sdk` | direct subprocess `--single` |
| Port | 8000 | 8001 |
| Sandbox | `openshell-claude-revproxy` | `openshell-grok-wrapper` |

Both expose the same OpenAI-compatible interface to LiteLLM.

## Credential Sync

Like the Claude wrapper, credentials are synced from host to sandbox:

```bash
# Sync after grok login or token refresh
bootstrap/sync-grok-credentials.sh
```

This copies `~/.grok/auth.json` from host to `/root/.grok/auth.json` in the sandbox.
