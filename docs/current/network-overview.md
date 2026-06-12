# Current Infrastructure State

> **History & context:** [homelab-review.md](homelab-review.md) — what the old setup was and why we rebuilt
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
- DNS wildcard: `*.lab.lan → 192.168.0.51` — **not yet configured; must be added before lab hostnames resolve from LAN clients**

---

## homelab VM (`192.168.0.51`)

### Specs

| Resource | Value | Notes |
|---|---|---|
| OS | Debian 13 (trixie) | |
| Podman runtime | rootless Podman 5.4.2 (overlay) | for Quadlet services |
| Docker Engine | not installed | required for OpenShell (see future plan) |
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

### Pending

- [ ] **AdGuard wildcard:** add `*.lab.lan → 192.168.0.51` rewrite so lab hostnames resolve from LAN clients
- [ ] **Docker Engine:** required for OpenShell agent sandboxes ([Phase 1](../future/ai-dev-ground.md#phase-1--vm-base-prep))
- [ ] **Local image registry:** `registry/registry.container` Quadlet on `localhost:5000`
- [ ] **Podman secrets:** `anthropic_api_key`, AWS Bedrock creds
- [ ] **`bootstrap/setup-host.sh`:** idempotent rebuild script (ai-net, Traefik, registry, linger)

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
    │           └── projects/ — one Quadlet per service on ai-net
    └── ... other devices via AdGuard DHCP
```

---

## DNS / routing flow

1. Client requests `<service>.lab.lan`
2. AdGuard resolves `*.lab.lan` → `192.168.0.51`
3. Traefik routes to the matching container via `ContainerName` label (`<name>` → `<name>.lab.lan`)

Traefik's `defaultRule` is `Host("{{ normalize .Name }}.lab.lan")` — naming a container `grafana` makes it available at `grafana.lab.lan` with no extra label. An explicit `traefik.http.routers.*.rule` label overrides this for custom hostnames.
