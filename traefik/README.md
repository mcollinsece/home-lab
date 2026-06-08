# Traefik (rootless Podman, on the `homelab` VM)

Reverse proxy for LAN-facing services. Routing is **100% container labels** via the
Podman socket — adding a service never touches `traefik.yml`.

- **Entry:** `http://<name>.lab.lan` (HTTP only, no TLS)
- **Dashboard:** `http://traefik.lab.lan/dashboard/`
- **Discovery:** `exposedByDefault=false` — only containers with `traefik.enable=true` are routed.

## Files
| File | Role |
|---|---|
| `traefik.yml` | static config (entrypoint `:80`, Podman provider, dashboard) |
| `traefik.container` | Quadlet unit; symlinked into `~/.config/containers/systemd/` |
| `../networks/ai-net.network` | the shared bridge Traefik and apps sit on |

## Host prerequisites (already applied)
```bash
# rootless can bind :80
echo 'net.ipv4.ip_unprivileged_port_start=80' | sudo tee /etc/sysctl.d/99-unprivileged-ports.conf
sudo sysctl --system
# Podman API socket for label discovery
systemctl --user enable --now podman.socket
```

## Install / start
```bash
ln -sf ~/home-lab/networks/ai-net.network  ~/.config/containers/systemd/ai-net.network
ln -sf ~/home-lab/traefik/traefik.container ~/.config/containers/systemd/traefik.container
systemctl --user daemon-reload
systemctl --user start traefik.service
```

## Expose a service
Hostnames are derived from the **container name** via the provider's `defaultRule`
(`Host(\`{{ normalize .Name }}.lab.lan\`)`). So the whole workflow is: put the
container on `ai-net`, name it, and opt it in — no `Host(...)` rule needed.

```ini
ContainerName=grafana          # REQUIRED in Quadlets — else name is `systemd-<unit>`
Network=ai-net.network         #   → would resolve to systemd-grafana.lab.lan
Label=traefik.enable=true
# Label=traefik.http.services.grafana.loadbalancer.server.port=3000  # only if not :80
```
→ live at `http://grafana.lab.lan`.

Need a non-default host (e.g. a path, multiple hosts)? An explicit label overrides
`defaultRule`:
```ini
Label=traefik.http.routers.grafana.rule=Host(`metrics.lab.lan`)
```

Then ensure AdGuard has `*.lab.lan → 192.168.0.51` (the linchpin — without it, names
don't resolve for other clients).

Verify without DNS:
```bash
curl -H 'Host: grafana.lab.lan' http://localhost/
```

## Update / roll back
Bump the tag in `traefik.container` (`Image=docker.io/traefik:v3.x`), then:
```bash
systemctl --user daemon-reload && systemctl --user restart traefik.service
```

## Teardown (clean)
```bash
systemctl --user disable --now traefik.service
rm ~/.config/containers/systemd/traefik.container ~/.config/containers/systemd/ai-net.network
systemctl --user daemon-reload
podman network rm ai-net          # optional
podman rmi docker.io/traefik:v3.3 # optional
```
