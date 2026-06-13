# LiteLLM Proxy

> Architecture spec and config reference for the LiteLLM Quadlet service.
> Implementation tasks live in [todos.md](todos.md) under Phase 4.5.

---

## Problem this solves

OpenClaw has no native Amazon Bedrock provider. OpenShell sandboxes currently require
per-sandbox credential injection (`osbox --bedrock`) to reach any non-subscription
backend. There is no single place to switch all inference traffic from one backend to
another.

LiteLLM is the answer: one OpenAI-compatible HTTP endpoint that acts as the routing
layer for the entire homelab. Backend changes happen in one config file.

---

## Design pattern (mirrors NVIDIA's stack at homelab scale)

NVIDIA's OpenShell has a built-in inference privacy router called `inference.local`.
Every sandbox — regardless of which CLI tool is running inside it — sets its API
base URL to `https://inference.local`. The OpenShell gateway operator configures
the real backend independently of the sandboxes; credentials never enter the sandbox.

This is the same design pattern we apply here, with LiteLLM as the configurable
backend that OpenShell routes to:

```
OpenClaw (Quadlet director) ──────────────────────► LiteLLM (:4000)
                                                          │
OpenShell gateway                                         │
  inference.local ──────────────────────────────────────►│
       ▲                                                  │
       │  all sandboxes point here                        ▼
  ┌────┴──────────────────────────────────┐        AWS Bedrock
  │  claude-code sandbox                   │        (today)
  │    ANTHROPIC_BASE_URL=inference.local  │
  │  gemini sandbox                        │        ── future ──
  │    GEMINI_BASE_URL=inference.local     │        OpenAI API
  │  codex sandbox                         │        Google Vertex
  │    OPENAI_BASE_URL=inference.local/v1  │        xAI / Grok
  │  grok sandbox                          │        Ollama (local)
  │    ...=inference.local                 │
  └───────────────────────────────────────┘
```

**Key property**: the CLI tools are the agentic runtime (tool use, planning, code
execution). They do not provide the model. Their own OAuth sessions / SaaS logins
are irrelevant for inference when `inference.local` is the endpoint — Bedrock
(via LiteLLM) serves the model. Swapping from Bedrock to any other backend is a
single LiteLLM config change; no sandbox is touched.

---

## Components

| Component | What it does |
|---|---|
| **LiteLLM Quadlet** | OpenAI-compatible proxy; holds real backend credentials; routes to Bedrock (today) and future providers |
| **OpenShell provider** | Entry in the OpenShell gateway that points `inference.local` to LiteLLM |
| **OpenShell inference route** | Active gateway config: `inference.local` → `litellm-local` provider → LiteLLM |
| **OpenClaw litellm provider** | OpenClaw's non-claude-cli model backend; HTTP to `http://litellm:4000` |

---

## File layout

```
litellm/
├── litellm.container     Quadlet unit file
├── litellm.env.example   Non-secret runtime config (committed)
├── litellm.env           Actual runtime config (gitignored)
└── config.yaml           LiteLLM model routing config (committed)
```

---

## LiteLLM config.yaml

```yaml
# LiteLLM model routing config.
# Mounted read-only at /app/config.yaml inside the container.
# Restart litellm after changes: systemctl --user restart litellm

model_list:

  # --- Bedrock: Claude Sonnet 4.6 (cross-region inference profile) ---
  # Verify the exact model ID in the AWS console:
  #   Bedrock → Inference → Cross-region inference → us-east-1 → Claude Sonnet
  # Typical format: us.anthropic.claude-sonnet-4-6-<date>-v1:0
  - model_name: claude-sonnet-4-6
    litellm_params:
      model: bedrock/us.anthropic.claude-sonnet-4-6-20250514-v1:0
      aws_access_key_id: os.environ/AWS_ACCESS_KEY_ID
      aws_secret_access_key: os.environ/AWS_SECRET_ACCESS_KEY
      aws_region_name: os.environ/AWS_REGION

  # Alias so both model name forms resolve to the same backend.
  # OpenShell inference router sends "anything" as the model name (gateway rewrites it);
  # OpenClaw and direct clients may send specific names.
  - model_name: bedrock/us.anthropic.claude-sonnet-4-6-20250514-v1:0
    litellm_params:
      model: bedrock/us.anthropic.claude-sonnet-4-6-20250514-v1:0
      aws_access_key_id: os.environ/AWS_ACCESS_KEY_ID
      aws_secret_access_key: os.environ/AWS_SECRET_ACCESS_KEY
      aws_region_name: os.environ/AWS_REGION

  # --- Future providers (uncomment when credentials are available) ---
  # - model_name: gpt-4o
  #   litellm_params:
  #     model: openai/gpt-4o
  #     api_key: os.environ/OPENAI_API_KEY

  # - model_name: gemini-2-5-pro
  #   litellm_params:
  #     model: gemini/gemini-2.5-pro
  #     api_key: os.environ/GOOGLE_API_KEY

  # - model_name: grok-3
  #   litellm_params:
  #     model: xai/grok-3
  #     api_key: os.environ/XAI_API_KEY

  # - model_name: ollama-local
  #   litellm_params:
  #     model: openai/mistral
  #     api_base: http://host.containers.internal:11434/v1
  #     api_key: none

litellm_settings:
  master_key: os.environ/LITELLM_MASTER_KEY

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
```

---

## litellm.container (Quadlet)

```ini
[Unit]
Description=LiteLLM proxy — unified model routing for OpenClaw and OpenShell sandboxes
Wants=network-online.target
After=network-online.target

[Container]
ContainerName=litellm
Image=ghcr.io/berriai/litellm:main-stable
Network=ai-net.network

# Model routing config — restart required after changes
Volume=%h/home-lab/litellm/config.yaml:/app/config.yaml:ro,z

# Non-secret config
EnvironmentFile=%h/home-lab/litellm/litellm.env

# LiteLLM master key — required by all clients (OpenClaw, osbox, OpenShell provider)
Secret=litellm_master_key,type=env,target=LITELLM_MASTER_KEY

# AWS Bedrock credentials
Secret=bedrock_aws_access_key_id,type=env,target=AWS_ACCESS_KEY_ID
Secret=bedrock_aws_secret_access_key,type=env,target=AWS_SECRET_ACCESS_KEY
Secret=bedrock_aws_region,type=env,target=AWS_REGION

# Future providers: uncomment when keys are available
# Secret=openai_api_key,type=env,target=OPENAI_API_KEY
# Secret=google_api_key,type=env,target=GOOGLE_API_KEY
# Secret=xai_api_key,type=env,target=XAI_API_KEY

Label=traefik.enable=true
Label=traefik.http.services.litellm.loadbalancer.server.port=4000

[Service]
Restart=on-failure
TimeoutStartSec=60

[Install]
WantedBy=default.target
```

---

## litellm.env.example

```bash
# litellm.env — non-secret runtime config for the LiteLLM Quadlet.
# Secrets (AWS keys, master key) are injected via Podman secrets — not here.
# Copy to litellm.env; this file is committed, litellm.env is gitignored.

# Uncomment for verbose proxy logging during initial setup:
# LITELLM_LOG=INFO
```

---

## Secrets

| Secret | Source | Consumer |
|---|---|---|
| `litellm_master_key` | `openssl rand -hex 32` | LiteLLM (gates all inbound requests) + all clients |
| `bedrock_aws_access_key_id` | existing (init-secrets) | **moves to litellm.container** (remove from openclaw.container) |
| `bedrock_aws_secret_access_key` | existing | moves to litellm.container |
| `bedrock_aws_region` | existing | moves to litellm.container |

`init-secrets.sh` needs a new LiteLLM section: generates `litellm_master_key`, writes
it to `.secrets/litellm.env`, and creates the Podman secret.

---

## OpenShell gateway configuration

After LiteLLM is running, register it as an OpenShell provider and set it as the
active inference route. This is a **one-time host-level setup** (not per-sandbox):

```bash
# Create a provider pointing to LiteLLM on the ai-net bridge.
# host.containers.internal resolves to the Podman host from the gateway;
# litellm is reachable on ai-net by container name, but the gateway runs
# on the host — use the published address or host bridge IP instead.
openshell provider create \
    --name litellm-local \
    --type openai \
    --credential OPENAI_API_KEY=$(cat ~/.secrets/litellm.env | grep LITELLM_MASTER_KEY | cut -d= -f2) \
    --config OPENAI_BASE_URL=http://host.containers.internal:4000/v1

# Set litellm-local as the active inference route for all sandboxes.
# "claude-sonnet-4-6" matches the model_name in config.yaml.
openshell inference set \
    --provider litellm-local \
    --model claude-sonnet-4-6

# Verify
openshell inference get
```

> **Note on host resolution**: the OpenShell gateway runs as a systemd service on the
> host, not inside a container, so it reaches LiteLLM at the host's bridge IP or via
> `host.containers.internal`. If LiteLLM is also reachable at `localhost:4000` after
> port-publish, that also works. Verify connectivity:
> `curl http://localhost:4000/v1/models -H "Authorization: Bearer <litellm_master_key>"`

---

## Sandbox launch pattern (post Phase 4.5)

Once the OpenShell inference route is configured, sandboxes need no credential
injection. `inference.local` is the uniform endpoint:

```bash
# Claude Code sandbox (inference.local replaces ANTHROPIC_BASE_URL + key injection)
openshell sandbox create --name claude-code \
    --policy openshell/policies/claude-code.yaml \
    --env ANTHROPIC_BASE_URL=https://inference.local \
    --env ANTHROPIC_API_KEY=unused \
    -- claude

# Codex sandbox (OpenAI-compatible endpoint)
openshell sandbox create --name codex \
    --policy openshell/policies/codex.yaml \
    --env OPENAI_BASE_URL=https://inference.local/v1 \
    --env OPENAI_API_KEY=unused \
    -- codex

# Gemini sandbox
openshell sandbox create --name gemini \
    --policy openshell/policies/gemini.yaml \
    --env GEMINI_API_KEY=unused \
    --env GOOGLE_GENAI_BASE_URL=https://inference.local \
    -- gemini
```

The `osbox` script will be updated to use this pattern instead of injecting
real credentials. `--bedrock` and `--litellm` flags become obsolete; inference
routing is gateway-level.

---

## OpenClaw director configuration

OpenClaw is a Quadlet, not an OpenShell sandbox — it cannot use `inference.local`.
It reaches LiteLLM directly over `ai-net`:

```bash
# Inside the openclaw container, register LiteLLM as a provider:
podman exec --user node openclaw openclaw onboard \
    --auth-choice litellm-api-key \
    --non-interactive  # if supported, else run interactively
```

Or via config patch:
```json
{
  "models": {
    "providers": {
      "litellm": {
        "baseUrl": "http://litellm:4000/v1",
        "apiKey": "<litellm_master_key>"
      }
    }
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "litellm/claude-sonnet-4-6",
        "fallbacks": ["claude-cli/claude-sonnet-4-6"]
      }
    }
  }
}
```

Keep `claude-cli` as a fallback so the director can still run if LiteLLM is down.

**Remove** the broken `amazon-bedrock/us.anthropic.claude-sonnet-4-6` fallback from
`openclaw.json` — it was never a valid OpenClaw provider.

**Remove** the `Secret=bedrock_aws_*` directives from `openclaw.container` — Bedrock
credentials now live only in `litellm.container`.

---

## Toggle: switching backends

Once this is deployed, switching ALL inference (director + every sandbox) from one
backend to another is:

```bash
# Switch to a different Bedrock model
openshell inference update --model bedrock-claude-opus-4

# Switch OpenShell sandboxes to a future OpenAI backend
openshell inference update --provider openai-prod --model gpt-4o

# Switch OpenClaw's primary model
# Edit openclaw.env: OPENCLAW_DEFAULT_MODEL=litellm/gpt-4o
# then: systemctl --user restart openclaw
```

---

## What changes in existing services

| Service | Change |
|---|---|
| `openclaw.container` | Remove `Secret=bedrock_aws_*`; Bedrock creds move to `litellm.container` |
| `openclaw.json` | Replace `amazon-bedrock/...` fallback with `litellm/claude-sonnet-4-6` |
| `openclaw.env.example` | Replace `OPENCLAW_DEFAULT_MODEL=amazon-bedrock/...` comment with `litellm/claude-sonnet-4-6` |
| `osbox` | Remove `--bedrock` credential injection; sandboxes use `inference.local` natively |
| `setup-host.sh` | Add `litellm/` to Quadlet scan; add OpenShell provider creation step; add `litellm_master_key` to secrets guidance |
| `init-secrets.sh` | Add LiteLLM section: generate + store `litellm_master_key` |

---

## Deferred

| Item | Notes |
|---|---|
| **Additional LiteLLM backends** | OpenAI, Google Vertex, xAI — stubs in config.yaml above; activate when API keys are available |
| **Per-sandbox inference override** | OpenShell's gateway-scoped routing means all sandboxes share one active backend. Per-sandbox overrides require separate gateway instances. Evaluate when multi-provider simultaneous routing is needed. |
| **LiteLLM virtual keys / spend tracking** | Budget limits per agent or sandbox. Needs SQLite/Postgres backend. Skip for now; master key is sufficient. |
| **LiteLLM UI** | Ships at `/ui`; disabled by default. Enable if spend visibility is wanted. |
| **Subscription pass-through (Method 1)** | `forward_llm_provider_auth_headers: true` in litellm_settings forwards client OAuth tokens to Anthropic. Useful if some sandboxes should bill to the Max/Pro subscription instead of Bedrock. Evaluate after Bedrock path is stable. |
