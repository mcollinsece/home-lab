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
| **`homelab`** (this box) | `192.168.0.51` | VM (Debian 13) | **AI dev ground** — the subject of this doc |
| Traefik | `192.168.0.52` | LXC | Reverse proxy / load balancer |
| AdGuard | `192.168.0.53` | LXC | DNS / ad-block (replaces Pi-hole) |

### Mapping: old responsibility → new home

| Old (on the Fedora monolith) | New | Implication for this VM |
|---|---|---|
| Pi-hole (DNS, macvlan `.53`) | **AdGuard LXC `192.168.0.53`** | ❌ No DNS container here. No macvlan needed. |
| Traefik (reverse proxy + socket mount + custom SELinux policy) | **Traefik LXC `192.168.0.52`** | ❌ No Traefik here. None of the `traefik.cil`/`.te` SELinux pain carries over (and Debian uses AppArmor, not SELinux, anyway). |
| WireGuard VPN | (host/LXC decision — out of scope for this VM) | ❌ Not on the dev ground. |
| Ollama / Open WebUI / Langflow / Bedrock GW | **Remote APIs now; vLLM cluster later** | Inference is *not* hosted here yet — agents call out to Anthropic/Bedrock/OpenAI. |
| `podman-compose@.service` template + `start_podman_services.sh` | **Podman Quadlets** (systemd-native) | Clean, declarative, no third-party `podman-compose` binary to vanish on you. |

**Net effect:** this VM sheds the proxy, DNS, and VPN concerns entirely. It has exactly one job — run containerized AI workflows — which keeps it simple and disposable.

---

## 2. Current state of this VM (measured, not assumed)

| Resource | Value | Verdict |
|---|---|---|
| OS | Debian 13 trixie | ✅ Good base |
| Runtime | rootless Podman 5.4.2 (overlay) | ✅ Matches the plan |
| User | `debian` uid 1000, has `sudo` | ✅ |
| CPU / RAM | 4 vCPU / 15 GB | ✅ Fine for orchestrating remote-API agents |
| **Disk** | **8 GB total, ~5.7 GB free, no LVM** | ⛔ **Blocker — fix first** |
| GPU | virtual QEMU VGA (`1234:1111`), no passthrough | ⚠️ CPU-only; expected — inference is remote for now |
| `linger` | **off** for `debian` | ⚠️ Must enable or rootless services die on logout |
| Network | single NIC `eth0` `192.168.0.51/24` | ✅ |

### The two things that will bite you immediately

1. **8 GB disk is far too small.** AI images are heavy — a single LangGraph/Python image with its deps is often 1–3 GB, and pulling a couple of agent images plus their build cache will exhaust 5.7 GB of headroom almost instantly. **Grow the VM disk in Proxmox before building anything** (see §6 step 0). Target at least 64–128 GB; rootless Podman stores images under `~/.local/share/containers`, which lives on `/`.

2. **`linger` is disabled.** Rootless Podman services managed by your *user* systemd instance stop when you log out unless lingering is on. Enable it: `sudo loginctl enable-linger debian`.

---

## 3. Target architecture (now) and how it grows into k8s (later)

The design rule: **everything you do now should translate to a Kubernetes manifest with minimal rework.** Concretely, that means containers (not host installs), per-project images pushed to a local registry, config via env/secrets, and one-command bring-up/teardown.

```
                         ┌──────────────────────────────────────────┐
   Traefik LXC (.52) ───▶│  homelab VM (.51) — rootless Podman       │
   (only for anything    │                                          │
    you choose to expose)│   ┌────────────┐  ┌────────────┐         │
                         │   │ hermes     │  │ openclaw   │  …       │   ──▶  Anthropic /
   AdGuard LXC (.53)     │   │ (Quadlet)  │  │ (Quadlet)  │         │        Bedrock /
   resolves *.lan etc.   │   └────────────┘  └────────────┘         │        OpenAI APIs
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
| Exposure | publish a port → Traefik LXC routes it | Ingress (Traefik/nginx) |

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
├── registry/
│   └── registry.container     # Quadlet for the local image registry
├── projects/
│   ├── _template/             # copy this to start a new agent project
│   │   ├── Containerfile
│   │   ├── <name>.container   # Quadlet unit (systemd --user)
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

### Step 0 — Grow the disk (do this first, in Proxmox)
On the Proxmox host (`192.168.0.50`): resize the VM disk (e.g. to 128 GB), then on this VM grow the partition + filesystem. There's no LVM, so it's a direct `growpart` + `resize2fs`:
```bash
sudo growpart /dev/sda 1
sudo resize2fs /dev/sda1
df -h /          # confirm the new size
```
*(Snapshot the VM in Proxmox before resizing.)*

### Step 1 — Host prep (rootless Podman essentials)
```bash
sudo loginctl enable-linger debian          # services survive logout
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

### Step 6 — Exposure (only if needed)
If a workflow needs a UI/endpoint reachable on the LAN, publish a port on the container and add a route on the **Traefik LXC (`.52`)** pointing at `192.168.0.51:<port>`; add the DNS name in **AdGuard (`.53`)**. Most agent jobs need no inbound exposure at all.

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

- [ ] **Snapshot + grow the VM disk** to ≥64 GB (Proxmox), then `growpart`/`resize2fs`. *(unblocks everything)*
- [ ] `sudo loginctl enable-linger debian`.
- [ ] Add `.gitignore` (§4) and a `projects/_template/` skeleton.
- [ ] `bootstrap/setup-host.sh`: create `ai-net` + the local registry Quadlet.
- [ ] Create the `anthropic_api_key` (and any Bedrock) Podman secret from an untracked `.env`.
- [ ] Stand up **Hermes** as the first project end-to-end; prove build → push → Quadlet → run → clean teardown.
- [ ] Then OpenClaw and the first LangGraph project on the same pattern.

---

*Carried-over hygiene from the old review that still applies: pin image tags (no `:latest`), keep secrets out of git, one source of truth per project, and a real teardown path so trial-and-error doesn't accumulate.*
