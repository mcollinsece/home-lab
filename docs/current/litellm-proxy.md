# LiteLLM Proxy

> Architecture reference for the LiteLLM Docker Compose service.
> Operational tasks and remaining TODOs live in [todos.md](todos.md).

---

## Problem this solves

All pay-per-token inference routes through one OpenAI-compatible endpoint.
Backend changes happen in one config file. CLI tools inside agent sandboxes never
hold real credentials — they talk to `inference.local`, which the OpenShell gateway
routes to LiteLLM. The Claude Code agent wrapper surfaces as just another model name
behind LiteLLM; callers never know they are hitting a full agentic runtime.

---

## Architecture

```
NemoClaw OpenClaw director ──────────────────────► LiteLLM (:4000)
                                                         │
OpenShell gateway                                        │
  inference.local ─────────────────────────────────────►│
       ▲                                                 │
       │  all sandboxes point here                       ├─── Bedrock (claude-sonnet-4-6)
  ┌────┴─────────────────────────────────────┐          │    AWS SigV4, cross-region profile
  │  claude-code sandbox                      │          │
  │    ANTHROPIC_BASE_URL=https://inference.  │          └─── claude-code-wrapper:8000
  │  codex sandbox (Phase 5)                 │               openshell-claude-revproxy sandbox
  │  gemini sandbox (Phase 6)                │               claude-code-openai-wrapper (uvicorn)
  └────────────────────────────────────────┬─┘               OAuth/Pro → api.anthropic.com
                                           │                   ▲
                                           └───────────────────┘
                                           (sandbox is also on ai-net, alias: claude-code-wrapper)
```

**Two auth paths, one credential boundary:**

| Route | Auth method | Credential holder |
|---|---|---|
| `claude-sonnet-4-6` → Bedrock | AWS SigV4 | LiteLLM container only |
| `claude-code-wrapper-local` → wrapper | OAuth/Pro subscription | sandbox `/root/.claude/` (synced from host) |

The CLI tools inside inference.local sandboxes (claude-code, codex, gemini) never hold
credentials — they point at `inference.local` and LiteLLM fills in the backend.
OpenClaw / any other LiteLLM client sees both Bedrock models and the claude-code agent
as interchangeable model names.

---

## Components

| Component | What it does |
|---|---|
| **LiteLLM** (Docker Compose service) | OpenAI-compatible proxy; sole holder of Bedrock creds; routes Bedrock models and reverse-proxies the claude-code wrapper |
| **OpenShell provider `litellm-local`** | Routes `inference.local` from the gateway to LiteLLM at `http://localhost:4000/v1` |
| **NemoClaw OpenClaw** | Configured with LiteLLM as the OpenAI-compatible provider; models: `litellm/claude-sonnet-4-6` and `litellm/claude-code-wrapper-local` |
| **claude-revproxy sandbox** | OpenShell sandbox running `claude-code-openai-wrapper`; connected to ai-net as `claude-code-wrapper`; outbound via OAuth |

---

## File layout

```
litellm/
├── config.yaml           LiteLLM model routing config (committed)
├── litellm.env.example   Non-secret runtime config template (committed)
└── litellm.env           Actual runtime config (gitignored; copy from example)

.secrets/
├── litellm.env           LITELLM_MASTER_KEY (gitignored; created by init-secrets)
└── bedrock.env           AWS credentials (gitignored; created by init-secrets)
```

---

## config.yaml

The full file is at `litellm/config.yaml`. Key model entries:

```yaml
model_list:

  # Bedrock: Claude Sonnet 4.6
  - model_name: claude-sonnet-4-6
    litellm_params:
      model: bedrock/us.anthropic.claude-sonnet-4-6
      aws_access_key_id: os.environ/AWS_ACCESS_KEY_ID
      aws_secret_access_key: os.environ/AWS_SECRET_ACCESS_KEY
      aws_region_name: os.environ/AWS_REGION
      max_tokens: 64000

  # Bedrock alias (full ARN form)
  - model_name: bedrock/us.anthropic.claude-sonnet-4-6
    litellm_params:
      model: bedrock/us.anthropic.claude-sonnet-4-6
      # ... same Bedrock params

  # claude-code agent via wrapper (three aliases for the same sandbox endpoint)
  # Auth: CLAUDE_CODE_AUTH_METHOD=cli (OAuth/Pro subscription, no AWS keys)
  - model_name: claude-code-wrapper-local
    litellm_params:
      model: openai/claude-sonnet-4-6
      api_base: http://claude-code-wrapper:8000/v1
      api_key: claude-code-internal-revproxy-key-2026

  - model_name: claude-code-sonnet
    litellm_params:
      model: openai/claude-sonnet-4-6
      api_base: http://claude-code-wrapper:8000/v1
      api_key: claude-code-internal-revproxy-key-2026

  - model_name: claude-code/sonnet
    litellm_params:
      model: openai/claude-sonnet-4-6
      api_base: http://claude-code-wrapper:8000/v1
      api_key: claude-code-internal-revproxy-key-2026

litellm_settings:
  master_key: os.environ/LITELLM_MASTER_KEY

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
```

`max_tokens: 64000` cap prevents OpenClaw from requesting 200K tokens, which Bedrock
rejects (128K limit on cross-region inference profiles).

Bedrock model ID: `us.anthropic.claude-sonnet-4-6` (no date suffix — Claude 4.x dropped
the date from the cross-region inference profile name). See the comment in
`litellm/config.yaml` for the Bedrock API verification command.

---

## Secrets

Populated by `init-secrets`. Injected into the Docker Compose `litellm` service via `env_file:`.

| Secret | Source | Consumer |
|---|---|---|
| `LITELLM_MASTER_KEY` | `openssl rand -hex 32` (auto) | LiteLLM (gates all inbound) + OpenShell provider + NemoClaw onboard |
| `AWS_ACCESS_KEY_ID` | IAM console | LiteLLM → Bedrock (sole credential holder) |
| `AWS_SECRET_ACCESS_KEY` | IAM console | LiteLLM → Bedrock |
| `AWS_REGION` | e.g. `us-east-1` | LiteLLM → Bedrock |

The claude-code wrapper uses OAuth (no AWS keys). Its credentials live at
`~/.claude/.credentials.json` on the host and are synced to the sandbox via
`bootstrap/sync-claude-credentials.sh`.

---

## OpenShell gateway configuration

After `docker compose up -d`, register LiteLLM as the OpenShell inference route
(one-time host setup; survives container restarts):

```bash
LITELLM_KEY=$(grep LITELLM_MASTER_KEY ~/home-lab/.secrets/litellm.env | cut -d= -f2)

openshell provider create \
    --name litellm-local --type openai \
    --credential "OPENAI_API_KEY=${LITELLM_KEY}" \
    --config OPENAI_BASE_URL=http://localhost:4000/v1

# --no-verify skips the embeddings probe (Bedrock doesn't support embeddings)
openshell inference set --no-verify --provider litellm-local --model claude-sonnet-4-6

openshell inference get  # verify
```

---

## NemoClaw integration

During `nemoclaw onboard`, select **OpenAI-compatible** as the inference provider:

```
API key:  <LITELLM_MASTER_KEY from .secrets/litellm.env>
Base URL: http://localhost:4000/v1
Model:    claude-sonnet-4-6
```

NemoClaw's OpenClaw sandbox routes all inference through LiteLLM. The probe service
(`nemoclaw-director-control-ui`) subsequently patches the director's `openclaw.json`
to rename the provider to `litellm` and add `claude-code-wrapper-local` to the model list.

---

## Sandbox launch pattern

Sandboxes need no credential injection. `inference.local` is the uniform endpoint:

```bash
# Claude Code sandbox (interactive use via inference.local → Bedrock)
openshell sandbox create --name claude-code --no-auto-providers \
    --policy openshell/policies/claude-code.yaml \
    --env ANTHROPIC_BASE_URL=https://inference.local \
    --env ANTHROPIC_API_KEY=unused \
    -- claude

# claude-code wrapper sandbox (persistent, serves as model endpoint)
# After create, run: bootstrap/setup-claude-revproxy.sh
openshell sandbox create --name claude-revproxy --no-auto-providers \
    --policy openshell/policies/claude-code.yaml

# Codex sandbox (Phase 5)
openshell sandbox create --name codex --no-auto-providers \
    --policy openshell/policies/codex.yaml \
    --env OPENAI_BASE_URL=https://inference.local/v1 \
    --env OPENAI_API_KEY=unused \
    -- codex

# Gemini sandbox (Phase 6)
openshell sandbox create --name gemini --no-auto-providers \
    --policy openshell/policies/gemini.yaml \
    --env GOOGLE_GENAI_BASE_URL=https://inference.local \
    --env GEMINI_API_KEY=unused \
    -- gemini
```

---

## Smoke-test

```bash
LITELLM_KEY=$(grep LITELLM_MASTER_KEY ~/home-lab/.secrets/litellm.env | cut -d= -f2)

# Model list (should show claude-sonnet-4-6, claude-code-wrapper-local, aliases)
curl -s http://localhost:4000/v1/models \
  -H "Authorization: Bearer ${LITELLM_KEY}" | python3 -m json.tool

# Bedrock inference
curl -s http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer ${LITELLM_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-sonnet-4-6","messages":[{"role":"user","content":"say hi"}]}' \
  | python3 -m json.tool

# Claude Code wrapper inference (requires claude-revproxy sandbox running)
curl -s http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer ${LITELLM_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-code-wrapper-local","messages":[{"role":"user","content":"what is 2+2?"}]}' \
  | python3 -m json.tool
```

---

## Operations

```bash
# Restart LiteLLM after config.yaml changes
docker compose -f ~/home-lab/docker/compose.yml restart litellm

# Tail logs
docker compose -f ~/home-lab/docker/compose.yml logs -f litellm

# View model list
docker compose -f ~/home-lab/docker/compose.yml exec litellm \
  curl -s http://localhost:4000/v1/models

# Start / restart the claude-code wrapper (after reboot or sandbox rebuild)
bootstrap/setup-claude-revproxy.sh

# Sync OAuth credentials to the wrapper sandbox (after claude auth login on host)
bootstrap/sync-claude-credentials.sh

# Check wrapper is listening
_SB=$(docker ps --filter 'name=openshell-claude-revproxy-' --format '{{.Names}}' | head -1)
docker exec "$_SB" ss -tlnp | grep ':8000'
```

---

## Deferred

| Item | Notes |
|---|---|
| **Additional providers** | OpenAI, Gemini, xAI stubs in `config.yaml`; activate when keys available (Phase 9) |
| **LiteLLM virtual keys / spend tracking** | Budget limits per sandbox. Needs SQLite/Postgres backend. Skip for now. |
| **LiteLLM UI** | Ships at `/ui`; disabled by default. Enable if spend visibility wanted. |
| **Per-sandbox inference override** | All sandboxes share one active backend. Per-sandbox overrides require separate gateway instances. |
| **systemd timer for credentials sync** | Keep OAuth token in `openshell-claude-revproxy` sandbox fresh without manual `sync-claude-credentials.sh`. |
