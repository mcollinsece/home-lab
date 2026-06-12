# Homelab Agentic AI Stack — Setup Plan

**Target:** Debian VM running NVIDIA OpenShell + NemoClaw + NeMo Agent Toolkit, hosting sandboxed coding agents (Claude Code first, then Codex and Gemini CLI) with per-project switching between Claude Max/Pro subscription and Bedrock.

> **Current platform state:** [../current/platform.md](../current/platform.md) — hardware, IPs, running services, pending items

> **Environment & intent:** This runs on a Proxmox VM on a single Dell OptiPlex — a **transitional development host**, not the final home. The plan is to migrate to a larger box (and eventually a compute cluster) once the stack is proven, which is why portability is a first-class design goal throughout — Quadlets that map to k8s, a local registry, remote inference (see [Now → Future mapping](#now--future-mapping) and [Path to k3s + vLLM](#path-to-k3s--vllm)). Because it's a dev host, it is **not a security-sensitive environment**: security still matters, but runtime/posture choices favour getting the stack working over hardening — e.g. rootless vs rootful Podman, or Docker, is a pragmatic call (see [Runtime](#runtime-podman-vs-docker)).

---

## How the stack fits together

| Layer | What it is | Role in your setup |
|---|---|---|
| **OpenShell** ([repo](https://github.com/NVIDIA/OpenShell)) | Open-source sandbox runtime (Apache 2.0, alpha). Gateway + per-sandbox containers, deny-by-default YAML network/filesystem/process policies, credential providers, inference router. | The foundation. Runs Claude Code, Codex, OpenCode, Copilot **unmodified** — all four ship in the base sandbox image. |
| **NemoClaw** ([repo](https://github.com/NVIDIA/NemoClaw), [docs](https://docs.nvidia.com/nemoclaw/latest/)) | One-command stack on top of OpenShell, for onboarding **OpenClaw**/**Hermes** always-on agents with routed inference and hardened policy presets. Alpha. | Phase 6 — **deferred experiment**. A convenience wrapper, not the agent; baseline runs OpenClaw directly on Podman (Phase 5), then NemoClaw is explored on Docker. Most valuable once you add local inference (GPU + vLLM). |
| **NeMo Agent Toolkit** ([repo](https://github.com/NVIDIA/NeMo-Agent-Toolkit)) | Python library for connecting/orchestrating teams of agents across frameworks; MCP client/server and A2A support. | Phase 7. The orchestration brain that coordinates your sandboxed agents. |

Key facts:

- `openshell sandbox create -- claude` launches Claude Code in an isolated container. Same for `codex`, `opencode`, `copilot`.
- Credentials never touch the sandbox filesystem — OpenShell **providers** auto-discover keys (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, etc.) from the host shell and inject them as env vars at runtime.
- Network egress is deny-by-default; you open it with hot-reloadable YAML policies enforced at the HTTP method/path level (L7).
- NemoClaw's inference router supports Anthropic, Anthropic-compatible endpoints (covers Bedrock gateways), OpenAI, Gemini, NVIDIA endpoints, and local Ollama. The agent talks to `inference.local`; keys stay on the host.
- No GPU needed — GPU only matters for local inference (Ollama/NIM/vLLM), which you're skipping for now.

---

## VM sizing requirements

The current VM (4 vCPU / 15 GB / 108 GB) meets the minimum. The **recommended** column describes the migration-target box, not this OptiPlex — the Proxmox host has only 16 GB total, so this VM is already near the hardware ceiling. Treat the baseline as a **"few agents on-demand"** host (spin sandboxes up per task, tear them down after) rather than many always-on agents; full multi-agent concurrency is a goal for the larger box.

| Resource | Minimum | Recommended for multi-agent |
|---|---|---|
| vCPU | 4 | 8 |
| RAM | 8 GB | 16–24 GB (each sandbox is a container; NemoClaw adds k3s + gateway) |
| Disk | 20 GB | 60+ GB (sandbox images ~2.4 GB each, plus Docker layer cache) |

Software: a container runtime (**rootless Podman** — already running this host's services) plus Node.js 22.16+, npm 10+, git.

### Runtime: Podman vs Docker

**OpenShell runs on Podman — you do not need Docker for Phases 2–4.** OpenShell's prerequisites list "Docker, Podman, or host virtualization (MicroVM)" as interchangeable backends, so the rootless Podman already running Traefik/Portainer covers the entire core of this plan.

The only place Docker has an edge is **NemoClaw**, whose tested Linux path is Docker (on fresh docker-ce installs with the containerd image store enabled, `nemoclaw onboard` handles the fuse-overlayfs workaround automatically). NemoClaw is intentionally deferred to a post-baseline experiment in [Phase 6](#phase-6--nemoclaw-experiment-deferred) — the entire agent baseline (Phases 2–5) stays on Podman.

**Decision: start on Podman; don't install Docker preemptively.** One runtime means one network model — sandboxes can share `ai-net` with Traefik/Portainer instead of straddling a Docker bridge and a separate Podman network. But Podman-first is a **preference, not a hard rule** (see the rootless note below): if OpenShell turns out to need Docker, install it and move on. Either way, Docker comes in for the Phase 6 NemoClaw experiment.

> **On rootless specifically:** OpenShell's docs say "Podman" but don't specify *rootless* Podman, and its per-sandbox L7 network enforcement may want root or extra privileges. **This is a development host, not a security-sensitive environment** — so rootless is a preference (consistency with the existing services), not a constraint. If the Phase 2 spike shows OpenShell needs rootful Podman or Docker, switching is an accepted trade-off — don't burn time forcing rootless. What *does* still matter: verify deny-by-default policy enforcement actually works in whichever mode you land on.
>
> **Validated (2026-06-12):** OpenShell v0.0.62 has a first-class `driver-podman` and runs fine on the existing **rootless** Podman (`OPENSHELL_DRIVERS=podman`, gateway bound `0.0.0.0:17670`). The supervisor enforces isolation *inside* each container (root via userns, not host root). Deny-by-default and L7 method/host enforcement both confirmed working — no rootful, no Docker. See [current state](../current/platform.md) for the exact config.

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
| Agent sandboxes | OpenShell (Podman or Docker) | OpenShell on k8s nodes, policies → NetworkPolicy |
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
├── .gitignore                      ✅ **/*.env, !*.env.example, !openshell/gateway.env, *.key
├── docs/
│   ├── current/
│   │   ├── platform.md             ✅ hardware, IPs, running services — current state
│   │   └── todos.md                ✅ human punchlist (manual/sensitive/interactive)
│   └── future/
│       └── ai-dev-ground.md        ✅ this file — AI stack plan
├── bootstrap/
│   └── setup-host.sh               ✅ idempotent host rebuild (Node, OpenShell, links)
├── networks/
│   └── ai-net.network              ✅ Quadlet: shared internal bridge
├── traefik/                        ✅ static config + Quadlet + README
├── portainer/                      ✅ Quadlet + data volume
├── openshell/                      ✅ agent sandbox runtime
│   ├── gateway.env                 ✅ gateway driver+bind (symlinked into ~/.config)
│   ├── policies/claude-code.yaml   ✅ Claude Code network policy (subscription)
│   └── README.md                   ✅ reproduce + sandbox lifecycle
├── projects/
│   └── _template/                  ✅ copy this to start a new service
├── registry/
│   └── registry.container          ☐ Quadlet for the local image registry
└── k8s/                            ☐ (future) manifests the Quadlets graduate into
```

---

## Phases 1–2 — base prep + OpenShell ✅ DONE

Built 2026-06-12 and reproducible from a clean checkout via
[`bootstrap/setup-host.sh`](../../bootstrap/setup-host.sh). Current-state details
in [platform.md](../current/platform.md); OpenShell specifics in
[openshell/README.md](../../openshell/README.md). In short:

- **Phase 1:** Node 22 (`node v22.22.3`) on the existing rootless Podman. No Docker
  on the critical path; the optional Docker Engine install is deferred to Phase 6.
- **Phase 2:** OpenShell `v0.0.62` on **rootless Podman** (native `driver-podman`,
  gateway bound `0.0.0.0:17670`). Isolation verified — deny-by-default egress plus
  L7 host/method enforcement. The `claude-code` sandbox is `Ready` with
  [`openshell/policies/claude-code.yaml`](../../openshell/policies/claude-code.yaml);
  all four agents (claude/codex/opencode/copilot) ship in the base image. The
  OpenShell repo is cloned at `/home/debian/OpenShell` for its agent skills
  (`.agents/skills/`, incl. `generate-sandbox-policy`).

`claude login` (Max/Pro OAuth) is done and the AdGuard `*.lab.lan` wildcard is
live — **Phase 2 complete.**

**Reproducibility re-verified 2026-06-12:** `setup-host.sh` re-run end-to-end with
all checks green, and the manual post-steps confirmed (sandbox `Ready`/healthy,
`claude login` + live prompt through the egress policy, `portainer.lab.lan` → 200).
This was an idempotent re-run over the live host, not a clean snapshot-revert — the
from-scratch rebuild stays unproven-but-low-risk, to be exercised at the real
migration (see [todos.md](../current/todos.md)).

## Phase 3 — Dual auth: Max/Pro subscription ↔ Bedrock per project  ✅ DONE (2026-06-12)

Claude Code picks its backend per project via settings precedence (project `.claude/settings.json` overrides user `~/.claude/settings.json`). Subscription OAuth is the default; Bedrock is opt-in via env.

**Inside the sandbox** (creds live in the sandbox, not on the host — same model
as `claude login`):

```jsonc
// ~/.claude/settings.json (sandbox user level) — AWS creds present but INERT:
// Claude Code ignores them unless a project sets CLAUDE_CODE_USE_BEDROCK.
// Subscription (OAuth from `claude login`) stays the default everywhere.
{
  "env": {
    "AWS_ACCESS_KEY_ID": "AKIA…",
    "AWS_SECRET_ACCESS_KEY": "…",
    "AWS_REGION": "us-east-1"
  }
}

// <bedrock-project>/.claude/settings.json — opt THIS project into Bedrock.
// Project settings override user settings, so only here is Bedrock active.
{
  "env": {
    "CLAUDE_CODE_USE_BEDROCK": "1",
    "AWS_REGION": "us-east-1",
    "ANTHROPIC_MODEL": "us.anthropic.claude-sonnet-4-6"   // verified 2026-06-12
  }
}
```

**How the creds actually get in (validated 2026-06-12 — the plan's original
`openshell provider create` for AWS does NOT work):**

OpenShell v0.0.62 has **no AWS/Bedrock provider type** (`provider list-profiles`
has only claude-code/codex/cursor/vertex/nvidia/…), and its egress proxy can't
SigV4-sign. So there's nothing to "auto-discover" AWS creds the way an
`ANTHROPIC_API_KEY` provider would. Instead Claude Code's bundled AWS SDK signs
each request itself, which means **the AWS keys must be present inside the
sandbox as env vars**. Two ways to put them there:

1. **Existing sandbox (no rebuild):** add them to the sandbox user
   `~/.claude/settings.json` `env` block (shown above) via `openshell sandbox
   exec` — preserves the Phase 2 subscription login.
2. **On rebuild (reproducible):** `openshell sandbox create … --env
   AWS_ACCESS_KEY_ID=… --env AWS_SECRET_ACCESS_KEY=… --env AWS_REGION=us-east-1`.

Either way the keys never hit git (a scoped IAM user, `bedrock:InvokeModel*` +
inference-profile read; see [todos.md](../current/todos.md)).

**Network policy** ([`openshell/policies/claude-code.yaml`](../../openshell/policies/claude-code.yaml),
hot-reloaded onto the live sandbox, **done 2026-06-12 — policy v2**) allows both:
   - Subscription: `api.anthropic.com`, `platform.claude.com`, `claude.ai`, …
   - Bedrock: `bedrock-runtime.{us-east-1,us-east-2,us-west-2}.amazonaws.com`
     (the `us.` cross-region profile fans out across all three) +
     `bedrock.us-east-1.amazonaws.com` (startup inference-profile discovery). No
     `sts.*` — static IAM-user keys self-sign; only role/SSO auth would need it.

Switching = `cd` into a project; no re-auth, no sandbox rebuild.

## Phase 4 — Add Codex and Gemini CLI

- **Codex**: already in the base sandbox image. `openshell sandbox create -- codex`; provider uses `OPENAI_API_KEY`; policy needs `api.openai.com`.
- **Gemini CLI**: not in the base image — use BYOC. Copy the [bring-your-own-container example](https://github.com/NVIDIA/OpenShell/tree/main/examples/bring-your-own-container), add `npm install -g @google/gemini-cli` to the Dockerfile, then `openshell sandbox create --from ./gemini-sandbox -- gemini`. Provider: `GEMINI_API_KEY`; policy: `generativelanguage.googleapis.com`.

One sandbox per agent keeps policies and credentials cleanly scoped.

## Phase 5 — Always-on OpenClaw assistant

The goal of this phase is an always-on assistant agent in a hardened sandbox, completing the agent baseline (Claude Code, Codex, Gemini, OpenClaw — and optionally Hermes), all on Podman. **NemoClaw is a wrapper, not the agent** — [OpenClaw](https://github.com/openclaw/openclaw) and Hermes are standalone open-source agents; NemoClaw bundles guided onboarding, an inference router, hardened policy presets, and lifecycle CLI around them, and pulls Nemotron models. We run OpenClaw directly here to keep the whole baseline on one runtime, and keep NemoClaw on the roadmap as a deliberate experiment in [Phase 6](#phase-6--nemoclaw-experiment-deferred) once that baseline is solid.

Why run OpenClaw directly rather than via NemoClaw *now* — weighed against this no-GPU/remote-API setup:

| NemoClaw feature | Needed here? |
|---|---|
| Onboarding wizard | No — write a BYOC Containerfile + policy YAML, same as Gemini in Phase 4 |
| Inference router (`inference.local`) | **No** — its real win is routing to *local* vLLM/Nemotron; you're remote-APIs-only, and OpenShell providers already inject `ANTHROPIC_API_KEY`/Bedrock creds |
| Hardened policy presets | No — reuse/tighten the policy you wrote for Claude Code |
| Lifecycle CLI | No — `openshell sandbox` commands, same as the other agents |
| Nemotron models | Irrelevant — remote APIs |

NemoClaw's value concentrates in the local-inference case you're deliberately skipping for now, so it's **deferred to [Phase 6](#phase-6--nemoclaw-experiment-deferred), not dropped** — revisited once you add GPU + vLLM in the k3s phase.

### Run OpenClaw as an OpenShell BYOC sandbox (Podman)

Same pattern as Gemini in Phase 4 — no Docker, no NemoClaw.

1. BYOC Containerfile based on the OpenShell sandbox image, adding OpenClaw:
   ```dockerfile
   # OpenClaw — standalone always-on assistant (github.com/openclaw/openclaw)
   RUN curl -fsSL https://openclaw.ai/install.sh | bash -s -- --install-method git --version main
   ```
2. Run it always-on (OpenClaw ships a daemon mode):
   ```bash
   openshell sandbox create --from ./openclaw-sandbox -- openclaw onboard --install-daemon
   ```
3. **Inference:** point OpenClaw straight at the API via the OpenShell provider that already injects `ANTHROPIC_API_KEY` (or Bedrock creds) — no router needed.
4. **Policy:** reuse and tighten the network policy from Claude Code; OpenShell's `generate-sandbox-policy` skill drafts it from plain English.
5. **Dashboard/TUI:** expose via SSH tunnel, or put the sandbox on `ai-net` for Traefik at `openclaw.lab.lan`.

**Why this shape:** every agent (Claude Code, Codex, Gemini, OpenClaw) becomes "just another OpenShell sandbox" — one runtime, one lifecycle, one policy mechanism, no alpha-on-alpha NemoClaw layer. You trade NemoClaw's one-command onboarding and managed router (≈80% of the polish) for manual BYOC wiring — and you get that polish back to evaluate in Phase 6.

**Verify during prototyping:** OpenShell sandboxes are built around agent *sessions*; confirm OpenClaw's daemon persists and stays reachable as a long-running process inside one.

> Hermes (Nous Research) is the other supported agent, but it's a self-evolving *research* agent rather than an always-on assistant, and its easy path ([`hermesclaw`](https://github.com/TheAiSingularity/hermesclaw)) hard-requires Docker — reintroducing the dependency you're avoiding. For an always-on assistant on Podman, prefer OpenClaw. A `hermes-open-sandbox` pip backend exists if you want Hermes specifically.

## Phase 6 — NemoClaw experiment (deferred)

> **Do this only after Phases 2–5 are running** — OpenShell, Claude Code, Codex, Gemini, OpenClaw (and optionally Hermes), all on Podman. NemoClaw stays on the roadmap as a deliberate experiment to explore once that baseline exists, **even if it ends up being the only service that runs under Docker.**

NemoClaw is NVIDIA's one-command stack wrapping OpenClaw/Hermes with guided onboarding, a managed inference router, hardened policy presets, and lifecycle CLI. Running it *after* the hand-rolled baseline is the point: the baseline gives you a reference to measure it against — what does NemoClaw's router and policy automation actually buy over the BYOC OpenClaw you already understand from Phase 5? It becomes most compelling when you add **local inference** (GPU + vLLM/Nemotron) in the k3s phase, which is exactly what its router is built for.

**Prerequisite:** the optional Docker Engine install from [Phase 1](#phase-1--vm-base-prep). Docker and rootless Podman coexist fine — treat NemoClaw as an isolated Docker island alongside the Podman baseline, not a migration off Podman. Don't run `openshell` commands directly against NemoClaw-managed sandboxes.

```bash
curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash   # runs `nemoclaw onboard` wizard; verify URL against current NemoClaw docs
```

- Wizard prompts: sandbox name → inference provider → network policy preset.
- Provider for this setup: **Anthropic** (option 4) or **Anthropic-compatible endpoint** (option 5) for Bedrock gateway.
- Dashboard at `http://127.0.0.1:18789/#token=...` (printed once — save it). LAN access: SSH tunnel `ssh -L 18789:127.0.0.1:18789 user@vm`.
- Lifecycle: use `nemoclaw onboard` / `nemoclaw <name> rebuild`.
- Terminal access: `nemoclaw <name> connect` then `openclaw tui`.

**What to evaluate:** whether NemoClaw's managed router + policy presets justify the Docker dependency over the direct-BYOC OpenClaw from Phase 5; how cleanly it coexists with the Podman services; and whether its inference routing earns its keep once local vLLM/Nemotron is in play.

## Phase 7 — NeMo Agent Toolkit orchestration

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

**Pre-work (see [todos.md](../current/todos.md) for detail):**

- [x] `bootstrap/setup-host.sh` — idempotent host rebuild
- [x] AdGuard wildcard `*.lab.lan → 192.168.0.51` (on AdGuard LXC `.53`)
- [ ] Podman secrets: `anthropic_api_key`, AWS Bedrock creds
- [ ] Local image registry `:5000`

**Phases:**

1. [x] Phase 1: Node 22 (Podman already present; Docker optional, NemoClaw-only) — `node v22.22.3`
2. [x] Phase 2: OpenShell + Claude Code sandbox — v0.0.62 on **rootless Podman** (Podman-first premise validated, no Docker); `claude-code` sandbox Ready, `claude login` done, AdGuard `*.lab.lan` wildcard live. **Complete.**
3. [x] Phase 3: Subscription ↔ Bedrock per-project switching — **complete** —
   policy v2 (Bedrock egress), us-east-1, default `us.anthropic.claude-sonnet-4-6`;
   both paths verified via `claude -p` (Bedrock from project dir, subscription elsewhere)
4. [ ] Phase 4: Codex sandbox; Gemini CLI BYOC sandbox
5. [ ] Phase 5: Always-on OpenClaw assistant (direct BYOC on Podman) — **completes the Podman baseline**
6. [ ] Phase 6: NemoClaw experiment (deferred; the one Docker service) — explore after baseline
7. [ ] Phase 7: NeMo Agent Toolkit orchestration layer

---

## Caveats

- **Everything NVIDIA here is alpha** (OpenShell and NemoClaw both carry "do not use in production" banners). Pin versions where you can (`OPENSHELL_VERSION`).
- The blog's `--remote spark` flow targets DGX Spark; the no-GPU Debian VM runs OpenShell on **rootless Podman** (`driver-podman`), validated end-to-end — Docker is not required for the agent baseline.
- Subscription (Max/Pro) use in long-running automated loops can hit rate limits — Bedrock is the better default for unattended/batch work; subscription for interactive sessions.
- Verify current Bedrock model IDs in the [Claude Code Bedrock docs](https://code.claude.com/docs/en/amazon-bedrock) when you get there.
- Pin image tags — no `:latest`. Secrets out of git. One Quadlet per project for clean teardown.

---

## Sources

- [NVIDIA OpenShell repo](https://github.com/NVIDIA/OpenShell) · [OpenShell blog announcement](https://developer.nvidia.com/blog/run-autonomous-self-evolving-agents-more-safely-with-nvidia-openshell/)
- [NemoClaw repo](https://github.com/NVIDIA/NemoClaw) · [prerequisites](https://docs.nvidia.com/nemoclaw/latest/get-started/prerequisites.html), [quickstart](https://docs.nvidia.com/nemoclaw/latest/get-started/quickstart.html), [inference options](https://docs.nvidia.com/nemoclaw/latest/inference/inference-options.html)
- [NeMo Agent Toolkit repo](https://github.com/NVIDIA/NeMo-Agent-Toolkit)
- [OpenClaw repo](https://github.com/openclaw/openclaw) · [OpenClaw install docs](https://docs.openclaw.ai/install) · [hermesclaw (Hermes-in-OpenShell)](https://github.com/TheAiSingularity/hermesclaw)
- [Claude Code on Amazon Bedrock](https://code.claude.com/docs/en/amazon-bedrock)
