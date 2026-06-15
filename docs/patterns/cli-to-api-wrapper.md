# CLI-to-API Wrapper Pattern

> **Design pattern for wrapping OAuth-authenticated agent CLIs as OpenAI-compatible HTTP endpoints**

This document describes the pattern used for `claude-code-wrapper-local` and `grok-wrapper-local`, 
and serves as a blueprint for creating wrappers for future CLIs (Codex, Gemini, Copilot, etc.).

---

## Table of Contents

- [Pattern Overview](#pattern-overview)
- [When to Use This Pattern](#when-to-use-this-pattern)
- [Architecture](#architecture)
- [Implementation Checklist](#implementation-checklist)
- [Code Structure](#code-structure)
- [OpenShell Integration](#openshell-integration)
- [LiteLLM Integration](#litellm-integration)
- [Testing Strategy](#testing-strategy)
- [Common Pitfalls](#common-pitfalls)
- [Examples](#examples)

---

## Pattern Overview

### The Problem

Modern AI agent CLIs (Claude Code, Grok Build, Codex, Gemini) use OAuth-based subscription 
authentication and have rich tool/file capabilities. However:

- They don't expose native HTTP APIs
- OAuth flow is interactive (can't be automated easily)
- They're designed for terminal use, not programmatic integration
- LiteLLM and similar proxies can't directly call them

### The Solution

**Wrap the CLI in a FastAPI application that:**

1. Spawns the authenticated CLI binary as a subprocess
2. Accepts OpenAI-format HTTP requests (`/v1/chat/completions`)
3. Converts requests → CLI prompts
4. Parses CLI output → OpenAI-format responses
5. Handles authentication via OAuth credentials on disk
6. Runs inside an isolated OpenShell sandbox

### The Result

```
OpenClaw / Any OpenAI-compatible client
    ↓
LiteLLM (routes by model name)
    ↓
Wrapper FastAPI (:800X)
    ↓
CLI subprocess (OAuth from disk)
    ↓
Provider API (Anthropic, xAI, OpenAI, Google)
```

The wrapper makes **subscription-based agents accessible through standard LLM APIs** without 
exposing credentials or requiring direct API keys.

---

## When to Use This Pattern

✅ **Use this pattern when:**

- CLI uses OAuth/subscription authentication (not just API keys)
- CLI is an agent with tools/file operations (not just completion)
- You want the CLI isolated in a sandbox
- You need OpenAI-compatible integration
- CLI output is parseable (JSON, structured text)

❌ **Don't use this pattern when:**

- CLI already has an HTTP API (use it directly)
- CLI requires interactive input mid-session (terminal-only features)
- You have direct API keys and can use the API directly
- CLI output is purely visual/TUI-based (no structured mode)

---

## Architecture

### Components

```
┌─────────────────────────────────────────────────────────────────┐
│ 1. FastAPI Wrapper Application                                 │
│    - HTTP server (:800X)                                        │
│    - OpenAI-compatible endpoints                                │
│    - Request validation                                         │
│    - Internal API key auth                                      │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│ 2. CLI Spawner                                                  │
│    - subprocess.run() or SDK wrapper                            │
│    - Prompt formatting                                          │
│    - Response parsing                                           │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│ 3. CLI Binary                                                   │
│    - OAuth credentials from disk (~/.cli/auth.json)            │
│    - Calls provider API                                         │
│    - Returns structured output                                  │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│ 4. Provider API (Anthropic, xAI, OpenAI, Google)              │
└─────────────────────────────────────────────────────────────────┘
```

### Isolation Layer (OpenShell Sandbox)

```
Host Machine
  ├── ~/.cli/auth.json (OAuth credentials)
  ├── bootstrap/setup-cli-wrapper.sh (deployment)
  └── bootstrap/sync-cli-credentials.sh (credential sync)
        ↓ (synced into sandbox)
OpenShell Sandbox (openshell-cli-wrapper)
  ├── /root/.cli/auth.json (synced credentials)
  ├── /sandbox/wrapper/src/main.py (FastAPI app)
  ├── /usr/local/bin/cli (or ~/.cli/bin/cli)
  └── /tmp/cli-workspace (working directory)
        ↓ (connected to Docker bridge)
Docker ai-net (172.18.x.x)
  └── alias: cli-wrapper (reachable from LiteLLM)
```

### Integration Layer (LiteLLM)

```
LiteLLM config.yaml:
  model_name: cli-wrapper-local
    → api_base: http://cli-wrapper:800X/v1
    → api_key: cli-internal-revproxy-key-2026

Request Flow:
  Client → LiteLLM (model=cli-wrapper-local)
         → Wrapper (http://cli-wrapper:800X/v1/chat/completions)
         → CLI subprocess
         → Provider API
         → Response
```

---

## Implementation Checklist

### Phase 1: Research & Setup

- [ ] **Install CLI locally** — Verify it works on host machine
- [ ] **Test OAuth flow** — Run `cli login`, confirm credentials location
- [ ] **Find credentials file** — Usually `~/.cli/auth.json` or `~/.cli/credentials.json`
- [ ] **Test CLI commands** — Identify non-interactive mode flags:
  - Single-shot mode: `--single`, `--non-interactive`, `--headless`
  - Output format: `--output-format json`, `--json`, `--format json`
  - Working directory: `--cwd`, `--directory`, `-C`
  - Disable TUI: `--no-tty`, `--no-alt-screen`, `--plain`
- [ ] **Parse output format** — Understand JSON structure CLI returns
- [ ] **Check network requirements** — What domains does CLI need? (for OpenShell policy)

### Phase 2: Create Wrapper Code

- [ ] **Create directory** — `wrappers/cli-openai-wrapper/`
- [ ] **Create `src/main.py`** — FastAPI application (see template below)
- [ ] **Create `requirements.txt`** — Dependencies (fastapi, uvicorn, pydantic)
- [ ] **Create `README.md`** — Attribution (if vendored) + integration docs
- [ ] **Test wrapper locally** — Run on host before sandboxing

### Phase 3: OpenShell Integration

- [ ] **Create network policy** — `openshell/policies/cli.yaml` (egress rules)
- [ ] **Create setup script** — `bootstrap/setup-cli-wrapper.sh`
- [ ] **Create credential sync script** — `bootstrap/sync-cli-credentials.sh`
- [ ] **Test in sandbox** — Create sandbox, run wrapper, verify CLI executes
- [ ] **Connect to ai-net** — `docker network connect --alias cli-wrapper ai-net $SANDBOX`

### Phase 4: LiteLLM Integration

- [ ] **Add model to `litellm/config.yaml`** — Route model name to wrapper endpoint
- [ ] **Add to OpenClaw picker** — Update `bootstrap/nemoclaw-director-probe.sh`
- [ ] **Test via LiteLLM** — `curl http://localhost:4000/v1/chat/completions`
- [ ] **Test in OpenClaw** — Select model, send test message

### Phase 5: Documentation & Testing

- [ ] **Create wrapper docs** — `docs/current/cli-wrapper.md` (comprehensive guide)
- [ ] **Document test cases** — Include reproduction commands
- [ ] **Update README.md** — Add wrapper to main project docs
- [ ] **Update todos.md** — Mark phase complete, note future work

---

## Code Structure

### Directory Layout

```
wrappers/cli-openai-wrapper/
├── src/
│   ├── __init__.py
│   └── main.py              # FastAPI application
├── requirements.txt          # Python dependencies
└── README.md                 # Attribution + integration docs
```

Keep it **simple**. Don't over-engineer with complex abstractions. The Claude wrapper has 
12 files because it's feature-rich; the Grok wrapper has 1 file. Match complexity to needs.

### FastAPI Template (`src/main.py`)

```python
"""
cli-openai-wrapper: Expose CLI as OpenAI-compatible endpoint

Pattern:
- FastAPI server on :800X
- Spawns CLI subprocess with OAuth credentials
- Converts OpenAI format ↔ CLI format
- Returns OpenAI-compatible responses
"""

from fastapi import FastAPI, HTTPException, Header
from pydantic import BaseModel
from typing import Optional, List
import os
import time
import logging
import subprocess
import json

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI(title="CLI OpenAI Wrapper")

# ── Configuration ──────────────────────────────────────────────────
WRAPPER_API_KEY = os.getenv("API_KEY", "cli-internal-revproxy-key-2026")
CLI_BIN = os.getenv("CLI_BIN", "/usr/local/bin/cli")
CLI_CWD = os.getenv("CLI_CWD", "/tmp/cli-workspace")

# ── Request Models ─────────────────────────────────────────────────
class ChatMessage(BaseModel):
    role: str
    content: str

class ChatCompletionRequest(BaseModel):
    model: str
    messages: List[ChatMessage]
    temperature: Optional[float] = 0.7
    max_tokens: Optional[int] = None
    stream: Optional[bool] = False

# ── Authentication ─────────────────────────────────────────────────
def verify_api_key(authorization: Optional[str] = Header(None)) -> bool:
    if not authorization:
        return False
    token = authorization.replace("Bearer ", "").strip()
    return token == WRAPPER_API_KEY

# ── Health Endpoints ───────────────────────────────────────────────
@app.get("/")
async def root():
    return {
        "status": "ok",
        "service": "cli-openai-wrapper"
    }

@app.get("/health")
async def health():
    cli_exists = os.path.exists(CLI_BIN)
    auth_exists = os.path.exists("/root/.cli/auth.json")  # adjust path
    return {
        "status": "healthy" if (cli_exists and auth_exists) else "unhealthy",
        "cli_binary": cli_exists,
        "authenticated": auth_exists
    }

# ── Models Endpoint ────────────────────────────────────────────────
@app.get("/v1/models")
async def list_models(authorization: Optional[str] = Header(None)):
    if not verify_api_key(authorization):
        raise HTTPException(status_code=401, detail="Invalid API key")
    
    return {
        "object": "list",
        "data": [
            {
                "id": "cli-wrapper-local",
                "object": "model",
                "created": int(time.time()),
                "owned_by": "provider"
            }
        ]
    }

# ── Chat Completions ───────────────────────────────────────────────
@app.post("/v1/chat/completions")
async def chat_completions(
    request: ChatCompletionRequest,
    authorization: Optional[str] = Header(None)
):
    """
    Main endpoint: spawns CLI subprocess, returns OpenAI-format response
    """
    if not verify_api_key(authorization):
        raise HTTPException(status_code=401, detail="Invalid API key")
    
    # Check CLI binary exists
    if not os.path.exists(CLI_BIN):
        raise HTTPException(status_code=500, detail=f"CLI not found: {CLI_BIN}")
    
    # Check authentication
    if not os.path.exists("/root/.cli/auth.json"):  # adjust path
        raise HTTPException(status_code=401, detail="CLI not authenticated")
    
    # Build prompt from messages
    prompt = "\n\n".join([
        f"{msg.role.capitalize()}: {msg.content}" 
        for msg in request.messages
    ])
    
    # Ensure workspace exists
    os.makedirs(CLI_CWD, exist_ok=True)
    
    try:
        # Spawn CLI subprocess
        # ADJUST THESE FLAGS FOR YOUR CLI:
        result = subprocess.run(
            [
                CLI_BIN,
                "--single",           # non-interactive mode
                prompt,               # the actual prompt
                "--output-format", "json",  # structured output
                "--cwd", CLI_CWD,     # working directory
                "--no-alt-screen"     # disable TUI
            ],
            capture_output=True,
            text=True,
            timeout=300,  # 5 minute timeout
            env=os.environ.copy()
        )
        
        if result.returncode != 0:
            logger.error(f"CLI failed: {result.stderr}")
            raise HTTPException(
                status_code=500,
                detail=f"CLI error: {result.stderr}"
            )
        
        # Parse CLI output
        try:
            cli_output = json.loads(result.stdout)
            # ADJUST THIS BASED ON YOUR CLI'S JSON STRUCTURE:
            response_text = cli_output.get("text", cli_output.get("response", result.stdout))
        except json.JSONDecodeError:
            # Fallback to plain text if JSON parsing fails
            response_text = result.stdout
        
        # Return OpenAI-format response
        return {
            "id": f"chatcmpl-cli-{int(time.time())}",
            "object": "chat.completion",
            "created": int(time.time()),
            "model": request.model,
            "choices": [{
                "index": 0,
                "message": {
                    "role": "assistant",
                    "content": response_text
                },
                "finish_reason": "stop"
            }],
            "usage": {
                "prompt_tokens": 0,
                "completion_tokens": 0,
                "total_tokens": 0
            }
        }
    
    except subprocess.TimeoutExpired:
        logger.error("CLI timeout")
        raise HTTPException(status_code=504, detail="CLI timeout")
    except Exception as e:
        logger.error(f"Error: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail=str(e))

# ── Run Server ─────────────────────────────────────────────────────
if __name__ == "__main__":
    import uvicorn
    port = int(os.getenv("PORT", "8002"))  # use unique port
    uvicorn.run(app, host="0.0.0.0", port=port)
```

### Key Customization Points

**Lines to adjust for each CLI:**

1. **Port number** — Use unique port (8000=claude, 8001=grok, 8002=codex, etc.)
2. **CLI binary path** — Where CLI is installed (`CLI_BIN`)
3. **Credentials path** — Where OAuth token lives (`/root/.cli/auth.json`)
4. **CLI flags** — Subprocess command arguments (varies per CLI)
5. **Output parsing** — How to extract response from CLI output
6. **Model name** — What to call it in LiteLLM (`cli-wrapper-local`)

---

## OpenShell Integration

### Network Policy Template (`openshell/policies/cli.yaml`)

```yaml
version: v1
kind: NetworkPolicy
metadata:
  name: cli
spec:
  egress:
    # Provider API endpoints (CUSTOMIZE FOR YOUR CLI)
    - to:
        - host: api.provider.com
        - host: auth.provider.com
      ports: [443]
      protocols: [tcp]
    
    # DNS (required)
    - to:
        - host: "*"
      ports: [53]
      protocols: [udp, tcp]
    
    # OpenShell gateway (for inference.local routing)
    - to:
        - host: host.openshell.internal
      ports: [17670]
      protocols: [tcp]
  
  filesystem:
    allow:
      - /tmp/**
      - /root/.cli/**  # ADJUST: where credentials live
      - /sandbox/**
      - /usr/local/bin/cli  # ADJUST: CLI binary path
  
  process:
    allow:
      - /sandbox/.uv/python/*/bin/python3
      - /sandbox/.uv/python/*/bin/uvicorn
      - /usr/local/bin/cli  # ADJUST: CLI binary
      - /usr/bin/bash
      - /usr/bin/curl  # for testing
```

**Key adjustments:**
- `api.provider.com` — Replace with actual API domain (e.g., `api.anthropic.com`, `api.x.ai`)
- `/root/.cli/**` — Path to CLI credentials
- `/usr/local/bin/cli` — Path to CLI binary (may be `/root/.cli/bin/cli` or similar)

### Setup Script Template (`bootstrap/setup-cli-wrapper.sh`)

```bash
#!/usr/bin/env bash
# Starts the cli-openai-wrapper inside the openshell-cli-wrapper sandbox

set -euo pipefail

say() { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }

_SB=$(docker ps --filter 'name=openshell-cli-wrapper-' --format '{{.Names}}' | head -1)
if [[ -z "$_SB" ]]; then
  echo "ERROR: openshell-cli-wrapper sandbox not running."
  echo "Create with: openshell sandbox create --name cli-wrapper --no-auto-providers --policy ~/home-lab/openshell/policies/cli.yaml"
  exit 1
fi
say "Sandbox: $_SB"

# ── 1. Sync CLI OAuth credentials ──────────────────────────────────
if [[ ! -f ~/.cli/auth.json ]]; then  # ADJUST: credentials path
  echo ""
  echo "CLI not authenticated on host. Run: cli login"
  echo "Then re-run this script."
  exit 1
fi

say "Syncing CLI OAuth credentials..."
"$(dirname "$0")/sync-cli-credentials.sh"

# ── 2. Install CLI in sandbox (if needed) ──────────────────────────
# OPTION A: CLI is installed via package manager
# say "Installing CLI in sandbox..."
# docker exec "$_SB" curl -fsSL https://cli.provider.com/install.sh | bash

# OPTION B: CLI is a single binary to download
# docker exec "$_SB" bash -c 'curl -L https://provider.com/cli-linux -o /usr/local/bin/cli && chmod +x /usr/local/bin/cli'

# OPTION C: Skip if CLI installed by other means

# ── 3. Connect sandbox to ai-net ────────────────────────────────────
say "Connecting sandbox to ai-net (alias: cli-wrapper)..."
if docker network inspect ai-net --format '{{range .Containers}}{{.Name}} {{end}}' | grep -q "$_SB"; then
  say "ai-net: already connected."
else
  docker network connect --alias cli-wrapper ai-net "$_SB"
  say "ai-net: connected."
fi

# ── 4. Copy wrapper code to sandbox ─────────────────────────────────
_UV_BIN="/sandbox/.uv/python/cpython-3.14.3-linux-x86_64-gnu/bin"
_WRAPPER_DIR="/sandbox/cli-wrapper"

say "Copying wrapper code to sandbox..."
docker exec "$_SB" mkdir -p "$_WRAPPER_DIR"
docker cp "$(dirname "$0")/../wrappers/cli-openai-wrapper/src" "$_SB:$_WRAPPER_DIR/"
docker cp "$(dirname "$0")/../wrappers/cli-openai-wrapper/requirements.txt" "$_SB:$_WRAPPER_DIR/"

# ── 5. Install wrapper dependencies ─────────────────────────────────
if ! docker exec "$_SB" "$_UV_BIN/python3" -c "import fastapi, uvicorn" 2>/dev/null; then
  say "Installing wrapper Python dependencies..."
  docker exec "$_SB" "$_UV_BIN/python3" -m pip install --quiet --break-system-packages \
    -r "$_WRAPPER_DIR/requirements.txt"
else
  say "Wrapper deps: already installed."
fi

# ── 6. Start wrapper ────────────────────────────────────────────────
say "Starting cli-openai-wrapper (OAuth / subscription)..."
docker exec "$_SB" pkill -f "uvicorn.*cli" 2>/dev/null || true
sleep 2
docker exec -d \
  -e API_KEY=cli-internal-revproxy-key-2026 \
  -e CLI_BIN=/usr/local/bin/cli \  # ADJUST
  -e CLI_CWD=/tmp/cli-workspace \
  -e "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$_UV_BIN" \
  "$_SB" \
  "$_UV_BIN/uvicorn" src.main:app --host 0.0.0.0 --port 8002 --app-dir "$_WRAPPER_DIR"

say "Waiting for wrapper to be ready..."
for i in {1..20}; do
  if docker exec "$_SB" ss -tlnp 2>/dev/null | grep -q ':8002'; then
    say "Wrapper listening on :8002"
    break
  fi
  sleep 1
done

if ! docker exec "$_SB" ss -tlnp 2>/dev/null | grep -q ':8002'; then
  echo "WARNING: wrapper did not start within 20s"
  exit 1
fi

say "Done. LiteLLM → cli-wrapper:8002 → CLI (OAuth subscription)"
```

### Credential Sync Script (`bootstrap/sync-cli-credentials.sh`)

```bash
#!/usr/bin/env bash
# Syncs CLI OAuth credentials from host to sandbox

set -euo pipefail

_SB=$(docker ps --filter 'name=openshell-cli-wrapper-' --format '{{.Names}}' | head -1)
if [[ -z "$_SB" ]]; then
  echo "ERROR: openshell-cli-wrapper sandbox not running."
  exit 1
fi

_HOST_CREDS="$HOME/.cli/auth.json"  # ADJUST: credentials path
_SANDBOX_CREDS="/root/.cli/auth.json"  # ADJUST

if [[ ! -f "$_HOST_CREDS" ]]; then
  echo "ERROR: No credentials at $_HOST_CREDS"
  echo "Run: cli login"
  exit 1
fi

echo "Syncing: $_HOST_CREDS → sandbox:$_SANDBOX_CREDS"
docker exec "$_SB" mkdir -p /root/.cli
docker cp "$_HOST_CREDS" "$_SB:$_SANDBOX_CREDS"
echo "Done."
```

---

## LiteLLM Integration

### Add to `litellm/config.yaml`

```yaml
model_list:
  # CLI Wrapper (OAuth subscription)
  - model_name: cli-wrapper-local
    litellm_params:
      model: openai/cli-model-name
      api_base: http://cli-wrapper:8002/v1  # ADJUST: port
      api_key: cli-internal-revproxy-key-2026
  
  # Alias (optional)
  - model_name: cli-beta
    litellm_params:
      model: openai/cli-model-name
      api_base: http://cli-wrapper:8002/v1
      api_key: cli-internal-revproxy-key-2026
```

### Add to OpenClaw Picker (`bootstrap/nemoclaw-director-probe.sh`)

Find the section that adds models to `openclaw.json` and add:

```bash
# Add cli-wrapper-local to model list
jq '.models.providers.litellm.models += [
  {
    "compat": {"supportsStore": false},
    "id": "cli-wrapper-local",
    "name": "litellm/cli-wrapper-local",
    "reasoning": false,
    "input": ["text"],
    "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0},
    "contextWindow": 131072,
    "maxTokens": 64000
  }
]' "$_OPENCLAW_JSON" > "$_OPENCLAW_JSON.tmp" && mv "$_OPENCLAW_JSON.tmp" "$_OPENCLAW_JSON"
```

---

## Testing Strategy

### 1. Local Testing (Before Sandboxing)

```bash
# Install CLI on host
cli login

# Test CLI directly
cli --single "What is 2+2?" --output-format json

# Run wrapper locally
cd wrappers/cli-openai-wrapper
pip install -r requirements.txt
CLI_BIN=/usr/local/bin/cli uvicorn src.main:app --port 8002

# Test wrapper
curl http://localhost:8002/health
curl http://localhost:8002/v1/chat/completions \
  -H "Authorization: Bearer cli-internal-revproxy-key-2026" \
  -H "Content-Type: application/json" \
  -d '{"model":"cli-wrapper-local","messages":[{"role":"user","content":"Hello"}]}'
```

### 2. Sandbox Testing

```bash
# Create sandbox
openshell sandbox create --name cli-wrapper \
  --no-auto-providers \
  --policy ~/home-lab/openshell/policies/cli.yaml

# Run setup script
bootstrap/setup-cli-wrapper.sh

# Test inside sandbox
_SB=$(docker ps --filter 'name=openshell-cli-wrapper-' --format '{{.Names}}' | head -1)
docker exec "$_SB" /usr/local/bin/cli --version
docker exec "$_SB" ss -tlnp | grep ':8002'
```

### 3. LiteLLM Integration Testing

```bash
# Test via LiteLLM
LITELLM_KEY=$(grep LITELLM_MASTER_KEY ~/.secrets/litellm.env | cut -d= -f2)
curl -s http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer ${LITELLM_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model":"cli-wrapper-local","messages":[{"role":"user","content":"What is 2+2?"}]}' \
  | python3 -m json.tool
```

### 4. OpenClaw End-to-End Testing

```bash
# Open openclaw.lab.lan in browser
# Select model: litellm/cli-wrapper-local
# Send test message
# Verify response

# Check OpenClaw logs
_DIR=$(docker ps --filter 'name=openshell-director' --format '{{.Names}}' | head -1)
docker exec "$_DIR" grep '"model":"cli-wrapper-local"' \
  /sandbox/.openclaw/agents/main/sessions/*.jsonl | tail -5
```

---

## Common Pitfalls

### 1. CLI Flags Change Between Versions

**Problem:** CLI is updated and flags change (e.g., `--headless` → `--single`)

**Solution:**
- Always test CLI flags after updates
- Check CLI `--help` for current options
- Document required CLI version in wrapper README

### 2. OAuth Token Expiration

**Problem:** Wrapper starts failing with auth errors after weeks/months

**Solution:**
- Document token lifetime (usually 30-90 days)
- Create systemd timer for `sync-cli-credentials.sh`
- Monitor wrapper logs for auth failures

### 3. Sandbox Not Connected to ai-net

**Problem:** LiteLLM can't reach wrapper (connection refused)

**Solution:**
- Verify: `docker network inspect ai-net | grep cli-wrapper`
- Reconnect: `docker network connect --alias cli-wrapper ai-net $SANDBOX`
- Check setup script runs this step

### 4. CLI Output Format Changes

**Problem:** CLI updates output JSON structure, wrapper breaks

**Solution:**
- Add fallbacks in parsing logic
- Log raw CLI output on parse errors
- Version-pin CLI if possible (e.g., via specific download URL)

### 5. Working Directory Permissions

**Problem:** CLI can't write files in `CLI_CWD`

**Solution:**
- Ensure `CLI_CWD` is writable by sandbox user
- OpenShell policy must allow writes to that path
- Use `/tmp/cli-workspace` as safe default

### 6. Network Policy Too Restrictive

**Problem:** CLI fails to connect to provider API

**Solution:**
- Check CLI logs for connection errors
- Add required domains to OpenShell policy
- Use `*:443` temporarily for debugging, then narrow down

### 7. Port Conflicts

**Problem:** Port 8002 already in use

**Solution:**
- Use unique port per wrapper (8000, 8001, 8002, 8003, ...)
- Document port allocation in main README
- Update LiteLLM config with correct port

---

## Examples

### Example 1: Codex Wrapper (Hypothetical)

```python
# wrappers/codex-openai-wrapper/src/main.py
CLI_BIN = os.getenv("CLI_BIN", "/usr/local/bin/codex")
CLI_CWD = os.getenv("CLI_CWD", "/tmp/codex-workspace")

# Spawn Codex CLI
result = subprocess.run(
    [CLI_BIN, "--non-interactive", prompt, "--format", "json"],
    capture_output=True,
    text=True,
    timeout=300,
    env=os.environ.copy()
)
```

**Network policy:**
```yaml
egress:
  - to:
      - host: api.openai.com
    ports: [443]
    protocols: [tcp]
```

**LiteLLM config:**
```yaml
- model_name: codex-wrapper-local
  litellm_params:
    model: openai/codex
    api_base: http://codex-wrapper:8003/v1
    api_key: codex-internal-revproxy-key-2026
```

### Example 2: Gemini Wrapper (Hypothetical)

```python
# wrappers/gemini-openai-wrapper/src/main.py
CLI_BIN = os.getenv("CLI_BIN", "/usr/local/bin/gemini")
CLI_CWD = os.getenv("CLI_CWD", "/tmp/gemini-workspace")

# Spawn Gemini CLI
result = subprocess.run(
    [CLI_BIN, "--no-tty", "--output=json", prompt],
    capture_output=True,
    text=True,
    timeout=300,
    env=os.environ.copy()
)
```

**Network policy:**
```yaml
egress:
  - to:
      - host: generativelanguage.googleapis.com
      - host: accounts.google.com
    ports: [443]
    protocols: [tcp]
```

**LiteLLM config:**
```yaml
- model_name: gemini-wrapper-local
  litellm_params:
    model: openai/gemini-pro
    api_base: http://gemini-wrapper:8004/v1
    api_key: gemini-internal-revproxy-key-2026
```

---

## Summary

### The Pattern in One Sentence

**Wrap an OAuth-authenticated agent CLI in FastAPI, spawn it as a subprocess, expose it as an OpenAI-compatible endpoint, isolate it in an OpenShell sandbox, and route to it via LiteLLM.**

### Checklist for New Wrapper

1. ✅ Research CLI (flags, auth, output format)
2. ✅ Create wrapper code (`wrappers/cli-openai-wrapper/`)
3. ✅ Create OpenShell policy (`openshell/policies/cli.yaml`)
4. ✅ Create setup scripts (`bootstrap/setup-cli-wrapper.sh`, `sync-cli-credentials.sh`)
5. ✅ Add to LiteLLM config (`litellm/config.yaml`)
6. ✅ Add to OpenClaw picker (`nemoclaw-director-probe.sh`)
7. ✅ Test locally, in sandbox, via LiteLLM, in OpenClaw
8. ✅ Document (`docs/current/cli-wrapper.md`)
9. ✅ Commit and push

### Port Allocation

| Wrapper | Port | Status |
|---|---|---|
| claude-code-wrapper | 8000 | ✅ Live |
| grok-wrapper | 8001 | ✅ Live |
| codex-wrapper | 8002 | ⬜ Planned (Phase 5) |
| gemini-wrapper | 8003 | ⬜ Planned (Phase 6) |
| copilot-wrapper | 8004 | ⬜ Future |

### Key Files for Each Wrapper

```
wrappers/cli-openai-wrapper/          ← Wrapper code
openshell/policies/cli.yaml           ← Network policy
bootstrap/setup-cli-wrapper.sh        ← Deployment
bootstrap/sync-cli-credentials.sh     ← Credential sync
litellm/config.yaml                   ← Model routing
docs/current/cli-wrapper.md           ← Documentation
```

---

**This pattern has been proven with:**
- ✅ claude-code-wrapper-local (Claude Code CLI)
- ✅ grok-wrapper-local (Grok Build CLI)

**Apply this pattern for:**
- ⬜ codex-wrapper-local (OpenAI Codex CLI)
- ⬜ gemini-wrapper-local (Google Gemini CLI)
- ⬜ copilot-wrapper-local (GitHub Copilot CLI)
- ⬜ Any future OAuth-based agent CLI

The pattern is **battle-tested**, **reproducible**, and **scales** to any OAuth-authenticated CLI that can run in non-interactive mode.
