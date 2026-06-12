# home-lab

Config files and documentation for my Proxmox-based home lab.

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
    │           ├── Traefik (Podman Quadlet) — reverse proxy, label-based routing
    │           ├── Portainer (Podman Quadlet) — portainer.lab.lan
    │           └── projects/ — one Quadlet per service on ai-net
    └── ... other devices via AdGuard DHCP
```

All `*.lab.lan` names resolve via AdGuard's wildcard rewrite (`*.lab.lan → 192.168.0.51`). Traefik routes per-service using container labels.

## Documentation

**Current state**

| Doc | What it covers |
|---|---|
| [docs/current/platform.md](docs/current/platform.md) | Hardware, IPs, running services, pending items — single source of truth |

**Future plans**

| Doc | What it covers |
|---|---|
| [docs/future/ai-dev-ground.md](docs/future/ai-dev-ground.md) | AI agent stack (OpenShell, NemoClaw, NeMo), Quadlet patterns, k8s roadmap |

**Config**

| Doc | What it covers |
|---|---|
| [traefik/README.md](traefik/README.md) | How to expose a service via Traefik labels |

## Adding a new service

1. Copy `projects/_template/` → `projects/<name>/`
2. Fill in `Containerfile`, `env.example`, and `<name>.container`
3. Set `ContainerName=<name>` and `Network=ai-net.network` in the Quadlet
4. Add `Label=traefik.enable=true` — service becomes available at `<name>.lab.lan` automatically
5. Link the Quadlet: `ln -s $(pwd)/projects/<name>/<name>.container ~/.config/containers/systemd/`
6. `systemctl --user daemon-reload && systemctl --user start <name>`

See [docs/future/ai-dev-ground.md](docs/future/ai-dev-ground.md#non-agent-services-quadlet-pattern) for the full pattern including revision and teardown.

## Secrets

Real `.env` files are gitignored. Commit only `*.env.example` / `env.example`. Promote long-lived secrets to Podman secrets:

```bash
printf '%s' "$ANTHROPIC_API_KEY" | podman secret create anthropic_api_key -
```
