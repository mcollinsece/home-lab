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

> **Note:** the homelab VM itself resolves via the router (`192.168.0.1`) + Tailscale, **not** AdGuard, so `*.lab.lan` does not resolve *from the VM*. Harmless — Traefik routes by Host header; sandboxes are outbound-only. Point the VM's resolver at `192.168.0.53` only if you want it to reach services by name locally.

---

## homelab VM (`192.168.0.51`)

### Specs

| Resource | Value | Notes |
|---|---|---|
| OS | Debian 13 (trixie) | |
| Podman runtime | rootless Podman 5.4.2 (overlay) | Quadlet services + OpenShell sandboxes |
| Node.js | v22.22.3 / npm 10.9.8 | NodeSource; Phase 1 prereq |
| OpenShell | v0.0.62 | agent sandbox runtime; gateway on `:17670`, Podman driver |
| Docker Engine | not installed | OpenShell runs on Podman; needed only for Phase 7 NemoClaw if Podman can't substitute |
| User | `debian` uid 1000, `sudo` | linger enabled — services survive logout |
| CPU / RAM | 4 vCPU / 15 GB | meets minimum; 8 vCPU / 16–24 GB recommended for multi-agent |
| Disk | 108 GB total, ~101 GB free | resized from 8 GB; no LVM |
| GPU | none | CPU-only; inference is remote |

### Running services

| Service | Type | Address | Status |
|---|---|---|---|
| `ai-net` | Podman bridge network | internal | ✅ |
| Traefik | Podman Quadlet | label-discovery via `podman.sock`, ports `:80` (→ HTTPS redirect) + `:443` (TLS) | ✅ |
| Portainer | Podman Quadlet | `https://portainer.lab.lan` | ✅ |
| Registry | Podman Quadlet | `registry.lab.lan` — Docker Registry v2 | ✅ |
| OpenShell gateway | systemd `--user` service | `0.0.0.0:17670` (mTLS), Podman driver | ✅ |
| `claude-code` sandbox | OpenShell sandbox | dual-auth: subscription (default) + Bedrock Sonnet 4.6 per-project | ✅ |
| OpenClaw | Podman Quadlet | `https://openclaw.lab.lan` — agent director; claude-cli primary, Bedrock fallback | ✅ |

> **OpenShell config note:** the gateway must bind `0.0.0.0:17670` (not the default `127.0.0.1`) so sandbox containers can reach it over the host bridge. Driver + bind live in [`openshell/gateway.env`](../../openshell/gateway.env), symlinked to `~/.config/openshell/gateway.env` by `setup-host.sh`. mTLS gates the wider bind. `openshell doctor check` falsely errors on Docker even when Podman is active — cosmetic.

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
systemctl --user restart traefik
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
| `init-secrets` | `bootstrap/init-secrets.sh` | Populate `.secrets/*.env` and Podman secrets from password manager after a clean rebuild |

Both are symlinked by `setup-host.sh` and resolve back to the repo via `readlink -f` so they work correctly even when invoked through the symlink.

### Agent sandbox architecture

```
OpenClaw (Quadlet — always-on director at openclaw.lab.lan)
   └── OpenShell gateway (:17670)  ← OpenClaw backend
         ├── claude-code sandbox  (worker — osbox --claudeai [--bedrock] [--headless])
         ├── codex sandbox        (worker — osbox --codex,   Phase 5)
         └── gemini sandbox       (worker — osbox --gemini,  Phase 6)
```

OpenClaw is the orchestration layer above OpenShell. It calls `openshell sandbox create`
internally (native integration: `docs.openclaw.ai/gateway/openshell`) to spawn and manage
worker sandboxes. **OpenShell is the control plane for all agent isolation.** OpenClaw
runs as a Quadlet (not inside a sandbox) because it needs to reach the gateway as a client.

For k8s migration: OpenClaw Quadlet → k8s Deployment; OpenShell sandboxes → k8s Pods.

### Agent sandbox lifecycle

OpenShell sandboxes have **container-local, manually-initialized state** — no provider
auto-injects credentials. Consequences:

- **A brand-new sandbox starts blank** — zero auth. Auth is staged by `osbox`: it
  uploads `~/.claude/.credentials.json`, `settings.json`, and `.claude.json` (with
  `/sandbox` pre-trusted) before the entrypoint runs, so Claude Code starts without
  the wizard or trust dialog.
- **The `claude-code` sandbox holds its auth** in `/sandbox/.claude/` (subscription
  token + Bedrock AWS keys in `settings.json` env block). Persists across
  `exec`/`connect`; survives as long as the container isn't removed.
- **Not pinned across reboots** — the sandbox container has no restart policy. After a
  host reboot, restart with `openshell sandbox create` or use `osbox` to recreate.
  A snapshot revert wipes the container entirely → redo manual auth steps.
- **`osbox` is idempotent** — running it twice on the same name exits cleanly with
  connect/dispatch/recreate instructions. Safe to call from a boot service.

### Secrets management

Two parallel stores (different consumers, both populated by `init-secrets`):

| Store | Path | Consumer |
|---|---|---|
| `.secrets/bedrock.env` | `~/home-lab/.secrets/` (gitignored) | `osbox --bedrock` (env injection into OpenShell sandboxes) |
| Podman secrets | `podman secret ls` | Quadlet containers via `Secret=` directive (OpenClaw `anthropic_api_key`, future Codex/Gemini) |

### Reproducing this host

```bash
git clone <repo> ~/home-lab && ~/home-lab/bootstrap/setup-host.sh
```

[`bootstrap/setup-host.sh`](../../bootstrap/setup-host.sh) is idempotent and reproduces:
base packages, Node 22, linger, Podman socket, Quadlet symlinks (ai-net / Traefik /
Portainer / Registry / OpenClaw), OpenShell (pinned `v0.0.62`), gateway.env symlink,
Podman registries.conf (`registry.lab.lan` insecure), and PATH tools (`osbox`,
`init-secrets`).

Manual steps after `setup-host.sh` (tracked in [todos.md](todos.md)):
- `init-secrets` — Bedrock keys + Anthropic API key → Podman secrets + `.secrets/`
- `cp openclaw/openclaw.env.example openclaw/openclaw.env`
- `claude login` (interactive OAuth — cannot be scripted)
- `systemctl --user start openclaw`
- Configure OpenShell backend in OpenClaw UI
- Generate mkcert CA + wildcard cert (see HTTPS / TLS section above)
- Install CA cert on each client device

> **Verified 2026-06-12:** idempotent re-run confirmed — Node 22, OpenShell `v0.0.62`,
> gateway + `podman.socket` active, `driver=podman`, bind `0.0.0.0:17670`, `Connected`.
> Manual post-steps also verified: `claude-code` sandbox Ready/healthy, `claude login`,
> live prompt through egress policy, `portainer.lab.lan` → Traefik 200. This was an
> idempotent re-run over the live host; a clean from-scratch rebuild is unproven but
> low-risk. See [TROUBLESHOOTING.md](../../bootstrap/TROUBLESHOOTING.md).

### Pending

Outstanding work lives in **[todos.md](todos.md)**. Current state:

- ✅ Phase 1 (Node 22) · Phase 2 (OpenShell + Claude Code subscription) · `setup-host.sh` · AdGuard `*.lab.lan` · Phase 3 (Bedrock dual-auth)
- ✅ Phase 4 — OpenClaw live at `https://openclaw.lab.lan` (claude-cli + Bedrock, Traefik HTTPS, device pairing complete); 2 items remain (OpenShell backend wiring, Bedrock model verification)
- ⬜ Phase 5 — Codex CLI sandbox (`osbox --codex`)
- ⬜ Phase 6 — Gemini CLI sandbox (`osbox --gemini`)
- ⬜ Phase 7 — NemoClaw + NeMo Agent Toolkit orchestration
- ⬜ Phase 8 — Alternative providers (OpenAI, Grok, Gemini CLI, Copilot, OpenRouter)

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
    │           ├── Traefik (Quadlet) — reverse proxy :80, label-based routing
    │           ├── Portainer (Quadlet) — portainer.lab.lan
    │           ├── Registry (Quadlet) — registry.lab.lan (Docker Registry v2 :5000)
    │           ├── OpenClaw (Quadlet) — openclaw.lab.lan (agent director :18789)
    │           ├── OpenShell gateway (systemd --user) — :17670, deny-by-default
    │           │     └── claude-code sandbox (Podman) — outbound-only, dual-auth
    │           └── projects/ — one Quadlet per service on ai-net
    └── ... other devices via AdGuard DHCP
```

---

## DNS / routing flow

1. Client requests `<service>.lab.lan`
2. AdGuard resolves `*.lab.lan` → `192.168.0.51`
3. Traefik routes to the matching container via `ContainerName` label

Traefik's `defaultRule` is `Host("{{ normalize .Name }}.lab.lan")` — naming a container
`grafana` makes it available at `grafana.lab.lan` with no extra label. An explicit
`traefik.http.routers.*.rule` label overrides this for custom hostnames or paths.
