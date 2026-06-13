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

> **Note:** the homelab VM itself resolves via the router (`192.168.0.1`) + Tailscale, **not** AdGuard, so `*.lab.lan` does not resolve *from the VM*. Harmless — Traefik routes by Host header; sandboxes are outbound-only.

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
| GPU | none | CPU-only; inference is remote (Bedrock via LiteLLM) |

> **Container runtime migration (2026-06-13):** Migrated from rootless Podman Quadlets to
> rootful Docker Engine + Docker Compose. Motivation: NemoClaw (NVIDIA's managed OpenClaw
> stack) requires Docker as its compute driver. All services now run as Docker Compose
> services defined in `docker/compose.yml`. OpenClaw is managed by NemoClaw (not Compose).
> Podman is retained on the system in case NemoClaw adds Podman support in a future release;
> tracked in [todos.md](todos.md).

### Running services

| Service | Type | Address | Status |
|---|---|---|---|
| `ai-net` | Docker bridge network | internal | ✅ |
| Traefik | Docker Compose | label-discovery via `/var/run/docker.sock`, ports `:80` (→ HTTPS redirect) + `:443` (TLS) | ✅ |
| Portainer | Docker Compose | `https://portainer.lab.lan` | ✅ |
| Registry | Docker Compose | `registry.lab.lan` — Docker Registry v2, `:5000` insecure | ✅ |
| LiteLLM | Docker Compose | `https://litellm.lab.lan`, `:4000` internal — unified inference proxy → Bedrock | ✅ |
| OpenShell gateway | systemd `--user` service | `0.0.0.0:17670` (mTLS), Docker driver | ✅ |
| OpenClaw | NemoClaw-managed sandbox | `http://127.0.0.1:18789` (local) / `openclaw.lab.lan` (via Traefik file route) | ⬜ pending NemoClaw onboard |

### Agent sandbox architecture

```
NemoClaw (host CLI — manages OpenClaw lifecycle)
   └── OpenClaw (OpenShell sandbox — agent director)
         └── LiteLLM (:4000) ← inference backend (Bedrock via Docker Compose)

OpenShell gateway (:17670, Docker driver)
  inference.local → litellm-local provider → http://localhost:4000/v1
         ├── claude-code sandbox  (worker — osbox --claudeai)
         ├── codex sandbox        (worker — osbox --codex,   Phase 5)
         └── gemini sandbox       (worker — osbox --gemini,  Phase 6)
```

**NemoClaw** is NVIDIA's managed stack that runs OpenClaw inside an OpenShell sandbox.
This provides native OpenClaw + OpenShell integration: proper sandbox isolation for the
director itself, and inference routed through `inference.local` gateway. NemoClaw is
installed via `curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash` and managed with
the `nemoclaw` CLI.

**LiteLLM** is the single inference credential boundary. All pay-per-token requests
(from NemoClaw's OpenClaw sandbox and from worker sandboxes via `inference.local`)
route through LiteLLM. Adding a new model provider is a one-line change to
`litellm/config.yaml`.

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
| `osbox` | `bootstrap/osbox` | Spin up an auth-ready OpenShell agent sandbox (`--claudeai`, `--bedrock`, `--clone`, `--headless`) |
| `init-secrets` | `bootstrap/init-secrets.sh` | Populate `.secrets/*.env` from password manager after a clean rebuild |

Both are symlinked by `setup-host.sh` and resolve back to the repo via `readlink -f`.

### Secrets management

All secrets are stored in `.secrets/` at the repo root (gitignored). Docker Compose
injects them via `env_file:` directives — no Docker Swarm required.

| File | Contents | Consumer |
|---|---|---|
| `.secrets/bedrock.env` | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION` | LiteLLM container (sole holder of Bedrock creds) |
| `.secrets/litellm.env` | `LITELLM_MASTER_KEY` | LiteLLM container + OpenShell provider + NemoClaw onboard |

`osbox` reads `.secrets/bedrock.env` for Bedrock credential injection into legacy sandboxes.
Post Phase 4.5, sandboxes use `inference.local` instead and no longer need raw creds.

### Reproducing this host

```bash
git clone <repo> ~/home-lab && ~/home-lab/bootstrap/setup-host.sh
```

[`bootstrap/setup-host.sh`](../../bootstrap/setup-host.sh) is idempotent and reproduces:
base packages, Node 22, Docker Engine, linger, insecure registry config, `/etc/hosts`
entry, OpenShell (pinned `v0.0.62`), gateway.env symlink (Docker driver), mkcert + cert,
and PATH tools (`osbox`, `init-secrets`).

Manual steps after `setup-host.sh` (tracked in [todos.md](todos.md)):
- `init-secrets` — Bedrock keys → `.secrets/bedrock.env`; LiteLLM key → `.secrets/litellm.env`
- `docker compose -f docker/compose.yml up -d` — start Traefik, Portainer, Registry, LiteLLM
- NemoClaw: `curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash` → interactive onboard
- Configure OpenShell inference routing: `openshell provider create` + `openshell inference set`
- `claude login` (interactive OAuth — if claude-cli backend needed)
- Install CA cert on each client device

### Pending

Outstanding work lives in **[todos.md](todos.md)**. Current state:

- ✅ Phase 1 (Node 22) · Phase 2 (OpenShell + Claude Code subscription) · `setup-host.sh` · AdGuard `*.lab.lan` · Phase 3 (Bedrock dual-auth)
- ✅ Phase 4 — OpenClaw live (previously as Podman Quadlet; migrated to NemoClaw in Phase 7)
- ✅ Phase 4.5 — LiteLLM proxy live (Bedrock routing verified; migrated to Docker Compose)
- ✅ Phase 7 — **Docker + NemoClaw migration complete** (2026-06-13): All services moved from Podman Quadlets to Docker Compose; NemoClaw onboard pending (interactive)
- ⬜ Phase 5 — Codex CLI sandbox (`osbox --codex`)
- ⬜ Phase 6 — Gemini CLI sandbox (`osbox --gemini`)
- ⬜ Phase 8 — Evaluate Podman support in future NemoClaw releases; restore Podman-based services if supported
- ⬜ Phase 9 — Alternative providers (OpenAI, Grok, Gemini CLI, Copilot, OpenRouter)

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
    │           ├── Traefik (Docker Compose) — reverse proxy :80/:443, label-based routing
    │           ├── Portainer (Docker Compose) — portainer.lab.lan
    │           ├── Registry (Docker Compose) — registry.lab.lan (Docker Registry v2 :5000)
    │           ├── LiteLLM (Docker Compose) — litellm.lab.lan — inference proxy → Bedrock
    │           ├── OpenShell gateway (systemd --user) — :17670 Docker driver, deny-by-default
    │           │     inference.local → litellm-local → http://localhost:4000/v1
    │           │     ├── NemoClaw sandbox (Docker) — OpenClaw director :18789
    │           │     ├── claude-code sandbox (Docker) — outbound-only, inference.local
    │           │     ├── codex sandbox (Phase 5)
    │           │     └── gemini sandbox (Phase 6)
    │           └── projects/ — one Docker Compose per service on ai-net
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
