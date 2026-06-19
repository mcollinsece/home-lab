# Homelab Agentic AI Stack — Setup Plan

**Target:** Debian VM running NVIDIA OpenShell + NemoClaw + NeMo Agent Toolkit,
hosting sandboxed coding agents (Claude Code and Grok Build live; Codex and Gemini CLI planned)
with three inference auth paths: Bedrock via LiteLLM, Claude OAuth via claude-code-openai-wrapper, and Grok OAuth via grok-openai-wrapper.

> **Current platform state:** [../current/platform.md](../current/platform.md) — hardware, IPs, running services, pending items

> **Environment & intent:** This runs on a Proxmox VM on a single Dell OptiPlex — a **transitional development host**, not the final home. The plan is to migrate to a larger box (and eventually a compute cluster) once the stack is proven, which is why portability is a first-class design goal — Docker Compose services map to k8s manifests, a local registry is already in place, inference is remote. Because it's a dev host, it is **not a security-sensitive environment**: security still matters, but runtime/posture choices favour getting the stack working.

---

## How the stack fits together

| Layer | What it is | Role in your setup |
|---|---|---|
| **OpenShell** ([repo](https://github.com/NVIDIA/OpenShell)) | Open-source sandbox runtime (Apache 2.0, alpha). Gateway + per-sandbox containers, deny-by-default YAML network/filesystem/process policies, credential providers, inference router. | The foundation. Runs Claude Code, Codex, and other agents unmodified. |
| **LiteLLM** ([repo](https://github.com/BerriAI/litellm)) | OpenAI-compatible inference proxy. Single credential boundary for Bedrock. Also reverse-proxies the claude-code wrapper. | The inference hub. Sandboxes via `inference.local` → LiteLLM → Bedrock; OpenClaw also uses `claude-code-wrapper-local` via LiteLLM. |
| **NemoClaw** ([repo](https://github.com/NVIDIA/NemoClaw), [docs](https://docs.nvidia.com/nemoclaw/latest/)) | NVIDIA's one-command stack for running **OpenClaw** inside an OpenShell sandbox. Docker-based. | Phase 7 ✅ fully live. Director "Ready"; `openclaw.lab.lan` live; three models functional in picker: `litellm/claude-sonnet-4-6`, `litellm/claude-code-wrapper-local`, `litellm/grok-wrapper-local`. Probe service persistent. |
| **claude-code-openai-wrapper** ([repo](https://github.com/RichardAtCT/claude-code-openai-wrapper)) | Python FastAPI app that wraps `claude_agent_sdk`, exposing the Claude Code agent as an OpenAI-compatible HTTP endpoint. | Phase 7 ✅ live. Runs inside `openshell-claude-revproxy` sandbox; spawns `claude` CLI via OAuth/Pro; accessible from LiteLLM via Docker ai-net alias `claude-code-wrapper:8000`. |
| **grok-openai-wrapper** (custom) | Python FastAPI app that wraps Grok Build CLI, exposing it as an OpenAI-compatible HTTP endpoint. | ✅ live (2026-06-15). Runs inside `openshell-grok-wrapper` sandbox; spawns `grok --single` via OAuth/Grok subscription; accessible from LiteLLM via Docker ai-net alias `grok-wrapper:8001`. |
| **NeMo Agent Toolkit** ([repo](https://github.com/NVIDIA/NeMo-Agent-Toolkit)) | Python library for orchestrating teams of agents across frameworks. | Phase 8+. The orchestration brain that coordinates sandboxed agents. |

Key facts:

- `openshell sandbox create -- claude` launches Claude Code in an isolated container. Same for `codex`, `opencode`, `copilot`.
- Sandboxes using `inference.local` hold no credentials; keys stay in LiteLLM.
- The claude-code wrapper uses OAuth/Pro subscription — no Bedrock credentials needed in the sandbox.
- NemoClaw runs OpenClaw itself inside an OpenShell sandbox — the director is also isolated.
- Network egress is deny-by-default; you open it with hot-reloadable YAML policies.
- No GPU needed — GPU only matters for local inference (Ollama/NIM/vLLM), skipped for now.

---

## VM sizing requirements

The current VM (4 vCPU / 15 GB / 108 GB) meets the minimum. The **recommended** column
describes the migration-target box, not this OptiPlex.

| Resource | Minimum | Recommended for multi-agent |
|---|---|---|
| vCPU | 4 | 8 |
| RAM | 8 GB | 16–24 GB |
| Disk | 20 GB | 60+ GB (sandbox images ~2.4 GB each, Docker layer cache) |

Software: Docker Engine, Node.js 22.16+, npm 10+, git.

### Runtime: Docker

**This stack runs on Docker Engine (rootful daemon).** NemoClaw requires Docker — it
builds and manages the OpenClaw sandbox image using Docker. OpenShell is configured with
`OPENSHELL_DRIVERS=docker` so all agent sandboxes also run as Docker containers.

**Why not rootless Podman?** The original plan was Podman-first (validated in Phases 1–4
and still technically feasible for the baseline). NemoClaw does not support Podman as of
2026-06-13. Since NemoClaw is the chosen path for OpenClaw (NVIDIA-backed, proper sandbox
isolation for the director), Docker is the correct runtime choice.

**Podman re-evaluation is tracked in Phase 8:** if NemoClaw adds Podman support in a future
release, migrating back would give better security posture (rootless vs. rootful daemon) for
a single-user homelab. For now, Docker is the pragmatic choice.

---

## Architecture

```
   LAN (*.lab.lan) ─────────┐
                            ▼
                  ┌──────────────────────────────────────────────┐
                  │  homelab VM (.51)                             │
                  │                                               │
                  │   ┌──────────┐  :80/:443                     │
                  │   │ Traefik  │  discovers via /var/run/docker.sock
                  │   └────┬─────┘  routes by label on ai-net    │
   AdGuard LXC (.53)       │                                      │
   *.lab.lan → .51         │   ┌────────────────┐               │
                           │   │ LiteLLM :4000  │               │   ──▶  AWS Bedrock
                           │   │ (ai-net)       │               │        (claude-sonnet-4-6)
                           │   └───────┬────────┘               │
                           │           │                          │
                           │   OpenShell lab gateway :17670       │
                           │     inference.local → LiteLLM       │
                           │   ┌────────────┐                     │
                           │   │ claude-code│                     │
                           │   │ sandbox    │  (interactive;      │
                           │   │ (Ready)    │   inference.local)  │
                           │   ├────────────┤                     │
                           │   │ claude-    │  CLAUDE_CODE_AUTH   │  ──▶  api.anthropic.com
                           │   │ revproxy   │  _METHOD=cli (OAuth)│       (Pro subscription)
                           │   │ sandbox    │  ai-net alias:      │
                           │   │ :8000      │  claude-code-wrapper│
                           │   └────────────┘                     │
                           │   NemoClaw (own gw :8080)            │
                           │   ┌────────────┐                     │
                           │   │ "director" │ OpenClaw ✅ live    │
                           │   │ (OpenClaw) │ models:             │
                           │   │ ai-net     │  litellm/claude-    │
                           │   │ alias:     │  sonnet-4-6         │
                           │   │ openclaw-  │  litellm/claude-    │
                           │   │ director   │  code-wrapper-local │
                           │   └────────────┘                     │
                           │   ai-net (Docker bridge 172.18.x)    │
                           └──────────────────────────────────────┘
```

### Now → Future mapping

| Concern | Now (single VM) | Future (k8s / multi-node) |
|---|---|---|
| Agent sandboxes | OpenShell (Docker driver) | OpenShell on k8s nodes, policies → NetworkPolicy |
| Supporting services | Docker **Compose** (`docker/compose.yml`) | Deployments / Jobs / CronJobs |
| Isolation & cleanup | one Compose per project; `docker compose down` | Namespace per project; `kubectl delete ns` |
| Images | build locally → push to local registry `:5000` | same registry → cluster pulls from it |
| Config | env files | ConfigMaps |
| Secrets | untracked `.secrets/*.env` → `env_file:` in Compose | k8s Secrets |
| Inference | remote APIs (Bedrock via LiteLLM, OAuth via wrapper) | vLLM cluster (GPU nodes) + remote fallback |
| Networking | `ai-net` Docker bridge | CNI (Flannel/Cilium) + Services |
| Exposure | Traefik labels → `<name>.lab.lan` | Ingress (Traefik/nginx) |

---

## Repository layout

```
home-lab/
├── README.md                              ✅ repo index + quick-add-service guide
├── .gitignore                             ✅ **/*.env (except committed examples), *-key.pem
├── docs/
│   ├── current/
│   │   ├── platform.md                   ✅ hardware, IPs, running services — current state
│   │   ├── todos.md                      ✅ immediate next steps + phase punchlist
│   │   └── litellm-proxy.md              ✅ LiteLLM architecture + operations
│   ├── future/
│   │   └── ai-dev-ground.md              ✅ this file — AI stack plan
│   └── diagrams/
│       ├── claude-code-agent-sandbox-flow.md   ✅ deployed two-direction architecture
│       └── claude-code-wrapper-data-flow.md    ✅ wrapper data flow detail
├── bootstrap/
│   ├── setup-host.sh                     ✅ idempotent host rebuild (Docker, OpenShell, tools)
│   ├── init-secrets.sh                   ✅ populate .secrets/*.env from password manager
│   ├── nemoclaw-director-probe.sh        ✅ probe: CORS, provider, shim, ai-net, openclaw start
│   ├── setup-claude-revproxy.sh          ✅ start wrapper in openshell-claude-revproxy sandbox
│   ├── sync-claude-credentials.sh        ✅ copy host ~/.claude to sandbox /root/.claude
│   ├── osbox                             ✅ OpenShell sandbox launcher helper
│   └── TROUBLESHOOTING.md               ✅ failure modes + fixes
├── docker/
│   └── compose.yml                       ✅ Traefik, Portainer, Registry, LiteLLM
├── traefik/                              ✅ static config + TLS config + certs + README
│   └── dynamic/
│       ├── openclaw-nemoclaw.yml         ✅ static route: openclaw.lab.lan → openclaw-director:18789
│       └── traefik-dashboard.yml         ✅ static route: traefik dashboard
├── litellm/
│   ├── config.yaml                       ✅ model routing (Bedrock + claude-code wrapper; future providers stubbed)
│   ├── litellm.env.example              ✅ non-secret config template
│   └── litellm.env                      gitignored; copy from example
├── openshell/                            ✅ agent sandbox runtime
│   ├── gateway.env                       ✅ gateway driver=docker + bind (symlinked into ~/.config)
│   ├── policies/claude-code.yaml        ✅ Claude Code network policy (Anthropic + api.anthropic.com egress)
│   └── README.md                        ✅ reproduce + sandbox lifecycle + inference.local
├── projects/
│   └── _template/                       ✅ Docker Compose template for new services
└── k8s/                                 ☐ (future) manifests the Compose services graduate into
```

---

## Phases 1–2 — base prep + OpenShell ✅ DONE

Built 2026-06-12 and reproducible from a clean checkout via
[`bootstrap/setup-host.sh`](../../bootstrap/setup-host.sh).

- **Phase 1:** Node 22 (`node v22.22.3`).
- **Phase 2:** OpenShell `v0.0.62`; `claude-code` sandbox `Ready` with
  [`openshell/policies/claude-code.yaml`](../../openshell/policies/claude-code.yaml);
  `claude login` done; AdGuard `*.lab.lan` wildcard live.

## Phase 3 — Dual auth: Max/Pro subscription ↔ Bedrock per project ✅ DONE (2026-06-12)

Claude Code picks its backend per project via settings precedence. The preferred pattern
for new sandboxes is `ANTHROPIC_BASE_URL=https://inference.local` → LiteLLM → Bedrock.
The per-project Bedrock switching pattern (`.claude/settings.json` env block) still works
for sandboxes with direct AWS key access, but `inference.local` is the preferred path.

## Phase 4 — OpenClaw director ✅ DONE (migrated to NemoClaw in Phase 7)

Originally deployed as a rootless Podman Quadlet (`openclaw.container`). Migrated to
NemoClaw in Phase 7 (2026-06-13): NemoClaw runs OpenClaw inside an OpenShell sandbox,
providing proper isolation for the director itself. The custom Containerfile and
entrypoint.sh are no longer needed; NemoClaw manages the image.

**Local registry** (`registry.lab.lan`) remains in service as a Docker Compose service
for future custom images.

## Phase 4.5 — LiteLLM proxy ✅ DONE (2026-06-13)

LiteLLM is deployed as a Docker Compose service in `docker/compose.yml`. Bedrock routing
confirmed end-to-end. Architecture and operations in
[docs/current/litellm-proxy.md](../current/litellm-proxy.md).

- **Bedrock model ID:** `us.anthropic.claude-sonnet-4-6` (no date suffix — verified)
- **max_tokens cap:** 64,000 — prevents OpenClaw's 200K requests from hitting Bedrock's 128K limit
- **Single Bedrock credential boundary:** all Bedrock inference routes through LiteLLM; no sandbox holds AWS keys

## Phase 5 — Codex CLI sandbox

Add OpenAI Codex CLI as a first-class `osbox`-managed agent.

- **`init-secrets` update** — add Codex section: prompts for `OPENAI_API_KEY`, writes `.secrets/codex.env`.
- **`openshell/policies/codex.yaml`** — egress policy for `api.openai.com`.
- **`--codex` flag for `osbox`** — sandboxes use `OPENAI_BASE_URL=https://inference.local/v1 OPENAI_API_KEY=unused`.
- **Verify** `osbox codex-1 --codex --headless`.

## Phase 6 — Gemini CLI sandbox

Add Google Gemini CLI as a sandboxed agent.

- **`init-secrets` update** — add Gemini section: `GOOGLE_API_KEY`, writes `.secrets/gemini.env`.
- **`openshell/policies/gemini.yaml`** — egress for `generativelanguage.googleapis.com` + GCP auth.
- **`--gemini` flag for `osbox`** — sandboxes use `GOOGLE_GENAI_BASE_URL=https://inference.local`.
- **Verify** `osbox gemini-1 --gemini --headless`.

## Phase 7 — NemoClaw + Docker migration + claude-code-wrapper-local ✅ DONE (2026-06-13/14)

**Fully live.** All services migrated from rootless Podman Quadlets to Docker Engine + Docker Compose.
OpenShell gateway driver = docker. Static file-provider routes in `traefik/dynamic/` work around
the Docker provider "client version 1.24 too old" skew. gateway.env kept simple; symlink restore
required after nemoclaw onboard.

**What's deployed:**

- NemoClaw director ("director" sandbox) is `Ready`; `openclaw.lab.lan` returns 200 and the dashboard loads.
- Routing: Traefik → `openclaw-director:18789` (Docker ai-net alias). No SSH tunnel or socat.
- Probe service (`nemoclaw-director-control-ui`) handles: CORS patch, litellm provider rename,
  claude-code-wrapper-local model add, pass-through shim, ai-net connect, openclaw gateway start.
- OpenClaw model picker: `litellm/claude-sonnet-4-6` (→ Bedrock) and `litellm/claude-code-wrapper-local` (→ wrapper).
- **claude-code-wrapper-local:** `claude-code-openai-wrapper` running in `openshell-claude-revproxy`
  OpenShell sandbox; `CLAUDE_CODE_AUTH_METHOD=cli` (OAuth/Pro); connected to ai-net as `claude-code-wrapper`;
  LiteLLM routes three aliases (`claude-code-sonnet`, `claude-code/sonnet`, `claude-code-wrapper-local`) to it.
  End-to-end verified: OpenClaw → LiteLLM → wrapper → Claude Code → Anthropic.

```bash
curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash
# During wizard: OpenAI-compatible → LiteLLM key → http://localhost:4000/v1 → claude-sonnet-4-6
systemctl --user enable --now nemoclaw-director-control-ui   # probe service
bootstrap/setup-claude-revproxy.sh                           # wrapper sandbox
bootstrap/sync-claude-credentials.sh                         # OAuth credentials
```

## Phase 8 — Podman re-evaluation + NeMo Agent Toolkit

**Podman re-evaluation:** Monitor NemoClaw release notes for Podman driver support.
If added, switching back to rootless Podman gives better security posture (no root daemon)
for a single-user homelab. The migration would be `OPENSHELL_DRIVERS=podman` +
converting Compose services back to Quadlets.

**NeMo Agent Toolkit orchestration:**
```bash
pip install nvidia-nat   # check repo for current package name
```
Define workflows in YAML/Python routing tasks across agents. Use MCP to expose tools
to/from sandboxes, A2A to delegate between agents. Pattern: NeMo Toolkit as
planner/router → dispatches into Claude Code / Codex / Gemini sandboxes → OpenShell
enforces what each can touch.

## Phase 9 — Alternative provider support

See [docs/current/todos.md](../current/todos.md) Phase 9 for the full list. In short:
add OpenAI, xAI Grok, Google Gemini, Ollama, and OpenRouter as additional LiteLLM backends.
Each is a stub already in `litellm/config.yaml` — activate by adding the API key to
`init-secrets.sh` and uncommenting the model block.

---

## Exposing services via Traefik

Traefik discovers containers by label over the Docker socket. To expose any service at
`<name>.lab.lan`, put it on `ai-net` and add labels:

```yaml
# In docker-compose.yaml / compose.yml
container_name: grafana         # REQUIRED — hostname derived from this
networks: [ai-net]
labels:
  - traefik.enable=true
  # Only if the container doesn't listen on :80:
  # - traefik.http.services.grafana.loadbalancer.server.port=3000
```

NemoClaw-managed containers (like the director) aren't discovered by Traefik's Docker provider
due to API version skew. Use static file routes in `traefik/dynamic/` instead — they hot-reload.

See [traefik/README.md](../../traefik/README.md) for the full label reference.

---

## Non-agent services: Docker Compose pattern

Supporting services (databases, dashboards, proxies) run as Docker Compose services.
The template is at `projects/_template/compose.yaml`:

```yaml
services:
  myapp:
    image: docker.io/library/nginx:1.27
    container_name: myapp
    networks: [ai-net]
    restart: unless-stopped
    labels:
      - traefik.enable=true

networks:
  ai-net:
    external: true
```

**Start:** `docker compose -f projects/<name>/compose.yaml up -d`
**Update:** bump image tag, `docker compose pull && docker compose up -d`
**Teardown:** `docker compose down`

---

## Path to k3s + vLLM

When you add a second/third Optiplex:

1. **Install k3s** on this node (`server`), join others as `agent`s.
2. **Point k3s at the existing local registry** — images need no rebuild.
3. **Graduate Compose → manifests:** `compose.yml` services → Deployment/Job; `env_file` → ConfigMap; `.secrets/*.env` → k8s Secret; `ai-net` → namespace + Services.
4. **Graduate OpenShell sandboxes:** container images translate directly; OpenShell network policies → NetworkPolicy objects.
5. **vLLM cluster:** GPU passthrough on Proxmox nodes; vLLM Deployments via the device plugin. Agents point `ANTHROPIC_BASE_URL` at the in-cluster vLLM Service — the only app-side change.
6. **GitOps (optional):** Flux/Argo against this repo for self-reconciling state.

---

## Order of operations

- [x] Phase 1: Node 22
- [x] Phase 2: OpenShell + Claude Code sandbox
- [x] Phase 3: Subscription ↔ Bedrock per-project switching
- [x] Phase 4: OpenClaw director (now managed by NemoClaw — Phase 7)
- [x] Phase 4.5: LiteLLM proxy (Docker Compose, Bedrock routing verified)
- [x] Phase 7: Docker + NemoClaw migration — **fully live** (director Ready, openclaw.lab.lan, claude-code-wrapper-local working end-to-end)
- [x] **Grok wrapper** (2026-06-15): grok-wrapper-local live — spawns Grok Build CLI with OAuth, same pattern as claude-code-wrapper
- [ ] Phase 5: Codex CLI sandbox
- [ ] Phase 6: Gemini CLI sandbox
- [ ] Phase 8: Podman re-evaluation + NeMo Agent Toolkit orchestration
- [ ] Phase 9: Alternative providers (OpenAI, Gemini, OpenRouter)
- [ ] k3s + vLLM on a second node

See [docs/current/todos.md](../current/todos.md) for the immediate next-step sequence.

---

## Caveats

- **Everything NVIDIA here is alpha** (OpenShell and NemoClaw both carry "do not use in production" banners). Pin versions where you can (`OPENSHELL_VERSION`).
- The claude-code-openai-wrapper requires an active Claude Pro/Max subscription. Run `bootstrap/sync-claude-credentials.sh` after `claude auth login` on the host.
- Subscription auth in long-running agentic loops can hit rate limits — Bedrock via LiteLLM is the better default for unattended/batch work.
- Verify current Bedrock model IDs in the [Claude Code Bedrock docs](https://code.claude.com/docs/en/amazon-bedrock) when updating. Claude 4.x IDs have no date suffix; older models do.
- Pin image tags — no `:latest`. Secrets out of git.

---

## Sources

- [NVIDIA OpenShell repo](https://github.com/NVIDIA/OpenShell) · [OpenShell blog](https://developer.nvidia.com/blog/run-autonomous-self-evolving-agents-more-safely-with-nvidia-openshell/)
- [NemoClaw repo](https://github.com/NVIDIA/NemoClaw) · [NemoClaw docs](https://docs.nvidia.com/nemoclaw/latest/)
- [NeMo Agent Toolkit repo](https://github.com/NVIDIA/NeMo-Agent-Toolkit)
- [LiteLLM repo](https://github.com/BerriAI/litellm)
- [OpenClaw repo](https://github.com/openclaw/openclaw) · [OpenClaw docs](https://docs.openclaw.ai)
- [claude-code-openai-wrapper](https://github.com/RichardAtCT/claude-code-openai-wrapper)
- [Claude Code on Amazon Bedrock](https://code.claude.com/docs/en/amazon-bedrock)
