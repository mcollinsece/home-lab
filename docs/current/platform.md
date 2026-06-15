# Current Infrastructure State

> **Future plans:** [../future/ai-dev-ground.md](../future/ai-dev-ground.md) — AI agent stack, phases, k8s roadmap

---

## Hardware

### Proxmox Host
- **Device:** Dell OptiPlex 7050 Micro (Renewed)
- **CPU:** Intel Quad Core i5-6500T (up to 3.1GHz)
- **RAM:** 16 GB DDR4
- **Storage:** 256 GB SSD
- **OS:** Proxmox VE
- **Web UI:** `192.168.0.50:8006`

---

## Network nodes

| Node | Address | Type | Role |
|---|---|---|---|
| Proxmox host | `192.168.0.50` | bare metal | Hypervisor |
| **homelab VM** | `192.168.0.51` | Proxmox VM | Primary workload host |
| AdGuard | `192.168.0.53` | LXC container | DHCP + DNS for entire LAN |

---

## AdGuard Home (`192.168.0.53`)

- DHCP server for the entire network
- Authoritative DNS for the entire network (replaces Pi-hole from old setup)
- Ad/tracker blocking
- DNS rewrites (configured ✅): `*.lab.lan → 192.168.0.51`, `adguard.lan → 192.168.0.53`, `debian.lan → 192.168.0.51`. LAN clients that use AdGuard for DNS (via DHCP) resolve lab hostnames; verified `portainer.lab.lan → 192.168.0.51 → Traefik HTTP 200`.

> **Note:** the homelab VM itself resolves via the router (`192.168.0.1`), so `*.lab.lan` does not resolve *from the VM*. Harmless — Traefik routes by Host header; sandboxes are outbound-only.

---

## homelab VM (`192.168.0.51`)

### Specs

| Resource | Value | Notes |
|---|---|---|
| OS | Debian 13 (trixie) | |
| Container runtime | Docker Engine (rootful) | Manages all core services via Docker Compose |
| Node.js | v22.22.3 / npm 10.9.8 | NodeSource; required by NemoClaw CLI |
| OpenShell | v0.0.62 | agent sandbox runtime; gateway on `:17670`, Docker driver |
| Podman | present (system default) | Not used for services; may be revisited if NemoClaw adds Podman support |
| User | `debian` uid 1000, `sudo` | linger enabled — OpenShell gateway survives logout |
| CPU / RAM | 4 vCPU / 15 GB | meets minimum; 8 vCPU / 16–24 GB recommended for multi-agent |
| Disk | 108 GB total, ~101 GB free | resized from 8 GB; no LVM |
| GPU | none | CPU-only; inference is remote (Bedrock via LiteLLM, or OAuth via wrapper) |

> **Container runtime migration (2026-06-13):** Migrated from rootless Podman Quadlets to
> rootful Docker Engine + Docker Compose. Motivation: NemoClaw (NVIDIA's managed OpenClaw
> stack) requires Docker as its compute driver. All services now run as Docker Compose
> services defined in `docker/compose.yml`. OpenClaw is managed by NemoClaw (not Compose).
> Podman is retained on the system in case NemoClaw adds Podman support in a future release;
> tracked in [todos.md](todos.md).

### Running services

| Service | Type | Address | Status |
|---|---|---|---|
| `ai-net` | Docker bridge network | internal (172.18.0.0/16) | ✅ |
| Traefik | Docker Compose | `:80` (→ HTTPS redirect) + `:443` (TLS), label-discovery via `/var/run/docker.sock` | ✅ |
| Portainer | Docker Compose | `https://portainer.lab.lan` | ✅ |
| Registry | Docker Compose | `registry.lab.lan` — Docker Registry v2, `:5000` insecure | ✅ |
| LiteLLM | Docker Compose | `https://litellm.lab.lan`, `:4000` internal — routes to Bedrock (claude-sonnet-4-6) and the claude-code wrapper | ✅ |
| OpenShell gateway (lab) | systemd `--user` | `0.0.0.0:17670` (mTLS), Docker driver, 0.0.62 binaries | ✅ |
| OpenShell gateway (nemoclaw) | managed by nemoclaw | `127.0.0.1:8080` plaintext, 0.0.44 | ✅ (for director) |
| OpenClaw director | NemoClaw-managed sandbox | `openclaw.lab.lan` (Traefik file route → Docker alias `openclaw-director:18789`) — models: `litellm/claude-sonnet-4-6` + `litellm/claude-code-wrapper-local`; token auth; CORS/provider patches persistent via `nemoclaw-director-control-ui` probe service | ✅ live |
| claude-revproxy sandbox | OpenShell (lab gw 17670) | ai-net alias `claude-code-wrapper:8000` — `claude-code-openai-wrapper` (uvicorn); OAuth/Pro → `api.anthropic.com`; no AWS credentials | ✅ live |

### Agent sandbox architecture

```
NemoClaw (host CLI — manages OpenClaw lifecycle)
   └── director sandbox (OpenClaw — openclaw.lab.lan)
         models: litellm/claude-sonnet-4-6         → LiteLLM → Bedrock
                 litellm/claude-code-wrapper-local  → LiteLLM → claude-revproxy sandbox

Routing chain for openclaw.lab.lan:
  Browser → Traefik → openclaw-director:18789 (Docker network alias on ai-net) → director sandbox
  (probe script connects director container to ai-net with alias; no SSH tunnel or socat)

OpenShell lab gateway (17670, Docker driver, mTLS, 0.0.62 /usr/bin)
  inference.local → litellm-local → http://localhost:4000/v1
    ├── claude-code sandbox (Ready; ANTHROPIC_BASE_URL=https://inference.local; interactive use)
    ├── claude-revproxy sandbox (Ready; uvicorn :8000; CLAUDE_CODE_AUTH_METHOD=cli → OAuth)
    │     connected to ai-net with alias claude-code-wrapper (outbound to api.anthropic.com)
    ├── codex sandbox (Phase 5)
    └── gemini sandbox (Phase 6)

NemoClaw gateway (8080 plaintext + 10.89.0.1 lo alias, 0.0.44 pinned, managed)
         └── director sandbox (OpenClaw; ✅ live)

LiteLLM model routing (Docker Compose, ai-net, :4000):
  claude-sonnet-4-6          → Bedrock (us.anthropic.claude-sonnet-4-6, SigV4)
  bedrock/us.anthropic.*     → Bedrock (alias)
  claude-code-sonnet         → http://claude-code-wrapper:8000/v1  (claude-revproxy sandbox)
  claude-code/sonnet         → http://claude-code-wrapper:8000/v1  (alias)
  claude-code-wrapper-local  → http://claude-code-wrapper:8000/v1  (alias, shown in OpenClaw picker)
```

**LiteLLM** is the single inference credential boundary. Bedrock routes hold the only AWS credentials.
The claude-code wrapper uses OAuth (no AWS keys); credentials are synced from `~/.claude/.credentials.json`
on the host to `/root/.claude/.credentials.json` in the sandbox via `bootstrap/sync-claude-credentials.sh`.

**NemoClaw** is NVIDIA's managed stack that runs OpenClaw inside an OpenShell sandbox.
This provides proper isolation for the director itself. The probe service
(`nemoclaw-director-control-ui`) handles: CORS patch, litellm-only provider, pass-through shim,
ai-net connect, and openclaw gateway start as the sandbox user on each boot.

### HTTPS / TLS

All `*.lab.lan` traffic is served over HTTPS. Traefik terminates TLS using a
[mkcert](https://github.com/FiloSottile/mkcert) wildcard cert signed by a local CA.
HTTP requests on `:80` are permanently redirected to HTTPS on `:443`.

| Artifact | Path in repo | Notes |
|---|---|---|
| Wildcard cert | `traefik/certs/_wildcard.lab.lan.pem` | expires 2028-09-13 |
| Wildcard key | `traefik/certs/_wildcard.lab.lan-key.pem` | gitignored (`*-key.pem`) |
| CA cert (public) | `traefik/certs/ca/rootCA.pem` | safe to commit; install on each client |
| CA key | `traefik/certs/ca/rootCA-key.pem` | gitignored |
| Dynamic TLS config | `traefik/tls.yml` | loaded by Traefik file provider; sets cert as default |

**Regenerate cert** (when it expires or if the CA is rotated):

```bash
CAROOT=traefik/certs/ca mkcert \
  -cert-file traefik/certs/_wildcard.lab.lan.pem \
  -key-file  traefik/certs/_wildcard.lab.lan-key.pem \
  "*.lab.lan"
docker compose -f docker/compose.yml restart traefik
```

**Install the CA on each client device** — one-time, per machine. Pull `rootCA.pem`
from git or scp it from the server, then:

- **macOS:** `sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain rootCA.pem`
- **Windows (Admin PowerShell):** `Import-Certificate -FilePath rootCA.pem -CertStoreLocation Cert:\LocalMachine\Root`
- **Linux:** `sudo cp rootCA.pem /usr/local/share/ca-certificates/lab-lan-ca.crt && sudo update-ca-certificates`

Firefox on Linux also requires a manual import: Settings → Privacy & Security →
Certificates → View Certificates → Authorities → Import.

### CLI tools (PATH-resident, in `~/.local/bin`)

| Command | Source | Purpose |
|---|---|---|
| `osbox` | `bootstrap/osbox` | Spin up an auth-ready OpenShell agent sandbox (`--claudeai`, `--bedrock`, `--clone`, `--headless`, `--wrapper`) |
| `init-secrets` | `bootstrap/init-secrets.sh` | Populate `.secrets/*.env` from password manager after a clean rebuild |

Both are symlinked by `setup-host.sh` and resolve back to the repo via `readlink -f`.

### Secrets management

All secrets are stored in `.secrets/` at the repo root (gitignored). Docker Compose
injects them via `env_file:` directives — no Docker Swarm required.

| File | Contents | Consumer |
|---|---|---|
| `.secrets/bedrock.env` | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION` | LiteLLM container (sole holder of Bedrock creds) |
| `.secrets/litellm.env` | `LITELLM_MASTER_KEY` | LiteLLM container + OpenShell provider + NemoClaw onboard |
| `~/.claude/.credentials.json` | Claude OAuth token | Host + synced to claude-revproxy sandbox |

Raw AWS credentials live **only** in the LiteLLM container. The claude-code wrapper uses
OAuth (no AWS keys). Worker sandboxes that use `inference.local` hold no credentials at all.

### Bootstrap scripts

| Script | Purpose |
|---|---|
| `bootstrap/setup-host.sh` | Idempotent host setup: Docker, Node 22, OpenShell, mkcert, PATH tools |
| `bootstrap/init-secrets.sh` | Interactive: Bedrock keys + LiteLLM key → `.secrets/` |
| `bootstrap/nemoclaw-director-probe.sh` | Run by `nemoclaw-director-control-ui` systemd unit — patches openclaw.json, connects to ai-net, starts openclaw gateway |
| `bootstrap/setup-claude-revproxy.sh` | Start the claude-code wrapper inside the `openshell-claude-revproxy` sandbox; idempotent |
| `bootstrap/sync-claude-credentials.sh` | Copy host `~/.claude/.credentials.json` → sandbox `/root/.claude/`; run after `claude auth login` |
| `bootstrap/osbox` | OpenShell sandbox launcher helper; `--wrapper` connects sandbox to ai-net as claude-code-wrapper |

### Reproducing this host

```bash
git clone <repo> ~/home-lab && ~/home-lab/bootstrap/setup-host.sh
```

[`bootstrap/setup-host.sh`](../../bootstrap/setup-host.sh) is idempotent and reproduces:
base packages, Node 22, Docker Engine, linger, insecure registry config, `/etc/hosts`
entry, OpenShell (pinned `v0.0.62`), gateway.env symlink (Docker driver), mkcert + cert,
and PATH tools (`osbox`, `init-secrets`).

Manual steps after `setup-host.sh`:
- `init-secrets` — Bedrock keys → `.secrets/bedrock.env`; LiteLLM key → `.secrets/litellm.env`
- `docker compose -f docker/compose.yml up -d` — start Traefik, Portainer, Registry, LiteLLM
- NemoClaw: `curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash` → interactive onboard
- Configure OpenShell inference routing: `openshell provider create` + `openshell inference set` (see litellm-proxy.md)
- `systemctl --user enable --now nemoclaw-director-control-ui` — start probe service; connects director to ai-net and starts openclaw gateway
- `claude auth login` on host, then `bootstrap/setup-claude-revproxy.sh` — wrapper sandbox setup + credential sync
- Install CA cert on each client device

### Pending

Outstanding work lives in **[todos.md](todos.md)**. Current state:

- ✅ Phase 1 (Node 22) · Phase 2 (OpenShell + Claude Code subscription) · `setup-host.sh` · AdGuard `*.lab.lan` · Phase 3 (Bedrock dual-auth)
- ✅ Phase 4 — OpenClaw live (previously as Podman Quadlet; migrated to NemoClaw in Phase 7)
- ✅ Phase 4.5 — LiteLLM proxy live (Bedrock routing verified; migrated to Docker Compose)
- ✅ Phase 7 — **Docker + NemoClaw migration** fully live (2026-06-13/14). Director "Ready"; `openclaw.lab.lan` live; both models functional in picker. Routing: Traefik → `openclaw-director:18789` (Docker network alias on ai-net). Probe service handles: CORS patch, litellm-only provider, pass-through shim, ai-net connect, openclaw gateway start.
- ✅ **claude-code-wrapper-local** — claude-code-openai-wrapper running in `openshell-claude-revproxy` sandbox; OAuth/Pro subscription auth; LiteLLM routes three aliases to `http://claude-code-wrapper:8000/v1`; verified end-to-end via OpenClaw director session (Harbor Freight question → Claude Code → Anthropic).
- ⬜ Phase 5 — Codex CLI sandbox (`osbox --codex`)
- ⬜ Phase 6 — Gemini CLI sandbox (`osbox --gemini`)
- ⬜ Phase 8 — Evaluate Podman support in future NemoClaw releases; restore Podman-based services if supported
- ⬜ Phase 9 — Alternative providers (OpenAI, Grok, Gemini CLI, Copilot, OpenRouter)
- ⬜ systemd timer for `sync-claude-credentials.sh` (keep OAuth token in sandbox fresh)
- ⬜ `nemoclaw-director-control-ui` probe service: auto-restart wrapper on sandbox rebuild

---

## Network topology

```
Internet
    │
  Router (192.168.0.1)
    │
  LAN (192.168.0.0/24)
    ├── 192.168.0.50  Proxmox host (Dell OptiPlex 7050 Micro)
    │     ├── 192.168.0.53  AdGuard Home (LXC) — DHCP + DNS, *.lab.lan wildcard
    │     └── 192.168.0.51  homelab VM (Debian 13)
    │           ├── Traefik (Docker Compose, ai-net) — reverse proxy :80/:443
    │           ├── Portainer (Docker Compose, ai-net) — portainer.lab.lan
    │           ├── Registry (Docker Compose, ai-net) — registry.lab.lan :5000
    │           ├── LiteLLM (Docker Compose, ai-net) — litellm.lab.lan → Bedrock + wrapper
    │           ├── OpenShell gateway (systemd --user) — :17670 Docker driver, deny-by-default
    │           │     inference.local → litellm-local → http://localhost:4000/v1
    │           │     ├── claude-code sandbox (Docker) — outbound-only, inference.local
    │           │     ├── claude-revproxy sandbox (Docker, on ai-net alias claude-code-wrapper)
    │           │     │     uvicorn :8000 → OAuth/Pro → api.anthropic.com
    │           │     ├── codex sandbox (Phase 5)
    │           │     └── gemini sandbox (Phase 6)
    │           └── NemoClaw gateway (:8080) + director sandbox (OpenClaw)
    │                 openclaw.lab.lan → Traefik → openclaw-director:18789 (ai-net alias)
    └── ... other devices via AdGuard DHCP
```

---

## DNS / routing flow

1. Client requests `<service>.lab.lan`
2. AdGuard resolves `*.lab.lan` → `192.168.0.51`
3. Traefik routes to the matching container via Docker label (`container_name` → `<name>.lab.lan`)

Traefik's `defaultRule` is `Host("{{ normalize .Name }}.lab.lan")` — naming a container
`grafana` makes it available at `grafana.lab.lan` with no extra label. An explicit
`traefik.http.routers.*.rule` label overrides this for custom hostnames or paths.

OpenClaw and Traefik dashboard use static file routes in `traefik/dynamic/` because
Traefik's Docker provider logs "client version 1.24 too old" for NemoClaw-managed containers
(different Docker API version than the lab's Docker socket).
