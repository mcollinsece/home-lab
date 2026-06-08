# AI Dev Ground — Architecture Changes & Path Forward

**Reviewed:** 2026-06-07
**This VM:** `homelab` — Debian 13 (trixie), rootless Podman 5.4.2, user `debian` (uid 1000), `192.168.0.51`
**Supersedes:** the single-host Fedora/Podman setup described in [`homelab-review.md`](./homelab-review.md)
**Goal:** turn this VM into an agentic-AI dev ground — run Hermes, OpenClaw, and custom LangGraph projects as containers that are easy to revision and tear down. Future state: a multi-node Kubernetes cluster with local CPU models and a vLLM homelab cluster.

---

## 1. What changed since the last review

The old homelab was **one Fedora box running everything** (Traefik, Pi-hole, Ollama, Open WebUI, Langflow, Bedrock GW, WireGuard) as a pile of per-project compose files. That host has been wiped and rebuilt as **Proxmox**, and the responsibilities are now split across purpose-built guests.

### New topology

| Node | Address | Type | Role |
|---|---|---|---|
| Proxmox host | `192.168.0.50` | bare metal | Hypervisor (Dell Optiplex) |
| **`homelab`** (this box) | `192.168.0.51` | VM (Debian 13) | **AI dev ground** + **Traefik** ingress (subject of this doc) |
| ~~Traefik~~ | ~~`192.168.0.52`~~ | ~~LXC~~ | **Retired** — moved onto the `homelab` VM as a rootless Podman container (see §6) |
| AdGuard | `192.168.0.53` | LXC | DNS / ad-block (replaces Pi-hole) |

### Mapping: old responsibility → new home

| Old (on the Fedora monolith) | New | Implication for this VM |
|---|---|---|
| Pi-hole (DNS, macvlan `.53`) | **AdGuard LXC `192.168.0.53`** | ❌ No DNS container here. No macvlan needed. |
| Traefik (reverse proxy + socket mount + custom SELinux policy) | **Rootless Podman container *on this VM*** (`traefik/`) | ✅ Traefik runs here, discovering services by container **label** over the rootless Podman socket. None of the `traefik.cil`/`.te` SELinux pain carries over — Debian uses AppArmor, no relabeling needed. |
| WireGuard VPN | (host/LXC decision — out of scope for this VM) | ❌ Not on the dev ground. |
| Ollama / Open WebUI / Langflow / Bedrock GW | **Remote APIs now; vLLM cluster later** | Inference is *not* hosted here yet — agents call out to Anthropic/Bedrock/OpenAI. |
| `podman-compose@.service` template + `start_podman_services.sh` | **Podman Quadlets** (systemd-native) | Clean, declarative, no third-party `podman-compose` binary to vanish on you. |

**Net effect:** this VM sheds the DNS and VPN concerns entirely. It *does* now run **Traefik** (the `.52` LXC was retired), but Traefik's static config lives in this repo and all routing is label-based — so the VM stays reproducible/disposable: re-create it, `git pull`, start the units, done. DNS deliberately stays isolated in the AdGuard LXC so it survives any experimentation here.

---

## 2. Current state of this VM (measured, not assumed)

| Resource | Value | Verdict |
|---|---|---|
| OS | Debian 13 trixie | ✅ Good base |
| Runtime | rootless Podman 5.4.2 (overlay) | ✅ Matches the plan |
| User | `debian` uid 1000, has `sudo` | ✅ |
| CPU / RAM | 4 vCPU / 15 GB | ✅ Fine for orchestrating remote-API agents |
| **Disk** | **108 GB total, ~101 GB free, no LVM** | ✅ **Resized — ample for AI images** |
| GPU | virtual QEMU VGA (`1234:1111`), no passthrough | ⚠️ CPU-only; expected — inference is remote for now |
| `linger` | **on** for `debian` | ✅ Rootless services survive logout |
| Network | single NIC `eth0` `192.168.0.51/24` | ✅ |

### Prerequisites — both resolved ✅

1. ~~**8 GB disk is far too small.**~~ **Resolved** — the VM disk has been grown to **108 GB** (~101 GB free, all on `/`). AI images are heavy (a single LangGraph/Python image with deps is often 1–3 GB), but there's now ample headroom for many images plus build cache. Rootless Podman stores images under `~/.local/share/containers`, which lives on `/`.

2. ~~**`linger` is disabled.**~~ **Resolved** — `loginctl enable-linger debian` has been run (`Linger=yes`), so rootless Podman services managed by your *user* systemd instance now survive logout.

---

## 3. Target architecture (now) and how it grows into k8s (later)

The design rule: **everything you do now should translate to a Kubernetes manifest with minimal rework.** Concretely, that means containers (not host installs), per-project images pushed to a local registry, config via env/secrets, and one-command bring-up/teardown.

```
   LAN (*.lab.lan) ─────────┐
                            ▼
                  ┌──────────────────────────────────────────┐
                  │  homelab VM (.51) — rootless Podman       │
                  │   ┌──────────┐  :80                       │
                  │   │ Traefik  │  discovers via podman.sock  │
                  │   └────┬─────┘  routes by Host() on ai-net │
   AdGuard LXC (.53)       │                                   │
   *.lab.lan → .51   │   ┌─▼──────────┐  ┌────────────┐        │   ──▶  Anthropic /
                     │   │ hermes     │  │ openclaw   │  …      │        Bedrock /
                     │   │ (Quadlet)  │  │ (Quadlet)  │         │        OpenAI APIs
                     │   └────────────┘  └────────────┘         │
                     │   ┌────────────┐  ┌────────────┐         │
                     │   │ langgraph  │  │ local       │        │
                     │   │ project A  │  │ registry    │        │
                     │   └────────────┘  │ :5000       │        │
                     │   ai-net (internal bridge)       │        │
                     └──────────────────────────────────────────┘
```

### Now → Future mapping

| Concern | Now (single VM, Podman) | Future (k8s / multi-node) |
|---|---|---|
| Orchestration | Podman **Quadlets** (`.container`, `.network`) | Deployments / Jobs / CronJobs |
| Isolation & cleanup | one Quadlet (or `podman` unit) per project; `podman rm`/disable unit | Namespace per project; `kubectl delete ns` |
| Images | build locally → push to local registry `:5000` | same registry → cluster pulls from it |
| Config | env files | ConfigMaps |
| **Secrets** | untracked `.env` → **Podman secrets** | **k8s Secrets** (same shape) |
| Inference | **remote APIs** | **vLLM cluster** (GPU nodes) + remote APIs as fallback |
| Networking | `ai-net` internal bridge | CNI (Flannel/Cilium) + Services |
| Exposure | add `traefik.*` labels → Traefik (on this VM) routes it | Ingress (Traefik/nginx) |

Picking Podman Quadlets now (over raw compose) is deliberate: a Quadlet *is* a systemd unit and its key/value shape (`Image=`, `Environment=`, `Secret=`, `Network=`) reads almost one-to-one against a Pod spec, so the eventual port to manifests is mechanical.

---

## 4. Repository layout

One git repo (this one), secrets never in it. Keep it boring and declarative.

```
home-lab/
├── README.md                  # index → this doc + homelab-review.md
├── ai-dev-ground.md           # this file
├── homelab-review.md          # history of the old setup
├── .gitignore                 # **/*.env, !*.env.example, *.key, age keys
├── bootstrap/
│   └── setup-host.sh          # idempotent: linger, ai-net, registry, dirs
├── networks/
│   └── ai-net.network         # Quadlet: shared internal bridge (Traefik + apps)
├── traefik/
│   ├── traefik.yml            # Traefik STATIC config (label-based routing)
│   ├── traefik.container      # Quadlet for the reverse proxy
│   └── README.md              # how to expose a service + teardown
├── portainer/
│   ├── portainer.container    # Quadlet: container-management UI (portainer.lab.lan)
│   └── portainer-data.volume  # Quadlet: persistent Portainer state
├── registry/
│   └── registry.container     # Quadlet for the local image registry
├── projects/
│   ├── _template/             # copy this to start a new service (Traefik-ready)
│   │   ├── app.container      # Quadlet unit (preferred)
│   │   ├── compose.yaml       # compose alternative
│   │   ├── Containerfile      # optional, if building your own image
│   │   ├── env.example        # documented, committed
│   │   └── README.md
│   ├── hermes/
│   ├── openclaw/
│   └── langgraph-foo/
└── k8s/                       # (future) manifests the Quadlets graduate into
```

`.gitignore` must exclude real env/secret material from day one:

```gitignore
**/*.env
!**/*.env.example
!**/env.example
*.key
*.age
```

---

## 5. The per-project pattern (revision + teardown)

This is the core of "easy to revision and clean up." Every workflow — Hermes, OpenClaw, a LangGraph app — follows the same three-file shape under `projects/<name>/`.

**1. `Containerfile`** — pin a base, install deps, copy code. Tag images with a version so you can roll back:

```bash
podman build -t localhost:5000/hermes:0.1.0 projects/hermes
podman push   localhost:5000/hermes:0.1.0
```

**2. `<name>.container`** (Quadlet, installed to `~/.config/containers/systemd/`):

```ini
[Unit]
Description=Hermes agent
After=network-online.target

[Container]
Image=localhost:5000/hermes:0.1.0
Network=ai-net.network
EnvironmentFile=%h/home-lab/projects/hermes/hermes.env   # untracked
Secret=anthropic_api_key,type=env,target=ANTHROPIC_API_KEY
# AutoUpdate=registry   # opt in per project if you want pull-on-restart

[Service]
Restart=on-failure

[Install]
WantedBy=default.target
```

**3. `env.example`** — committed and documented; the real `hermes.env` is gitignored.

**Revision:** bump the image tag, rebuild/push, edit `Image=`, `systemctl --user daemon-reload && systemctl --user restart hermes`. Roll back by pointing `Image=` at the old tag — it's still in the registry.

**Teardown — genuinely clean:**
```bash
systemctl --user disable --now hermes
rm ~/.config/containers/systemd/hermes.container
systemctl --user daemon-reload
podman rmi localhost:5000/hermes:0.1.0   # optional: drop the image too
```
No leftover state, no orphaned networks (everything shares `ai-net`), nothing to hunt for later. This is exactly the rot the old setup accumulated (`backup.service`, `backup_*compose`, stale env dirs) — the one-unit-per-project rule prevents it.

For **one-shot / batch** workflows (a LangGraph job that runs and exits), skip the long-lived Quadlet and run `podman run --rm ...`, or use a `Type=oneshot` unit + a `.timer` for scheduled runs. These become k8s `Job`/`CronJob` later.

---

## 6. Setup steps (in order)

### Step 0 — Grow the disk ✅ done
The VM disk has been resized to **108 GB** (~101 GB free on `/`), so this step is complete. For reference, the resize was a direct `growpart` + `resize2fs` (no LVM):
```bash
sudo growpart /dev/sda 1
sudo resize2fs /dev/sda1
df -h /          # confirm the new size
```
*(Snapshot the VM in Proxmox before any future resize.)*

### Step 1 — Host prep (rootless Podman essentials)
```bash
sudo loginctl enable-linger debian          # ✅ done — services survive logout
# confirm subuid/subgid ranges exist for rootless (Debian usually sets these):
grep debian /etc/subuid /etc/subgid
```

### Step 2 — Internal network
```bash
podman network create ai-net
# or as a Quadlet: networks/ai-net.network  → [Network] name=ai-net
```

### Step 3 — Local registry (so images are versioned + k8s-ready)
A registry now means the future cluster pulls the *same* images you build today.
```bash
podman volume create registry-data
# registry/registry.container Quadlet running registry:2 on 127.0.0.1:5000
```
For local-only `localhost:5000` over HTTP, no TLS config is needed for pushes from this host.

### Step 4 — Secrets (untracked `.env` → Podman secrets)
Per the chosen approach — gitignored `.env` for dev convenience, promoted to a Podman secret for anything long-lived:
```bash
printf '%s' "$ANTHROPIC_API_KEY" | podman secret create anthropic_api_key -
# referenced in the Quadlet via:  Secret=anthropic_api_key,type=env,target=ANTHROPIC_API_KEY
```
These map 1:1 to `kubectl create secret` later. **Never commit the real `.env`.**

### Step 5 — First project
Copy `projects/_template/` → `projects/hermes/`, fill in the `Containerfile` and `env`, build/push, drop the Quadlet, enable it. Repeat for OpenClaw and each LangGraph app.

### Step 6 — Exposure (only if needed) — Traefik runs here now ✅
Traefik runs as a rootless Podman container on this VM (`traefik/`), discovering services by **label** over the rootless Podman socket (`%t/podman/podman.sock`). To expose a service: put it on `ai-net` and add labels — no Traefik file edits, no SSH, no sync:

```ini
ContainerName=<name>          # REQUIRED in Quadlets — else the name is `systemd-<unit>`
Network=ai-net.network        #   and the host becomes systemd-<name>.lab.lan
Label=traefik.enable=true
# Label=traefik.http.services.<name>.loadbalancer.server.port=<port>  # only if not 80
```

The hostname is derived from the container name automatically (provider
`defaultRule = Host(`{{ normalize .Name }}.lab.lan`)`), so naming a container
`grafana` makes it `grafana.lab.lan` with no `Host(...)` label. An explicit
`traefik.http.routers.*.rule` label still overrides this when you need a custom host.

Then add one wildcard DNS rewrite in **AdGuard (`.53`)**: `*.lab.lan → 192.168.0.51`, and every service is reachable at `http://<name>.lab.lan`. HTTP only for now (no TLS). Prereqs that made this work: `net.ipv4.ip_unprivileged_port_start=80` (so rootless can bind :80) and the enabled `podman.socket` user unit. Most agent jobs need no inbound exposure at all.

---

## 7. Path to the future state (k8s + vLLM)

When you add a second/third Optiplex:

1. **Install k3s** on this node first (`server`), join the others as `agent`s. k3s is the right weight for homelab and uses standard manifests.
2. **Point k3s at the existing local registry** (or migrate it into the cluster) — the images you've been building need no rebuild.
3. **Graduate Quadlets → manifests.** Each `.container` becomes a Deployment/Job; `EnvironmentFile` → ConfigMap; `Secret=` → k8s Secret; `ai-net` → a namespace + Services. Keep these under `k8s/`.
4. **vLLM cluster:** vLLM needs GPUs, which this VM doesn't have. Plan for **PCI/GPU passthrough** on the Proxmox nodes (or dedicated GPU boxes), label those nodes, and schedule vLLM `Deployment`s with `nvidia.com/gpu` requests via the device plugin. Agents then point their OpenAI-compatible base URL at the in-cluster vLLM Service instead of (or alongside) remote APIs — the only app-side change is the base URL + model name.
5. **GitOps (optional):** once manifests exist, Flux/Argo against this repo makes the cluster self-reconciling.

The single-node discipline now (containers, registry, env/secret separation, one-unit-per-project) is what makes step 3 a translation rather than a rewrite.

---

## 8. Immediate next steps

- [x] **Snapshot + grow the VM disk** — done, now 108 GB (~101 GB free). *(unblocked everything)*
- [x] `sudo loginctl enable-linger debian` — done (`Linger=yes`).
- [x] Add `.gitignore` (§4) and a `projects/_template/` skeleton (Quadlet + compose, Traefik-ready).
- [x] **`ai-net` bridge + Traefik** stood up on this VM (rootless Quadlets in `networks/`, `traefik/`); label discovery, dashboard, and default-deny all verified.
- [x] **Portainer** UI (`portainer/`) on `ai-net`, routed at `portainer.lab.lan`, persistent volume — verified.
- [ ] **AdGuard:** add the `*.lab.lan → 192.168.0.51` wildcard rewrite so hostnames resolve from other LAN clients.
- [ ] `bootstrap/setup-host.sh`: fold in the `ai-net` + Traefik + local registry setup so a rebuild is one command.
- [ ] Create the `anthropic_api_key` (and any Bedrock) Podman secret from an untracked `.env`.
- [ ] Stand up **Hermes** as the first project end-to-end; prove build → push → Quadlet → run → clean teardown.
- [ ] Then OpenClaw and the first LangGraph project on the same pattern.

---

*Carried-over hygiene from the old review that still applies: pin image tags (no `:latest`), keep secrets out of git, one source of truth per project, and a real teardown path so trial-and-error doesn't accumulate.*
