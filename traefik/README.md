# Traefik (Docker Compose, on the `homelab` VM)

Reverse proxy for LAN-facing services. Routing is **100% container labels** via the
Docker socket — adding a service never touches `traefik.yml`.

- **Entry:** `http://<name>.lab.lan` → permanent redirect to HTTPS
- **HTTPS:** `https://<name>.lab.lan` — mkcert wildcard cert (`*.lab.lan`, expires 2028-09-13)
- **Dashboard:** `https://traefik.lab.lan`
- **Discovery:** `exposedByDefault=false` — only containers with `traefik.enable=true` are routed.

## Files

| File | Role |
|---|---|
| `traefik.yml` | static config (entrypoints :80/:443, Docker provider, dashboard) |
| `tls.yml` | dynamic TLS config loaded by the file provider; sets wildcard cert as default |
| `certs/` | mkcert wildcard cert + CA (keys gitignored via `*-key.pem`) |
| `../docker/compose.yml` | defines the Traefik service (image, socket mount, ports, labels) |

## Start / restart

```bash
# All services together
docker compose -f ~/home-lab/docker/compose.yml up -d

# Traefik only
docker compose -f ~/home-lab/docker/compose.yml restart traefik

# Logs
docker compose -f ~/home-lab/docker/compose.yml logs -f traefik
```

## Expose a service

Hostnames are derived from the **container name** via the provider's `defaultRule`
(`Host(\`{{ normalize .Name }}.lab.lan\`)`). The whole workflow is: put the container
on `ai-net`, name it, and opt it in — no explicit `Host(...)` rule needed.

**In a Docker Compose file:**
```yaml
services:
  grafana:
    container_name: grafana       # REQUIRED — hostname comes from this
    networks: [ai-net]
    labels:
      - traefik.enable=true
      # Only needed if the container doesn't listen on :80:
      # - traefik.http.services.grafana.loadbalancer.server.port=3000

networks:
  ai-net:
    external: true                # join the shared bridge; don't create a new one
```
→ live at `https://grafana.lab.lan`.

Need a custom host (e.g. a path, multiple hosts)? An explicit label overrides `defaultRule`:
```yaml
labels:
  - traefik.http.routers.grafana.rule=Host(`metrics.lab.lan`)
```

Verify without DNS:
```bash
curl -k -H 'Host: grafana.lab.lan' https://localhost/
```

## NemoClaw / static routes + dashboard workaround

NemoClaw-managed containers (and the dashboard) don't reliably get (or the Docker provider doesn't load) labels because of a persistent "client version 1.24 too old" error with the current Docker daemon (even with DOCKER_API_VERSION=1.41). We rely on the file provider (directory: /etc/traefik/dynamic, watch: true) + static .yml files.

Pre-placed during session:
- `traefik/dynamic/openclaw-nemoclaw.yml` (routes openclaw.lab.lan → 127.0.0.1:18789; see todos for Bad Gateway troubleshooting).
- `traefik/dynamic/traefik-dashboard.yml` (static router for traefik.lab.lan → api@internal; added so the dashboard works even when the Docker provider is broken).

Example (the openclaw one):

```yaml
# traefik/dynamic/openclaw-nemoclaw.yml
http:
  routers:
    openclaw:
      rule: "Host(`openclaw.lab.lan`)"
      entrypoints: [websecure]
      tls: {}
      service: openclaw
  services:
    openclaw:
      loadBalancer:
        servers:
          - url: "http://127.0.0.1:18789"
```

No restart needed — Traefik hot-reloads file provider changes. The original container labels for the dashboard are still in docker/compose.yml but are secondary; the static file takes precedence for reliability.

## Update Traefik

Bump the image tag in `docker/compose.yml` (`image: docker.io/traefik:v3.x`), then:
```bash
docker compose -f ~/home-lab/docker/compose.yml pull traefik
docker compose -f ~/home-lab/docker/compose.yml up -d traefik
```

## Regenerate the wildcard cert

```bash
CAROOT=~/home-lab/traefik/certs/ca mkcert \
  -cert-file ~/home-lab/traefik/certs/_wildcard.lab.lan.pem \
  -key-file  ~/home-lab/traefik/certs/_wildcard.lab.lan-key.pem \
  "*.lab.lan"
docker compose -f ~/home-lab/docker/compose.yml restart traefik
```

Clients don't need to reinstall the CA — only the leaf cert changed.
