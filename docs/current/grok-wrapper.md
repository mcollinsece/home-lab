# Grok Wrapper (grok-wrapper-local)

> **Status:** ✅ Live — OAuth/Grok subscription, spawns Grok Build CLI, OpenAI-compatible endpoint

---

## What It Is

`grok-wrapper-local` is a FastAPI application that wraps the **Grok Build CLI** (xAI's official agent CLI) and exposes it as an OpenAI-compatible HTTP endpoint. This allows OpenClaw and other LiteLLM clients to invoke the full Grok Build agent (with tools, reasoning, and multi-turn sessions) as if it were a standard LLM API endpoint.

**Key properties:**
- **No API keys** — uses OAuth subscription authentication (Grok subscription required)
- **Full agent capability** — not just chat completion; Grok CLI has tools, file operations, reasoning
- **Isolated execution** — runs inside an OpenShell sandbox with network policy enforcement
- **OpenAI-compatible** — accepts `/v1/chat/completions` requests in OpenAI format

---

## Architecture

```
OpenClaw / LiteLLM client
    │
    ├─► POST /v1/chat/completions
    │   model: grok-wrapper-local
    │   Authorization: Bearer grok-internal-revproxy-key-2026
    │
    ▼
LiteLLM (:4000, Docker ai-net)
    │
    ├─► http://grok-wrapper:8001/v1/chat/completions
    │   (routes to openshell-grok-wrapper sandbox via ai-net alias)
    │
    ▼
openshell-grok-wrapper sandbox
    │
    ├─► FastAPI (uvicorn :8001)
    │   /sandbox/grok-wrapper/src/main.py
    │
    ├─► spawns: /root/.grok/bin/grok --single "<prompt>" \
    │            --output-format json \
    │            --cwd /tmp/grok-workspace \
    │            --no-alt-screen
    │
    └─► Grok Build CLI (OAuth) → api.x.ai → xAI Grok API
```

---

## File Locations

| Component | Path | Description |
|---|---|---|
| **Wrapper source** | `wrappers/grok-openai-wrapper/src/main.py` | FastAPI application (spawns Grok CLI) |
| **Setup script** | `bootstrap/setup-grok-wrapper.sh` | Creates sandbox, syncs creds, starts wrapper |
| **Credential sync** | `bootstrap/sync-grok-credentials.sh` | Copies host `~/.grok/auth.json` → sandbox `/root/.grok/` |
| **Network policy** | `openshell/policies/grok.yaml` | OpenShell egress policy (allows `api.x.ai`, `auth.x.ai`) |
| **LiteLLM config** | `litellm/config.yaml` | Routes `grok-wrapper-local` and `grok-beta` to `http://grok-wrapper:8001/v1` |

**Inside the sandbox:**
| Path | What it is |
|---|---|
| `/root/.grok/bin/grok` | Grok Build CLI binary (symlink to `../downloads/grok-linux-x86_64`) |
| `/root/.grok/auth.json` | OAuth credentials (synced from host) |
| `/root/.grok/logs/unified.jsonl` | Grok CLI structured logs |
| `/root/.grok/sessions/` | Session state (only for interactive mode; `--single` doesn't persist here) |
| `/sandbox/grok-wrapper/` | Wrapper code and dependencies |
| `/tmp/grok-workspace/` | Grok CLI working directory (`GROK_CWD`) |

---

## Credentials

| Credential | Location | How it's used |
|---|---|---|
| **Grok OAuth token** | Host: `~/.grok/auth.json` → Sandbox: `/root/.grok/auth.json` | Grok CLI reads this automatically; synced by `sync-grok-credentials.sh` |
| **Wrapper internal API key** | `grok-internal-revproxy-key-2026` | LiteLLM → wrapper auth; set via `API_KEY` env var when wrapper starts |

**No AWS credentials.** The wrapper uses OAuth/Grok subscription, not Bedrock.

**Credential sync:**
```bash
# After grok login on host, sync to sandbox:
bootstrap/sync-grok-credentials.sh
```

OAuth tokens can expire. If requests start failing with auth errors, re-run `grok login` on the host and sync again.

---

## How It Works

1. **Request arrives** — LiteLLM forwards an OpenAI-format request to `http://grok-wrapper:8001/v1/chat/completions`
2. **Wrapper receives** — FastAPI app validates the internal API key
3. **Build prompt** — Converts OpenAI message array into a plain-text prompt (formats system/user/assistant roles)
4. **Spawn Grok CLI** — Runs `/root/.grok/bin/grok --single "<prompt>" --output-format json --cwd /tmp/grok-workspace --no-alt-screen` as a subprocess
5. **Grok CLI executes** — Authenticates via `/root/.grok/auth.json`, calls xAI API, returns JSON response
6. **Parse and return** — Wrapper extracts response text from JSON, wraps it in OpenAI `chat.completion` format, returns to LiteLLM

**Key detail:** The `--single` flag runs Grok in **non-interactive mode** (one-shot). This means:
- No persistent session directories under `/root/.grok/sessions/`
- Faster startup (no TUI initialization)
- Structured JSON output
- Each request is a fresh session

---

## Starting the Wrapper

**Prerequisites:**
1. Grok Build CLI installed and authenticated on the host (`grok login`)
2. OpenShell sandbox created: `openshell sandbox create --name grok-wrapper --no-auto-providers --policy ~/home-lab/openshell/policies/grok.yaml`

**Start wrapper:**
```bash
bootstrap/setup-grok-wrapper.sh
```

**What it does:**
1. Syncs OAuth credentials from host to sandbox
2. Installs Grok Build CLI in sandbox (if not already present)
3. Connects sandbox to `ai-net` with alias `grok-wrapper`
4. Copies wrapper code to `/sandbox/grok-wrapper/`
5. Installs Python dependencies (fastapi, uvicorn, pydantic)
6. Starts uvicorn on `:8001` with environment:
   - `API_KEY=grok-internal-revproxy-key-2026`
   - `GROK_BIN=/root/.grok/bin/grok`
   - `GROK_CWD=/tmp/grok-workspace`

**Verify it's running:**
```bash
_SB=$(docker ps --filter 'name=openshell-grok-wrapper-' --format '{{.Names}}' | head -1)
docker exec "$_SB" ss -tlnp | grep ':8001'
```

Should show uvicorn listening on `0.0.0.0:8001`.

---

## Testing / Verification

### 1. Direct CLI test (inside sandbox)

Test that Grok CLI can execute:

```bash
_SB=$(docker ps --filter 'name=openshell-grok-wrapper-' --format '{{.Names}}' | head -1)
docker exec "$_SB" /root/.grok/bin/grok --version
```

**Expected output:** `grok 0.2.51 (f4f85a649)` (or newer version)

Run a test prompt:

```bash
docker exec "$_SB" /root/.grok/bin/grok --single "What is 2+2? Answer with just the number." \
  --output-format json \
  --cwd /tmp/grok-workspace \
  --no-alt-screen
```

**Expected output:** JSON with `"text": "4"` (or similar)

### 2. Wrapper endpoint test (via LiteLLM)

From the homelab VM:

```bash
LITELLM_KEY=$(grep LITELLM_MASTER_KEY ~/home-lab/.secrets/litellm.env | cut -d= -f2)

curl -s http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer ${LITELLM_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "grok-wrapper-local",
    "messages": [{"role": "user", "content": "What is 2+2? Answer with just the number."}]
  }' | python3 -m json.tool
```

**Expected output:**
```json
{
  "id": "chatcmpl-grok-...",
  "object": "chat.completion",
  "model": "grok-wrapper-local",
  "choices": [{
    "message": {
      "content": "{\n  \"text\": \"4\",\n  \"stopReason\": \"EndTurn\",\n  ...\n}",
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
3. Select model: `litellm/grok-wrapper-local`
4. Ask: "Who is Elon Musk?"
5. Verify response includes xAI/Grok-specific context

**Verify it used the wrapper** (check OpenClaw session logs):

```bash
_DIR=$(docker ps --filter 'name=openshell-director' --format '{{.Names}}' | head -1)
docker exec "$_DIR" grep -E '"model":"grok-wrapper-local"' \
  /sandbox/.openclaw/agents/main/sessions/*.jsonl | tail -5
```

Should show recent messages with `"model":"grok-wrapper-local"`.

---

## Unit Test Reproduction Commands

### Test Case 1: Math question (simple prompt)

**Command:**
```bash
_SB=$(docker ps --filter 'name=openshell-grok-wrapper-' --format '{{.Names}}' | head -1)
docker exec "$_SB" /root/.grok/bin/grok --single "What is 2+2? Answer with just the number." \
  --output-format json \
  --cwd /tmp/grok-workspace \
  --no-alt-screen
```

**Expected JSON fields:**
- `text`: Contains "4"
- `stopReason`: "EndTurn"
- `sessionId`: UUID format
- `requestId`: UUID format

### Test Case 2: Knowledge question (reproduces "Elon Musk" test)

**Command:**
```bash
_SB=$(docker ps --filter 'name=openshell-grok-wrapper-' --format '{{.Names}}' | head -1)
docker exec "$_SB" /root/.grok/bin/grok --single "User: who is elon musk?" \
  --output-format json \
  --cwd /tmp/grok-workspace \
  --no-alt-screen
```

**Expected output:**
- `text`: Multi-paragraph response about Elon Musk mentioning Tesla, SpaceX, xAI
- `stopReason`: "EndTurn"
- `thought`: Explanation of how Grok approached the question

### Test Case 3: LiteLLM routing (end-to-end)

**Command:**
```bash
LITELLM_KEY=$(grep LITELLM_MASTER_KEY ~/home-lab/.secrets/litellm.env | cut -d= -f2)
curl -s http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer ${LITELLM_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model":"grok-wrapper-local","messages":[{"role":"user","content":"Tell me a fun fact about penguins in one sentence."}]}' \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['choices'][0]['message']['content'][:200])"
```

**Expected:** Response text starting with a penguin fact

---

## Troubleshooting

### Wrapper not responding (timeout or 500 errors)

**Check wrapper is running:**
```bash
_SB=$(docker ps --filter 'name=openshell-grok-wrapper-' --format '{{.Names}}' | head -1)
docker exec "$_SB" ps aux | grep uvicorn
```

Should show `uvicorn src.main:app --host 0.0.0.0 --port 8001`.

**Restart wrapper:**
```bash
bootstrap/setup-grok-wrapper.sh
```

### Authentication errors (401 from xAI)

Grok OAuth token expired. Re-authenticate on host:

```bash
grok login
bootstrap/sync-grok-credentials.sh
```

### "Grok CLI error: unexpected argument '--headless'"

Old Grok CLI version. The wrapper uses `--single`, NOT `--headless`. Check `main.py` line 126 — should be:

```python
[GROK_BIN, "--single", prompt, "--output-format", "json", "--cwd", GROK_CWD, "--no-alt-screen"]
```

If you see `--headless`, that's outdated code.

### Sandbox not connected to ai-net

LiteLLM can't reach `grok-wrapper:8001`. Reconnect:

```bash
_SB=$(docker ps --filter 'name=openshell-grok-wrapper-' --format '{{.Names}}' | head -1)
docker network connect --alias grok-wrapper ai-net "$_SB"
```

---

## Session Logging Behavior

**Key finding from testing:**

The Grok CLI `--single` mode does NOT create persistent session directories under `/root/.grok/sessions/`. This is by design:

- `--single` is for **non-interactive, one-shot requests**
- Sessions are ephemeral (created, used, discarded)
- Full session state (chat history, rewind points, etc.) is NOT written to disk
- **Logs still exist** in `/root/.grok/logs/unified.jsonl` with session metadata

**What you'll see in logs:**

```bash
_SB=$(docker ps --filter 'name=openshell-grok-wrapper-' --format '{{.Names}}' | head -1)
docker exec "$_SB" tail -50 /root/.grok/logs/unified.jsonl | grep -E "session created|prompt received"
```

Shows:
```json
{"ts":"2026-06-15T15:39:17.877Z","src":"shell","pid":333,"lvl":"info","sid":"019ecbef-e784-7783-8684-281faab32a56","msg":"session created","ctx":{"cwd":"/tmp/grok-workspace"}}
{"ts":"2026-06-15T15:39:17.878Z","src":"shell","pid":333,"lvl":"info","sid":"019ecbef-e784-7783-8684-281faab32a56","msg":"prompt received"}
```

But `/root/.grok/sessions/<session-id>/` will NOT exist.

**For interactive mode** (not used by the wrapper), sessions ARE persisted:
- `chat_history.jsonl` — full conversation
- `events.jsonl` — tool calls, edits, etc.
- `summary.json` — session metadata

The wrapper's use of `--single` is correct for stateless API requests. If you need session audit trails, check:
1. `/root/.grok/logs/unified.jsonl` in the sandbox
2. OpenClaw director's session logs at `/sandbox/.openclaw/agents/main/sessions/*.jsonl`
3. LiteLLM logs: `docker logs litellm`

---

## Model Aliases

LiteLLM routes two model names to the same wrapper endpoint:

| Model name in request | Route target |
|---|---|
| `grok-wrapper-local` | `http://grok-wrapper:8001/v1` (primary name; shown in OpenClaw picker) |
| `grok-beta` | `http://grok-wrapper:8001/v1` (alias) |

Both point to the same Grok Build CLI instance running in `openshell-grok-wrapper`.

---

## Operations

**Start wrapper:**
```bash
bootstrap/setup-grok-wrapper.sh
```

**Restart wrapper (after code changes):**
```bash
bootstrap/setup-grok-wrapper.sh  # idempotent; kills old process, starts new one
```

**Sync OAuth credentials (after re-login):**
```bash
bootstrap/sync-grok-credentials.sh
```

**Check wrapper health:**
```bash
curl -s http://localhost:8001/health | python3 -m json.tool
```

**Check wrapper status (from ai-net):**
```bash
docker run --rm --network ai-net curlimages/curl:latest \
  curl -s http://grok-wrapper:8001/ | jq .
```

**View Grok CLI version:**
```bash
_SB=$(docker ps --filter 'name=openshell-grok-wrapper-' --format '{{.Names}}' | head -1)
docker exec "$_SB" /root/.grok/bin/grok --version
```

**Tail Grok CLI logs:**
```bash
_SB=$(docker ps --filter 'name=openshell-grok-wrapper-' --format '{{.Names}}' | head -1)
docker exec "$_SB" tail -f /root/.grok/logs/unified.jsonl
```

---

## Deferred / Future Work

| Item | Notes |
|---|---|
| **systemd timer for credential sync** | Keep OAuth token fresh without manual sync (daily/hourly) |
| **Wrapper auto-start on reboot** | systemd `--user` service (like `nemoclaw-director-control-ui`) |
| **Session audit trail** | Current `--single` mode doesn't persist sessions; if audit required, switch to interactive mode or log requests in wrapper |
| **Streaming support** | Wrapper returns full response; streaming not implemented (LiteLLM doesn't forward SSE from wrapper) |
| **Token usage tracking** | Grok CLI doesn't expose token counts in `--single` mode; usage is always `{prompt_tokens: 0, completion_tokens: 0}` |

---

## Summary

The grok-wrapper-local integration:

✅ **Works end-to-end** — OpenClaw → LiteLLM → wrapper → Grok CLI → xAI API  
✅ **Uses OAuth** — No API keys, no Bedrock, just Grok subscription  
✅ **Isolated** — Runs in OpenShell sandbox with network policy  
✅ **Reproducible** — All tests documented with exact commands  
✅ **Verified** — Both direct CLI tests and full routing chain confirmed working

The wrapper is production-ready for internal use. The only missing piece is automated credential refresh (systemd timer) and auto-start on reboot (systemd service).
