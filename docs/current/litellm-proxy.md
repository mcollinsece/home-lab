# LiteLLM Proxy

> Architecture reference for the LiteLLM Docker Compose service.
> Operational tasks and remaining TODOs live in [todos.md](todos.md).

---

## Problem this solves

All pay-per-token inference routes through one OpenAI-compatible endpoint.
Backend changes happen in one config file. CLI tools inside agent sandboxes never
hold real credentials — they talk to `inference.local`, which the OpenShell gateway
routes to LiteLLM.

---

## Architecture

```
NemoClaw OpenClaw sandbox ────────────────────────► LiteLLM (:4000)
                                                          │
OpenShell gateway                                         │
  inference.local ──────────────────────────────────────►│
       ▲                                                  │
       │  all sandboxes point here                        ▼
  ┌────┴──────────────────────────────────┐        AWS Bedrock
  │  claude-code sandbox                   │        (primary today)
  │    ANTHROPIC_BASE_URL=inference.local  │
  │  gemini sandbox (Phase 6)              │        ── future ──
  │    GEMINI_BASE_URL=inference.local     │        OpenAI API
  │  codex sandbox (Phase 5)              │        Google Vertex
  │    OPENAI_BASE_URL=inference.local/v1  │        xAI / Grok
  └───────────────────────────────────────┘        Ollama (local)
```

**Key property**: the CLI tools (Claude Code, Codex, Gemini) are the agentic runtime.
They do not provide the model. Their own OAuth sessions are irrelevant when
`inference.local` is the endpoint. Swapping backends is a single `litellm/config.yaml`
change — no sandbox is touched.

---

## Components

| Component | What it does |
|---|---|
| **LiteLLM** (Docker Compose service) | OpenAI-compatible proxy; sole holder of Bedrock creds; routes to Bedrock today, extensible to any provider |
| **OpenShell provider `litellm-local`** | Routes `inference.local` from the gateway to LiteLLM at `http://localhost:4000/v1` |
| **NemoClaw OpenClaw** | Configured with LiteLLM as the OpenAI-compatible provider during `nemoclaw onboard` |

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

```yaml
model_list:
  - model_name: claude-sonnet-4-6
    litellm_params:
      model: bedrock/us.anthropic.claude-sonnet-4-6
      aws_access_key_id: os.environ/AWS_ACCESS_KEY_ID
      aws_secret_access_key: os.environ/AWS_SECRET_ACCESS_KEY
      aws_region_name: os.environ/AWS_REGION
      max_tokens: 64000
    model_info:
      max_tokens: 64000
      max_input_tokens: 128000
      max_output_tokens: 64000

litellm_settings:
  master_key: os.environ/LITELLM_MASTER_KEY

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
```

`max_tokens: 64000` cap prevents NemoClaw's OpenClaw from requesting 200K tokens,
which Bedrock rejects (128K limit on cross-region inference profiles).

Bedrock model ID: `us.anthropic.claude-sonnet-4-6` (no date suffix — Claude 4.x
dropped the date from the cross-region inference profile name). Verified via Bedrock
SigV4 API. See comment in the actual `litellm/config.yaml` for the verification command.

---

## Secrets

Populated by `init-secrets`. Injected into the Docker Compose `litellm` service via `env_file:`.

| Secret | Source | Consumer |
|---|---|---|
| `LITELLM_MASTER_KEY` | `openssl rand -hex 32` (auto) | LiteLLM (gates all inbound) + OpenShell provider + NemoClaw onboard |
| `AWS_ACCESS_KEY_ID` | IAM console | LiteLLM → Bedrock (sole credential holder) |
| `AWS_SECRET_ACCESS_KEY` | IAM console | LiteLLM → Bedrock |
| `AWS_REGION` | e.g. `us-east-1` | LiteLLM → Bedrock |

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

NemoClaw's OpenClaw sandbox will route all inference through LiteLLM, which routes
to Bedrock. The sandbox itself holds no AWS credentials.

---

## Sandbox launch pattern

Sandboxes need no credential injection. `inference.local` is the uniform endpoint:

```bash
# Claude Code sandbox
openshell sandbox create --name claude-code --no-auto-providers \
    --policy openshell/policies/claude-code.yaml \
    --env ANTHROPIC_BASE_URL=https://inference.local \
    --env ANTHROPIC_API_KEY=unused \
    -- claude

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

# Model list
curl -s http://localhost:4000/v1/models \
  -H "Authorization: Bearer ${LITELLM_KEY}" | python3 -m json.tool

# End-to-end inference
curl -s http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer ${LITELLM_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-sonnet-4-6","messages":[{"role":"user","content":"say hi"}]}' \
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
```

---

## Deferred

| Item | Notes |
|---|---|
| **Additional providers** | OpenAI, Gemini, xAI stubs in `config.yaml`; activate when keys available (Phase 9) |
| **LiteLLM virtual keys / spend tracking** | Budget limits per sandbox. Needs SQLite/Postgres backend. Skip for now. |
| **LiteLLM UI** | Ships at `/ui`; disabled by default. Enable if spend visibility wanted. |
| **Per-sandbox inference override** | All sandboxes share one active backend. Per-sandbox overrides require separate gateway instances. |
