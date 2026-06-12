# Homelab Review — Old Fedora Setup

> **This is a historical document.** It covers the single-host Fedora setup that was wiped and replaced by the current Proxmox-based homelab in June 2026.
> For the current infrastructure state, see [network-overview.md](network-overview.md).
> For the AI agent stack plan, see [../future/ai-dev-ground.md](../future/ai-dev-ground.md).

**Host:** Fedora (kernel 7.0.11), rootless Podman 5.8.2, SELinux enforcing
**Reviewed:** 2026-06-06
**Scope:** `/home/mbc` and `/opt/podman-services`
**Author:** Claude Code (documentation + recommendations only — no changes were made to running services)

---

## ⚠️ Security issues found at review time

These were live exposures on the old host. Documented here for reference; the host has since been wiped.

1. **Live AWS IAM credentials committed in plaintext** in `/opt/podman-services/bedrockgw/docker-compose.yml` and `bedrockgw/temp_keys`. Keys should be rotated/revoked if not already done.

2. **WireGuard private keys in plaintext** under `/opt/podman-services/wireguard/config/`. Never commit these; regenerate if they were ever pushed to a repo.

3. **Weak / default credentials:**
   - Pi-hole `WEBPASSWORD: "pihole"`
   - Langflow Postgres `langflow / langflow`
   - Open WebUI `WEBUI_AUTH=False` — authentication disabled entirely

---

## 1. What this homelab was

A rootless-Podman host running a handful of self-hosted services, each as its own `docker-compose.yml`, fronted by Traefik for `Host`-based routing.

| Service | Image | Purpose | Routed as |
|---|---|---|---|
| Traefik | `traefik:latest` | Reverse proxy / dashboard | dashboard on `:8080` (insecure) |
| Portainer | `portainer-ce:latest` | Container management UI | `portainer.lan` |
| Ollama | `ollama/ollama` | Local LLM runtime | `ollama.lan` |
| Open WebUI | `open-webui:v0.5.18` | Chat UI for Ollama | `openwebui.lan` |
| Langflow + Postgres | `langflowai/langflow`, `postgres:16` | LLM flow builder | `langflow.lan` |
| Bedrock Gateway | locally built | OpenAI-compatible proxy to AWS Bedrock | `bedrock.lan` |
| WireGuard | `linuxserver/wireguard` | VPN into the LAN | UDP `:51820` |
| Pi-hole | `pihole/pihole:latest` | DNS sinkhole / ad-block | macvlan `192.168.0.53` |

**State at review time:** every container was `Exited` — nothing running. The Langflow/Postgres pair had been down ~15 months; the rest exited ~4 hours prior.

### How it was wired

- A manually-created external Podman bridge network named **`podman`** was the shared "web" network. Traefik discovered containers there.
- **Traefik used two discovery mechanisms inconsistently:** Docker/Podman provider via labels (`.lan` suffix) and a file provider pointing at the *static* config file instead of `dynamic.yml` — meaning the file-provider routes never actually loaded.
- Services were managed by a **systemd user template unit** `podman-compose@.service`, with one instance per project. `podman-compose` itself was no longer installed, so nothing would restart on boot.
- DNS was handled by Pi-hole running on macvlan at `192.168.0.53`.

---

## 2. How it was set up (mechanics & history)

- **Per-project env files** drove the systemd template at `/etc/systemd/user/podman-compose@.service`, reading `EnvironmentFile=/opt/podman-services/config/containers/compose/projects/%i.env`.
- **SELinux was fought, not configured.** Custom policy was generated with `audit2allow` (`traefik.cil`, `traefik_podman.te/.pp`) to allow Traefik to use the Podman socket under enforcing SELinux. The root issue was mounting the full Podman socket into containers.
- **TLS was attempted then abandoned.** A proper Let's Encrypt setup existed in `backup_docker-compose.yaml` but the active config dropped to HTTP-only with a 0-byte `acme.json`.
- **Lots of trial-and-error left on disk:** multiple `backup.service` variants with three different `EnvironmentFile` paths, `backup_docker-compose.yaml`, stale duplicate env dirs. No way to tell live config from dead config.

---

## 3. Problems & root causes

### Architecture / correctness
1. `podman-compose` uninstalled but all systemd units still called it — nothing would start on reboot.
2. File provider misconfigured — pointed at the static config file, not `dynamic.yml`. `dynamic.yml` was never loaded.
3. Two naming schemes (`.lan` vs `.local`) — `.local` is reserved for mDNS and behaves unpredictably.
4. No HTTPS — only plain HTTP on the LAN.
5. Traefik dashboard `insecure=true` on `:8080` with no auth.
6. Open WebUI called Ollama via Traefik (`http://ollama.lan`) instead of directly over the shared network (`http://ollama:11434`) — extra hop, extra failure point.
7. Config path drift — three different `EnvironmentFile` locations; only one was real.
8. Inconsistent restart policies and stray `version:` keys (obsolete in Compose spec).

### Security
9. Full Podman socket mounted into Traefik and Portainer — a container escape is game over. Root cause of all the SELinux custom policy work.
10. Secrets in compose files, not in untracked env files or a secrets store.
11. No `.gitignore` — live databases and credentials sat alongside config files.

### Operability
12. No backups of anything that mattered (Pi-hole gravity DB, Open WebUI DB, Langflow Postgres, WireGuard keys).
13. Leftover/ambiguous files made it impossible to identify authoritative config.
14. Orphaned Podman networks accumulated with no owner.

---

## 4. What was done (the rebuild)

The Fedora host was wiped and rebuilt as **Proxmox** in June 2026. Responsibilities were split across purpose-built guests:

- DNS/DHCP → **AdGuard Home** LXC at `192.168.0.53` (replaced Pi-hole, isolated from experimentation)
- All workloads → **Debian 13 VM** at `192.168.0.51` using rootless Podman Quadlets (systemd-native, no `podman-compose` dependency)
- Traefik moved onto the VM itself, using label-based discovery over the Podman socket

Key improvements applied from the lessons in §3:
- One repo, one source of truth, `.gitignore` from day one — secrets never committed
- Podman Quadlets over compose — no third-party binary, clean systemd integration
- One internal domain (`*.lab.lan`) everywhere
- One Quadlet per project — guaranteed clean teardown

See [network-overview.md](network-overview.md) for what's currently running and [../future/ai-dev-ground.md](../future/ai-dev-ground.md) for the AI agent stack plan.

---

## 5. File-by-file index (old Fedora setup — for reference)

**Keep / migrate:** `traefik/{traefik.yml,dynamic.yml,acme.json}`, each service's `docker-compose.yml`, `pihole/etc-pihole/*`, `wireguard/config/*` (keep secret, never commit).

**Delete:** `/home/mbc/backup.service`, `/home/mbc/backup.service1`, `/home/mbc/start_podman_services.sh`, `traefik/backup_docker-compose.yaml`, `openwebui/backup-docker-compose`, `wireguard/backup_compose`, `~/.config/containers/compose/projects/` (stale), `bedrockgw/temp_keys` (after rotating the key).

**Reconsider:** `traefik/{traefik.cil,traefik.json,traefik_podman.te,traefik_podman.pp}` — SELinux modules unnecessary once you switch to a socket proxy; remove with `semodule -r traefik_podman`.
