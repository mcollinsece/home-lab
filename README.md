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

| Doc | What it covers |
|---|---|
| [docs/network-overview.md](docs/network-overview.md) | Hardware specs, IP assignments, service roles |
| [ai-dev-ground.md](ai-dev-ground.md) | Current architecture, Quadlet patterns, k8s path |
| [homelab-review.md](homelab-review.md) | History of the old Fedora setup + rebuild recommendations |
| [traefik/README.md](traefik/README.md) | How to expose a service via Traefik labels |

## Adding a new service

1. Copy `projects/_template/` → `projects/<name>/`
2. Fill in `Containerfile`, `env.example`, and `<name>.container`
3. Set `ContainerName=<name>` and `Network=ai-net.network` in the Quadlet
4. Add `Label=traefik.enable=true` — service becomes available at `<name>.lab.lan` automatically
5. Link the Quadlet: `ln -s $(pwd)/projects/<name>/<name>.container ~/.config/containers/systemd/`
6. `systemctl --user daemon-reload && systemctl --user start <name>`

See [ai-dev-ground.md §5](ai-dev-ground.md#5-the-per-project-pattern-revision--teardown) for the full pattern including revision and teardown.

## Secrets

Real `.env` files are gitignored. Commit only `*.env.example` / `env.example`. Promote long-lived secrets to Podman secrets:

```bash
printf '%s' "$ANTHROPIC_API_KEY" | podman secret create anthropic_api_key -
```
