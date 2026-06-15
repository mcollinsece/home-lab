# home-lab

A self-hosted **ground for running autonomous coding agents** — Claude Code today,
Codex / Gemini next — each boxed in its own isolated sandbox, on a Proxmox VM
deliberately built to graduate to a real cluster later.

## Why this exists

I want to run capable coding agents *autonomously* — long-horizon, unattended,
sometimes overnight — without handing a model the keys to my network or my host.
Off-the-shelf "agent in a Docker container" setups give you isolation **or**
convenience, rarely both, and they leak credentials into the workspace the moment
the agent can read a file. This repo is the opposite trade: maximum isolation with
the agent none the wiser.

The engine is **[NVIDIA OpenShell](https://github.com/NVIDIA/OpenShell)** — a
sandbox runtime that runs each agent in its own container with a
**deny-by-default network policy**. The agent gets a normal shell; the gateway
decides what it's allowed to reach.

**[NemoClaw](https://github.com/NVIDIA/NemoClaw)** (NVIDIA's managed OpenClaw stack)
runs the always-on OpenClaw director inside its own OpenShell sandbox — proper process
and network isolation for the orchestration layer itself, not just the workers.

**[LiteLLM](https://github.com/BerriAI/litellm)** is the single inference credential
boundary. It routes Bedrock-backed models to AWS and reverse-proxies agent wrappers
(Claude Code, Grok Build) for agentic tool-use sessions. No sandbox ever holds a raw model key.

### What's actually unique here

- **Three auth paths, zero credential leakage.** Bedrock calls (claude-sonnet-4-6) go
  through LiteLLM only. Claude Code and Grok Build agent sessions use OAuth subscriptions
  from inside isolated sandboxes. Neither path exposes credentials to user code.
- **Agentic inference as first-class models.** Both Claude Code and Grok Build agents run
  inside OpenShell sandboxes and are registered in LiteLLM as models. OpenClaw can invoke
  them exactly like any other model — tools, long sessions, file work, all inside isolated sandboxes.
- **CLI-to-API pattern.** OAuth-authenticated agent CLIs (claude, grok) are wrapped as
  OpenAI-compatible HTTP endpoints, making subscription-based agents accessible via standard
  LLM APIs without exposing credentials.
- **Built to migrate, on purpose.** This OptiPlex is a *transitional* dev host.
  Docker Compose services have a direct path to k8s manifests; OpenShell sandboxes
  map to k8s Pods; the local registry is already cluster-ready.

### Status at a glance

| Capability | State |
|---|---|
| Reverse proxy + HTTPS (Traefik) on `*.lab.lan` | ✅ live |
| Docker Compose services (Traefik, Portainer, Registry, LiteLLM) | ✅ live |
| LiteLLM → Amazon Bedrock (`claude-sonnet-4-6`) | ✅ live |
| OpenShell lab gateway — Docker driver, deny-by-default sandboxes | ✅ live |
| **NemoClaw director** (OpenClaw in its own OpenShell sandbox) | ✅ live — `openclaw.lab.lan`; three models: `claude-sonnet-4-6`, `claude-code-wrapper-local`, `grok-wrapper-local`; Traefik → Docker alias; probe service persistent |
| **Claude Code agent wrapper** (`claude-code-wrapper-local`) | ✅ live — OAuth/Pro subscription; inside `openshell-claude-revproxy` sandbox; LiteLLM reverse-proxies it as an agentic model |
| **Grok agent wrapper** (`grok-wrapper-local`) | ✅ live — OAuth/Grok subscription; inside `openshell-grok-wrapper` sandbox; uses Grok Build CLI; LiteLLM reverse-proxies it as an agentic model |
| Claude Code sandbox (lab gateway, interactive) | ✅ live — `inference.local` → LiteLLM → Bedrock |
| Codex CLI sandbox | ⬜ roadmap (Phase 5) |
| Gemini CLI sandbox | ⬜ roadmap (Phase 6) |
| Podman runtime re-evaluation | ⬜ roadmap (Phase 8) |
| Alternative providers (OpenAI, Gemini, OpenRouter) | ⬜ roadmap (Phase 9) |
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
    │           ├── Traefik (Docker Compose, ai-net) — reverse proxy :80/:443
    │           ├── Portainer (Docker Compose, ai-net) — portainer.lab.lan
    │           ├── LiteLLM (Docker Compose, ai-net) — litellm.lab.lan → Bedrock + wrapper
    │           ├── Registry (Docker Compose, ai-net) — registry.lab.lan :5000
    │           ├── OpenShell lab gateway (systemd --user) — :17670 mTLS, Docker driver
    │           │     inference.local → LiteLLM → Bedrock
    │           │     ├── claude-code sandbox — interactive agent, outbound via inference.local
    │           │     ├── openshell-claude-revproxy (on ai-net as claude-code-wrapper)
    │           │     │     └── claude-code-openai-wrapper — OAuth/Pro → api.anthropic.com
    │           │     └── openshell-grok-wrapper (on ai-net as grok-wrapper)
    │           │           └── grok-openai-wrapper — OAuth/Grok → xAI
    │           └── NemoClaw (gateway :8080, Docker driver)
    │                 └── director sandbox (OpenClaw) — on ai-net → openclaw.lab.lan
    │                       models: claude-sonnet-4-6, claude-code-wrapper-local, grok-wrapper-local
    └── ... other devices via AdGuard DHCP
```

`*.lab.lan` names resolve via AdGuard's wildcard rewrite (`*.lab.lan → 192.168.0.51`);
Traefik routes per-service by container label or static file config.

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
| [docs/current/platform.md](docs/current/platform.md) | Hardware, IPs, running services, sandbox architecture — single source of truth |
| [docs/current/todos.md](docs/current/todos.md) | Active work items and roadmap punchlist |
| [docs/current/litellm-proxy.md](docs/current/litellm-proxy.md) | LiteLLM architecture, model routing, operations |

**Future plans**

| Doc | What it covers |
|---|---|
| [docs/future/ai-dev-ground.md](docs/future/ai-dev-ground.md) | The agent stack (OpenShell → NemoClaw → NeMo), phases, k8s roadmap |

**Config**

| Doc | What it covers |
|---|---|
| [openshell/README.md](openshell/README.md) | Agent sandboxes — gateway config, sandbox lifecycle, inference.local, dual-gateway notes |
| [traefik/README.md](traefik/README.md) | Exposing services via Traefik labels; static file routes for OpenClaw + dashboard |
| [bootstrap/TROUBLESHOOTING.md](bootstrap/TROUBLESHOOTING.md) | OpenShell/Docker failure modes; dual-gateway gotchas; openclaw recovery |

## Reproduce the host

```bash
git clone <repo> ~/home-lab && ~/home-lab/bootstrap/setup-host.sh
```

[`bootstrap/setup-host.sh`](bootstrap/setup-host.sh) is idempotent: base packages,
Node 22, Docker Engine, OpenShell (pinned `v0.0.62`), gateway.env symlink, mkcert +
wildcard cert, and PATH tools (`osbox`, `init-secrets`).

**After `setup-host.sh`** (manual / interactive steps):
1. `init-secrets` — populate `.secrets/bedrock.env` + `.secrets/litellm.env`
2. `docker compose -f docker/compose.yml up -d` — start all Docker Compose services
3. `nemoclaw onboard` — interactive; point at `http://localhost:4000/v1`, key from litellm.env
4. Wire OpenShell inference: `openshell provider create` + `openshell inference set` (see litellm-proxy.md)
5. `systemctl --user enable --now nemoclaw-director-control-ui` — start probe service
6. `bootstrap/setup-claude-revproxy.sh` — start the claude-code wrapper in its sandbox
7. `claude auth login` on host, then `bootstrap/sync-claude-credentials.sh` — OAuth for wrapper
8. Install CA cert on each client device

**Post-nemoclaw note:** `nemoclaw onboard` installs its own 0.0.44 CLI + gateway (8080).
The lab gateway (17670 mTLS) uses the 0.0.62 binaries. Always use the explicit form for
lab sandbox commands:
```bash
/usr/bin/openshell --gateway-endpoint http://127.0.0.1:17670 --gateway-insecure sandbox create ...
```
After nemoclaw: `ln -sfn ~/home-lab/openshell/gateway.env ~/.config/openshell/gateway.env`

## Adding a new service

1. Copy `projects/_template/` → `projects/<name>/`
2. Edit `compose.yaml` — set `container_name: <name>` and add your image/env/ports
3. Add `Label: traefik.enable=true` — service becomes available at `<name>.lab.lan`
4. Join the shared network: `networks: [ai-net]` with `ai-net: {external: true}`
5. Start: `docker compose -f projects/<name>/compose.yaml up -d`

See [traefik/README.md](traefik/README.md) for the full label reference.

## Secrets

Real `.env` files are gitignored — commit only `*.env.example`.

```bash
init-secrets      # interactive: prompts for Bedrock keys, auto-generates LiteLLM key
                  # writes: .secrets/bedrock.env  .secrets/litellm.env
```

| Secret location | Contents | Consumer |
|---|---|---|
| `.secrets/bedrock.env` | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION` | LiteLLM container only |
| `.secrets/litellm.env` | `LITELLM_MASTER_KEY` | LiteLLM + OpenShell provider + NemoClaw onboard |
| `~/.claude/.credentials.json` | Claude OAuth token | Host + synced to claude-revproxy sandbox |

Raw AWS credentials live **only** in the LiteLLM container. The claude-code wrapper uses
OAuth (no AWS keys). Sandboxes using `inference.local` hold no credentials at all.
