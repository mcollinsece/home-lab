# home-lab

A self-hosted **ground for running autonomous coding agents** — Claude Code today,
Codex / Gemini / an always-on OpenClaw assistant next — each boxed in its own
isolated sandbox, on a Proxmox VM that's deliberately built to graduate to a real
cluster later.

## Why this exists

I want to run capable coding agents *autonomously* — long-horizon, unattended,
sometimes overnight — without handing a model the keys to my network or my host.
Off-the-shelf "agent in a Docker container" setups give you isolation **or**
convenience, rarely both, and they leak credentials into the workspace the moment
the agent can read a file. This repo is the opposite trade: maximum isolation with
the agent none the wiser.

The engine is **[NVIDIA OpenShell](https://github.com/NVIDIA/OpenShell)** — a
sandbox runtime that runs each agent (Claude Code, Codex, Gemini, and
**OpenClaw** as an always-on assistant) in its own container with a
**deny-by-default network policy**. The agent gets a normal shell; the gateway
decides what it's allowed to reach.

**[NemoClaw](https://github.com/NVIDIA/NemoClaw)** (NVIDIA's managed OpenClaw stack)
runs the always-on OpenClaw director inside an OpenShell sandbox — proper process and
network isolation for the orchestration layer itself, not just the workers.

**[LiteLLM](https://github.com/BerriAI/litellm)** sits between all agents and the
real model backends. Every sandbox points to `inference.local`; OpenShell routes that
to LiteLLM; LiteLLM holds the real credentials (Bedrock today). Swapping backends is
one line in `litellm/config.yaml`.

### What's actually unique here

- **The agent never sees a credential it could exfiltrate, yet auth still works.**
  Secrets live outside the sandbox; egress is an explicit allowlist (host:port + binary
  identity), so even a fully compromised agent can only talk to the handful of endpoints
  its policy names.
- **Single inference credential boundary.** LiteLLM is the only service that holds
  real model API keys. All agents — whether running interactively or unattended — route
  through it via OpenShell's `inference.local` gateway. Adding a model provider is one
  config change with no sandbox rebuilds.
- **Built to migrate, on purpose.** This OptiPlex is a *transitional* dev host.
  Docker Compose services have a direct path to k8s manifests; OpenShell sandboxes
  map to k8s Pods; the local registry is already cluster-ready. The path to k3s +
  vLLM on a bigger box is a port, not a rewrite.

### Status at a glance

| Capability | State |
|---|---|
| Reverse proxy + HTTPS (Traefik) on `*.lab.lan` | ✅ live |
| Docker Compose services (Traefik, Portainer, Registry, LiteLLM) | ✅ live |
| LiteLLM → Amazon Bedrock (Claude Sonnet 4.6) | ✅ live (Phase 4.5) |
| OpenShell gateway — Docker driver, deny-by-default sandboxes | ✅ live |
| Claude Code sandbox — Max/Pro subscription | ✅ live |
| Per-project subscription ↔ Bedrock dual-auth | ✅ live (Phase 3) |
| **NemoClaw director** (OpenClaw in its own OpenShell sandbox) | ⬜ Bad Gateway on openclaw.lab.lan (director provisioning in progress; run `nemoclaw director status` + `rebuild --yes`; see todos) |
| Claude Code sandbox (lab gateway) | ✅ Ready (recreated post-nemoclaw with `/usr/bin/openshell --gateway-endpoint http://127.0.0.1:17670 --gateway-insecure` + inference.local) |
| Codex CLI sandbox | ⬜ roadmap (Phase 5) |
| Gemini CLI sandbox | ⬜ roadmap (Phase 6) |
| Podman runtime re-evaluation (when NemoClaw supports it) | ⬜ roadmap (Phase 8) |
| Alternative providers (OpenAI, Grok, Gemini, Copilot, OpenRouter) | ⬜ roadmap (Phase 9) |
| k3s + vLLM on a second node | ⬜ roadmap |

Full vision, phases, and the k8s roadmap: **[docs/future/ai-dev-ground.md](docs/future/ai-dev-ground.md)**.
Current built state: **[docs/current/platform.md](docs/current/platform.md)**.
Immediate next steps: **[docs/current/todos.md](docs/current/todos.md)**.

## Network topology

```
Internet
    │
  Router
    │
  LAN (192.168.0.0/24)
    ├── 192.168.0.50  Proxmox host (Dell OptiPlex 7050 Micro)
    │     ├── 192.168.0.53  AdGuard Home (LXC) — DHCP + DNS + *.lab.lan wildcard
    │     └── 192.168.0.51  homelab VM (Debian 13) — primary workload host
    │           ├── Traefik (Docker Compose) — reverse proxy :80/:443, HTTPS
    │           ├── Portainer (Docker Compose) — portainer.lab.lan
    │           ├── LiteLLM (Docker Compose) — litellm.lab.lan — inference proxy → Bedrock
    │           ├── Registry (Docker Compose) — registry.lab.lan :5000
    │           ├── OpenShell lab gateway (systemd --user) — :17670 (mTLS), Docker driver, 0.0.62
    │           │     inference.local → LiteLLM → Bedrock
    │           │     └── claude-code (and future codex/gemini) sandboxes — outbound-only, per-agent policy
    │           ├── NemoClaw (own gateway :8080 plaintext + 10.89.0.1 alias, 0.0.44 pin)
    │           │     └── "director" sandbox (OpenClaw) — :18789 local → openclaw.lab.lan (static Traefik route)
    │           └── projects/ — one Docker Compose per service on ai-net
    └── ... other devices via AdGuard DHCP
```

`*.lab.lan` names resolve via AdGuard's wildcard rewrite (`*.lab.lan → 192.168.0.51`);
Traefik routes per-service by container label. All traffic is served over HTTPS. Agent
sandboxes are **outbound-only** — they make API calls through `inference.local`, nothing
routes in.

## HTTPS / local CA trust

All `*.lab.lan` traffic is served over HTTPS via Traefik with a [mkcert](https://github.com/FiloSottile/mkcert)
wildcard certificate. The cert is signed by a local CA (`traefik/certs/ca/rootCA.pem`)
— install it once on each device you use to access the lab.

**Get the CA cert:**
```bash
# from git (no secrets — public cert only)
git clone <repo> && cp traefik/certs/ca/rootCA.pem ~/Downloads/lab-lan-ca.pem
# or scp from the VM
scp debian@192.168.0.51:~/home-lab/traefik/certs/ca/rootCA.pem ~/Downloads/lab-lan-ca.pem
```

**macOS:**
```bash
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain ~/Downloads/lab-lan-ca.pem
```

**Windows (Admin PowerShell):**
```powershell
Import-Certificate -FilePath "$HOME\Downloads\lab-lan-ca.pem" `
  -CertStoreLocation Cert:\LocalMachine\Root
```

**Linux (Debian / Ubuntu):**
```bash
sudo cp ~/Downloads/lab-lan-ca.pem /usr/local/share/ca-certificates/lab-lan-ca.crt
sudo update-ca-certificates
```
Firefox on Linux also requires: Settings → Privacy & Security → Certificates →
View Certificates → Authorities → Import → select `lab-lan-ca.pem`.

Cert expires **2028-09-13**; CA valid until **2036-06-13**.

## Documentation

**Current state**

| Doc | What it covers |
|---|---|
| [docs/current/platform.md](docs/current/platform.md) | Hardware, IPs, running services, sandbox lifecycle — single source of truth |
| [docs/current/todos.md](docs/current/todos.md) | Immediate next steps + phase punchlist |
| [docs/current/litellm-proxy.md](docs/current/litellm-proxy.md) | LiteLLM architecture, config, operations |

**Future plans**

| Doc | What it covers |
|---|---|
| [docs/future/ai-dev-ground.md](docs/future/ai-dev-ground.md) | The agent stack (OpenShell → NemoClaw → NeMo), phases, k8s roadmap |

**Config**

| Doc | What it covers |
|---|---|
| [openshell/README.md](openshell/README.md) | Agent sandboxes — gateway config, sandbox lifecycle, inference.local (note dual gateways post-nemoclaw; use explicit endpoint for lab) |
| [traefik/README.md](traefik/README.md) | How to expose a Docker Compose service via Traefik labels (static files in dynamic/ for dashboard + openclaw; Docker provider has persistent client-version errors) |
| [bootstrap/TROUBLESHOOTING.md](bootstrap/TROUBLESHOOTING.md) | OpenShell/Docker failure modes and fixes (added: openclaw Bad Gateway / director Provisioning, dual-gateway gotchas, post-nemoclaw gateway restore) |

## Reproduce the host

```bash
git clone <repo> ~/home-lab && ~/home-lab/bootstrap/setup-host.sh
```

[`bootstrap/setup-host.sh`](bootstrap/setup-host.sh) is idempotent: base packages,
Node 22, Docker Engine, OpenShell (pinned `v0.0.62`), gateway.env (simple repo version — symlink **must** be restored after nemoclaw), mkcert + wildcard
cert, and PATH tools (`osbox`, `init-secrets`). **Sensitive/interactive steps are not
scripted** — credentials, `claude login`, NemoClaw onboard + director provisioning troubleshoot, and post-onboard lab claude-code recreate using `/usr/bin/openshell --gateway-endpoint http://127.0.0.1:17670 --gateway-insecure` (dual-gateway reality) are manual, tracked in
[docs/current/todos.md](docs/current/todos.md). The script's final banner now includes the exact current post-nemoclaw commands.

**Post-nemoclaw note (from this session):** `nemoclaw onboard` installs its own 0.0.44 CLI + gateway (8080 plaintext, may overwrite `gateway.env`). The lab gateway (17670 mTLS) uses the restored 0.0.62 binaries and the simple repo `openshell/gateway.env` (OPENSHELL_DRIVERS=docker + BIND=0.0.0.0). Always recreate lab sandboxes (claude-code) with the explicit form:
`/usr/bin/openshell --gateway-endpoint http://127.0.0.1:17670 --gateway-insecure ... --env ANTHROPIC_BASE_URL=https://inference.local ...`
After nemoclaw runs: `ln -sfn ~/home-lab/openshell/gateway.env ~/.config/openshell/gateway.env`. Director (on nemoclaw gw) currently shows Bad Gateway — see todos.md for status/rebuild/18789/log/alias details. Static Traefik routes in `traefik/dynamic/` (openclaw-nemoclaw.yml + traefik-dashboard.yml) bypass Docker provider skew.

## Adding a new service

1. Copy `projects/_template/` → `projects/<name>/`
2. Edit `compose.yaml` — set `container_name: <name>` and add your image/env/ports
3. Add `Label: traefik.enable=true` — service becomes available at `<name>.lab.lan`
4. Join the shared network: `networks: [ai-net]` with `ai-net: {external: true}`
5. Start: `docker compose -f projects/<name>/compose.yaml up -d`

See [traefik/README.md](traefik/README.md) for the full label reference.

## Secrets

Real `.env` files are gitignored — commit only `*.env.example`.

Secrets flow into containers via Docker Compose `env_file:` directives.
No Docker Swarm or Podman secrets needed.

```bash
init-secrets      # interactive: prompts for Bedrock keys, auto-generates LiteLLM key
                  # writes: .secrets/bedrock.env  .secrets/litellm.env
```

Raw AWS credentials (Bedrock) live **only** in the LiteLLM container. All agents
use `inference.local` → LiteLLM — no sandbox ever holds a real model API key.
