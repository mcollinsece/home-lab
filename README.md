# home-lab

A self-hosted **ground for running autonomous coding agents** — Claude Code today,
Codex / Gemini / an always-on OpenClaw assistant next — each boxed in its own
isolated sandbox, on a Proxmox VM that's deliberately built to graduate to a real
cluster later.

## Why this exists

I want to run capable coding agents *autonomously* — long-horizon, unattended,
sometimes overnight — without handing a model the keys to my network or my host.
Off-the-shelf "agent in a Docker container" setups give you isolation **or**
convenience, rarely both, and they leak credentials into the workspace the moment
the agent can read a file. This repo is the opposite trade: maximum isolation with
the agent none the wiser.

The engine is **[NVIDIA OpenShell](https://github.com/NVIDIA/OpenShell)** — a
sandbox runtime that runs each agent (Claude Code, Codex, OpenCode, Copilot, and
eventually **OpenClaw** as an always-on assistant) in its own container with a
**deny-by-default network policy**. The agent gets a normal shell; the gateway
decides what it's allowed to reach.

### What's actually unique here

- **The agent never sees a credential it could exfiltrate, yet auth still works.**
  Secrets live outside the sandbox or are scoped to it deliberately; egress is an
  explicit allowlist (host:port + binary identity), so even a fully compromised
  agent can only talk to the handful of endpoints its policy names.
- **Rootless Podman, no Docker, no host root.** Each sandbox is a rootless
  container in its own user/mount/PID/network namespaces, mapped under an
  unprivileged user. The same runtime already serving Traefik/Portainer — one
  network model, not a Docker island bolted on.
- **Per-project backend switching with a single `cd`.** A project that opts in via
  `.claude/settings.json` runs on **Amazon Bedrock**; everywhere else falls back to
  the **Claude Max/Pro subscription**. Interactive work on the subscription,
  unattended/batch work on Bedrock — no re-auth, no rebuild. (Live today — see
  [ai-dev-ground.md › Phase 3](docs/future/ai-dev-ground.md).)
- **Built to migrate, on purpose.** This OptiPlex is a *transitional* dev host.
  Supporting services are Podman **Quadlets** whose key/value shape maps almost
  1:1 to Kubernetes manifests; images go through a local registry; inference is
  remote. The path to k3s + vLLM on a bigger box is a port, not a rewrite.

### Status at a glance

| Capability | State |
|---|---|
| Reverse proxy + dashboards (Traefik, Portainer) on `*.lab.lan` | ✅ live |
| OpenShell gateway on rootless Podman, deny-by-default sandboxes | ✅ live |
| Claude Code sandbox — Max/Pro subscription | ✅ live |
| Per-project subscription ↔ **Bedrock** dual-auth | ✅ live (Phase 3) |
| Codex + Gemini CLI sandboxes | ☐ roadmap (Phase 4) |
| Always-on **OpenClaw** assistant | ☐ roadmap (Phase 5) |
| k3s + vLLM on a second node | ☐ roadmap |

Full vision, phases, and the k8s roadmap: **[docs/future/ai-dev-ground.md](docs/future/ai-dev-ground.md)**.
Current built state: **[docs/current/platform.md](docs/current/platform.md)**.

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
    │           ├── OpenShell gateway (systemd --user) — :17670, deny-by-default
    │           │     └── agent sandboxes (Podman) — outbound-only, per-agent policy
    │           └── projects/ — one Quadlet per service on ai-net
    └── ... other devices via AdGuard DHCP
```

`*.lab.lan` names resolve via AdGuard's wildcard rewrite (`*.lab.lan → 192.168.0.51`);
Traefik routes per-service by container label. Agent sandboxes are **outbound-only**
— they make API calls out, nothing routes in, so they need no Traefik entry.

## Documentation

**Current state**

| Doc | What it covers |
|---|---|
| [docs/current/platform.md](docs/current/platform.md) | Hardware, IPs, running services, sandbox lifecycle — single source of truth |
| [docs/current/todos.md](docs/current/todos.md) | Human punchlist: manual/sensitive/interactive steps + next phases |

**Future plans**

| Doc | What it covers |
|---|---|
| [docs/future/ai-dev-ground.md](docs/future/ai-dev-ground.md) | The agent stack (OpenShell → Codex/Gemini → OpenClaw → NeMo), dual-auth, sandbox lifecycle, Quadlet patterns, k8s roadmap |

**Config**

| Doc | What it covers |
|---|---|
| [openshell/README.md](openshell/README.md) | Agent sandboxes on rootless Podman — gateway gotchas, sandbox lifecycle |
| [traefik/README.md](traefik/README.md) | How to expose a service via Traefik labels |
| [bootstrap/TROUBLESHOOTING.md](bootstrap/TROUBLESHOOTING.md) | OpenShell/host rebuild failure modes and fixes |

## Reproduce the host

This server is transitional — rebuild from a clean checkout:

```bash
git clone <repo> ~/home-lab && ~/home-lab/bootstrap/setup-host.sh
```

[`bootstrap/setup-host.sh`](bootstrap/setup-host.sh) is idempotent: base packages,
Node 22, linger, Podman socket, Quadlet symlinks, OpenShell (pinned), and the
git-managed `gateway.env`. **Sensitive/interactive bits are not scripted** — agent
sandbox creation, `claude login`, and Bedrock keys are manual post-steps tracked in
[todos.md](docs/current/todos.md). When a rebuild misbehaves, see
[bootstrap/TROUBLESHOOTING.md](bootstrap/TROUBLESHOOTING.md).

## Adding a new service

1. Copy `projects/_template/` → `projects/<name>/`
2. Fill in `Containerfile`, `env.example`, and `<name>.container`
3. Set `ContainerName=<name>` and `Network=ai-net.network` in the Quadlet
4. Add `Label=traefik.enable=true` — service becomes available at `<name>.lab.lan` automatically
5. Link the Quadlet: `ln -s $(pwd)/projects/<name>/<name>.container ~/.config/containers/systemd/`
6. `systemctl --user daemon-reload && systemctl --user start <name>`

See [docs/future/ai-dev-ground.md](docs/future/ai-dev-ground.md#non-agent-services-quadlet-pattern)
for the full pattern including revision and teardown.

## Secrets

Real `.env` files are gitignored — commit only `*.env.example` / `env.example`.
There are **two distinct secret stores**, by design:

- **Podman secrets** for Quadlet services (long-lived, host-managed):
  ```bash
  printf '%s' "$ANTHROPIC_API_KEY" | podman secret create anthropic_api_key -
  ```
- **Sandbox-resident creds** for agents — the Max/Pro subscription token (from
  `claude login`) and AWS Bedrock keys live *inside* the sandbox, never in git.
  A snapshot revert or sandbox rebuild wipes them; re-add per
  [todos.md](docs/current/todos.md).
