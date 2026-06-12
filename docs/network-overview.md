# Home Lab Network Overview

## Physical Hardware

### Proxmox Host
- **Device:** Dell OptiPlex 7050 Micro (Renewed)
- **CPU:** Intel Quad Core i5-6500T (up to 3.1GHz)
- **RAM:** 16GB DDR4
- **Storage:** 256GB SSD
- **OS:** Proxmox VE
- **IP:** `192.168.0.50:8006`

## Network Services

### AdGuard Home
- **Type:** LXC Container (on Proxmox)
- **IP:** `192.168.0.53`
- **Roles:**
  - DHCP server for the entire network
  - DNS server for the entire network
  - Ad/tracker blocking
- **DNS wildcard:** `*.lab.lan` → `192.168.0.51` (routes all lab hostnames to Traefik)

### Debian VM (`homelab`)
- **Type:** Proxmox VM
- **OS:** Debian 13 (trixie)
- **IP:** `192.168.0.51`
- **CPU/RAM:** 4 vCPU / 15 GB
- **Disk:** 108 GB
- **Role:** Primary workload host — all containers, jobs, and services run here

## Services on the Debian VM

### Traefik (Reverse Proxy)
- **Type:** Podman Quadlet (systemd-native)
- **Discovery:** Label-based, via rootless Podman socket (`%t/podman/podman.sock`)
- **Routing:** Container name auto-maps to `<name>.lab.lan`; override with explicit `traefik.http.routers.*` labels
- **DNS integration:** AdGuard resolves `*.lab.lan` → `192.168.0.51`, Traefik handles per-service routing

### Portainer
- **Type:** Podman Quadlet
- **URL:** `portainer.lab.lan`
- **Purpose:** Container management UI

### Projects (per-service Quadlets)
Each service under `projects/` runs as its own Podman Quadlet on the shared `ai-net` bridge network. See [`projects/_template/`](../projects/_template/) for the standard pattern.

## Network Topology

```
Internet
    │
  Router
    │
  LAN (192.168.0.0/24)
    ├── 192.168.0.50  Proxmox host (Dell OptiPlex 7050 Micro)
    │     ├── 192.168.0.53  AdGuard Home (LXC) — DHCP + DNS, *.lab.lan wildcard
    │     └── 192.168.0.51  homelab VM (Debian 13) — primary workload host
    │           ├── Traefik (Quadlet) — label-based reverse proxy
    │           ├── Portainer (Quadlet) — portainer.lab.lan
    │           └── projects/ — one Quadlet per service on ai-net bridge
    └── ... other devices via AdGuard DHCP
```

## DNS / Routing Flow

1. Client requests `<service>.lab.lan`
2. AdGuard resolves `*.lab.lan` → `192.168.0.51`
3. Traefik receives the request and routes to the matching Podman container by label
