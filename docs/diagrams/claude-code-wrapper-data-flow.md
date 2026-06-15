# Claude Code OpenAI Wrapper — Data Flow

**Status (2026-06-14): LIVE.** The wrapper is deployed and serving requests. This document
details the data flow through `claude-code-openai-wrapper` running inside the
`openshell-claude-revproxy` OpenShell sandbox.

**Auth path:** OAuth/Pro subscription (`CLAUDE_CODE_AUTH_METHOD=cli`) — not Bedrock.
The wrapper sandbox holds no AWS credentials.

For the high-level architecture (what was added vs. what is unchanged), see
[claude-code-agent-sandbox-flow.md](claude-code-agent-sandbox-flow.md).

---

## Mermaid Diagram

```mermaid
flowchart TB
    subgraph Clients["Clients (via LiteLLM)"]
        OC["OpenClaw / NemoClaw director\n(model: litellm/claude-code-wrapper-local)"]
        EXT["Any OpenAI-compatible client\n(model: claude-code-sonnet, etc.)"]
    end

    subgraph LiteLLM["LiteLLM (Docker :4000, ai-net)"]
        direction TB
        LLM_CFG["config.yaml\nmodel_name: claude-code-wrapper-local\napi_base: http://claude-code-wrapper:8000/v1\napi_key: claude-code-internal-revproxy-key-2026"]
        LLM["LiteLLM router\n(logging, retries, fallback)"]
    end

    subgraph Sandbox["openshell-claude-revproxy sandbox (OpenShell isolation)"]
        direction TB
        WRAPPER["uvicorn src.main:app :8000\nclaude-code-openai-wrapper\n(OpenAI-compatible FastAPI)"]
        SDK["claude_agent_sdk.query()\nbundled claude CLI subprocess\nfull agent: tools, edits, sessions"]
        AUTH["CLAUDE_CODE_AUTH_METHOD=cli\n/root/.claude/.credentials.json\n(synced from host via sync-claude-credentials.sh)"]
        CWD["CLAUDE_CWD=/tmp\n(safe workspace for agent file ops)"]
    end

    subgraph Anthropic["Anthropic (cloud)"]
        ANT["api.anthropic.com\nOAuth/Pro subscription\n(no AWS SigV4 — not Bedrock)"]
    end

    %% Main data flow
    OC -->|"1. POST /v1/chat/completions\nmodel=claude-code-wrapper-local"| LLM
    EXT -->|"same OpenAI format"| LLM
    LLM --> LLM_CFG
    LLM -->|"2. Forwarded to sandbox\nBearer: claude-code-internal-revproxy-key-2026"| WRAPPER
    WRAPPER -->|"3. claude_agent_sdk.query()"| SDK
    SDK --> AUTH
    SDK --> CWD
    SDK -->|"4. OAuth HTTP to api.anthropic.com\n(sandbox egress allowed by policy)"| ANT
    ANT -->|"5. Response"| SDK
    SDK -->|"6. OpenAI-shaped response"| WRAPPER
    WRAPPER -->|"7. Response through LiteLLM"| LLM
    LLM -->|"8. Final response"| OC
    LLM --> EXT

    classDef cred fill:#fef3c7,stroke:#d97706
    class AUTH,LLM_CFG cred

    classDef boundary fill:#ecfdf5,stroke:#10b981,stroke-dasharray: 5 5
    class Sandbox boundary

    classDef client fill:#dbeafe,stroke:#3b82f6
    class OC,EXT client
```

---

## Step-by-Step Data Flow

1. **Client request** — OpenClaw director (or any OpenAI client) sends
   `POST /v1/chat/completions` with `model: claude-code-wrapper-local` (or either alias)
   to LiteLLM at `http://localhost:4000` (or via the inference.local gateway).
   Auth: `Authorization: Bearer ${LITELLM_MASTER_KEY}`.

2. **LiteLLM routing** — matches model name to the `openai` upstream entry in
   `litellm/config.yaml`; forwards to `http://claude-code-wrapper:8000/v1`
   (Docker ai-net DNS alias for the `openshell-claude-revproxy` sandbox container).
   Adds `Authorization: Bearer claude-code-internal-revproxy-key-2026`.

3. **Wrapper receives** — `claude-code-openai-wrapper` (uvicorn FastAPI) accepts
   the request. `RATE_LIMIT_ENABLED=false` — no throttle for internal LiteLLM caller.
   The wrapper translates from OpenAI chat format to the SDK's message format.

4. **SDK executes** — `claude_agent_sdk.query()` spawns the bundled `claude` CLI binary
   as a subprocess. `CLAUDE_CODE_AUTH_METHOD=cli` causes it to use the OAuth credentials
   at `/root/.claude/.credentials.json` (which were synced from the host by
   `bootstrap/sync-claude-credentials.sh`). `CLAUDE_CWD=/tmp` gives the agent a
   writable working directory inside the sandbox.

5. **Anthropic API** — the bundled claude binary calls `api.anthropic.com` directly
   over HTTPS (OAuth/Pro subscription). The sandbox policy permits this egress. This is
   **not** Bedrock — no SigV4, no AWS credentials.

6. **Response path** — agent result comes back through `claude_agent_sdk` → wrapper
   (assembled into an OpenAI-shaped `ChatCompletion` response) → LiteLLM → original caller.

---

## Key Properties

- **No AWS credentials in the sandbox.** The wrapper uses OAuth, not Bedrock. AWS keys
  live only in the LiteLLM container, which handles the separate Bedrock path for
  `claude-sonnet-4-6`.
- **OpenShell isolation.** The wrapper runs inside an OpenShell sandbox. The agent's file
  operations are scoped to `CLAUDE_CWD=/tmp` inside the container; the host filesystem is
  not accessible.
- **Docker ai-net reachability.** The sandbox is connected to the Docker `ai-net` bridge
  with alias `claude-code-wrapper`, making it reachable as `http://claude-code-wrapper:8000`
  from other ai-net containers (LiteLLM, Traefik, etc.).
- **Nothing changes in NemoClaw.** The director probe adds the model to `openclaw.json`
  idempotently on each start. The director itself continues to use `litellm` as its
  only inference provider.
- **Credential sync.** OAuth tokens expire. Run `bootstrap/sync-claude-credentials.sh`
  after any `claude auth login` on the host to refresh the token in the sandbox. A
  future systemd timer will automate this.

---

## Environment Variables (wrapper start)

| Variable | Value | Purpose |
|---|---|---|
| `CLAUDE_CODE_AUTH_METHOD` | `cli` | Use OAuth credentials, not Bedrock |
| `API_KEY` | `claude-code-internal-revproxy-key-2026` | Bearer token that LiteLLM sends to the wrapper |
| `RATE_LIMIT_ENABLED` | `false` | No rate limiting for internal caller |
| `CLAUDE_CWD` | `/tmp` | Agent working directory inside sandbox |

Started by `bootstrap/setup-claude-revproxy.sh`:
```bash
docker exec -d \
  -e CLAUDE_CODE_AUTH_METHOD=cli \
  -e API_KEY=claude-code-internal-revproxy-key-2026 \
  -e RATE_LIMIT_ENABLED=false \
  -e CLAUDE_CWD=/tmp \
  "$_SB" \
  "$_UV_BIN/uvicorn" src.main:app --host 0.0.0.0 --port 8000 --app-dir /sandbox/wrapper
```
