# OpenShell (agent sandboxes, rootless Podman)

[OpenShell](https://github.com/NVIDIA/OpenShell) runs sandboxed coding agents
(Claude Code, Codex, etc.) as isolated containers on the homelab VM's existing
**rootless Podman** — no Docker. Phase 2 of
[../docs/future/ai-dev-ground.md](../docs/future/ai-dev-ground.md).

## Files
| File | Role |
|---|---|
| `gateway.env` | gateway env overrides; symlinked to `~/.config/openshell/gateway.env` |
| `policies/claude-code.yaml` | network policy for the Claude Code sandbox (subscription/OAuth) |

The OpenShell binary, its `openshell-gateway` systemd `--user` service, and the
mTLS certs under `~/.local/state/openshell/` are installed by
[`../bootstrap/setup-host.sh`](../bootstrap/setup-host.sh) — not committed here.

## Why `gateway.env` matters (the one gotcha)
The Debian `.deb` install binds the gateway to `127.0.0.1`, but the Podman driver
needs `0.0.0.0:17670`: sandboxes reach the gateway over the host bridge
(`host.containers.internal`), not loopback. Without it, sandboxes provision but
fail with `Policy fetch failed`. `gateway.env` sets `OPENSHELL_DRIVERS=podman`
and `OPENSHELL_BIND_ADDRESS=0.0.0.0`. mTLS still gates the wider bind.

> `openshell doctor check` always errors on Docker even when the Podman driver is
> active and working — cosmetic. Confirm the real backend in the gateway log:
> `journalctl --user -u openshell-gateway | grep 'compute driver'`.

## Reinstall / reproduce
```bash
~/home-lab/bootstrap/setup-host.sh        # installs OpenShell + links gateway.env
```

## (Re)create the Claude Code sandbox
```bash
openshell sandbox create --name claude-code --no-auto-providers \
    --policy ~/home-lab/openshell/policies/claude-code.yaml -- claude
# first run only — authenticate the Max/Pro subscription:
openshell sandbox connect claude-code
#   inside: claude login   (browser OAuth)  then  claude
```

## Everyday commands
```bash
openshell sandbox list
openshell sandbox connect claude-code
openshell policy get claude-code --full
openshell logs claude-code --tail
openshell term                                  # live TUI
```

Sandboxes are **outbound-only** — no Traefik exposure needed. Sandbox state is
ephemeral; the durable, reproducible parts are this dir + `setup-host.sh`.
