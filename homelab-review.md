# Homelab Review & Rebuild Recommendations

**Host:** Fedora (kernel 7.0.11), rootless Podman 5.8.2, SELinux enforcing
**Reviewed:** 2026-06-06
**Scope:** `/home/mbc` and `/opt/podman-services`
**Author:** Claude Code (documentation + recommendations only — no changes were made to running services)

---

## ⚠️ Read this first — urgent security items

Before you do anything else with the rebuild, address these. They are live exposures, not style issues.

1. **Live AWS IAM credentials are committed in plaintext.** A long‑term access key (`AKIA…`) and secret are hardcoded in two places:
   - `/opt/podman-services/bedrockgw/docker-compose.yml` (env vars)
   - `/opt/podman-services/bedrockgw/temp_keys`

   **Rotate/revoke these keys in the AWS console now**, regardless of the rebuild. Assume they are compromised — they have been sitting in cleartext on disk and in shell history. Replace with a scoped IAM user (Bedrock-only) and inject via an untracked `.env` file or a secrets manager.

2. **WireGuard server + peer private keys and preshared key are in plaintext** under `/opt/podman-services/wireguard/config/`. Normal for a running WireGuard, but **must never be committed to git**. If you version this repo, exclude the entire `wireguard/config/` tree and regenerate keys if it was ever pushed anywhere.

3. **Weak / default credentials in service configs:**
   - Pi-hole `WEBPASSWORD: "pihole"` (`/home/mbc/pihole/docker-compose.yaml`)
   - Langflow Postgres `langflow / langflow` (`/opt/podman-services/langflow/docker-compose.yml`)
   - Open WebUI `WEBUI_AUTH=False` — the LLM chat UI has authentication disabled entirely.

---

## 1. What this homelab is

A rootless-Podman host running a handful of self-hosted services, each as its own `docker-compose.yml`, fronted by Traefik for `Host`-based routing. Services found:

| Service | Image | Purpose | Routed as |
|---|---|---|---|
| Traefik | `traefik:latest` | Reverse proxy / dashboard | dashboard on `:8080` (insecure) |
| Portainer | `portainer-ce:latest` | Container management UI | `portainer.lan` |
| Ollama | `ollama/ollama` | Local LLM runtime | `ollama.lan` |
| Open WebUI | `open-webui:v0.5.18` | Chat UI for Ollama | `openwebui.lan` |
| Langflow + Postgres | `langflowai/langflow`, `postgres:16` | LLM flow builder | `langflow.lan` |
| Bedrock Gateway | locally built `bedrock-gateway` | OpenAI-compatible proxy to AWS Bedrock | `bedrock.lan` |
| WireGuard | `linuxserver/wireguard` | VPN into the LAN | UDP `:51820` |
| Pi-hole | `pihole/pihole:latest` | DNS sinkhole / ad-block | macvlan `192.168.0.53` |

**State at review time:** every container is `Exited` — nothing is currently running. The Langflow/Postgres pair has been down ~15 months; the rest exited ~4 hours ago.

### How it's wired together

- A manually-created external Podman bridge network named **`podman`** is the shared "web" network. Most services attach to it and Traefik discovers them there.
- **Traefik discovers backends two ways at once**, inconsistently:
  - **Docker/Podman provider** via labels (`traefik.http.routers.<svc>...`) — used by Portainer, Ollama, Open WebUI, Langflow, Bedrock. These use the **`.lan`** suffix.
  - **File provider** (`dynamic.yml`) — defines `portainer.local`, `plex.local`, `deluge.local` pointing at hardcoded `192.168.0.50:<port>`. These use the **`.local`** suffix.
- Traefik reads the Podman socket directly (`/run/user/1000/podman/podman.sock` → `/var/run/docker.sock`) to do label discovery. Same for Portainer.
- DNS for the `.lan` / `.local` names is presumably handled by Pi-hole (`custom.list`), so hitting Traefik on `:80` resolves to the right backend.
- Services are meant to be kept alive by a **systemd user template unit** `podman-compose@.service` (lingering enabled), with one instance enabled per project. There's also a manual `start_podman_services.sh` bootstrap script.

---

## 2. How it was set up (mechanics & history)

- **Per-project env files** drive the systemd template. The installed unit (`/etc/systemd/user/podman-compose@.service`) reads `EnvironmentFile=/opt/podman-services/config/containers/compose/projects/%i.env`, where each `.env` sets `COMPOSE_PROJECT_DIR`, `COMPOSE_FILE`, `COMPOSE_PROJECT_NAME`. Instances are enabled for traefik, portainer, ollama, openwebui, bedrockgw, wireguard (symlinks in `~/.config/systemd/user/default.target.wants/`).
- **SELinux was fought, not configured.** To allow Traefik to use the mounted socket under enforcing SELinux, custom policy was generated:
  - `traefik.cil` / `traefik.json` (container SELinux profile)
  - `traefik_podman.te` / `.pp` (an `audit2allow` module: `allow init_t container_file_t:sock_file write`)
  - plus `security_opt: label=type:container_runtime_t` on nearly every service.
  This is the classic "got an AVC denial, ran audit2allow until it worked" pattern.
- **TLS was attempted then abandoned.** `backup_docker-compose.yaml` shows a proper Let's Encrypt setup (port 443, HTTP→HTTPS redirect, `tlschallenge`, `acme.json`). The *active* config dropped all of that — only a `:80` web entrypoint remains and `acme.json` is 0 bytes. So the current setup is **HTTP-only**.
- **Lots of trial-and-error left on disk:** `backup.service` / `backup.service1` (two unit variants with three *different* EnvironmentFile paths), `backup_docker-compose.yaml`, `backup_compose`, `backup-docker-compose`, an abandoned `wg-easy` variant, a duplicate env dir at `~/.config/containers/compose/projects/` (only traefik+portainer) that no longer matches the active `/opt` path.

---

## 3. Problems & root causes

### Architecture / correctness
1. **`podman-compose` is no longer installed** (`command not found`), but every systemd unit still calls `/usr/local/bin/podman-compose up`. On the next boot/restart **nothing will come up**. Podman 5.x ships native `podman compose` (a provider shim), which is what should be used.
2. **The file provider is misconfigured and silently dead.** `traefik.yml` sets `file.filename: /etc/traefik/traefik.yml` — it points the dynamic-file provider at the *static* config file, not at `dynamic.yml`. `dynamic.yml` is never mounted into the container and never loaded, so the `plex.local` / `deluge.local` / `portainer.local` routes don't exist. (Those backends at `192.168.0.50` may not even exist anymore.)
3. **Two naming schemes (`.lan` vs `.local`).** `.local` is reserved for mDNS (Avahi/Bonjour) and will behave unpredictably on many clients. Label routes use `.lan`; file routes use `.local`. Pick one non-reserved internal domain (e.g. `*.home.arpa` or `*.lan`).
4. **No HTTPS.** Everything (Portainer, Open WebUI, dashboards) is plain HTTP on the LAN. The working ACME config exists only in the backup file.
5. **Traefik dashboard is `insecure=true` on `:8080`** with no auth — anyone on the LAN can see/modify routing state.
6. **Open WebUI talks to Ollama the long way around** (`OLLAMA_BASE_URL=http://ollama.lan`), routing container→Traefik→container over port 80 instead of directly over the shared network (`http://ollama:11434`). Extra hop, extra failure point, and it depends on DNS + Traefik being healthy just for internal traffic.
7. **Config path drift.** Three different `EnvironmentFile` locations across the unit variants (`/opt/podman-services/config/...`, `/opt/config/...`, `~/.config/...`), and a stale duplicate env dir. Only one is real; the others are traps.
8. **Inconsistent restart policies** (`unless-stopped` vs `always` vs none) and a stray `version:` key everywhere (obsolete in Compose spec).
9. **Minor:** Ollama sets `OLLAMA_MODELS=/root/.ollama` (should be `/root/.ollama/models`); Pi-hole `ServerIP` and the macvlan IP are both `.53` but the env/compose pairing is easy to get wrong on macvlan.

### Security (beyond the urgent list)
10. **Mounting the Podman socket into Traefik and Portainer** gives those containers full control of the container runtime — a container escape there is game over. This is also *why* all the SELinux custom policy was needed. Use a **read-only socket proxy** (e.g. `tecnativa/docker-socket-proxy`) and the SELinux pain mostly disappears.
11. **Secrets live in compose files**, not in untracked env files or a secrets store (AWS keys, DB passwords, Pi-hole password).
12. **No `.gitignore` / repo hygiene.** The full upstream `bedrock-access-gateway` git repo is checked out inside the services tree, and Open WebUI's live data (`webui.db`, `chroma.sqlite3`, audit logs, model cache) sits alongside config. If this dir is ever committed, secrets and databases go with it.

### Operability
13. **No backups** of the things that matter (Pi-hole gravity DB, Open WebUI DB, Langflow Postgres, WireGuard config). A `backup.service` was sketched but only ever held a copy of the compose unit, not an actual backup job.
14. **Leftover/ambiguous files** make it unclear which config is authoritative — a future-you (or me) can't tell the live file from the dead one.
15. **Orphaned Podman networks** (`webproxy`, `podman-default-kube-network`, `langflow_langflow_net`) accumulate with no owner.

---

## 4. Recommended rebuild

### Guiding principles
- **One repo, one source of truth, secrets out of it.** A single `git` repo (e.g. `~/homelab`) with a clear layout, secrets in untracked `.env` files referenced via `env_file:`, and a real `.gitignore`. Consider `sops` + `age` if you want encrypted secrets *in* the repo.
- **Declarative and reproducible.** Prefer **Podman Quadlets** (`.container`/`.network` systemd-native units) over the `podman-compose@` template. Quadlets are the supported path on Podman 5.x, integrate cleanly with systemd, restart correctly, and don't depend on a third-party `podman-compose` binary that just vanished on you. If you'd rather stay in Compose, standardize on native `podman compose` and fix the unit `ExecStart`.

### Suggested layout
```
~/homelab/
├── .gitignore            # ignores **/secrets.env, wireguard/config, *.db, acme.json
├── README.md             # how it all fits together (this doc, kept current)
├── networks/             # quadlet .network files (edge, internal)
├── traefik/
│   ├── traefik.yml        # static config (entrypoints, providers, ACME)
│   ├── dynamic/           # dynamic config dir, actually mounted
│   └── secrets.env        # (untracked)
├── services/
│   ├── portainer/
│   ├── ollama/
│   ├── openwebui/
│   ├── langflow/
│   ├── bedrockgw/secrets.env   # (untracked) AWS creds
│   ├── pihole/secrets.env      # (untracked)
│   └── wireguard/
└── backup/               # restic/borg script + systemd timer
```

### Networking
- Two networks: **`edge`** (Traefik + anything published) and **`internal`** (DB ↔ app, Ollama ↔ Open WebUI). Put Postgres and Ollama on `internal` only; reach Ollama from Open WebUI directly as `http://ollama:11434` — no Traefik hop.
- Keep Pi-hole on macvlan as-is (it genuinely needs its own L2 identity for DNS), but document the `enp0s31f6` parent dependency clearly so it survives a NIC rename.

### Traefik (you said you want to keep it — here's how to do it better)
- **Use a socket proxy** instead of bind-mounting `podman.sock` into Traefik. `tecnativa/docker-socket-proxy` exposes a locked-down, read-only Docker API on the `internal` network; point Traefik's provider at `tcp://socket-proxy:2375`. This removes the root-equivalent mount **and** removes the need for the custom SELinux `.cil`/`.te` modules.
- **Two entrypoints with redirect:** `web` (:80 → redirect to :443) and `websecure` (:443). Re-enable the ACME resolver from your backup compose (or use an internal CA / self-signed for LAN-only with a wildcard cert).
- **One discovery mechanism.** Use the Docker-label provider for containers; only use the file provider for the genuinely external boxes (`192.168.0.50` Plex/Deluge) and mount a real `dynamic/` directory. Don't point the file provider at the static config.
- **Secure the dashboard:** `api.insecure=false`, expose it as a router on `traefik.lan` behind basic-auth or your VPN only.
- **One internal domain.** Pick `*.lan` (or `*.home.arpa`) everywhere and add the wildcard/records once in Pi-hole.

### Secrets & creds
- New scoped AWS IAM user for Bedrock; creds only in `bedrockgw/secrets.env` (untracked) or Podman secrets.
- Strong unique passwords for Pi-hole and Postgres (generate, store in a password manager).
- Turn **Open WebUI auth back on** (`WEBUI_AUTH=True`) before it's reachable from anything.

### Operability
- **Backups:** a `restic` (or `borg`) repo + systemd timer covering Pi-hole `etc-pihole`, Open WebUI `webui-data`, Langflow Postgres (via `pg_dump`), Traefik `acme.json`, and WireGuard `config`. Off-box target (NAS/S3).
- **Updates:** pin image tags (you already pin Open WebUI; do the same for Traefik, Pi-hole, Ollama instead of `:latest`) and use Renovate or a periodic `podman auto-update` with digest pinning so updates are deliberate.
- **Cleanup:** remove `backup.service*`, `backup_*compose*`, the stale `~/.config/containers/...` env dir, and prune the orphaned `webproxy` / `podman-default-kube-network` / `langflow_langflow_net` networks. Move the `bedrock-access-gateway` clone out of the services tree (build from a pinned ref in CI or a `Containerfile`, don't vendor the whole repo).

### Migration order (low-risk path)
1. Revoke the exposed AWS keys; rotate Pi-hole/Postgres passwords. *(do today)*
2. Create the new repo + `.gitignore`; move configs in, secrets to untracked `.env`.
3. Stand up Traefik + socket-proxy with TLS on the `edge` network; verify the dashboard is auth'd.
4. Migrate services one at a time as Quadlets (or fixed Compose), validating each behind Traefik before the next.
5. Add the backup timer; do a test restore.
6. Delete the old `/opt/podman-services` trial-and-error files once the new stack is proven.

---

## 5. File-by-file index (for the cleanup)

**Keep / migrate:** `traefik/{traefik.yml,dynamic.yml,acme.json}`, each service's `docker-compose.yml`, `pihole/etc-pihole/*` (data), `wireguard/config/*` (data — keep secret), `config/.../projects/*.env`.

**Delete (dead/duplicate/trial):** `/home/mbc/backup.service`, `/home/mbc/backup.service1`, `/home/mbc/start_podman_services.sh` (superseded by units/quadlets), `traefik/backup_docker-compose.yaml`, `openwebui/backup-docker-compose`, `wireguard/backup_compose`, `~/.config/containers/compose/projects/` (stale), `bedrockgw/temp_keys` (**after** rotating the key).

**Reconsider:** `traefik/{traefik.cil,traefik.json,traefik_podman.te,traefik_podman.pp}` — these SELinux modules become unnecessary once you switch to a socket proxy; remove the loaded module (`semodule -r traefik_podman`) as part of cleanup.

---

*No services were started, stopped, or modified during this review. The only action recommended for "today" is rotating the exposed AWS credentials and weak passwords.*
