# Claude Code Wrapper (claude-code-wrapper-local)

> **Status:** ✅ Live — OAuth/Pro subscription, spawns Claude Code CLI, OpenAI-compatible endpoint

---

## What It Is

`claude-code-wrapper-local` is a FastAPI application that wraps the **Claude Code CLI** (Anthropic's official agent CLI) via the `claude_agent_sdk` and exposes it as an OpenAI-compatible HTTP endpoint. This allows OpenClaw and other LiteLLM clients to invoke the full Claude Code agent (with tools, file operations, multi-turn sessions) as if it were a standard LLM API endpoint.

**Key properties:**
- **No API keys** — uses OAuth subscription authentication (Claude Pro/Max subscription required)
- **Full agent capability** — not just chat completion; Claude Code has tools, edits, shell commands, MCP servers
- **Isolated execution** — runs inside an OpenShell sandbox with network policy enforcement
- **OpenAI-compatible** — accepts `/v1/chat/completions` requests in OpenAI format

---

## Architecture

```
OpenClaw / LiteLLM client
    │
    ├─► POST /v1/chat/completions
    │   model: claude-code-wrapper-local
    │   Authorization: Bearer claude-code-internal-revproxy-key-2026
    │
    ▼
LiteLLM (:4000, Docker ai-net)
    │
    ├─► http://claude-code-wrapper:8000/v1/chat/completions
    │   (routes to openshell-claude-revproxy sandbox via ai-net alias)
    │
    ▼
openshell-claude-revproxy sandbox
    │
    ├─► FastAPI (uvicorn :8000)
    │   /sandbox/wrapper/claude-code-openai-wrapper/src/main.py
    │
    ├─► claude_agent_sdk.query()
    │   spawns bundled claude CLI as subprocess
    │
    └─► Claude Code CLI (OAuth) → api.anthropic.com → Anthropic API
```

---

## File Locations

| Component | Path | Description |
|---|---|---|
| **Wrapper repo** | `wrappers/claude-code-openai-wrapper/` | Git submodule (RichardAtCT/claude-code-openai-wrapper) |
| **Setup script** | `bootstrap/setup-claude-revproxy.sh` | Creates sandbox, syncs creds, starts wrapper |
| **Credential sync** | `bootstrap/sync-claude-credentials.sh` | Copies host `~/.claude/.credentials.json` → sandbox `/root/.claude/` |
| **Network policy** | `openshell/policies/claude-code.yaml` | OpenShell egress policy (allows `api.anthropic.com`) |
| **LiteLLM config** | `litellm/config.yaml` | Routes `claude-code-wrapper-local`, `claude-code-sonnet`, `claude-code/sonnet` to `http://claude-code-wrapper:8000/v1` |

**Inside the sandbox:**
| Path | What it is |
|---|---|
| `/root/.claude/.credentials.json` | OAuth credentials (synced from host) |
| `/sandbox/wrapper/` | Wrapper code (cloned repo) |
| `/tmp/` | Claude Code working directory (`CLAUDE_CWD`) |

---

## Credentials

| Credential | Location | How it's used |
|---|---|---|
| **Claude OAuth token** | Host: `~/.claude/.credentials.json` → Sandbox: `/root/.claude/.credentials.json` | Claude Code CLI reads this automatically; synced by `sync-claude-credentials.sh` |
| **Wrapper internal API key** | `claude-code-internal-revproxy-key-2026` | LiteLLM → wrapper auth; set via `API_KEY` env var when wrapper starts |

**No AWS credentials.** The wrapper uses OAuth/Pro subscription, not Bedrock.

**Credential sync:**
```bash
# After claude auth login on host, sync to sandbox:
bootstrap/sync-claude-credentials.sh
```

OAuth tokens can expire. If requests start failing with auth errors, re-run `claude auth login` on the host and sync again.

---

## How It Works

1. **Request arrives** — LiteLLM forwards an OpenAI-format request to `http://claude-code-wrapper:8000/v1/chat/completions`
2. **Wrapper receives** — FastAPI app validates the internal API key
3. **Rate limiting check** — If enabled (`RATE_LIMIT_ENABLED=true`), checks request count; disabled for internal LiteLLM caller
4. **Format conversion** — Converts OpenAI message array into format expected by `claude_agent_sdk`
5. **Spawn Claude Code** — Calls `claude_agent_sdk.query()` which spawns the bundled `claude` CLI binary as a subprocess
6. **Claude Code executes** — Authenticates via `/root/.claude/.credentials.json` (OAuth), calls `api.anthropic.com`, returns result
7. **Parse and return** — Wrapper extracts response, wraps it in OpenAI `chat.completion` format, returns to LiteLLM

**Key detail:** The wrapper uses `CLAUDE_CODE_AUTH_METHOD=cli`, which tells the SDK to use OAuth credentials from disk rather than looking for Bedrock credentials.

---

## Starting the Wrapper

**Prerequisites:**
1. Claude Code CLI installed and authenticated on the host (`claude auth login`)
2. OpenShell sandbox created: `openshell sandbox create --name claude-revproxy --no-auto-providers --policy ~/home-lab/openshell/policies/claude-code.yaml`

**Start wrapper:**
```bash
bootstrap/setup-claude-revproxy.sh
```

**What it does:**
1. Syncs OAuth credentials from host to sandbox
2. Connects sandbox to `ai-net` with alias `claude-code-wrapper`
3. Clones `claude-code-openai-wrapper` repo into `/sandbox/wrapper/` (if not present)
4. Installs Python dependencies (fastapi, uvicorn, claude_agent_sdk)
5. Starts uvicorn on `:8000` with environment:
   - `CLAUDE_CODE_AUTH_METHOD=cli`
   - `API_KEY=claude-code-internal-revproxy-key-2026`
   - `RATE_LIMIT_ENABLED=false`
   - `CLAUDE_CWD=/tmp`

**Verify it's running:**
```bash
_SB=$(docker ps --filter 'name=openshell-claude-revproxy-' --format '{{.Names}}' | head -1)
docker exec "$_SB" ss -tlnp | grep ':8000'
```

Should show uvicorn listening on `0.0.0.0:8000`.

---

## Testing / Verification

### 1. Wrapper health check

```bash
_SB=$(docker ps --filter 'name=openshell-claude-revproxy-' --format '{{.Names}}' | head -1)
docker exec "$_SB" curl -s http://localhost:8000/health | python3 -m json.tool
```

**Expected output:**
```json
{
  "status": "healthy",
  "auth_method": "cli",
  "credentials_exist": true
}
```

### 2. Wrapper endpoint test (via LiteLLM)

From the homelab VM:

```bash
LITELLM_KEY=$(grep LITELLM_MASTER_KEY ~/home-lab/.secrets/litellm.env | cut -d= -f2)

curl -s http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer ${LITELLM_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "claude-code-wrapper-local",
    "messages": [{"role": "user", "content": "What is 2+2? Reply with just the number."}]
  }' | python3 -m json.tool
```

**Expected output:**
```json
{
  "id": "chatcmpl-...",
  "object": "chat.completion",
  "model": "claude-code-wrapper-local",
  "choices": [{
    "message": {
      "content": "4",
      "role": "assistant"
    },
    "finish_reason": "stop"
  }],
  "usage": {...}
}
```

### 3. OpenClaw end-to-end test

1. Open `https://openclaw.lab.lan` in browser
2. Paste gateway token: `b6-eEoQQuiX_wYDUlN25jnGSdh8zHt-y_lfj_m2dYdQ`
3. Select model: `litellm/claude-code-wrapper-local`
4. Ask: "Explain what makes Claude Code different from regular Claude."
5. Verify response mentions agent capabilities, tools, file operations

**Verify it used the wrapper** (check OpenClaw session logs):

```bash
_DIR=$(docker ps --filter 'name=openshell-director' --format '{{.Names}}' | head -1)
docker exec "$_DIR" grep -E '"model":"claude-code-wrapper-local"' \
  /sandbox/.openclaw/agents/main/sessions/*.jsonl | tail -5
```

Should show recent messages with `"model":"claude-code-wrapper-local"`.

---

## Unit Test Reproduction Commands

### Test Case 1: Simple math question

**Command:**
```bash
LITELLM_KEY=$(grep LITELLM_MASTER_KEY ~/home-lab/.secrets/litellm.env | cut -d= -f2)
curl -s http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer ${LITELLM_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-code-wrapper-local","messages":[{"role":"user","content":"What is 2+2?"}]}' \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('Response:', d['choices'][0]['message']['content'][:100])"
```

**Expected:** Response containing "4"

### Test Case 2: Knowledge question

**Command:**
```bash
LITELLM_KEY=$(grep LITELLM_MASTER_KEY ~/home-lab/.secrets/litellm.env | cut -d= -f2)
curl -s http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer ${LITELLM_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-code-wrapper-local","messages":[{"role":"user","content":"What is Claude Code?"}]}' \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('Response:', d['choices'][0]['message']['content'][:200])"
```

**Expected:** Response explaining Claude Code agent capabilities

### Test Case 3: Direct wrapper test (inside sandbox)

```bash
_SB=$(docker ps --filter 'name=openshell-claude-revproxy-' --format '{{.Names}}' | head -1)
docker exec "$_SB" curl -s http://localhost:8000/v1/chat/completions \
  -H "Authorization: Bearer claude-code-internal-revproxy-key-2026" \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-sonnet-4-6","messages":[{"role":"user","content":"Hello"}]}' \
  | python3 -m json.tool
```

**Expected:** OpenAI-format completion response

---

## Troubleshooting

### Wrapper not responding (timeout or 500 errors)

**Check wrapper is running:**
```bash
_SB=$(docker ps --filter 'name=openshell-claude-revproxy-' --format '{{.Names}}' | head -1)
docker exec "$_SB" ps aux | grep uvicorn
```

Should show `uvicorn src.main:app --host 0.0.0.0 --port 8000`.

**Restart wrapper:**
```bash
bootstrap/setup-claude-revproxy.sh
```

### Authentication errors (401 from Anthropic)

Claude OAuth token expired. Re-authenticate on host:

```bash
claude auth login
bootstrap/sync-claude-credentials.sh
```

### "No credentials found" error

Credentials not synced to sandbox:

```bash
_SB=$(docker ps --filter 'name=openshell-claude-revproxy-' --format '{{.Names}}' | head -1)
docker exec "$_SB" ls -la /root/.claude/.credentials.json
```

If missing, sync:
```bash
bootstrap/sync-claude-credentials.sh
```

### Sandbox not connected to ai-net

LiteLLM can't reach `claude-code-wrapper:8000`. Reconnect:

```bash
_SB=$(docker ps --filter 'name=openshell-claude-revproxy-' --format '{{.Names}}' | head -1)
docker network connect --alias claude-code-wrapper ai-net "$_SB"
```

### "CLAUDE_CODE_AUTH_METHOD not set" error

Wrapper started without required environment variable. Check `setup-claude-revproxy.sh` line ~70:

```bash
docker exec -d \
  -e CLAUDE_CODE_AUTH_METHOD=cli \
  ...
```

Must be set to `cli` for OAuth mode.

---

## Wrapper Configuration

**Environment variables** (set when wrapper starts):

| Variable | Value | Purpose |
|---|---|---|
| `CLAUDE_CODE_AUTH_METHOD` | `cli` | Use OAuth credentials, not Bedrock |
| `API_KEY` | `claude-code-internal-revproxy-key-2026` | Bearer token that LiteLLM sends to wrapper |
| `RATE_LIMIT_ENABLED` | `false` | No rate limiting for internal caller |
| `CLAUDE_CWD` | `/tmp` | Claude Code working directory inside sandbox |

**Wrapper source** (in sandbox at `/sandbox/wrapper/claude-code-openai-wrapper/`):

The wrapper is a clone of [RichardAtCT/claude-code-openai-wrapper](https://github.com/RichardAtCT/claude-code-openai-wrapper). Key files:
- `src/main.py` — FastAPI application
- `requirements.txt` — Python dependencies (includes `claude_agent_sdk`)

---

## Session Logging Behavior

Unlike the Grok wrapper, Claude Code via `claude_agent_sdk` **does create session state**, but it's managed by the SDK and the bundled CLI binary. Session logs are not directly accessible in a simple directory structure like Grok's `/root/.grok/sessions/`.

**For audit trails:**
1. **OpenClaw director logs** — `/sandbox/.openclaw/agents/main/sessions/*.jsonl` in the director sandbox
2. **LiteLLM logs** — `docker logs litellm`
3. **Wrapper logs** — check uvicorn stdout (not currently persisted; could redirect to file)

If deep session introspection is needed, the `claude_agent_sdk` may expose session APIs — check the SDK documentation.

---

## Model Aliases

LiteLLM routes three model names to the same wrapper endpoint:

| Model name in request | Route target |
|---|---|
| `claude-code-wrapper-local` | `http://claude-code-wrapper:8000/v1` (primary name; shown in OpenClaw picker) |
| `claude-code-sonnet` | `http://claude-code-wrapper:8000/v1` (alias) |
| `claude-code/sonnet` | `http://claude-code-wrapper:8000/v1` (alias) |

All three point to the same Claude Code instance running in `openshell-claude-revproxy`.

---

## Operations

**Start wrapper:**
```bash
bootstrap/setup-claude-revproxy.sh
```

**Restart wrapper (after code changes):**
```bash
bootstrap/setup-claude-revproxy.sh  # idempotent; kills old process, starts new one
```

**Sync OAuth credentials (after re-login):**
```bash
bootstrap/sync-claude-credentials.sh
```

**Check wrapper health:**
```bash
_SB=$(docker ps --filter 'name=openshell-claude-revproxy-' --format '{{.Names}}' | head -1)
docker exec "$_SB" curl -s http://localhost:8000/health | python3 -m json.tool
```

**Check wrapper status (from ai-net):**
```bash
docker run --rm --network ai-net curlimages/curl:latest \
  curl -s http://claude-code-wrapper:8000/ | jq .
```

**View wrapper logs (if redirected to file):**

Currently logs go to uvicorn stdout (not persisted). To capture:
```bash
_SB=$(docker ps --filter 'name=openshell-claude-revproxy-' --format '{{.Names}}' | head -1)
docker logs "$_SB" 2>&1 | grep uvicorn
```

---

## Comparison: Claude Code Wrapper vs. Grok Wrapper

| Aspect | Claude Code Wrapper | Grok Wrapper |
|---|---|---|
| **CLI spawned** | `claude_agent_sdk.query()` (bundles `claude` binary) | `/root/.grok/bin/grok --single` |
| **Output format** | Parsed by SDK, no `--output-format` flag needed | `--output-format json` explicit |
| **Session persistence** | Managed by SDK (opaque) | `--single` mode: no persistent sessions |
| **Working directory** | `CLAUDE_CWD=/tmp` | `--cwd /tmp/grok-workspace` |
| **Auth method env** | `CLAUDE_CODE_AUTH_METHOD=cli` | Grok CLI auto-detects from `~/.grok/auth.json` |
| **Port** | `:8000` | `:8001` |
| **Rate limiting** | Has rate limit config (disabled for internal use) | No rate limiting implemented |
| **Wrapper source** | Git submodule (external repo) | Custom code in this repo |

---

## Deferred / Future Work

| Item | Notes |
|---|---|
| **systemd timer for credential sync** | Keep OAuth token fresh without manual sync (daily/hourly) |
| **Wrapper auto-start on reboot** | systemd `--user` service (like `nemoclaw-director-control-ui`) |
| **Wrapper log persistence** | Currently uvicorn stdout not captured; redirect to `/var/log/` or structured logger |
| **Streaming support** | Wrapper may support streaming via SDK; test and document |
| **Token usage tracking** | Check if `claude_agent_sdk` exposes token counts; currently returns `{prompt_tokens: 0, completion_tokens: 0}` |

---

## Summary

The claude-code-wrapper-local integration:

✅ **Works end-to-end** — OpenClaw → LiteLLM → wrapper → Claude Code CLI → api.anthropic.com  
✅ **Uses OAuth** — No API keys, no Bedrock, just Claude Pro/Max subscription  
✅ **Isolated** — Runs in OpenShell sandbox with network policy  
✅ **Reproducible** — All tests documented with exact commands  
✅ **Verified** — Both direct wrapper tests and full routing chain confirmed working

The wrapper is production-ready for internal use. The only missing pieces are automated credential refresh (systemd timer) and auto-start on reboot (systemd service).
