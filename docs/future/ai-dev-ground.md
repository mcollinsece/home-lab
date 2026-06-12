# Homelab Agentic AI Stack — Setup Plan

**Target:** Debian VM running NVIDIA OpenShell + NemoClaw + NeMo Agent Toolkit, hosting sandboxed coding agents (Claude Code first, then Codex and Gemini CLI) with per-project switching between Claude Max/Pro subscription and Bedrock.

> **Current infrastructure state:** [../current/network-overview.md](../current/network-overview.md) — hardware, IPs, running services, pending items
> **History:** [../current/homelab-review.md](../current/homelab-review.md) — old Fedora setup and lessons learned

---

## How the stack fits together

| Layer | What it is | Role in your setup |
|---|---|---|
| **OpenShell** ([repo](https://github.com/NVIDIA/OpenShell)) | Open-source sandbox runtime (Apache 2.0, alpha). Gateway + per-sandbox containers, deny-by-default YAML network/filesystem/process policies, credential providers, inference router. | The foundation. Runs Claude Code, Codex, OpenCode, Copilot **unmodified** — all four ship in the base sandbox image. |
| **NemoClaw** ([repo](https://github.com/NVIDIA/NemoClaw), [docs](https://docs.nvidia.com/nemoclaw/latest/)) | One-command stack on top of OpenShell, for onboarding **OpenClaw** always-on agents with routed inference and hardened policy presets. Alpha. | Phase 5. Not how you run Claude Code — it's for the always-on OpenClaw assistant layer. |
| **NeMo Agent Toolkit** ([repo](https://github.com/NVIDIA/NeMo-Agent-Toolkit)) | Python library for connecting/orchestrating teams of agents across frameworks; MCP client/server and A2A support. | Phase 6. The orchestration brain that coordinates your sandboxed agents. |

Key facts:

- `openshell sandbox create -- claude` launches Claude Code in an isolated container. Same for `codex`, `opencode`, `copilot`.
- Credentials never touch the sandbox filesystem — OpenShell **providers** auto-discover keys (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, etc.) from the host shell and inject them as env vars at runtime.
- Network egress is deny-by-default; you open it with hot-reloadable YAML policies enforced at the HTTP method/path level (L7).
- NemoClaw's inference router supports Anthropic, Anthropic-compatible endpoints (covers Bedrock gateways), OpenAI, Gemini, NVIDIA endpoints, and local Ollama. The agent talks to `inference.local`; keys stay on the host.
- No GPU needed — GPU only matters for local inference (Ollama/NIM/vLLM), which you're skipping for now.

---

## VM sizing requirements

The current VM (4 vCPU / 15 GB / 108 GB) meets the minimum. Multi-agent use is better served by the recommended column.

| Resource | Minimum | Recommended for multi-agent |
|---|---|---|
| vCPU | 4 | 8 |
| RAM | 8 GB | 16–24 GB (each sandbox is a container; NemoClaw adds k3s + gateway) |
| Disk | 20 GB | 60+ GB (sandbox images ~2.4 GB each, plus Docker layer cache) |

Software: Docker Engine (docker-ce), Node.js 22.16+, npm 10+, git.

> NemoClaw's tested Linux path is Docker. On fresh docker-ce installs with the containerd image store enabled, `nemoclaw onboard` handles the fuse-overlayfs workaround automatically — no manual setup.

Docker and Podman can coexist. Install Docker for OpenShell sandboxes while keeping rootless Podman for the existing Quadlet services (Traefik, Portainer, future projects).

---

## Architecture

```
   LAN (*.lab.lan) ─────────┐
                            ▼
                  ┌──────────────────────────────────────────┐
                  │  homelab VM (.51)                         │
                  │   ┌──────────┐  :80                       │
                  │   │ Traefik  │  discovers via podman.sock  │
                  │   └────┬─────┘  routes by Host() on ai-net │
   AdGuard LXC (.53)       │                                   │
   *.lab.lan → .51         │   ┌────────────┐  ┌────────────┐  │   ──▶  Anthropic /
                           │   │ OpenShell  │  │  Portainer │  │        Bedrock /
                           │   │ sandboxes  │  │  (Quadlet) │  │        OpenAI APIs
                           │   └────────────┘  └────────────┘  │
                           │   ┌────────────┐  ┌────────────┐  │
                           │   │ projects/  │  │  local     │  │
                           │   │ (Quadlets) │  │  registry  │  │
                           │   └────────────┘  │  :5000     │  │
                           │   ai-net (internal bridge)      │  │
                           └──────────────────────────────────┘
```

### Now → Future mapping

| Concern | Now (single VM) | Future (k8s / multi-node) |
|---|---|---|
| Agent sandboxes | OpenShell (Docker-based) | OpenShell on k8s nodes, policies → NetworkPolicy |
| Supporting services | Podman **Quadlets** (`.container`, `.network`) | Deployments / Jobs / CronJobs |
| Isolation & cleanup | one unit per project; `systemctl --user disable` | Namespace per project; `kubectl delete ns` |
| Images | build locally → push to local registry `:5000` | same registry → cluster pulls from it |
| Config | env files | ConfigMaps |
| Secrets | untracked `.env` → Podman secrets | k8s Secrets (same shape) |
| Inference | remote APIs (Anthropic / Bedrock / OpenAI) | vLLM cluster (GPU nodes) + remote APIs as fallback |
| Networking | `ai-net` internal bridge | CNI (Flannel/Cilium) + Services |
| Exposure | Traefik labels → `<name>.lab.lan` | Ingress (Traefik/nginx) |

Picking Quadlets now is deliberate: the key/value shape (`Image=`, `Environment=`, `Secret=`, `Network=`) maps almost one-to-one to a Pod spec, so the port to manifests is mechanical, not a rewrite.

---

## Repository layout

```
home-lab/
├── README.md                       ✅ repo index + quick-add-service guide
├── .gitignore                      ✅ **/*.env, !*.env.example, *.key, age keys
├── docs/
│   ├── current/
│   │   ├── network-overview.md     ✅ hardware, IPs, running services, pending items
│   │   └── homelab-review.md       ✅ history of the old Fedora setup
│   └── future/
│       └── ai-dev-ground.md        ✅ this file — AI stack plan
├── networks/
│   └── ai-net.network              ✅ Quadlet: shared internal bridge
├── traefik/
│   ├── traefik.yml                 ✅ Traefik static config
│   ├── traefik.container           ✅ Quadlet for the reverse proxy
│   └── README.md                   ✅ how to expose a service
├── portainer/
│   ├── portainer.container         ✅ Quadlet: container-management UI
│   └── portainer-data.volume       ✅ Quadlet: persistent Portainer state
├── projects/
│   └── _template/                  ✅ copy this to start a new service
├── bootstrap/
│   └── setup-host.sh               ☐ idempotent: linger, ai-net, registry, dirs
├── registry/
│   └── registry.container          ☐ Quadlet for the local image registry
└── k8s/                            ☐ (future) manifests the Quadlets graduate into
```

---

## Phase 1 — VM base prep

```bash
# As root or with sudo on Debian
apt update && apt upgrade -y
apt install -y curl git ca-certificates gnupg

# Docker Engine (official repo — Debian's docker.io package is often stale)
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/debian $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
  > /etc/apt/sources.list.d/docker.list
apt update && apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
usermod -aG docker $USER   # log out/in after

# Node 22 LTS (NodeSource)
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt install -y nodejs
node -v   # must be >= 22.16
```

Hygiene: SSH key-only auth; this VM holds live credentials, keep it off any exposed network segment.

## Phase 2 — OpenShell + first Claude Code sandbox  ← START HERE

```bash
# Install OpenShell (binary installer)
curl -LsSf https://raw.githubusercontent.com/NVIDIA/OpenShell/main/install.sh | sh

# Create a Claude Code sandbox
openshell sandbox create -- claude
```

Useful commands:

```bash
openshell sandbox list
openshell sandbox connect <name>                              # SSH into the sandbox
openshell policy set <name> --policy policy.yaml --wait      # hot-reload network policy
openshell logs <name> --tail
openshell term                                               # k9s-style live TUI
```

Verify isolation: inside the sandbox, `curl https://api.github.com/zen` should return a 403 from the proxy until you apply a policy allowing it. The repo's `examples/sandbox-policy-quickstart/` has a runnable demo.

Also clone `https://github.com/NVIDIA/OpenShell.git` on the VM — the repo ships agent skills (`.agents/skills/`) for CLI help, gateway debugging, and **policy generation from plain English** (`generate-sandbox-policy`).

## Phase 3 — Dual auth: Max/Pro subscription ↔ Bedrock per project

Claude Code picks its backend per project via settings precedence (project `.claude/settings.json` overrides user `~/.claude/settings.json`). Subscription OAuth is the default; Bedrock is opt-in via env.

**Inside the sandbox**, per project:

```jsonc
// ~/.claude/settings.json — default = subscription (run `claude login` once)
{ }

// <bedrock-project>/.claude/settings.json
{
  "env": {
    "CLAUDE_CODE_USE_BEDROCK": "1",
    "AWS_REGION": "us-east-1",
    "ANTHROPIC_MODEL": "us.anthropic.claude-sonnet-4-6"   // verify current Bedrock model ID
  }
}
```

**Host-side wiring (OpenShell):**

1. Anthropic provider — auto-discovered from `ANTHROPIC_API_KEY`, or run `claude login` (OAuth) inside the sandbox once for subscription auth.
2. AWS provider — `openshell provider create` with `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` (scoped IAM user, `bedrock:InvokeModel*` only).
3. Network policy must allow both paths:
   - Subscription: `api.anthropic.com`, `console.anthropic.com`, `claude.ai`
   - Bedrock: `bedrock-runtime.<region>.amazonaws.com`, `sts.<region>.amazonaws.com`

Switching = `cd` into a project; no re-auth, no sandbox rebuild.

## Phase 4 — Add Codex and Gemini CLI

- **Codex**: already in the base sandbox image. `openshell sandbox create -- codex`; provider uses `OPENAI_API_KEY`; policy needs `api.openai.com`.
- **Gemini CLI**: not in the base image — use BYOC. Copy the [bring-your-own-container example](https://github.com/NVIDIA/OpenShell/tree/main/examples/bring-your-own-container), add `npm install -g @google/gemini-cli` to the Dockerfile, then `openshell sandbox create --from ./gemini-sandbox -- gemini`. Provider: `GEMINI_API_KEY`; policy: `generativelanguage.googleapis.com`.

One sandbox per agent keeps policies and credentials cleanly scoped.

## Phase 5 — NemoClaw (always-on OpenClaw agent)

```bash
curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash   # runs `nemoclaw onboard` wizard
```

- Wizard prompts: sandbox name → inference provider → network policy preset.
- Provider for this setup: **Anthropic** (option 4) or **Anthropic-compatible endpoint** (option 5) for Bedrock gateway.
- Dashboard at `http://127.0.0.1:18789/#token=...` (printed once — save it). LAN access: SSH tunnel `ssh -L 18789:127.0.0.1:18789 user@vm`.
- Lifecycle: use `nemoclaw onboard` / `nemoclaw <name> rebuild` — don't run `openshell` commands directly against NemoClaw-managed sandboxes.
- Terminal access: `nemoclaw <name> connect` then `openclaw tui`.

## Phase 6 — NeMo Agent Toolkit orchestration

```bash
# In a venv on the VM (or in its own sandbox)
pip install nvidia-nat   # check repo for current package name
```

- Define workflows in YAML/Python routing tasks across agents.
- Use **MCP** to expose tools to/from sandboxes, **A2A** to delegate between agents.
- Pattern: NeMo Agent Toolkit as planner/router → dispatches tasks into Claude Code / Codex / Gemini sandboxes → OpenShell enforces what each can touch.

---

## Exposing services via Traefik

Traefik (already running) discovers containers by label over the Podman socket. To expose any service at `<name>.lab.lan`, put it on `ai-net` and add labels:

```ini
ContainerName=<name>          # REQUIRED — without this the name becomes `systemd-<unit>`
Network=ai-net.network
Label=traefik.enable=true
# Label=traefik.http.services.<name>.loadbalancer.server.port=<port>  # only if not :80
```

The `defaultRule` is `Host("{{ normalize .Name }}.lab.lan")`, so `ContainerName=grafana` → `grafana.lab.lan` with no extra label. An explicit `traefik.http.routers.*.rule` label overrides this for custom hostnames.

Most agent sandboxes need no inbound exposure — they only make outbound API calls.

---

## Non-agent services: Quadlet pattern

Supporting services (databases, registries, dashboards) run as rootless Podman Quadlets. Three-file shape under `projects/<name>/`:

**`Containerfile`** — pin a base, tag images with a version:

```bash
podman build -t localhost:5000/<name>:0.1.0 projects/<name>
podman push   localhost:5000/<name>:0.1.0
```

**`<name>.container`** (symlinked into `~/.config/containers/systemd/`):

```ini
[Unit]
Description=<name>
After=network-online.target

[Container]
Image=localhost:5000/<name>:0.1.0
ContainerName=<name>
Network=ai-net.network
EnvironmentFile=%h/home-lab/projects/<name>/<name>.env   # untracked
Secret=anthropic_api_key,type=env,target=ANTHROPIC_API_KEY
Label=traefik.enable=true

[Service]
Restart=on-failure

[Install]
WantedBy=default.target
```

**`env.example`** — committed; the real `<name>.env` is gitignored.

**Revision:** bump the image tag, rebuild/push, edit `Image=`, `systemctl --user daemon-reload && systemctl --user restart <name>`. Roll back by pointing `Image=` at the old tag.

**Teardown:**

```bash
systemctl --user disable --now <name>
rm ~/.config/containers/systemd/<name>.container
systemctl --user daemon-reload
podman rmi localhost:5000/<name>:0.1.0   # optional
```

For one-shot / batch workflows: `podman run --rm ...` or a `Type=oneshot` unit + `.timer`. These become k8s `Job`/`CronJob` later.

---

## Path to k3s + vLLM

When you add a second/third Optiplex:

1. **Install k3s** on this node (`server`), join others as `agent`s.
2. **Point k3s at the existing local registry** — images need no rebuild.
3. **Graduate Quadlets → manifests:** `.container` → Deployment/Job; `EnvironmentFile` → ConfigMap; `Secret=` → k8s Secret; `ai-net` → namespace + Services. Keep manifests under `k8s/`.
4. **Graduate OpenShell sandboxes:** container images translate directly; OpenShell network policies → NetworkPolicy objects.
5. **vLLM cluster:** GPU passthrough on Proxmox nodes; vLLM Deployments with `nvidia.com/gpu` requests via the device plugin. Agents point their OpenAI-compatible base URL at the in-cluster vLLM Service — the only app-side change.
6. **GitOps (optional):** Flux/Argo against this repo for self-reconciling state.

---

## Order of operations

**Pre-work (see [current state](../current/network-overview.md#pending) for detail):**

- [ ] AdGuard wildcard `*.lab.lan → 192.168.0.51`
- [ ] Podman secrets: `anthropic_api_key`, AWS Bedrock creds
- [ ] `bootstrap/setup-host.sh`

**Phases:**

1. [ ] Phase 1: Docker Engine + Node 22
2. [ ] Phase 2: OpenShell + Claude Code sandbox ← **initial setup goal**
3. [ ] Phase 3: Subscription + Bedrock providers, per-project switching
4. [ ] Phase 4: Codex sandbox; Gemini CLI BYOC sandbox
5. [ ] Phase 5: NemoClaw + OpenClaw assistant
6. [ ] Phase 6: NeMo Agent Toolkit orchestration layer

---

## Caveats

- **Everything NVIDIA here is alpha** (OpenShell and NemoClaw both carry "do not use in production" banners). Pin versions where you can (`OPENSHELL_VERSION`).
- The blog's `--remote spark` flow targets DGX Spark; the no-GPU Debian VM uses the plain Docker path, which is the primary tested one.
- Subscription (Max/Pro) use in long-running automated loops can hit rate limits — Bedrock is the better default for unattended/batch work; subscription for interactive sessions.
- Verify current Bedrock model IDs in the [Claude Code Bedrock docs](https://code.claude.com/docs/en/amazon-bedrock) when you get there.
- Pin image tags — no `:latest`. Secrets out of git. One Quadlet per project for clean teardown.

---

## Sources

- [NVIDIA OpenShell repo](https://github.com/NVIDIA/OpenShell) · [OpenShell blog announcement](https://developer.nvidia.com/blog/run-autonomous-self-evolving-agents-more-safely-with-nvidia-openshell/)
- [NemoClaw repo](https://github.com/NVIDIA/NemoClaw) · [prerequisites](https://docs.nvidia.com/nemoclaw/latest/get-started/prerequisites.html), [quickstart](https://docs.nvidia.com/nemoclaw/latest/get-started/quickstart.html), [inference options](https://docs.nvidia.com/nemoclaw/latest/inference/inference-options.html)
- [NeMo Agent Toolkit repo](https://github.com/NVIDIA/NeMo-Agent-Toolkit)
- [Claude Code on Amazon Bedrock](https://code.claude.com/docs/en/amazon-bedrock)
