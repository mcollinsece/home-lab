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

> **Note:** the homelab VM itself resolves via the router (`192.168.0.1`) + Tailscale, **not** AdGuard, so `*.lab.lan` does not resolve *from the VM*. Harmless (Traefik routes by Host header; sandboxes are outbound-only). Point the VM's resolver at `192.168.0.53` only if you want it to reach services by name locally.

---

## homelab VM (`192.168.0.51`)

### Specs

| Resource | Value | Notes |
|---|---|---|
| OS | Debian 13 (trixie) | |
| Podman runtime | rootless Podman 5.4.2 (overlay) | for Quadlet services + OpenShell sandboxes |
| Node.js | v22.22.3 / npm 10.9.8 | NodeSource; Phase 1 prereq |
| OpenShell | v0.0.62 | agent sandbox runtime; gateway on `:17670`, Podman driver |
| Docker Engine | not installed | OpenShell runs on Podman; Docker is an optional fallback, and is needed for the Phase 6 NemoClaw experiment (see future plan) |
| User | `debian` uid 1000, `sudo` | linger enabled — services survive logout |
| CPU / RAM | 4 vCPU / 15 GB | meets minimum; 8 vCPU / 16–24 GB recommended for multi-agent |
| Disk | 108 GB total, ~101 GB free | resized from 8 GB; no LVM |
| GPU | none | CPU-only; inference is remote |

### Running services

| Service | Type | Address | Status |
|---|---|---|---|
| `ai-net` | Podman bridge network | internal | ✅ |
| Traefik | Podman Quadlet | label-discovery via `podman.sock`, port `:80` | ✅ |
| Portainer | Podman Quadlet | `portainer.lab.lan` | ✅ |
| OpenShell gateway | systemd `--user` service | `0.0.0.0:17670` (mTLS), Podman driver, `openshell` bridge | ✅ |
| `claude-code` sandbox | OpenShell sandbox (Podman) | outbound-only; dual-auth policy v2 `openshell/policies/claude-code.yaml` (Anthropic + Bedrock egress) | ✅ dual-auth live: subscription (default) + Bedrock Sonnet 4.6 per-project, both verified |

> **OpenShell config note:** the gateway must bind `0.0.0.0:17670` (not the Debian `.deb` default of `127.0.0.1`) so sandbox containers can reach it over the host bridge. Driver + bind live in [`openshell/gateway.env`](../../openshell/gateway.env) (`OPENSHELL_DRIVERS=podman`, `OPENSHELL_BIND_ADDRESS=0.0.0.0`), git-managed and symlinked to `~/.config/openshell/gateway.env` by the bootstrap script. mTLS gates the wider bind. `openshell doctor check` falsely errors on Docker even when Podman is active — cosmetic.

### Reproducing this host

This server is **transitional** — not its forever home — so everything is
designed to rebuild from a clean checkout:

```bash
git clone <repo> ~/home-lab && ~/home-lab/bootstrap/setup-host.sh
```

[`bootstrap/setup-host.sh`](../../bootstrap/setup-host.sh) is idempotent and
reproduces: base packages, Node 22, linger, the Podman socket, the Quadlet
symlinks (ai-net/Traefik/Portainer), OpenShell (pinned `v0.0.62`), and the
git-managed `gateway.env` symlink. It deliberately leaves out anything sensitive
or interactive — those are tracked in [todos.md](todos.md).

> **Verified 2026-06-12:** re-ran end-to-end and confirmed every checklist item
> (Node 22, OpenShell `v0.0.62`, gateway + `podman.socket` active, `driver=podman`,
> bind `0.0.0.0:17670`, `Connected`), plus the manual post-steps — `claude-code`
> sandbox `Ready`/healthy, `claude login` + a live prompt through the egress policy,
> and `portainer.lab.lan` → Traefik 200. This was an **idempotent re-run over the
> live host**, not a clean snapshot-revert; the from-scratch rebuild is unproven but
> low-risk (repo + [TROUBLESHOOTING.md](../../bootstrap/TROUBLESHOOTING.md) are the
> durability guarantee, not a VM snapshot). See [todos.md](todos.md) for the detail.

### Agent sandbox lifecycle (important)

OpenShell sandboxes are **container-local, manually-initialized state** — there is
no provider configured to auto-inject credentials (`openshell provider list` →
none), and no provider type fits this setup's auth anyway (subscription is
interactive OAuth; Bedrock needs env-var keys for SigV4). Consequences:

- **A brand-new sandbox starts blank** — fresh `/sandbox` from the base image, zero
  auth. Auth is initialized only by what you put into the create flow: `claude
  login` (subscription) and AWS keys via `--env` at create or a `settings.json`
  merge (Bedrock). Nothing carries over from the existing `claude-code` sandbox.
- **The existing `claude-code` sandbox holds its auth** in `/sandbox/.claude/`
  (`.credentials.json` = subscription, `settings.json` env = AWS keys). It persists
  across `exec`/`connect` and survives on disk as long as the container isn't
  *removed*.
- **Not pinned across reboot:** the sandbox container's restart policy is `no` and
  there's no systemd/Quadlet unit — after a host reboot it may need a restart
  (Phase 5's always-on OpenClaw will need a Quadlet/restart policy). A snapshot
  revert wipes it entirely → re-do the manual auth steps.

A reproducible spawn script (`bootstrap/new-claude-sandbox.sh`) is tracked in
[todos.md](todos.md).

### Pending

Outstanding work (manual/sensitive/interactive items + next phases) lives in
**[todos.md](todos.md)**. Headlines:

- [ ] Phase 4 Codex + Gemini CLI sandboxes; local registry `:5000`; reproducible
      sandbox-spawn script; Podman secrets
- [x] ~~Phase 1 (Node 22)~~ · ~~Phase 2 (OpenShell + Claude Code subscription)~~ ·
      ~~`setup-host.sh`~~ · ~~AdGuard `*.lab.lan` wildcard~~ ·
      ~~**Phase 3 Bedrock dual-auth**~~ — **done (2026-06-12)**

> **Docker Engine:** confirmed **not** needed for the agent baseline — OpenShell
> runs natively on rootless Podman. Install only for the deferred Phase 6
> NemoClaw experiment.

---

## Network topology

```
Internet
    │
  Router
    │
  LAN (192.168.0.0/24)
    ├── 192.168.0.50  Proxmox host (Dell OptiPlex 7050 Micro)
    │     ├── 192.168.0.53  AdGuard Home (LXC) — DHCP + DNS, *.lab.lan wildcard ☐
    │     └── 192.168.0.51  homelab VM (Debian 13)
    │           ├── Traefik (Quadlet) — label-based reverse proxy on :80
    │           ├── Portainer (Quadlet) — portainer.lab.lan
    │           ├── OpenShell gateway (systemd --user) — :17670, deny-by-default
    │           │     └── claude-code sandbox (Podman) — outbound-only, dual-auth
    │           └── projects/ — one Quadlet per service on ai-net
    └── ... other devices via AdGuard DHCP
```

---

## DNS / routing flow

1. Client requests `<service>.lab.lan`
2. AdGuard resolves `*.lab.lan` → `192.168.0.51`
3. Traefik routes to the matching container via `ContainerName` label (`<name>` → `<name>.lab.lan`)

Traefik's `defaultRule` is `Host("{{ normalize .Name }}.lab.lan")` — naming a container `grafana` makes it available at `grafana.lab.lan` with no extra label. An explicit `traefik.http.routers.*.rule` label overrides this for custom hostnames.
